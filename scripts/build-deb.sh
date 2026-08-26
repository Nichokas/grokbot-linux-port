#!/usr/bin/env bash
set -euo pipefail
# build-deb.sh — assemble Debian source packages from a release tarball
#
# Launchpad builders have no network: every byte must ship inside the source
# package. The release tarball (~143 MB) IS the orig tarball — native package
# (3.0 (native)), so no .orig/.debian split. Build-Depends are static t64 names
# (noble renamed libasound2→libasound2t64 etc.; the `| alt` covers resolute
# whether it kept t64 or reverted). Version is per-ubuntu-series:
#   <ver>~ppa<N>~<serie>1  (e.g. 0.25.0~ppa1~noble1; N mirrors the spec Release counter)
# dpkg-buildpackage -S produces .dsc/.changes/.tar.gz; with --sign-key they are
# GPG-signed (Launchpad requires signed .changes/.dsc).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARBALL=""
SHA256=""
SIGN_KEY=""
OUT_DIR="ppa-out"
SERIES=()

usage() {
  cat <<EOF
Usage: $(basename "$0") --tarball <path> --sha256 <hex> [--series noble|resolute]... [--sign-key <KEYID>] [--out-dir <dir>]

  --tarball  Path to Grok_Bot_<ver>_linux_x64.tar.gz (required)
  --sha256   Expected sha256 of the tarball (required; verified before build)
  --series   Ubuntu series to build for (repeatable; default: noble resolute)
  --sign-key GPG key id to sign .dsc/.changes with (dpkg-buildpackage -k<KEYID>)
  --out-dir  Output directory for .changes/.dsc (default: ppa-out)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tarball) TARBALL="${2:?--tarball requires a path}"; shift 2 ;;
    --sha256) SHA256="${2:?--sha256 requires a value}"; shift 2 ;;
    --series) SERIES+=("${2:?--series requires a value}"); shift 2 ;;
    --sign-key) SIGN_KEY="${2:?--sign-key requires a key id}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:?--out-dir requires a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 1 ;;
    *) echo "error: unexpected argument $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${TARBALL}" || -z "${SHA256}" ]]; then
  echo "error: --tarball and --sha256 are required" >&2; usage >&2; exit 1
