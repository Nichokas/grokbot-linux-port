#!/usr/bin/env bash
set -euo pipefail

# port.sh — produce Linux artefacts from a Grok Bot Windows distribution
#
# Takes a Grok Bot version (e.g. 0.19.0), downloads the win32 NSIS installer,
# extracts the embedded Electron application without Wine (7z x app-64.7z),
# fuses it with the official Electron 42.1.0 Linux binary, rebuilds the six
# native modules against the target Electron, and assembles distributable
# artefacts (tar.gz always; AppImage when tooling is available).
#
# Usage:
#   scripts/port.sh 0.19.0
#   scripts/port.sh --electron-version 42.1.0 0.19.0
#
# Prerequisites (Actions and local): 7z/p7zip-full, curl, unzip, nodejs 22,
# python3 + make + g++ (for node-gyp), asar (via @electron/asar).
#
# The six native modules requiring rebuild against Electron 42.1.0:
#   better-sqlite3, cursor-proclist, tree-sitter, tree-sitter-bash,
#   tree-chunk-napi, whichlang-node
# cf. nativeModule rebuild contract in the porting analysis.

ELECTRON_VERSION_DEFAULT="42.1.0"
ELECTRON_VERSION="${ELECTRON_VERSION_DEFAULT}"
NATIVE_MODULES=(
  "better-sqlite3"
  "cursor-proclist"
  "tree-sitter"
  "tree-sitter-bash"
  "tree-chunk-napi"
  "whichlang-node"
)

WIN32_URL_TEMPLATE="https://downloads.cursor.com/grokbot/stable/win32-x64/%s/Grok_Bot_%s_Setup.exe"
DARWIN_URL_TEMPLATE="https://downloads.cursor.com/grokbot/stable/darwin-x64/%s/Grok_Bot_%s_x64.dmg"
ELECTRON_URL_TEMPLATE="https://github.com/electron/electron/releases/download/v%s/electron-v%s-linux-x64.zip"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <version>

Options:
  --electron-version <ver>  Target Electron version (default: ${ELECTRON_VERSION_DEFAULT})
  -h, --help                Show this help

