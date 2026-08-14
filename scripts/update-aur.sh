#!/usr/bin/env bash
set -euo pipefail
# update-aur.sh — bump pkgver/sha256sums and regenerate .SRCINFO for both AUR packages
#
# Usage:
#   scripts/update-aur.sh 0.20.0
#   scripts/update-aur.sh --no-download 0.20.0   # trust existing sums / skip hashing
#
# Fetches sha256 for:
#   grokbot-linux-port     -> source tarball  github.com/.../archive/v<ver>.tar.gz
#   grokbot-linux-port-bin -> release tarball github.com/.../releases/download/v<ver>/Grok_Bot_<ver>_linux_x64.tar.gz
# Updates PKGBUILD pkgver+sha256sums and regenerates .SRCINFO via makepkg --printsrcinfo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NO_DOWNLOAD=false
if [[ "${1:-}" == "--no-download" ]]; then
  NO_DOWNLOAD=true
  shift
fi

if [[ $# -ne 1 ]]; then
  echo "usage: $(basename "$0") [--no-download] <x.y.z>" >&2
  exit 1
fi
VER="$1"
if ! [[ "${VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version '${VER}' does not match x.y.z" >&2
  exit 1
fi

update_one() {
  local dir="$1" expect_src="$2" sum="$3"
  local pkgbuild="${dir}/PKGBUILD"
  [[ -f "${pkgbuild}" ]] || { echo "skip: no ${pkgbuild}" >&2; return 0; }

  # Bump pkgver
  sed -i -E "s/^pkgver=.*/pkgver=${VER}/" "${pkgbuild}"

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

if [[ "${NO_DOWNLOAD}" == "true" ]]; then
  update_one "${REPO_ROOT}/aur/grokbot-linux-port" "" ""
  update_one "${REPO_ROOT}/aur/grokbot-linux-port-bin" "" ""
  exit 0
fi

SRC_TARBALL_URL="https://github.com/Nichokas/grokbot-linux-port/archive/v${VER}.tar.gz"
BIN_TARBALL_URL="https://github.com/Nichokas/grokbot-linux-port/releases/download/v${VER}/Grok_Bot_${VER}_linux_x64.tar.gz"

echo "Hashing source tarball: ${SRC_TARBALL_URL}" >&2
SRC_SUM="$(curl --fail --silent --show-error --location --retry 2 --max-time 120 "${SRC_TARBALL_URL}" | sha256sum | awk '{print $1}')"
echo "  -> ${SRC_SUM}" >&2

echo "Hashing release tarball: ${BIN_TARBALL_URL}" >&2
BIN_SUM=""
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

update_one "${REPO_ROOT}/aur/grokbot-linux-port" "${SRC_TARBALL_URL}" "${SRC_SUM}"
if [[ -n "${BIN_SUM}" ]]; then
  update_one "${REPO_ROOT}/aur/grokbot-linux-port-bin" "${BIN_TARBALL_URL}" "${BIN_SUM}"
else
  echo "note: release tarball not available — skipping grokbot-linux-port-bin bump (re-run: scripts/update-aur.sh ${VER})" >&2
fi

echo "done — review with: git diff aur/"
