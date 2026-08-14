#!/usr/bin/env bash
set -euo pipefail
# update-aur.sh — bump pkgver/sha256sums and regenerate .SRCINFO for both AUR packages
#
# Usage:
#   scripts/update-aur.sh 0.20.0
#   scripts/update-aur.sh --no-download 0.20.0            # trust existing sums / skip hashing / bump pkgrel
#   scripts/update-aur.sh --bin-sum <sha256> 0.20.0       # -bin sum pre-hashed by the release job
#   scripts/update-aur.sh --bin-only --bin-sum <s> 0.20.0 # touch only the -bin package (rebuild resync)
#
# --bin-sum exists because the release job hashes the artifact bytes it just
# uploaded: hashing the freshly-published URL again would race GitHub's CDN
# propagation and can bake a sum for bytes the CDN no longer serves. The
# source package always hashes the tag tarball itself — the tag already
# exists at release-publish time, so there is no race.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NO_DOWNLOAD=false
BIN_SUM=""
BIN_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-download)
      NO_DOWNLOAD=true
      shift
      ;;
    --bin-sum)
      BIN_SUM="${2:?'--bin-sum requires a sha256 argument'}"
      shift 2
      ;;
    --bin-only)
      BIN_ONLY=true
      shift
      ;;
    -*)
      echo "error: unknown flag '$1'" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 1 ]]; then
  echo "usage: $(basename "$0") [--no-download] [--bin-only] [--bin-sum <sha256>] <x.y.z>" >&2
  exit 1