Example:
  $(basename "$0") 0.19.0
  $(basename "$0") --electron-version 42.1.0 0.19.0
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --electron-version)
        ELECTRON_VERSION="${2:?--electron-version requires a value}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "error: unknown option $1" >&2
        usage >&2
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -ne 1 ]]; then
    echo "error: exactly one <version> argument is required" >&2
    usage >&2
    exit 1
  fi

  GROK_VERSION="$1"

  if ! [[ "${GROK_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version '${GROK_VERSION}' does not match x.y.z" >&2
    exit 1
  fi
}

check_prereqs() {
  local missing=()
  for cmd in curl 7z unzip node npm npx; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      # p7zip on Debian provides 7za/7zr, not always 7z — probe alternatives
      if [[ "${cmd}" == "7z" ]] && { command -v 7za >/dev/null 2>&1 || command -v 7zr >/dev/null 2>&1; }; then
        continue
      fi
      missing+=("${cmd}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "error: missing required commands: ${missing[*]}" >&2
    echo "hint: sudo apt-get install -y p7zip-full curl unzip build-essential python3" >&2
    exit 1
  fi
}

resolve_7z() {
  if command -v 7z >/dev/null 2>&1; then
    echo "7z"
  elif command -v 7za >/dev/null 2>&1; then
    echo "7za"
  else
    echo "7zr"
  fi
}

download_with_retry() {
  local url="$1" dest="$2"
  echo "Downloading ${url}" >&2
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 600 \
    -o "${dest}" "${url}"
}

# fetch_cached — download_with_retry backed by GROKBOT_CACHE_DIR (CI points it
# at a Namespace cache volume): PR smoke builds and dispatch rebuilds skip the
# multi-hundred-MB win32/Electron fetches. Cache population lands via atomic
# rename so a concurrent job can never observe a torn copy.
fetch_cached() {
  local url="$1" dest="$2"
  local name cached
  name="$(basename "${dest}")"
  if [[ -n "${GROKBOT_CACHE_DIR:-}" ]]; then
    cached="${GROKBOT_CACHE_DIR}/${name}"
    if [[ -s "${cached}" ]]; then
      echo "Using cached ${name} ($(du -h "${cached}" | cut -f1))" >&2
      cp "${cached}" "${dest}"
      return 0
    fi
  fi
  if ! download_with_retry "${url}" "${dest}"; then
    return 1
  fi
  if [[ -n "${GROKBOT_CACHE_DIR:-}" ]]; then
    mkdir -p "${GROKBOT_CACHE_DIR}"
    # Writer-unique temp: a shared ".${name}.tmp" would let one job's mv
    # publish another job's still-in-flight cp as a truncated archive.
    local tmp
    tmp="$(mktemp "${GROKBOT_CACHE_DIR}/.${name}.tmp.XXXXXX")"
    cp "${dest}" "${tmp}"
    mv -f "${tmp}" "${cached}"
    echo "Cached ${name} ($(du -h "${dest}" | cut -f1)) for future runs" >&2
  fi
}

main() {
  parse_args "$@"
  check_prereqs

  local SEVEN_ZIP
  SEVEN_ZIP="$(resolve_7z)"

  local workdir outdir electron_dir app_staging
  workdir="$(mktemp -d -t grokbot-port-XXXXXX)"
  outdir="${REPO_ROOT}/dist"
  mkdir -p "${outdir}"

  echo "Grok Bot version  : ${GROK_VERSION}" >&2
  echo "Electron version  : ${ELECTRON_VERSION}" >&2
  echo "Work directory    : ${workdir}" >&2
  echo "Output directory  : ${outdir}" >&2

  # shellcheck disable=SC2064
  trap "echo \"Cleaning workdir ${workdir}\" >&2; rm -rf \"${workdir}\"" EXIT

  # -----------------------------------------------------------------------
  # 1. Fetch win32 NSIS installer — primary source of truth
  # -----------------------------------------------------------------------
  local win32_url installer_path
  # shellcheck disable=SC2059
  win32_url="$(printf "${WIN32_URL_TEMPLATE}" "${GROK_VERSION}" "${GROK_VERSION}")"
  installer_path="${workdir}/Grok_Bot_${GROK_VERSION}_Setup.exe"

  if ! fetch_cached "${win32_url}" "${installer_path}"; then
    echo "warn: win32 installer download failed for ${GROK_VERSION}" >&2
    # Opportunistic darwin fallback — useful to distinguish propagation delay
    # from genuine non-existence when diagnosing failures.
    local darwin_url
    darwin_url="$(printf "${DARWIN_URL_TEMPLATE}" "${GROK_VERSION}" "${GROK_VERSION}")"
    echo "hint: darwin artifact would be at ${darwin_url}" >&2
    exit 1
  fi
  echo "Fetched win32 installer: $(du -h "${installer_path}" | cut -f1)" >&2

  # -----------------------------------------------------------------------
  # 2. Extract NSIS installer without Wine
  #
  # The installer is an NSIS self-extractor. The payload of interest is
  # app-64.7z (or legacy app-32.7z). 7z can extract NSIS archives directly:
  #   7z x Grok_Bot_xxx_Setup.exe
  # then:
  #   7z x app-64.7z
  # No Wine component is ever invoked.
  #
  # Layout caveat: where the payload lands is upstream-defined and has
  # changed over time. Older installers placed app-64.7z at the extraction
  # root; current ones (observed 0.20.0) nest it under $PLUGINSDIR/.
  # Hard-coding either location is fragile — locate the archive recursively.
  # -----------------------------------------------------------------------
  local nsis_dir app_archive
  nsis_dir="${workdir}/nsis"
  mkdir -p "${nsis_dir}"
  pushd "${nsis_dir}" >/dev/null
  echo "Extracting NSIS installer (wine-less)..." >&2
  # Not redirected to /dev/null: 7z warnings (e.g. "BadCmd=11" on NSIS-3
  # Unicode under p7zip 16.02) are the only extraction diagnostics available
  # in CI logs, and stdout carries no secrets in this pipeline.
  "${SEVEN_ZIP}" x -y "${installer_path}" >&2

  # NSIS applies restrictive directory modes (drwx------) that would break a
  # non-root consumer of the staged tree; normalise to standard permissions.
  find . -type d -exec chmod 755 {} + 2>/dev/null || true

  # Locate the embedded 7z payload wherever 7z placed it (root, $PLUGINSDIR,
  # or future nesting). -print -quit stops at the first hit; identical names
  # deeper in the tree are installer scratch copies, not additional payloads.
  app_archive="$(find . -type f \( -name 'app-64.7z' -o -name 'app-32.7z' \) -print -quit 2>/dev/null || true)"
  if [[ -z "${app_archive}" ]]; then
    echo "error: no app-64.7z or app-32.7z found after NSIS extraction" >&2
    echo "contents of nsis dir (recursive, depth 3):" >&2
    find . -maxdepth 3 | sort >&2
    exit 1
  fi
  # 7z x on NSIS can exit 0 with warnings while leaving a truncated payload.
  # Validate the 7z magic (37 7A BC AF 27 1C) before trusting the archive —
  # a corrupt app-64.7z would otherwise fail later with a far less clear error.
  if [[ "$(head -c 6 "${app_archive}" | od -An -tx1 | tr -d ' \n')" != "377abcaf271c" ]]; then
    echo "error: ${app_archive} does not have a valid 7z header — NSIS extraction likely truncated" >&2
    echo "hint: re-run; if persistent, the upstream installer layout changed and the locate logic needs updating" >&2
    exit 1
  fi
  echo "Found embedded archive: ${app_archive} (7z magic OK)" >&2

  local app_dir="${workdir}/app-extracted"
  mkdir -p "${app_dir}"
  "${SEVEN_ZIP}" x -y "${app_archive}" -o"${app_dir}" >/dev/null
  popd >/dev/null

  # The extracted tree contains resources/app.asar and
  # resources/app.asar.unpacked (native binaries), plus locales/*.pak etc.
  # when present. Verify the minimum viable payload.
  if [[ ! -f "${app_dir}/resources/app.asar" ]]; then
    # Some NSIS layouts emit directly without a resources/ prefix
    if [[ -f "${app_dir}/app.asar" ]]; then
      mkdir -p "${app_dir}/resources"
      mv "${app_dir}/app.asar" "${app_dir}/resources/app.asar"
      if [[ -d "${app_dir}/app.asar.unpacked" ]]; then
        mv "${app_dir}/app.asar.unpacked" "${app_dir}/resources/app.asar.unpacked"
      fi
    else
      echo "error: app.asar not found after 7z extraction" >&2
      find "${app_dir}" -maxdepth 4 -type f | head -n 40 >&2
      exit 1
    fi
  fi
  echo "Application payload verified (app.asar present)." >&2

  # -----------------------------------------------------------------------
  # 3. Optionally unpack app.asar for native-module rebuild visibility
  #
  # @electron/asar is the canonical tool; fall back to 7z extraction if
  # unavailable (asar is a plain tar-like format that 7z can partially read).
  # -----------------------------------------------------------------------
  local asar_unpacked_hint="${app_dir}/resources/app.asar.unpacked"
  if [[ ! -d "${asar_unpacked_hint}" ]]; then
    echo "warn: app.asar.unpacked not present in installer — creating empty placeholder" >&2
    mkdir -p "${asar_unpacked_hint}"
  fi

  # -----------------------------------------------------------------------
  # 4. Download Electron Linux binary for the target arch
  # -----------------------------------------------------------------------
  local electron_url electron_zip
  electron_url="$(printf "${ELECTRON_URL_TEMPLATE}" "${ELECTRON_VERSION}" "${ELECTRON_VERSION}")"
  electron_zip="${workdir}/electron-v${ELECTRON_VERSION}-linux-x64.zip"

  fetch_cached "${electron_url}" "${electron_zip}"
  echo "Fetched Electron ${ELECTRON_VERSION} for linux-x64" >&2

  electron_dir="${workdir}/electron"
  mkdir -p "${electron_dir}"
  unzip -q "${electron_zip}" -d "${electron_dir}"
  echo "Electron extracted to ${electron_dir}" >&2

  # -----------------------------------------------------------------------
  # 5. Stage the Linux application directory
  #
  # Layout mirrors the Electron Linux distribution:
  #   Grok_Bot_<ver>_linux_x64/
  #     grok-bot            (electron binary, renamed)
  #     chrome-sandbox
  #     resources/app.asar (+ app.asar.unpacked, locales, *.pak, etc.)
  #     locales/            (top-level locales required by Chromium)
  # -----------------------------------------------------------------------
  local linux_app_name="Grok_Bot_${GROK_VERSION}_linux_x64"
  local staged="${workdir}/${linux_app_name}"
  mkdir -p "${staged}/resources"

  # Electron binary
  cp "${electron_dir}/electron" "${staged}/grok-bot"
  chmod +x "${staged}/grok-bot"

  # Chromium helpers — copy what the Electron zip distributes
  for f in "${electron_dir}/chrome-sandbox" "${electron_dir}/chrome_crashpad_handler" \
           "${electron_dir}/libEGL.so" "${electron_dir}/libGLESv2.so" \
           "${electron_dir}/libffmpeg.so" "${electron_dir}/libvk_swiftshader.so" \
           "${electron_dir}/libvulkan.so.1" \
           "${electron_dir}/vk_swiftshader_icd.json"; do
    [[ -f "${f}" ]] && cp "${f}" "${staged}/"
  done
  # Preserve executable bits for sandbox/crash handler
  [[ -f "${staged}/chrome-sandbox" ]] && chmod 4755 "${staged}/chrome-sandbox" 2>/dev/null || true
  [[ -f "${staged}/chrome_crashpad_handler" ]] && chmod +x "${staged}/chrome_crashpad_handler" || true

  # Chromium runtime data required before ICU init — missing any of these
  # triggers "Invalid file descriptor to ICU data received" / SIGTRAP.
  for f in "${electron_dir}/icudtl.dat" \
           "${electron_dir}/snapshot_blob.bin" \
           "${electron_dir}/v8_context_snapshot.bin"; do
    [[ -f "${f}" ]] && cp "${f}" "${staged}/"
  done

  # Top-level locales and .pak files (required for startup)
  if [[ -d "${electron_dir}/locales" ]]; then
    cp -r "${electron_dir}/locales" "${staged}/"
  fi
  for pak in "${electron_dir}"/*.pak; do
    [[ -f "${pak}" ]] && cp "${pak}" "${staged}/"
  done
  for so in "${electron_dir}"/*.so; do
    [[ -f "${so}" ]] && cp "${so}" "${staged}/" 2>/dev/null || true
  done
  for so1 in "${electron_dir}"/*.so.1; do
    [[ -f "${so1}" ]] && cp "${so1}" "${staged}/" 2>/dev/null || true
  done

  # Application resources — overwrite Electron's default app.asar if present
  cp "${app_dir}/resources/app.asar" "${staged}/resources/app.asar"
  if [[ -d "${app_dir}/resources/app.asar.unpacked" ]]; then
    rm -rf "${staged}/resources/app.asar.unpacked"
    cp -r "${app_dir}/resources/app.asar.unpacked" "${staged}/resources/"
  fi
  # Carry extra resource files (e.g. app-update.yml, icons) when present
  for extra in "${app_dir}/resources"/*; do
    [[ -e "${extra}" ]] || continue
    base="$(basename "${extra}")"
    if [[ "${base}" != "app.asar" && "${base}" != "app.asar.unpacked" ]]; then
      cp -r "${extra}" "${staged}/resources/" 2>/dev/null || true
    fi
  done

  echo "Staged Linux app at ${staged}" >&2
  du -sh "${staged}" >&2

  # NSIS payload preserves restrictive modes (drwx------ on app.asar.unpacked,
  # etc.). tar -czf would propagate them into the artefact and a non-root
  # consumer (e.g. the AUR -bin package after pacman installs as root) would
  # then ship a directory only root can read. Normalise before packaging —
  # dirs 755, files 644 — then restore the exec/setuid bits the blanket 644
  # just stripped. Order matters: normalise first, fix exec bits second.
  find "${staged}" -type d -exec chmod 755 {} +
  find "${staged}" -type f -exec chmod 644 {} +
  chmod 755 "${staged}/grok-bot"
  [[ -f "${staged}/chrome-sandbox" ]] && chmod 4755 "${staged}/chrome-sandbox"
  [[ -f "${staged}/chrome_crashpad_handler" ]] && chmod 755 "${staged}/chrome_crashpad_handler"
  # .node shared objects are dlopen()ed, not exec()ed, but several loaders
  # (and some dlopen hardening paths) expect them readable+executable; the
  # Electron-distributed .so files keep their upstream +x for the same reason.
  find "${staged}" -type f \( -name "*.node" -o -name "*.so" -o -name "*.so.*" \) -exec chmod 755 {} +

  # -----------------------------------------------------------------------
  # 6. Rebuild native modules against Electron 42.1.0
  #
  # Native binaries are vendored under dist/deps/ (see runtime-deps-manifest.json),
  # not under node_modules. Running @electron/rebuild from the app root therefore
  # finds zero candidates ("No native modules found", exit 0) and leaves the 6
  # win32 .node blobs untouched (MZ guard below would then fail). Instead, drive
  # the rebuild one module at a time from each dist/deps/<pkg> directory with
  # --module-dir, patching better-sqlite3 for the Node 24 ExternalPointerTypeTag
  # arity change and using the bundled node-addon-api via NODE_PATH. NAPI/Rust
  # modules (whichlang-node, @anysphere/tree-chunk-napi) use npm prebuilds or
  # cargo; cursor-proclist and tree-chunk-napi have no Linux source or prebuild
  # (private Anysphere code), so their .node files are rewritten to a
  # dependency-free N-API stub (scripts/native-stubs/linux-stub.cc). The stub
  # is a valid ELF that loads with empty exports — node-gyp-build resolves it,
  # and calling code reads "feature unavailable" instead of dying in dlopen
  # with "invalid ELF header".
  #
  # Both app.asar:dist/deps/ (packed) and resources/app.asar.unpacked/dist/deps/
  # carry PE binaries before the fix; rebuild against app.asar.unpacked, then
  # mirror patched .node into a fresh asar extract and repack to keep the two
  # copies coherent.
  # -----------------------------------------------------------------------
  local need_rebuild=true
  if [[ ! -d "${staged}/resources/app.asar.unpacked" ]] || \
     ! find "${staged}/resources/app.asar.unpacked" -name "*.node" -print -quit 2>/dev/null | grep -q .; then
    echo "No .node binaries found in app.asar.unpacked — skipping native rebuild (pure JS payload or already stripped)." >&2
    need_rebuild=false
  fi

  if [[ "${need_rebuild}" == "true" ]]; then
    local asar_tmp="${workdir}/asar-unpacked"
    mkdir -p "${asar_tmp}"

    local has_asar=false
    if command -v asar >/dev/null 2>&1 || npx --yes @electron/asar --help >/dev/null 2>&1; then
      has_asar=true
    fi

    if [[ "${has_asar}" == "true" ]]; then
      echo "Unpacking app.asar for native rebuild..." >&2
      if npx --yes @electron/asar extract "${staged}/resources/app.asar" "${asar_tmp}" 2>/dev/null; then
        echo "app.asar extracted to ${asar_tmp}" >&2
      elif command -v asar >/dev/null 2>&1 && asar extract "${staged}/resources/app.asar" "${asar_tmp}" 2>/dev/null; then
        echo "app.asar extracted via asar CLI" >&2
      else
        echo "warn: asar extraction failed — native rebuild will target unpacked tree only" >&2
        asar_tmp=""
      fi
    else
      echo "warn: @electron/asar not available — native rebuild will target unpacked tree only" >&2
      asar_tmp=""
    fi

    # Canonical source for native modules on this build.
    local deps_root="${staged}/resources/app.asar.unpacked/dist/deps"
    if [[ ! -d "${deps_root}" ]]; then
      echo "error: expected native deps dir ${deps_root} not found" >&2
      exit 1
    fi

    fetch_better_sqlite_electron_prebuild() {
      local mod_dir="$1"
      local url="https://github.com/WiseLibs/better-sqlite3/releases/download/v12.11.1/better-sqlite3-v12.11.1-electron-v146-linux-x64.tar.gz"
      local tmp
      tmp="$(mktemp -d -t bs-pre-XXXXXX)"
      echo "  fetching better-sqlite3 electron-v146 prebuild (12.11.1, API-compatible with 12.6.2)" >&2
      if ! curl --fail --silent --show-error --location --retry 2 --max-time 60 -o "$tmp/bs.tar.gz" "$url" 2>&1; then
        echo "error: failed to fetch better-sqlite3 prebuild from $url" >&2
        rm -rf "$tmp"
        return 1
      fi
      local dest="$mod_dir/build/Release/better_sqlite3.node"
      mkdir -p "$(dirname "$dest")"
      # Tarball contains build/Release/better_sqlite3.node at root
      if ! tar -xzf "$tmp/bs.tar.gz" -C "$tmp" 2>/dev/null; then
        echo "error: failed to extract better-sqlite3 prebuild tarball" >&2
        rm -rf "$tmp"
        return 1
      fi
      local src
      src="$(find "$tmp" -name "better_sqlite3.node" -print -quit 2>/dev/null || true)"
      if [[ -z "$src" || ! -f "$src" ]]; then
        echo "error: better_sqlite3.node not found in prebuild tarball" >&2
        rm -rf "$tmp"
        return 1
      fi
      cp -f "$src" "$dest"
      # Prebuild's build/Release is ELF; sanity check
      if head -c 2 "$dest" | grep -q MZ; then
        echo "error: fetched better-sqlite3 prebuild still has MZ header" >&2
        rm -rf "$tmp"
        return 1
      fi
      rm -rf "$tmp"
      echo "  installed $(basename "$dest") ($(du -h "$dest" | cut -f1)) from prebuild" >&2
      return 0
    }

    patch_better_sqlite_external_arity() {
      local mod_dir="$1"
      local cpp="$mod_dir/src/better_sqlite3.cpp"
      [[ -f "$cpp" ]] || return 0
      if grep -q "ExternalPointerTypeTag" "$cpp"; then
        return 0
      fi
      echo "  patching better-sqlite3 External::New arity (Node 24 / ExternalPointerTypeTag)" >&2
      # The single call site in better-sqlite3@12.6.2:
      #   v8::Local<v8::External> data = v8::External::New(isolate, addon);
      # Node 24 requires a third argument: ExternalPointerTypeTag::kExternalPointerTypeTagUntyped
      # Keep the header inclusion minimal — v8-external.h is reachable via v8.h.
      python3 - "$cpp" <<'PYPATCH'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
old = "v8::Local<v8::External> data = v8::External::New(isolate, addon);"
new = "v8::Local<v8::External> data = v8::External::New(isolate, addon, v8::ExternalPointerTypeTag::kExternalPointerTypeTagUntyped);"
if old in t:
    t = t.replace(old, new)
    # Ensure the Tag enum is visible even if include path is shallow
    if "v8-external.h" not in t:
        t = t.replace('#include <node.h>', '#include <node.h>\n#include <v8-external.h>')
    p.write_text(t)
    print("patched", sys.argv[1])
else:
    print("patch site not found in", sys.argv[1], file=sys.stderr)
    sys.exit(1)
PYPATCH
    }

    # compile_native_stub — build the dependency-free N-API stub used to
    # replace Windows-only .node blobs that have no Linux source or prebuild.
    # Flags keep the output minimal and bit-for-bit reproducible (no build-id
    # or debug nondeterminism) so repacked artefacts hash-stabilise.
    compile_native_stub() {
      local dest="$1"
      local node_include=""
      local cand
      for cand in /usr/include/node /usr/include/nodejs /usr/local/include/node; do
        if [[ -f "${cand}/node_api.h" ]]; then
          node_include="${cand}"
          break
        fi
      done
      if [[ -z "${node_include}" ]]; then
        cand="$(find /usr/include /usr/local/include -maxdepth 3 -name node_api.h -print -quit 2>/dev/null || true)"
        [[ -n "${cand}" ]] && node_include="$(dirname "${cand}")"
      fi
      if [[ -z "${node_include}" ]]; then
        echo "error: node_api.h not found — install the nodejs development headers (nodejs-dev/libnode-dev)" >&2
        return 1
      fi
      g++ -shared -fPIC -s -O2 \
        -Wl,-z,noexecstack -Wl,--build-id=none \
        -I"${node_include}" \
        "${SCRIPT_DIR}/native-stubs/linux-stub.cc" -o "${dest}"
    }

    fix_one_node_module() {
      local name="$1"
      local kind="$2"
      local mod_rel="$name"
      local mod_dir="${deps_root}/${mod_rel}"

      if [[ "$name" == "@anysphere/tree-chunk-napi" ]]; then
        mod_rel="@anysphere/tree-chunk-napi"
        mod_dir="${deps_root}/@anysphere/tree-chunk-napi"
      fi

      if [[ ! -d "$mod_dir" ]]; then
        echo "  skip ${name}: not present under ${deps_root}" >&2
        return 0
      fi

      case "$kind" in
        node-gyp-fetch)
          echo "  fetching ${name} prebuilt (or rebuilding from npm source)" >&2
          local tmp_npm
          tmp_npm="$(mktemp -d -t npm-src-XXXXXX)"
          local pkg_spec="$name"
          # Pin to same versions vendored in the Windows build (reduces API drift)
          if [[ "$name" == "tree-sitter" ]]; then pkg_spec="tree-sitter@0.21.1"; fi
          if [[ "$name" == "tree-sitter-bash" ]]; then pkg_spec="tree-sitter-bash@0.21.0"; fi
          if ! (cd "$tmp_npm" && npm pack --ignore-scripts "$pkg_spec" >/dev/null 2>&1); then
            echo "error: npm pack $pkg_spec failed" >&2
            rm -rf "$tmp_npm"
            exit 1
          fi
          local tgz2
          tgz2="$(ls "$tmp_npm"/*.tgz 2>/dev/null | head -n 1 || true)"
          # Prefer a linux-x64 prebuilt if the npm package ships one
          local prebuilt=""
          mkdir -p "$tmp_npm/ex"
          tar -xzf "$tgz2" -C "$tmp_npm/ex" 2>/dev/null
          # Remove stale Windows build artefacts (MSVC build/Release) so node-gyp-build
          # prefers the linux prebuild instead of the win32 .node in build/Release.
          rm -rf "${mod_dir}/build"
          if compgen -G "$tmp_npm/ex/package/prebuilds/linux-x64/*.node" >/dev/null 2>&1; then
            prebuilt="$(ls "$tmp_npm/ex/package/prebuilds/linux-x64/"*.node 2>/dev/null | head -n 1 || true)"
          fi
          if [[ -n "${prebuilt:-}" && -f "$prebuilt" ]]; then
            echo "  using npm prebuilt $(basename "$prebuilt")" >&2
            # tree-sitter-bash's loader uses node-gyp-build(root) -> build/Release/
            # but tree-sitter-bash npm also has prebuilds/linux-x64/ — copy into the
            # location the loader actually checks on Linux.
            if [[ "$name" == "tree-sitter-bash" ]]; then
              local dest_dir="${mod_dir}/prebuilds/linux-x64"
              mkdir -p "$dest_dir"
              cp -f "$prebuilt" "$dest_dir/$(basename "$prebuilt")"
              echo "  installed $(basename "$prebuilt") ($(du -h "$dest_dir/$(basename "$prebuilt")" | cut -f1))" >&2
            else
              mkdir -p "${mod_dir}/prebuilds/linux-x64"
              cp -f "$prebuilt" "${mod_dir}/prebuilds/linux-x64/$(basename "$prebuilt")"
              echo "  installed $(basename "$prebuilt")" >&2
            fi
          else
            echo "  no linux-x64 prebuild in npm pack for ${name}; rebuilding from npm source" >&2
            # Replace the stripped vendored dir with the full-source npm copy
            rm -rf "${mod_dir}.orig"
            mv "$mod_dir" "${mod_dir}.orig"
            cp -a "$tmp_npm/ex/package" "$mod_dir"
            # Ensure sibling helpers (node-addon-api etc.) are still reachable
            if ! (NODE_PATH="${deps_root}:${deps_root}/node-addon-api:${NODE_PATH:-}" \
                  npx --yes @electron/rebuild --version "${ELECTRON_VERSION}" --module-dir "${mod_dir}" 2>&1); then
              if [[ "${GROKBOT_ALLOW_BROKEN_NATIVE:-}" == "1" ]]; then
                echo "warn: rebuild of ${name} failed — continuing (GROKBOT_ALLOW_BROKEN_NATIVE=1)" >&2
                rm -rf "$tmp_npm"
                return 0
              fi
              echo "error: rebuild of ${name} failed (module-dir ${mod_dir})" >&2
              rm -rf "$tmp_npm"
              exit 1
            fi
          fi
          rm -rf "$tmp_npm"
          ;;

        node-gyp)
          if [[ "$name" == "better-sqlite3" ]]; then
            # Prefer the GitHub electron-v146 prebuild (ELF, no toolchain needed).
            # The vendored 12.6.2 source does not compile against Electron 42 / Node 24:
            # V8 API breakage beyond External::New (Value() arity, Holder/This, etc.)
            # 12.11.1 is the latest 12.x on npm and ships a compatible v146 prebuild
            # with the same native ABI / JS API.
            if ! fetch_better_sqlite_electron_prebuild "$mod_dir"; then
              echo "  warn: prebuild fetch failed, falling back to source patch+rebuild" >&2
              patch_better_sqlite_external_arity "$mod_dir"
              if ! (NODE_PATH="${deps_root}:${deps_root}/node-addon-api:${NODE_PATH:-}" \
                    npx --yes @electron/rebuild --version "${ELECTRON_VERSION}" --module-dir "${mod_dir}" 2>&1); then
                if [[ "${GROKBOT_ALLOW_BROKEN_NATIVE:-}" == "1" ]]; then
                  echo "warn: rebuild of ${name} failed — continuing (GROKBOT_ALLOW_BROKEN_NATIVE=1)" >&2
                  return 0
                fi
                echo "error: rebuild of ${name} failed (module-dir ${mod_dir})" >&2
                exit 1
              fi
            fi
          elif [[ "$name" == "cursor-proclist" ]]; then
            # Private Anysphere module with no C++ sources and no linux prebuild:
            # node-gyp-build resolves build/Release/ first on every platform, so
            # the vendored PE would win on Linux and crash dlopen. Replace it
            # with the N-API stub; the guarded require reads empty exports as
            # "feature unavailable" (idle-time process scan).
            echo "  replacing ${name} win32 blob with N-API stub (no linux source available)" >&2
            compile_native_stub "${mod_dir}/build/Release/cursor_proclist.node"
          else
            echo "  rebuilding ${name} (node-gyp, --module-dir ${mod_dir})" >&2
            if ! (NODE_PATH="${deps_root}:${deps_root}/node-addon-api:${NODE_PATH:-}" \
                  npx --yes @electron/rebuild --version "${ELECTRON_VERSION}" --module-dir "${mod_dir}" 2>&1); then
              if [[ "${GROKBOT_ALLOW_BROKEN_NATIVE:-}" == "1" ]]; then
                echo "warn: rebuild of ${name} failed — continuing (GROKBOT_ALLOW_BROKEN_NATIVE=1)" >&2
                return 0
              fi
              echo "error: rebuild of ${name} failed (module-dir ${mod_dir})" >&2
              exit 1
            fi
          fi
          ;;

        napi-whichlang)
          echo "  fixing ${name}: fetching whichlang-node-linux-x64-gnu@0.2.1 (npm prebuilt)" >&2
          local tmp_pkg
          tmp_pkg="$(mktemp -d -t whichlang-XXXXXX)"
          # --ignore-scripts avoids running its prebuild-install hook; we just need the .node blob
          if ! (cd "$tmp_pkg" && npm pack --ignore-scripts "whichlang-node-linux-x64-gnu@0.2.1" >/dev/null 2>&1); then
            echo "error: npm pack whichlang-node-linux-x64-gnu@0.2.1 failed" >&2
            rm -rf "$tmp_pkg"
            exit 1
          fi
          local tgz
          tgz="$(ls "$tmp_pkg"/whichlang-node-linux-x64-gnu-*.tgz 2>/dev/null | head -n 1 || true)"
          mkdir -p "$tmp_pkg/ex"
          tar -xzf "$tgz" -C "$tmp_pkg/ex" 2>/dev/null
          local linux_node="$tmp_pkg/ex/package/whichlang-node.linux-x64-gnu.node"
          if [[ ! -f "$linux_node" ]]; then
            echo "error: expected $linux_node not found in npm tarball" >&2
            rm -rf "$tmp_pkg"
            exit 1
          fi
          # Keep the win32 blob alongside (harmless) and add the linux one the loader prefers on gnu hosts
          cp "$linux_node" "${mod_dir}/whichlang-node.linux-x64-gnu.node"
          # The loader for glibc hosts tries the local file first (whichlang-node.linux-x64-gnu.node)
          # before falling back to the npm package — no need to fabricate the package dir.
          echo "  installed $(basename "$linux_node") ($(du -h "$linux_node" | cut -f1))" >&2
          rm -rf "$tmp_pkg"
          ;;

        napi-tree-chunk)
          # Private Anysphere crate: dist has no Cargo.toml and npm has no
          # @anysphere/tree-chunk-napi-linux-x64-gnu tarball. The napi-rs loader
          # probes tree-chunk-napi.linux-x64-gnu.node first on glibc hosts — a
          # path the win32 tarball never ships — so place the N-API stub there.
          # host-main.cjs requires it unguarded at top level; without the stub
          # the host subprocess dies on spawn ("Cannot find module"), with the
          # stub it starts and only tree-chunk call sites fail.
          echo "  placing N-API stub at ${name}.linux-x64-gnu.node (no linux crate or prebuild)" >&2
          compile_native_stub "${mod_dir}/tree-chunk-napi.linux-x64-gnu.node"
          ;;

        *)
          echo "error: unknown native kind '$kind' for $name" >&2
          exit 1
          ;;
      esac
    }

    fix_one_node_module "better-sqlite3" "node-gyp"
    fix_one_node_module "cursor-proclist" "node-gyp"
    fix_one_node_module "tree-sitter" "node-gyp-fetch"
    fix_one_node_module "tree-sitter-bash" "node-gyp-fetch"
    fix_one_node_module "whichlang-node" "napi-whichlang"
    fix_one_node_module "@anysphere/tree-chunk-napi" "napi-tree-chunk"

    # Keep app.asar:dist/deps/ coherent with the fixed unpacked tree when we
    # have an extracted copy to repack. app.asar's natives are otherwise stale.
    if [[ -n "${asar_tmp:-}" && -d "${asar_tmp}/dist/deps" ]]; then
      echo "Mirroring fixed native blobs into app.asar extract..." >&2
      # For rebuilt modules, copy the concrete .node artefacts. For the npm-fetched
      # whichlang file, the new linux-x64-gnu file is the only new entry.
      for rel in \
        "better-sqlite3/build/Release/better_sqlite3.node" \
        "cursor-proclist/build/Release/cursor_proclist.node" \
        "tree-sitter/build/Release/tree_sitter_runtime_binding.node" \
        "tree-sitter-bash/build/Release/tree_sitter_bash_binding.node" \
        "whichlang-node/whichlang-node.linux-x64-gnu.node" \
        "whichlang-node/whichlang-node.linux-x64-musl.node" \
        "@anysphere/tree-chunk-napi/tree-chunk-napi.linux-x64-gnu.node"; do
        if [[ -f "${deps_root}/${rel}" ]]; then
          mkdir -p "${asar_tmp}/dist/deps/$(dirname "$rel")"
          cp -f "${deps_root}/${rel}" "${asar_tmp}/dist/deps/${rel}"
        fi
      done
      # Tree-sitter native modules are shipped as prebuilds/ after the fix (no
      # build/Release on this branch). Copy any linux prebuilds that now exist.
      for pre in "${deps_root}/tree-sitter/prebuilds/linux-x64"/*.node "${deps_root}/tree-sitter-bash/prebuilds/linux-x64"/*.node "${deps_root}/tree-sitter/prebuilds"/*.node; do
        [[ -f "$pre" ]] || continue
        rel="${pre#"${deps_root}/"}"
        mkdir -p "${asar_tmp}/dist/deps/$(dirname "$rel")"
        cp -f "$pre" "${asar_tmp}/dist/deps/${rel}"
      done
      # Purge stale Windows build dir from the extracted tree so node-gyp-build
      # inside the packed asar prefers prebuilds/linux-x64.
      rm -rf "${asar_tmp}/dist/deps/tree-sitter/build" "${asar_tmp}/dist/deps/tree-sitter-bash/build"

      local asar_cmd
      if command -v asar >/dev/null 2>&1; then
        asar_cmd="asar"
      else
        asar_cmd="npx --yes @electron/asar"
      fi
      echo "Repacking app.asar..." >&2
      # shellcheck disable=SC2086
      if ! ${asar_cmd} pack "${asar_tmp}" "${staged}/resources/app.asar" 2>&1; then
        echo "warn: asar repack failed — unpacked tree carries the fixes, packed copy remains stale" >&2
      fi
    fi

    # Hard gate: fail if any *loadable* native is still a Windows PE. A
    # remaining MZ blob is only dead code when Linux loaders can provably
    # never resolve it — win32 prebuild dirs (node-gyp-build filter) or
    # napi-rs's *.win32-*.node filenames. Anything else (build/Release PE,
    # misnamed blob) would be dlopened at runtime and crash the process.
    local mz_list mz_live
    mz_list="$(find "${staged}/resources/app.asar.unpacked" -name "*.node" -type f -exec sh -c \
      'head -c 2 "$1" | grep -q MZ && printf "%s\n" "$1"' _ {} \; 2>/dev/null || true)"
    mz_live=""
    if [[ -n "${mz_list}" ]]; then
      mz_live="$(printf '%s\n' "${mz_list}" \
        | grep -v -e '/prebuilds/win32-' -e '\.win32-[^/]*\.node$' 2>/dev/null || true)"
    fi
    if [[ -n "${mz_live}" ]]; then
      local mz_count
      mz_count="$(printf '%s\n' "${mz_live}" | grep -c . || true)"
      if [[ "${GROKBOT_ALLOW_BROKEN_NATIVE:-}" == "1" ]]; then
        echo "warn: ${mz_count} loadable win32 .node binaries remain — GROKBOT_ALLOW_BROKEN_NATIVE=1 override active" >&2
        printf '%s\n' "${mz_live}" | head -n 20 >&2
      else
        echo "error: ${mz_count} loadable .node files still carry MZ header after rebuild" >&2
        printf '%s\n' "${mz_live}" | head -n 20 >&2
        echo "hint:  fix the rebuild toolchain (python3, make, g++, @electron/rebuild deps) or set GROKBOT_ALLOW_BROKEN_NATIVE=1" >&2
        exit 1
      fi
    elif [[ -n "${mz_list}" ]]; then
      echo "note: dead win32 blob(s) remain, unreachable by Linux loaders (prebuilds/win32-*, *.win32-*.node):" >&2
      printf '  %s\n' "${mz_list}" | head -n 5 >&2
    fi
    echo "Native rebuild completed." >&2
  fi

  # -----------------------------------------------------------------------
  # 6b. Desktop icon
  #
  # app-icon-*.png lives inside packed app.asar, not app.asar.unpacked, so a
  # find(1) of the staged tree returns nothing. Extract it to grok-bot.png
  # at the tarball root; the AUR PKGBUILDs, the RPM spec, and the AppImage
  # AppDir all look for that name. Best-effort: a missing icon must not
  # fail the tarball.
  # -----------------------------------------------------------------------
  local asar_path="${staged}/resources/app.asar"
  local icon_dest="${staged}/grok-bot.png"
  if [[ -f "${asar_path}" ]]; then
    if python3 "${SCRIPT_DIR}/extract-asar-icon.py" "${asar_path}" "${icon_dest}"; then
      echo "Staged desktop icon: ${icon_dest} ($(wc -c < "${icon_dest}") bytes)" >&2
    else
      echo "warn: could not extract app-icon from app.asar — packages will ship without a hicolor icon" >&2
    fi
  fi

  # -----------------------------------------------------------------------
  # 7. chrome-sandbox permissions
  #
  # Electron requires chrome-sandbox to be owned by root and setuid 4755.
  # In GitHub Actions (root) we can satisfy this; locally as non-root we warn.
  # -----------------------------------------------------------------------
  if [[ -f "${staged}/chrome-sandbox" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      chown root:root "${staged}/chrome-sandbox"
      chmod 4755 "${staged}/chrome-sandbox"
      echo "chrome-sandbox permissions set (root:root 4755)." >&2
    else
      echo "warn: not running as root — cannot chown chrome-sandbox to root:root" >&2
      echo "hint: after extracting the tar.gz, run: sudo chown root:root chrome-sandbox && sudo chmod 4755 chrome-sandbox" >&2
      # Ensure at least executable for non-sandboxed runs (--no-sandbox)
      chmod 4755 "${staged}/chrome-sandbox" 2>/dev/null || chmod +x "${staged}/chrome-sandbox" || true
    fi
  fi

  # -----------------------------------------------------------------------
  # 8. Create distributable artefacts (tar.gz always; AppImage when possible)
  # -----------------------------------------------------------------------
  local artifacts=()

  # 8a. tar.gz (always)
  local tarball="${outdir}/${linux_app_name}.tar.gz"
  echo "Creating tarball ${tarball}..." >&2
  tar -czf "${tarball}" -C "${workdir}" "${linux_app_name}"
  artifacts+=("${tarball}")
  echo "Tarball: $(du -h "${tarball}" | cut -f1) ${tarball}" >&2

  # 8b. AppImage — via AppDir + appimagetool (no electron-builder required)
  #
  # chrome-sandbox cannot be setuid inside an AppImage (squashfs built as
  # non-root), so AppRun forces --no-sandbox. Users needing a strict sandbox
  # should use the tarball with `sudo chown root:root chrome-sandbox`.
  # Best-effort: failures are warned, never fatal to the tarball.
  if command -v mksquashfs >/dev/null 2>&1; then
    echo "Attempting AppImage creation..." >&2
    local appimage_name="Grok_Bot_${GROK_VERSION}_x86_64.AppImage"
    local appimage_path="${outdir}/${appimage_name}"
    local appdir="${workdir}/AppDir"

    rm -rf "${appdir}"
    mkdir -p "${appdir}/usr/bin" \
             "${appdir}/usr/share/applications" \
             "${appdir}/usr/share/icons/hicolor/256x256/apps"

    cp -a "${staged}/." "${appdir}/usr/bin/"

    local icon_src=""
    # Prefer the icon planted in 6b; fall back to a loose PNG if port.sh
    # ran against an older tree that already unpacked one.
    local icon_candidates=(
      "${staged}/grok-bot.png"
      "${staged}/resources/app.asar.unpacked/dist/renderer/assets/app-icon-"*.png
    )
    for cand in "${icon_candidates[@]}"; do
      if [[ -f "${cand}" ]]; then icon_src="${cand}"; break; fi
    done
    if [[ -z "${icon_src}" || ! -f "${icon_src}" ]]; then
      icon_src="$(find "${staged}" -name "app-icon*.png" -print -quit 2>/dev/null || true)"
    fi

    if [[ -n "${icon_src}" && -f "${icon_src}" ]]; then
      cp "${icon_src}" "${appdir}/grok-bot.png"
      cp "${icon_src}" "${appdir}/.DirIcon"
      cp "${icon_src}" "${appdir}/usr/share/icons/hicolor/256x256/apps/grok-bot.png"
      echo "AppImage icon: ${icon_src}" >&2
    else
      echo "warn: no icon found for AppImage — using empty placeholder" >&2
      : > "${appdir}/grok-bot.png"
      : > "${appdir}/.DirIcon"
    fi

    cat > "${appdir}/grok-bot.desktop" <<'DESKTOP_EOF'
[Desktop Entry]
Name=Grok Bot
GenericName=Grok Bot
Comment=Grok Bot desktop agent
Exec=grok-bot --no-sandbox
Icon=grok-bot
Type=Application
Categories=Utility;
Terminal=false
StartupWMClass=grok-bot
DESKTOP_EOF
    # Append versioned metadata
    echo "X-AppImage-Version=${GROK_VERSION}" >> "${appdir}/grok-bot.desktop"
    cp "${appdir}/grok-bot.desktop" "${appdir}/usr/share/applications/grok-bot.desktop"

    cat > "${appdir}/AppRun" <<'APPRUN_EOF'
#!/bin/sh
SELF="$(readlink -f "$0")"
HERE="${SELF%/*}"
exec "${HERE}/usr/bin/grok-bot" --no-sandbox "$@"
APPRUN_EOF
    chmod +x "${appdir}/AppRun"

    # Obtain appimagetool (continuous) — best-effort download
    local appimagetool_bin="${workdir}/appimagetool"
    local appimagetool_ok=false
    if command -v appimagetool >/dev/null 2>&1; then
      appimagetool_bin="$(command -v appimagetool)"
      appimagetool_ok=true
    else
      if curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
           --connect-timeout 15 --max-time 300 \
           -o "${appimagetool_bin}" \
           "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" 2>&1; then
        chmod +x "${appimagetool_bin}"
        # Extract to avoid FUSE requirement in CI
        if "${appimagetool_bin}" --appimage-extract >/dev/null 2>&1; then
          appimagetool_bin="${PWD}/squashfs-root/AppRun"
          appimagetool_ok=true
          # appimagetool extracts to ./squashfs-root relative to cwd — run from workdir
          if [[ ! -f "${appimagetool_bin}" ]]; then
            appimagetool_bin="${workdir}/squashfs-root/AppRun"
            if [[ ! -f "${appimagetool_bin}" ]]; then
              appimagetool_ok=false
            fi
          fi
        else
          appimagetool_ok=true
        fi
      else
        echo "warn: failed to download appimagetool — skipping AppImage" >&2
      fi
    fi

    if [[ "${appimagetool_ok}" == "true" ]]; then
      # appimagetool may have extracted squashfs-root to CWD or workdir — resolve
      local at_bin="${appimagetool_bin}"
      if [[ ! -f "${at_bin}" ]]; then
        for cand in "${PWD}/squashfs-root/AppRun" "${workdir}/squashfs-root/AppRun" "./squashfs-root/AppRun"; do
          if [[ -f "${cand}" ]]; then at_bin="${cand}"; break; fi
        done
      fi
      # Run from workdir so relative squashfs-root resolves; force arch
      if ! (cd "${workdir}" 2>/dev/null; ARCH=x86_64 "${at_bin}" "${appdir}" "${appimage_path}" 2>&1); then
        echo "warn: appimagetool failed — skipping AppImage" >&2
        rm -f "${appimage_path}" 2>/dev/null || true
      else
        if [[ -f "${appimage_path}" ]]; then
          artifacts+=("${appimage_path}")
          echo "AppImage: $(du -h "${appimage_path}" | cut -f1) ${appimage_path}" >&2
        fi
      fi
      rm -rf "${workdir}/squashfs-root" ./squashfs-root 2>/dev/null || true
    fi
  else
    echo "Skipping AppImage — mksquashfs not found (install squashfs-tools)." >&2
  fi

  # -----------------------------------------------------------------------
  # 9. Report
  # -----------------------------------------------------------------------
  echo "" >&2
  echo "Build complete for Grok Bot ${GROK_VERSION} (Electron ${ELECTRON_VERSION})." >&2
  echo "Artifacts:" >&2
  for a in "${artifacts[@]}"; do
    echo "  ${a} ($(du -h "${a}" | cut -f1))" >&2
    # Also emit to stdout for machine consumption (one path per line)
    printf '%s\n' "${a}"
  done

  # Keep workdir on explicit request for debugging
  if [[ -n "${GROKBOT_KEEP_WORKDIR:-}" ]]; then
    echo "Keeping workdir at ${workdir} (GROKBOT_KEEP_WORKDIR=1)" >&2
    trap - EXIT
  fi
}

main "$@"
