#!/usr/bin/env bash
set -euo pipefail
# update-aur.sh — bump pkgver/sha256sums and regenerate .SRCINFO for the
# grokbot-linux-port-bin AUR package
#
# Usage:
#   scripts/update-aur.sh 0.20.0                                     # hash release tarballs, bump pkgver
#   scripts/update-aur.sh --bin-sum-x64 <s> --bin-sum-arm64 <s> 0.20.0  # sums pre-hashed by the release job
#   scripts/update-aur.sh --bin-only --bin-sum-x64 <s> [--bin-sum-arm64 <s>] 0.20.0  # rebuild resync: pkgrel bump only
#
# --bin-sum-{x64,arm64} exist because the release job hashes the artifact bytes
# it just uploaded: hashing the freshly-published URL again would race GitHub's
# CDN propagation and can bake a sum for bytes the CDN no longer serves.
#
# The PKGBUILD only bumps pkgver when BOTH arch sums are present, otherwise
# the missing branch's makepkg would download the new version with the old
# digest and fail. The build in auto-update.yml publishes both arches in one
# job, so a half-published release leaves the bump skipped with a warning.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BIN_SUM_X64=""
BIN_SUM_ARM64=""
BIN_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-sum)
      # Legacy single-arch form: feeds the x64 slot.
      BIN_SUM_X64="${2:?'--bin-sum requires a sha256 argument'}"
      shift 2
      ;;
    --bin-sum-x64)
      BIN_SUM_X64="${2:?'--bin-sum-x64 requires a sha256 argument'}"
      shift 2
      ;;
    --bin-sum-arm64)
      BIN_SUM_ARM64="${2:?'--bin-sum-arm64 requires a sha256 argument'}"
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
  echo "usage: $(basename "$0") [--bin-only] [--bin-sum-x64 <sha>] [--bin-sum-arm64 <sha>] <x.y.z>" >&2
  exit 1