fi
VER="$1"
if ! [[ "${VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version '${VER}' does not match x.y.z" >&2
  exit 1
fi
if [[ -n "${BIN_SUM}" && ! "${BIN_SUM}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: --bin-sum '${BIN_SUM}' is not a lowercase sha256 hex digest" >&2
  exit 1
fi

update_one() {
  local dir="$1" expect_src="$2" sum="$3" bump_pkgrel="${4:-false}"
  local pkgbuild="${dir}/PKGBUILD"
  [[ -f "${pkgbuild}" ]] || { echo "skip: no ${pkgbuild}" >&2; return 0; }

  # Bump pkgver
  sed -i -E "s/^pkgver=.*/pkgver=${VER}/" "${pkgbuild}"

  if [[ "${bump_pkgrel}" == "true" ]]; then
    # AUR helpers only re-notify users on pkgrel bumps; a same-pkgver rebuild
    # is otherwise invisible to already-installed clients.
    local cur_rel
    cur_rel="$(sed -nE 's/^pkgrel=([0-9]+).*/\1/p' "${pkgbuild}")"
    sed -i -E "s/^pkgrel=.*/pkgrel=$(( ${cur_rel:-1} + 1 ))/" "${pkgbuild}"
  fi

  if [[ "${NO_DOWNLOAD}" == "false" ]]; then
    if [[ -n "${sum}" ]]; then
      # Replace first sha256sums occurrence (supports both array forms)
      # Keep quoting intact: sha256sums=('...') or sha256sums=("...")
      python3 - <<PY
import re, pathlib
p = pathlib.Path("${pkgbuild}")
t = p.read_text()
# Replace first sha256sums=(...) with new sum
t2 = re.sub(r"sha256sums=\([^)]*\)", "sha256sums=('${sum}')", t, count=1)
p.write_text(t2)
print("updated sha256sums in ${pkgbuild}")
PY
    fi
  fi

  if command -v makepkg >/dev/null 2>&1; then
    local tmp_srcinfo
    tmp_srcinfo="$(mktemp)"
    if (cd "${dir}" && makepkg --printsrcinfo > "${tmp_srcinfo}"); then
      mv "${tmp_srcinfo}" "${dir}/.SRCINFO"
      echo "regenerated ${dir}/.SRCINFO"
    else
      rm -f "${tmp_srcinfo}"
      echo "error: makepkg --printsrcinfo failed for ${dir} — .SRCINFO left unchanged" >&2
      return 1
    fi
  else
    # Fallback for CI (ubuntu runners have no makepkg): re-derive .SRCINFO
    # minimally — pkgver + sha256sums — via python so committed metadata
    # never goes stale when makepkg is absent.
    FALLBACK_DIR="${dir}" VER_PY="${VER}" PKGBUILD_PATH="${dir}/PKGBUILD" python3 - <<'PYEOF'
import pathlib, re, os
VER_FALLBACK = os.environ.get("VER_PY", "")
_dir = os.environ.get("FALLBACK_DIR", "")
pkgbuild = pathlib.Path(f"{_dir}/PKGBUILD")
srcinfo = pathlib.Path(f"{_dir}/.SRCINFO")
t = pkgbuild.read_text()
def field(name):
    m = re.search(rf"^{name}=([^\n]+)", t, re.MULTILINE)
    return m.group(1).strip() if m else ""
if srcinfo.exists():
    s = srcinfo.read_text()
    s = re.sub(r"(?m)^\s*pkgver =.*", f"	pkgver = {field('pkgver').strip() or VER_FALLBACK}", s, count=1)
    m_rel = re.search(r"^pkgrel=([^\n]+)", t, re.MULTILINE)
    if m_rel:
        s = re.sub(r"(?m)^\s*pkgrel =.*", f"	pkgrel = {m_rel.group(1).strip()}", s, count=1)
    m_src = re.search(r"^source=.*", t, re.MULTILINE)
    if m_src:
        raw_src = m_src.group(0)
        # Expand PKGBUILD variables that makepkg would
        m_pkg = re.search(r"^pkgname=([^\n]+)", t, re.MULTILINE)
        pkgname = m_pkg.group(1).strip().strip("\"'") if m_pkg else ""
        expanded = raw_src.replace("${pkgname}", pkgname).replace("$pkgname", pkgname).replace("${pkgver}", VER_FALLBACK).replace("$pkgver", VER_FALLBACK)
        try:
            src_val = expanded.split("=",1)[1].strip()
            src_val = src_val.strip()
            if src_val.startswith("(") and src_val.endswith(")"):
                src_val = src_val[1:-1].strip()
            if (src_val.startswith('"') and src_val.endswith('"')) or (src_val.startswith("'") and src_val.endswith("'")):
                src_val = src_val[1:-1]
            src_val = src_val.strip().strip('"').strip("'").strip()
            if src_val.startswith("("):
                src_val = src_val[1:]
            if src_val.endswith(")"):
                src_val = src_val[:-1]
            src_val = src_val.strip().strip('"').strip("'").strip()
            s = re.sub(r"(?m)^\s*source =.*", f"	source = {src_val}", s, count=1)
        except Exception:
            pass
    m = re.search(r"sha256sums=\(([^)]*)\)", t)
    if m:
        sums = re.findall(r"'([^']*)'|\"([^\"]*)\"", m.group(1))
        flat = [a or b for a,b in sums]
        if flat:
            s = re.sub(r"(?m)^\s*sha256sums =.*", f"	sha256sums = {flat[0]}", s, count=1)
    srcinfo.write_text(s)
    print(f"fallback patched {srcinfo} (no makepkg)")
else:
    print(f"warn: no {srcinfo} to patch and no makepkg — .SRCINFO not regenerated for {_dir}" , flush=True)
PYEOF
  fi
}

SRC_PKG_DIR="${REPO_ROOT}/aur/grokbot-linux-port"
BIN_PKG_DIR="${REPO_ROOT}/aur/grokbot-linux-port-bin"

# A rebuild resync only touches the binary package: same upstream source,
# freshly rebuilt release bytes. --no-download means the caller just wants
# pkgver/pkgrel metadata updated without hashing anything.
if [[ "${NO_DOWNLOAD}" == "true" ]]; then
  if [[ "${BIN_ONLY}" == "true" ]]; then
    update_one "${BIN_PKG_DIR}" "" "" true
  else
    update_one "${SRC_PKG_DIR}" "" "" true
    update_one "${BIN_PKG_DIR}" "" "" true
  fi
  echo "done — review with: git diff aur/"
  exit 0
fi

if [[ "${BIN_ONLY}" != "true" ]]; then
  SRC_TARBALL_URL="https://github.com/Nichokas/grokbot-linux-port/archive/v${VER}.tar.gz"
  echo "Hashing source tarball: ${SRC_TARBALL_URL}" >&2
  SRC_SUM="$(curl --fail --silent --show-error --location --retry 2 --max-time 120 "${SRC_TARBALL_URL}" | sha256sum | awk '{print $1}')"
  echo "  -> ${SRC_SUM}" >&2
  update_one "${SRC_PKG_DIR}" "${SRC_TARBALL_URL}" "${SRC_SUM}"
fi

BIN_TARBALL_URL="https://github.com/Nichokas/grokbot-linux-port/releases/download/v${VER}/Grok_Bot_${VER}_linux_x64.tar.gz"
if [[ -z "${BIN_SUM}" ]]; then
  echo "Hashing release tarball: ${BIN_TARBALL_URL}" >&2
  # HEAD probes can 403 on some CDNs while GET succeeds — try HEAD first, then attempt GET hash directly.
  if curl --head --fail --silent --location --max-time 15 "${BIN_TARBALL_URL}" >/dev/null 2>&1; then
    BIN_SUM="$(curl --fail --silent --show-error --location --retry 2 --max-time 300 "${BIN_TARBALL_URL}" | sha256sum | awk '{print $1}')"
    echo "  -> ${BIN_SUM}" >&2
  else
    echo "HEAD probe failed — attempting GET hash as fallback..." >&2
    _fallback_tmp="$(mktemp)"
    if curl --fail --silent --show-error --location --retry 2 --max-time 300 -o "${_fallback_tmp}" "${BIN_TARBALL_URL}" 2>/dev/null && [[ -s "${_fallback_tmp}" ]]; then
      _fallback_sum="$(sha256sum "${_fallback_tmp}" | awk '{print $1}')"
    else
      _fallback_sum=""
    fi
    rm -f "${_fallback_tmp}"
    if [[ -n "${_fallback_sum}" && "${#_fallback_sum}" -eq 64 ]]; then
      BIN_SUM="${_fallback_sum}"
      echo "  -> ${BIN_SUM} (via GET fallback)" >&2
    else
      BIN_SUM=""
      echo "warn: release tarball not yet available (release may not be published) — leaving -bin untouched" >&2
    fi
    unset _fallback_sum
  fi
else
  echo "Using caller-supplied -bin sha256: ${BIN_SUM}" >&2
fi

if [[ -n "${BIN_SUM}" ]]; then
  # pkgrel bumps only on rebuild resyncs (--bin-only): a fresh pkgver resets
  # to pkgrel=1 by convention handled at PKGBUILD authoring time.
  update_one "${BIN_PKG_DIR}" "${BIN_TARBALL_URL}" "${BIN_SUM}" "${BIN_ONLY}"
else
  echo "note: release tarball not available — skipping grokbot-linux-port-bin bump (re-run: scripts/update-aur.sh ${VER})" >&2
fi

echo "done — review with: git diff aur/"