fi
if [[ ! "${SHA256}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: --sha256 '${SHA256}' is not a lowercase sha256 hex digest" >&2; exit 1
fi
if [[ ! -f "${TARBALL}" ]]; then
  echo "error: tarball not found: ${TARBALL}" >&2; exit 1
fi
if [[ ${#SERIES[@]} -eq 0 ]]; then
  SERIES=(noble resolute)
fi
for s in "${SERIES[@]}"; do
  case "${s}" in noble|resolute) ;; *) echo "error: unsupported series '${s}' (expected noble or resolute)" >&2; exit 1 ;; esac
done

TARBALL_BASENAME="$(basename "${TARBALL}")"
if ! [[ "${TARBALL_BASENAME}" =~ Grok_Bot_([0-9]+\.[0-9]+\.[0-9]+)_linux_x64\.tar\.gz ]]; then
  echo "error: tarball name '${TARBALL_BASENAME}' does not match Grok_Bot_<ver>_linux_x64.tar.gz" >&2; exit 1
fi
VER="${BASH_REMATCH[1]}"

# Debian revision (~ppa<N>) mirrors the spec's Release counter: update-spec.sh
# bumps it on every rebuild resync, so re-uploading fixed bytes yields
# <ver>~ppa2~<series>1 instead of a duplicate Launchpad rejects.
PPA_REV="$(sed -nE 's/^Release:[[:space:]]+([0-9]+).*/\1/p' "${REPO_ROOT}/grokbot-linux-port.spec" 2>/dev/null || true)"
PPA_REV="${PPA_REV:-1}"

# Fail fast on re-uploaded bytes under the same NVR — same rationale as spec %prep.
echo "Verifying sha256 of ${TARBALL} ..." >&2
ACTUAL_SUM="$(sha256sum "${TARBALL}" | awk '{print $1}')"
if [[ "${ACTUAL_SUM}" != "${SHA256}" ]]; then
  echo "error: sha256 mismatch for ${TARBALL}" >&2
  echo "  expected: ${SHA256}" >&2
  echo "  actual:   ${ACTUAL_SUM}" >&2
  exit 1
fi
echo "  sha256 OK (${SHA256:0:12}…)" >&2

if [[ "${OUT_DIR}" != /* ]]; then
  OUT_DIR="${REPO_ROOT}/${OUT_DIR}"
fi
# Re-run friendly AND safe: clear the out-dir only when every top-level entry
# is something this script generated; foreign content (--out-dir $HOME) must
# fail loudly, never be wiped.
if [[ -e "${OUT_DIR}" || -L "${OUT_DIR}" ]]; then
  [[ -d "${OUT_DIR}" ]] || { echo "error: --out-dir '${OUT_DIR}' exists and is not a directory" >&2; exit 1; }
  while IFS= read -r -d '' entry; do
    case "$(basename "${entry}")" in
      noble|resolute|grokbot-linux-port_*) ;;
      *) echo "error: --out-dir '${OUT_DIR}' contains foreign entry '$(basename "${entry}")' — remove it first" >&2; exit 1 ;;
    esac
  done < <(find "${OUT_DIR}" -mindepth 1 -maxdepth 1 -print0)
  rm -rf "${OUT_DIR}"
fi
mkdir -p "${OUT_DIR}"

CHANGES_FILES=()
# Every extracted tree (~143 MB each) dies with the process via this trap —
# a mid-build failure must not leave them in /tmp.
WORKDIRS=()
cleanup_workdirs() { [[ ${#WORKDIRS[@]} -eq 0 ]] || rm -rf "${WORKDIRS[@]}"; }
trap cleanup_workdirs EXIT

for SER in "${SERIES[@]}"; do
  echo "==> Building source package for ${SER} (${VER}~ppa${PPA_REV}~${SER}1)" >&2

  WORK="$(mktemp -d -t grokbot-deb-${SER}-XXXXXX)"
  WORKDIRS+=("${WORK}")

  # Extract; tarball roots at Grok_Bot_<ver>_linux_x64 — rename to
  # grokbot-linux-port-<ver> (native Source: name must match directory).
  # Exact-name match so a mislabeled tarball can't package another version's
  # payload under this filename's DEB_VERSION.
  tar -xzf "${TARBALL}" -C "${WORK}"
  SRC_TOP="$(find "${WORK}" -maxdepth 1 -type d -name "Grok_Bot_${VER}_linux_x64" -print -quit)"
  if [[ -z "${SRC_TOP}" ]]; then
    echo "error: could not locate extracted top-level dir in ${WORK}" >&2
    ls -R "${WORK}" | head -n 80 >&2
    exit 1
  fi
  PKG_DIR_NAME="grokbot-linux-port-${VER}"
  PKG_DIR="${WORK}/${PKG_DIR_NAME}"
  if [[ "${SRC_TOP}" != "${PKG_DIR}" ]]; then
    mv "${SRC_TOP}" "${PKG_DIR}"
  fi

  # -----------------------------------------------------------------------
  # debian/ — generated per-series (version differs). Template embedded as
  # heredoc so the repo stays free of tracked debian/ files (native source
  # format would otherwise require them at repo root). debhelper-compat (= 13)
  # pins the compat level without a debian/compat file.
  # -----------------------------------------------------------------------
  mkdir -p "${PKG_DIR}/debian/source"

  # Native format: the tarball is the orig; Launchpad builds with no network.
  cat > "${PKG_DIR}/debian/source/format" <<'FMT'
3.0 (native)
FMT

  DEB_VERSION="${VER}~ppa${PPA_REV}~${SER}1"
  DEB_DATE="$(LC_ALL=C date -R -u)"

  cat > "${PKG_DIR}/debian/changelog" <<CHLOG
grokbot-linux-port (${DEB_VERSION}) ${SER}; urgency=medium

  * Sync with upstream release v${VER}

 -- Nichokas <nichokas@users.noreply.github.com>  ${DEB_DATE}
CHLOG

  cat > "${PKG_DIR}/debian/control" <<'CTRL'
Source: grokbot-linux-port
Section: utils
Priority: optional
Maintainer: Nichokas <nichokas@users.noreply.github.com>
Standards-Version: 4.6.2
Build-Depends: debhelper-compat (= 13)
Rules-Requires-Root: binary-targets
Homepage: https://github.com/Nichokas/grokbot-linux-port

Package: grokbot-linux-port
Architecture: amd64
Depends: ${misc:Depends}, libgtk-3-0t64 | libgtk-3-0, libnss3, libxss1, libxtst6, libxrandr2, libxdamage1, libxcomposite1, libxfixes3, libdrm2, libgbm1, libxkbcommon0, libasound2t64 | libasound2, libatspi2.0-0t64 | libatspi2.0-0, libcups2t64 | libcups2, libcairo2, libpango-1.0-0, libexpat1, hicolor-icon-theme
Recommends: libnotify-bin
Provides: grok-bot, grokbot
Conflicts: grok-bot, grokbot
Description: Grok Bot desktop agent for Linux (wine-less port)
 Grok Bot desktop agent for Linux without Wine: the official Windows (NSIS)
 payload fused with Electron 42.1.0 and native modules rebuilt for Linux.
 This package installs the prebuilt tarball published on GitHub Releases by
 the grokbot-linux-port CI.
CTRL

  # /opt is where self-contained vendor bundles belong (Chrome, Slack, Discord
  # do the same); lintian flags any /opt path as error unless overridden here.
  cat > "${PKG_DIR}/debian/grokbot-linux-port.lintian-overrides" <<'OVR'
# Electron bundle ships every library it needs; /opt/grokbot-linux-port is the
# conventional home for self-contained vendor apps (same layout as RPM/AUR).
grokbot-linux-port: dir-or-file-in-opt
grokbot-linux-port: no-manual-page
OVR

  cat > "${PKG_DIR}/debian/copyright" <<COPY
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Source: https://github.com/Nichokas/grokbot-linux-port

Files: *
Copyright: Nichokas and Grok Bot upstream
License: Proprietary
 Grok Bot is proprietary software. This package fetches the prebuilt Linux
 tarball published at https://github.com/Nichokas/grokbot-linux-port/releases.
 See upstream terms at https://grok.com and inside resources/app.asar.
COPY

  # Minimal dh rules. Install mirrors RPM/AUR: /opt/grokbot-linux-port + symlinks
  # + desktop file + best-effort icon (loose PNG or asar-extracted). fixperms
  # re-applies chrome-sandbox 4755 after dh_fixperms strips it — it only runs
  # on the binary build inside Launchpad (-S runs clean only), which is where
  # setuid matters.
  cat > "${PKG_DIR}/debian/rules" <<'RULES'
#!/usr/bin/make -f
%:
	dh $@

override_dh_auto_build:
	# prebuilt payload — nothing to compile

override_dh_auto_install:
	install -d debian/grokbot-linux-port/opt/grokbot-linux-port
	install -d debian/grokbot-linux-port/usr/bin
	install -d debian/grokbot-linux-port/usr/share/applications
	install -d debian/grokbot-linux-port/usr/share/icons/hicolor/256x256/apps
	tar cf - --exclude=debian . | (cd debian/grokbot-linux-port/opt/grokbot-linux-port && tar xf -)
	chmod -R u+rwX,go+rX,go-w debian/grokbot-linux-port/opt/grokbot-linux-port || true
	if [ ! -x debian/grokbot-linux-port/opt/grokbot-linux-port/grok-bot ] && [ -x debian/grokbot-linux-port/opt/grokbot-linux-port/electron ]; then \
	  mv debian/grokbot-linux-port/opt/grokbot-linux-port/electron debian/grokbot-linux-port/opt/grokbot-linux-port/grok-bot; \
	fi
	chmod +x debian/grokbot-linux-port/opt/grokbot-linux-port/grok-bot || true
	ln -sf /opt/grokbot-linux-port/grok-bot debian/grokbot-linux-port/usr/bin/grok-bot
	ln -sf /opt/grokbot-linux-port/grok-bot debian/grokbot-linux-port/usr/bin/grokbot
	printf '[Desktop Entry]\nName=Grok Bot\nGenericName=Grok Bot\nComment=Grok Bot desktop agent (Linux port)\nExec=/opt/grokbot-linux-port/grok-bot %%U\nIcon=grok-bot\nType=Application\nCategories=Utility;Development;\nStartupWMClass=grok-bot\nMimeType=x-scheme-handler/grokbot;\nTerminal=false\n' > debian/grokbot-linux-port/usr/share/applications/grok-bot.desktop
	icon=""; \
	for cand in debian/grokbot-linux-port/opt/grokbot-linux-port/grok-bot.png \
	  debian/grokbot-linux-port/opt/grokbot-linux-port/resources/app.asar.unpacked/dist/renderer/assets/app-icon-*.png; do \
	  if [ -f "$$cand" ]; then icon="$$cand"; break; fi; \
	done; \
	if [ -z "$$icon" ]; then icon=$$(find debian/grokbot-linux-port/opt/grokbot-linux-port -name 'app-icon*.png' -print -quit 2>/dev/null || true); fi; \
	if [ -n "$$icon" ] && [ -f "$$icon" ]; then \
	  install -m644 "$$icon" debian/grokbot-linux-port/usr/share/icons/hicolor/256x256/apps/grok-bot.png; \
	elif [ -f debian/grokbot-linux-port/opt/grokbot-linux-port/resources/app.asar ]; then \
	  python3 debian/extract-helper.py debian/grokbot-linux-port/opt/grokbot-linux-port/resources/app.asar debian/grokbot-linux-port/usr/share/icons/hicolor/256x256/apps/grok-bot.png || true; \
	fi

override_dh_fixperms:
	dh_fixperms
	if [ -f debian/grokbot-linux-port/opt/grokbot-linux-port/chrome-sandbox ]; then chmod 4755 debian/grokbot-linux-port/opt/grokbot-linux-port/chrome-sandbox || true; fi

# Helper extracted at build time — keeps the asar parser out of shell quoting hell
RULES
  chmod 755 "${PKG_DIR}/debian/rules"

  # Ship the asar icon helper alongside sources (referenced by rules); excluded
  # from the installed payload by the --exclude=debian tar above, and harmless
  # as a native source file.
  if [[ -f "${REPO_ROOT}/scripts/extract-asar-icon.py" ]]; then
    cp "${REPO_ROOT}/scripts/extract-asar-icon.py" "${PKG_DIR}/debian/extract-helper.py"
  else
    # Fallback: embed the minimal asar walker inline if the helper is absent
    cat > "${PKG_DIR}/debian/extract-helper.py" <<'PYHELPER'
import json, pathlib, struct, sys
def walk(node, prefix=""):
    for name, meta in node.get("files", {}).items():
        path = f"{prefix}/{name}" if prefix else name
        if "files" in meta:
            yield from walk(meta, path)
        else:
            yield path, meta
try:
    asar, dest = sys.argv[1], sys.argv[2]
    import json as _j
    with open(asar, "rb") as fh:
        if struct.unpack("<I", fh.read(4))[0] != 4:
            raise SystemExit("bad asar pickle")
        hs = struct.unpack("<I", fh.read(4))[0]
        hp = fh.read(hs)
        sl = struct.unpack_from("<I", hp, 4)[0]
        hdr = _j.loads(hp[8:8+sl])
        hits = [(p,m) for p,m in walk(hdr) if p.rsplit("/",1)[-1].startswith("app-icon") and p.endswith(".png") and "offset" in m]
        if not hits:
            raise SystemExit("no app-icon*.png in asar")
        p,m = max(hits, key=lambda x: int(x[1]["size"]))
        fh.seek(8+hs+int(m["offset"]))
        blob = fh.read(int(m["size"]))
        if blob[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit("not a PNG")
        pathlib.Path(dest).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(dest).write_bytes(blob)
except Exception as e:
    raise SystemExit(f"error: {e}")
PYHELPER
  fi

  # dpkg-buildpackage -S: source-only (Launchpad builds the binary).
  # Unsigned (-us -uc) for local lint; -k<KEYID> signs .dsc/.changes for PPA.
  echo "  dpkg-buildpackage -S for ${SER} ..." >&2
  pushd "${PKG_DIR}" >/dev/null
  if [[ -n "${SIGN_KEY}" ]]; then
    dpkg-buildpackage -S -k"${SIGN_KEY}" -d 2>&1 | sed 's/^/  [dpkg] /' >&2
  else
    dpkg-buildpackage -S -us -uc -d 2>&1 | sed 's/^/  [dpkg] /' >&2
  fi
  popd >/dev/null

  OUT_SERIES="${OUT_DIR}/${SER}"
  mkdir -p "${OUT_SERIES}"
  shopt -s nullglob
  # Native package leaves .dsc, .tar.gz/.tar.xz, _source.changes, .buildinfo in WORK
  for f in "${WORK}"/grokbot-linux-port*.* "${WORK}"/*.dsc "${WORK}"/*.changes "${WORK}"/*.buildinfo "${WORK}"/*.tar.*; do
    [[ -f "${f}" ]] || continue
    mv -f "${f}" "${OUT_SERIES}/"
  done
  shopt -u nullglob

  if ! ls "${OUT_SERIES}"/*.dsc >/dev/null 2>&1; then
    echo "error: no .dsc produced for ${SER}" >&2; exit 1
  fi
  if ! ls "${OUT_SERIES}"/*_source.changes >/dev/null 2>&1; then
    echo "error: no _source.changes produced for ${SER}" >&2; exit 1
  fi

  for ch in "${OUT_SERIES}"/*_source.changes; do
    CHANGES_FILES+=("${ch}")
  done

  echo "  -> ${OUT_SERIES}/ ($(ls -1 "${OUT_SERIES}" | tr '\n' ' '))" >&2
done

echo "" >&2
echo "Source packages ready for dput:" >&2
for ch in "${CHANGES_FILES[@]}"; do
  echo "  dput ppa:nichito/grokbot-linux-port ${ch}" >&2
  echo "${ch}"
done
