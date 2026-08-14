#!/usr/bin/env bash
set -euo pipefail

# port.sh — produce Linux artefacts from a Grok Bot Windows distribution
#
# Takes a Grok Bot version (e.g. 0.19.0), downloads the win32 NSIS installer,
# extracts the embedded Electron application without Wine (7z x app-64.7z),
# fuses it with the official Electron 42.1.0 Linux binary, rebuilds the six
# native modules against the target Electron, and assembles distributable
# artefacts (tar.gz mandatory; deb/AppImage best-effort).
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

  if ! download_with_retry "${win32_url}" "${installer_path}"; then
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
  echo "Found embedded archive: ${app_archive}" >&2

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

  download_with_retry "${electron_url}" "${electron_zip}"
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
           "${electron_dir}/vk_swiftshader_icd.json"; do
    [[ -f "${f}" ]] && cp "${f}" "${staged}/"
  done
  # Preserve executable bits for sandbox/crash handler
  [[ -f "${staged}/chrome-sandbox" ]] && chmod 4755 "${staged}/chrome-sandbox" 2>/dev/null || true
  [[ -f "${staged}/chrome_crashpad_handler" ]] && chmod +x "${staged}/chrome_crashpad_handler" || true

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

  # -----------------------------------------------------------------------
  # 6. Rebuild native modules against Electron 42.1.0
  #
  # The win32 app.asar.unpacked ships native .node binaries compiled against
  # the Windows Electron ABI. They must be rebuilt for Linux.  We unpack
  # app.asar to a temporary location, run @electron/rebuild, then repack.
  # If asar tooling is unavailable the rebuild is best-effort and the tar.gz
  # is still produced — the user is warned.
  # -----------------------------------------------------------------------
  local need_rebuild=true
  if [[ ! -d "${staged}/resources/app.asar.unpacked" ]] || \
     ! find "${staged}/resources/app.asar.unpacked" -name "*.node" -print -quit 2>/dev/null | grep -q .; then
    echo "No .node binaries found in app.asar.unpacked — skipping native rebuild (pure JS payload or already stripped)." >&2
    need_rebuild=false
  fi

  if [[ "${need_rebuild}" == "true" ]]; then
    # Prefer the official rebuild tool; install ephemerally if needed
    local asar_tmp="${workdir}/asar-unpacked"
    mkdir -p "${asar_tmp}"

    local has_asar=false
    if command -v asar >/dev/null 2>&1 || npx --yes @electron/asar --help >/dev/null 2>&1; then
      has_asar=true
    fi

    if [[ "${has_asar}" == "true" ]]; then
      echo "Unpacking app.asar for native rebuild..." >&2
      # Try npx asar first, then bare asar
      if npx --yes @electron/asar extract "${staged}/resources/app.asar" "${asar_tmp}" 2>/dev/null; then
        echo "app.asar extracted to ${asar_tmp}" >&2
      elif command -v asar >/dev/null 2>&1 && asar extract "${staged}/resources/app.asar" "${asar_tmp}" 2>/dev/null; then
        echo "app.asar extracted via asar CLI" >&2
      else
        echo "warn: asar extraction failed — will attempt in-place rebuild" >&2
        asar_tmp="${staged}/resources"
      fi
    else
      echo "warn: @electron/asar not available — attempting in-place rebuild" >&2
      asar_tmp="${staged}/resources"
    fi

    # Resolve the effective app root for rebuild (contains package.json)
    local rebuild_root="${asar_tmp}"
    if [[ ! -f "${rebuild_root}/package.json" ]]; then
      # Search one level deeper (common when asar root contains app/ subdir)
      local found
      found="$(find "${asar_tmp}" -maxdepth 3 -name "package.json" -print -quit 2>/dev/null || true)"
      if [[ -n "${found}" ]]; then
        rebuild_root="$(dirname "${found}")"
      fi
    fi

    if [[ -f "${rebuild_root}/package.json" ]]; then
      echo "Running @electron/rebuild for Electron ${ELECTRON_VERSION} in ${rebuild_root}" >&2
      echo "Target modules: ${NATIVE_MODULES[*]}" >&2
      # Use npx with --yes to avoid interactive prompts in CI
      if ! (cd "${rebuild_root}" && npx --yes @electron/rebuild --version "${ELECTRON_VERSION}" 2>&1); then
        echo "warn: @electron/rebuild exited non-zero — native modules may require manual rebuild" >&2
        echo "hint: cd ${rebuild_root} && npx @electron/rebuild --version ${ELECTRON_VERSION}" >&2
      else
        echo "Native rebuild completed." >&2
      fi

      # Repack if we unpacked
      if [[ "${asar_tmp}" != "${staged}/resources" && -d "${asar_tmp}" ]]; then
        local asar_cmd
        if command -v asar >/dev/null 2>&1; then
          asar_cmd="asar"
        else
          asar_cmd="npx --yes @electron/asar"
        fi
        echo "Repacking app.asar..." >&2
        # shellcheck disable=SC2086
        if ! ${asar_cmd} pack "${asar_tmp}" "${staged}/resources/app.asar" 2>&1; then
          echo "warn: asar repack failed — leaving unpacked tree in place" >&2
        fi
      fi
    else
      echo "warn: no package.json found under ${asar_tmp} — skipping @electron/rebuild" >&2
      echo "hint: native modules (if any) remain as shipped for win32; they will fail on Linux until rebuilt" >&2
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
  # 8. Create distributable artefacts
  #
  # tar.gz is mandatory (always produced). deb/AppImage are best-effort and
  # depend on optional tooling (electron-installer-debian, electron-builder).
  # -----------------------------------------------------------------------
  local artifacts=()

  # 8a. tar.gz (always)
  local tarball="${outdir}/${linux_app_name}.tar.gz"
  echo "Creating tarball ${tarball}..." >&2
  tar -czf "${tarball}" -C "${workdir}" "${linux_app_name}"
  artifacts+=("${tarball}")
  echo "Tarball: $(du -h "${tarball}" | cut -f1) ${tarball}" >&2

  # 8b. deb — via electron-installer-debian when available
  if command -v electron-installer-debian >/dev/null 2>&1 || npx --yes electron-installer-debian --help >/dev/null 2>&1; then
    echo "Attempting .deb creation (best-effort)..." >&2
    local deb_out="${outdir}/deb"
    mkdir -p "${deb_out}"
    # Derive a Debian-friendly version (strip leading v, ensure valid)
    local deb_version="${GROK_VERSION}"
    # Minimal debian config — installer reads package.json for metadata when
    # available, otherwise uses supplied options.
    if ! npx --yes electron-installer-debian \
        --src "${staged}" \
        --dest "${deb_out}" \
        --arch amd64 \
        --options.version "${deb_version}" 2>&1; then
      echo "warn: electron-installer-debian failed — skipping .deb" >&2
    else
      for deb in "${deb_out}"/*.deb; do
        [[ -f "${deb}" ]] || continue
        local final_deb="${outdir}/$(basename "${deb}")"
        # Normalise name to Grok_Bot_<ver>_linux_x64.deb when possible
        mv "${deb}" "${final_deb}" 2>/dev/null || cp "${deb}" "${final_deb}"
        artifacts+=("${final_deb}")
        echo "Deb: ${final_deb}" >&2
      done
    fi
  else
    echo "Skipping .deb — electron-installer-debian not installed (npm i -D electron-installer-debian to enable)." >&2
  fi

  # 8c. AppImage — via electron-builder when available
  if command -v electron-builder >/dev/null 2>&1 || npx --yes electron-builder --help >/dev/null 2>&1; then
    echo "AppImage creation is available via electron-builder but requires a full build config — skipping in port.sh (use electron-builder manually)." >&2
  else
    echo "Skipping AppImage — electron-builder not installed." >&2
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