fi
VER="$1"
if ! [[ "${VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version '${VER}' does not match x.y.z" >&2
  exit 1
fi
for v in BIN_SUM_X64 BIN_SUM_ARM64; do
  if [[ -n "${!v}" && ! "${!v}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: ${v} '${!v}' is not a lowercase sha256 hex digest" >&2
    exit 1
  fi
done

# --bin-only (rebuild resync) must still receive a sum to validate, otherwise
# the bump would be silent and the AUR tree would drift. This guard fails
# loudly: a caller that forgot --bin-sum-* wants a hard error, not a no-op.
if [[ "${BIN_ONLY}" == "true" ]]; then
  if [[ -z "${BIN_SUM_X64}" && -z "${BIN_SUM_ARM64}" ]]; then
    echo "error: --bin-only requires --bin-sum-x64 and/or --bin-sum-arm64" >&2
    exit 1
  fi
fi

PKG_DIR="${REPO_ROOT}/aur/grokbot-linux-port-bin"
PKG_BUILD="${PKG_DIR}/PKGBUILD"
[[ -f "${PKG_BUILD}" ]] || { echo "error: ${PKG_BUILD} missing" >&2; exit 1; }

if [[ "${BIN_ONLY}" != "true" ]]; then
  sed -i -E "s/^pkgver=.*/pkgver=${VER}/" "${PKG_BUILD}"
fi

# -bin: fetch each arch's tarball sum independently. Caller-supplied sums
# (--bin-sum-x64 / --bin-sum-arm64) take precedence so the release job can
# hand off fresh bytes without a re-download race. Hashing the release URL is
# the fallback for a manual invocation; an arch whose tarball is absent from
# the release leaves its slot empty and the guard below skips the bump.
if [[ -z "${BIN_SUM_X64}" ]]; then
  url="https://github.com/Nichokas/grokbot-linux-port/releases/download/v${VER}/Grok_Bot_${VER}_linux_x64.tar.gz"
  echo "Hashing release tarball: ${url}" >&2
  if curl --head --fail --silent --location --max-time 15 "${url}" >/dev/null 2>&1; then
    BIN_SUM_X64="$(curl --fail --silent --show-error --location --retry 2 --max-time 300 "${url}" | sha256sum | awk '{print $1}')"
    echo "  -> x64: ${BIN_SUM_X64}" >&2
  else
    echo "warn: x64 release tarball not yet available (release may not be published)" >&2
  fi
fi
if [[ -z "${BIN_SUM_ARM64}" ]]; then
  url="https://github.com/Nichokas/grokbot-linux-port/releases/download/v${VER}/Grok_Bot_${VER}_linux_arm64.tar.gz"
  echo "Hashing release tarball: ${url}" >&2
  if curl --head --fail --silent --location --max-time 15 "${url}" >/dev/null 2>&1; then
    BIN_SUM_ARM64="$(curl --fail --silent --show-error --location --retry 2 --max-time 300 "${url}" | sha256sum | awk '{print $1}')"
    echo "  -> arm64: ${BIN_SUM_ARM64}" >&2
  else
    echo "warn: arm64 release tarball not yet available (release may not be published)" >&2
  fi
fi

# Guard (fix #2): only bump when BOTH arch sums are present. If only one
# branch has a digest, bumping the shared pkgver would leave the other
# branch with a stale checksum — that branch's makepkg would then download
# the new version with the old digest and fail. Skip + warn instead of
# corrupting AUR; the next CI run that publishes both arches picks up cleanly.
if [[ -z "${BIN_SUM_X64}" || -z "${BIN_SUM_ARM64}" ]]; then
  echo "warn: only one arch sum present (x64=${BIN_SUM_X64:-<empty>} arm64=${BIN_SUM_ARM64:-<empty>}); skipping -bin bump to avoid a stale checksum" >&2
  echo "done — review with: git diff aur/"
  exit 0
fi

if [[ "${BIN_ONLY}" == "true" ]]; then
  # AUR helpers only re-notify users on pkgrel bumps; a same-pkgver rebuild
  # is otherwise invisible to already-installed clients.
  cur_rel="$(sed -nE 's/^pkgrel=([0-9]+).*/\1/p' "${PKG_BUILD}")"
  sed -i -E "s/^pkgrel=.*/pkgrel=$(( ${cur_rel:-1} + 1 ))/" "${PKG_BUILD}"
fi

PKGBUILD_PATH="${PKG_BUILD}" SUM_X64="${BIN_SUM_X64}" SUM_ARM64="${BIN_SUM_ARM64}" python3 - <<'PY'
import os, re, pathlib
pkgbuild = pathlib.Path(os.environ["PKGBUILD_PATH"])
t = pkgbuild.read_text()
for var, val in (("sha256sums_x86_64", os.environ["SUM_X64"]),
                 ("sha256sums_aarch64", os.environ["SUM_ARM64"])):
    pat = re.compile(rf'(?m)^{var}=\(([^)]*)\)')
    t = pat.sub(f"{var}=('{val}')", t, count=1)
pkgbuild.write_text(t)
print(f"updated sha256sums in {pkgbuild}")
PY

if command -v makepkg >/dev/null 2>&1; then
  tmp_srcinfo="$(mktemp)"
  if (cd "${PKG_DIR}" && makepkg --printsrcinfo > "${tmp_srcinfo}"); then
    mv "${tmp_srcinfo}" "${PKG_DIR}/.SRCINFO"
    echo "regenerated ${PKG_DIR}/.SRCINFO"
  else
    rm -f "${tmp_srcinfo}"
    echo "error: makepkg --printsrcinfo failed — .SRCINFO left unchanged" >&2
    exit 1
  fi
else
  # Fallback for CI (ubuntu runners have no makepkg): re-derive .SRCINFO
  # minimally — pkgver/pkgrel + source_* + per-arch sha256sums — so committed
  # metadata never goes stale when makepkg is absent.
  FALLBACK_DIR="${PKG_DIR}" VER_PY="${VER}" PKGBUILD_PATH="${PKG_BUILD}" python3 - <<'PYEOF'
import pathlib, re, os
VER_FALLBACK = os.environ.get("VER_PY", "")
_dir = os.environ.get("FALLBACK_DIR", "")
pkgbuild = pathlib.Path(f"{_dir}/PKGBUILD")
srcinfo = pathlib.Path(f"{_dir}/.SRCINFO")
t = pkgbuild.read_text()
def field(name):
    m = re.search(rf"^{name}=([^\n]+)", t, re.MULTILINE)
    return m.group(1).strip() if m else ""
PKGNAME_FALLBACK = field("pkgname").strip("\"'")
s = srcinfo.read_text()
s = re.sub(r"(?m)^\s*pkgver =.*", f"	pkgver = {field('pkgver').strip() or VER_FALLBACK}", s, count=1)
m_rel = re.search(r"^pkgrel=([^\n]+)", t, re.MULTILINE)
if m_rel:
    s = re.sub(r"(?m)^\s*pkgrel =.*", f"	pkgrel = {m_rel.group(1).strip()}", s, count=1)
# makepkg writes the entries fully expanded, so mirror its substitutions.
def replace_source(s, t_pat, val):
    if not val:
        return s
    for ref, ref_val in (("pkgver", VER_FALLBACK), ("pkgname", PKGNAME_FALLBACK)):
        val = val.replace(f"${{{ref}}}", ref_val).replace(f"${ref}", ref_val)
    return re.sub(rf"(?m)^\s*{re.escape(t_pat)} =.*", f"\t{t_pat} = {val}", s, count=1)
for m_src in re.finditer(r"^source(_[A-Za-z0-9_]+)?=([^\n]+)", t, re.MULTILINE):
    var = m_src.group(0).split("=", 1)[0]
    # Keep the whole quoted entry: makepkg preserves the 'name::url' rename
    # prefix in .SRCINFO, and package() references that renamed file.
    entry_m = re.search(r"""['"]([^'"]+)['"]""", m_src.group(2))
    if entry_m:
        s = replace_source(s, var, entry_m.group(1).strip())
for arch_var in ("sha256sums_x86_64", "sha256sums_aarch64"):
    m = re.search(rf"^{arch_var}=\(([^)]*)\)", t, re.MULTILINE)
    if m:
        sums = re.findall(r"'([^']*)'|\"([^\"]*)\"", m.group(1))
        flat = [a or b for a, b in sums]
        if flat:
            s = re.sub(rf"(?m)^\s*{re.escape(arch_var)} =.*", f"\t{arch_var} = {flat[0]}", s, count=1)
srcinfo.write_text(s)
print(f"fallback patched {srcinfo} (no makepkg)")
PYEOF
fi

echo "done — review with: git diff aur/"
