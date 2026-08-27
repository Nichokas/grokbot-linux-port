#!/usr/bin/env bash
set -euo pipefail
# update-aur.sh — bump pkgver/sha256sums and regenerate .SRCINFO for both AUR packages
#
# Usage:
#   scripts/update-aur.sh 0.20.0
#   scripts/update-aur.sh --no-download 0.20.0                                  # trust existing sums / skip hashing / bump pkgrel
#   scripts/update-aur.sh --bin-sum-x64 <s> [--bin-sum-arm64 <s>] 0.20.0        # -bin sums pre-hashed by the release job
#   scripts/update-aur.sh --bin-only --bin-sum-x64 <s> [--bin-sum-arm64 <s>] 0.20.0  # touch only the -bin package (rebuild resync)
#   scripts/update-aur.sh --bin-only --bin-sum <s> 0.20.0                       # legacy: --bin-sum is treated as x64
#
# --bin-sum-{x64,arm64} exist because the release job hashes the artifact bytes
# it just uploaded: hashing the freshly-published URL again would race GitHub's
# CDN propagation and can bake a sum for bytes the CDN no longer serves. The
# source package always hashes the tag tarball itself — the tag already exists
# at release-publish time, so there is no race.
#
# The -bin PKGBUILD only bumps pkgver when BOTH arch sums are present, otherwise
# the missing branch's makepkg would download the new version with the old
# digest and fail. The build matrix in auto-update.yml may have published only
# one arch this run; in that case we skip and warn instead of corrupting AUR.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NO_DOWNLOAD=false
BIN_SUM_X64=""
BIN_SUM_ARM64=""
BIN_SUM=""
BIN_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-download)
      NO_DOWNLOAD=true
      shift
      ;;
    --bin-sum)
      # Legacy single-arch form: feeds the x64 slot so the existing release
      # job that only builds x64 keeps working without code churn.
      BIN_SUM_X64="${2:?'--bin-sum requires a sha256 argument'}"
      BIN_SUM="${BIN_SUM_X64}"
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
  echo "usage: $(basename "$0") [--no-download] [--bin-only] [--bin-sum-x64 <sha>] [--bin-sum-arm64 <sha>] [--bin-sum <sha>] <x.y.z>" >&2
  exit 1
fi
VER="$1"
if ! [[ "${VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version '${VER}' does not match x.y.z" >&2
  exit 1
fi
for v in BIN_SUM BIN_SUM_X64 BIN_SUM_ARM64; do
  if [[ -n "${!v}" && ! "${!v}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: ${v} '${!v}' is not a lowercase sha256 hex digest" >&2
    exit 1
  fi
done

# --bin-only exists to skip the source-tarball fetch (the upstream tag
# archive is stable across rebuilds; only the prebuilt bytes change). It
# must still receive a sum to validate, otherwise the bump would be silent
# and the AUR tree would drift. This guard fails loudly: a caller that
# forgot --bin-sum-* / --bin-sum wants the previous "exit 0" behaviour
# turned into a hard error.
if [[ "${BIN_ONLY}" == "true" ]]; then
  if [[ -z "${BIN_SUM_X64}" && -z "${BIN_SUM_ARM64}" && -z "${BIN_SUM}" ]]; then
    echo "error: --bin-only requires --bin-sum-x64 and/or --bin-sum-arm64 (or legacy --bin-sum)" >&2
    exit 1
  fi
fi

update_one() {
  local dir="$1" expect_src="$2" sum="$3" bump_pkgrel="${4:-false}"
  # Per-arch sums: set by the caller via env when present; only slots with
  # non-empty values are written. An empty slot is a deliberate "leave the
  # existing digest alone" signal.
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
    # The -bin PKGBUILD uses per-arch sha256sums_x86_64 / sha256sums_aarch64;
    # the source package keeps the legacy plain sha256sums=(...). ${sum_x64}
    # / ${sum_arm64} are passed as env vars from the caller when applicable;
    # ${sum} is the legacy single-arch value used by the source package.
    if [[ -n "${sum}" || -n "${AUR_SUM_X64:-}" || -n "${AUR_SUM_ARM64:-}" ]]; then
      PKGBUILD="${pkgbuild}" SUM="${sum:-}" AUR_SUM_X64="${AUR_SUM_X64:-}" AUR_SUM_ARM64="${AUR_SUM_ARM64:-}" python3 - <<'PY'
import os, re, pathlib
pkgbuild = pathlib.Path(os.environ["PKGBUILD"])
sum_legacy = os.environ.get("SUM", "")
sum_x64 = os.environ.get("AUR_SUM_X64", "")
sum_arm64 = os.environ.get("AUR_SUM_ARM64", "")
t = pkgbuild.read_text()
# Per-arch sums: only the slot whose value is non-empty gets touched.
def replace_per_arch(t, var, val):
    if not val:
        return t
    pat = re.compile(rf'(?m)^{var}=\(([^)]*)\)')
    return pat.sub(f"{var}=('{val}')", t, count=1)
t = replace_per_arch(t, "sha256sums_x86_64", sum_x64)
t = replace_per_arch(t, "sha256sums_aarch64", sum_arm64)
# Legacy single-arch sha256sums=(...) used by the source package.
if sum_legacy:
    t = re.sub(r"sha256sums=\(([^)]*)\)", f"sha256sums=('{sum_legacy}')", t, count=1)
pkgbuild.write_text(t)
print(f"updated sha256sums in {pkgbuild}")
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
    # Sync source_x86_64 / source_aarch64 (and any other source_*) lines,
    # not just source=. The -bin PKGBUILD uses per-arch source arrays.
    def replace_source(t_pat, val):
        if not val:
            return
        # expand ${pkgver} / $pkgver
        v = val.replace("${pkgver}", VER_FALLBACK).replace("$pkgver", VER_FALLBACK)
        s = re.sub(rf"(?m)^\s*{re.escape(t_pat)} =.*", f"\t{t_pat} = {v}", s, count=1)
    for m_src in re.finditer(r"^source(_[A-Za-z0-9_]+)?=([^\n]+)", t, re.MULTILINE):
        var = m_src.group(0).split("=", 1)[0]
        # Pull the URL out: source_x86_64=(...::URL) — same shape for plain source=
        raw = m_src.group(2)
        # raw looks like ('name::url') — extract url
        url_m = re.search(r"::([^'\")]+)", raw)
        if url_m:
            replace_source(var, url_m.group(1).strip())
    m = re.search(r"sha256sums=\(([^)]*)\)", t)
    if m:
        sums = re.findall(r"'([^']*)'|\"([^\"]*)\"", m.group(1))
        flat = [a or b for a,b in sums]
        if flat:
            s = re.sub(r"(?m)^\s*sha256sums =.*", f"	sha256sums = {flat[0]}", s, count=1)
    # Per-arch sha256sums_x86_64 / sha256sums_aarch64
    for arch_var in ("sha256sums_x86_64", "sha256sums_aarch64"):
        m = re.search(rf"^{arch_var}=\(([^)]*)\)", t, re.MULTILINE)
        if m:
            sums = re.findall(r"'([^']*)'|\"([^\"]*)\"", m.group(1))
            flat = [a or b for a,b in sums]
            if flat:
                s = re.sub(rf"(?m)^\s*{re.escape(arch_var)} =.*", f"\t{arch_var} = {flat[0]}", s, count=1)
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

# -bin: fetch each arch's tarball sum independently. Caller-supplied sums
# (--bin-sum-x64 / --bin-sum-arm64) take precedence so the release job can
# hand off fresh bytes without a re-download race. Hashing defaults to x64
# only when the caller did not pass anything; arm64 stays empty unless
# explicitly supplied, which is the current CI default (build matrix has
# x64 enabled, arm64 still rolling out).
if [[ -z "${BIN_SUM_X64}" ]]; then
  BIN_TARBALL_URL_X64="https://github.com/Nichokas/grokbot-linux-port/releases/download/v${VER}/Grok_Bot_${VER}_linux_x64.tar.gz"
  echo "Hashing release tarball: ${BIN_TARBALL_URL_X64}" >&2
  if curl --head --fail --silent --location --max-time 15 "${BIN_TARBALL_URL_X64}" >/dev/null 2>&1; then
    BIN_SUM_X64="$(curl --fail --silent --show-error --location --retry 2 --max-time 300 "${BIN_TARBALL_URL_X64}" | sha256sum | awk '{print $1}')"
    echo "  -> x64: ${BIN_SUM_X64}" >&2
  else
    echo "warn: x64 release tarball not yet available (release may not be published)" >&2
  fi
fi
if [[ -z "${BIN_SUM_ARM64}" ]]; then
  BIN_TARBALL_URL_ARM64="https://github.com/Nichokas/grokbot-linux-port/releases/download/v${VER}/Grok_Bot_${VER}_linux_arm64.tar.gz"
  echo "Hashing release tarball: ${BIN_TARBALL_URL_ARM64}" >&2
  if curl --head --fail --silent --location --max-time 15 "${BIN_TARBALL_URL_ARM64}" >/dev/null 2>&1; then
    BIN_SUM_ARM64="$(curl --fail --silent --show-error --location --retry 2 --max-time 300 "${BIN_TARBALL_URL_ARM64}" | sha256sum | awk '{print $1}')"
    echo "  -> arm64: ${BIN_SUM_ARM64}" >&2
  else
    echo "warn: arm64 release tarball not yet available (release may not be published)" >&2
  fi
fi

# Guard (fix #2): the -bin PKGBUILD only bumps pkgver when BOTH arch sums
# are present. If only one branch has a digest, bumping the shared pkgver
# would leave the other branch with a stale checksum — that branch's
# makepkg would then download the new version with the old digest and
# fail. Skip + warn instead of corrupting AUR. The next CI run that
# publishes both arches will pick up cleanly.
if [[ -n "${BIN_SUM_X64}" && -n "${BIN_SUM_ARM64}" ]]; then
  AUR_SUM_X64="${BIN_SUM_X64}" AUR_SUM_ARM64="${BIN_SUM_ARM64}" update_one "${BIN_PKG_DIR}" "" "" "${BIN_ONLY}"
elif [[ -n "${BIN_SUM_X64}" || -n "${BIN_SUM_ARM64}" ]]; then
  if [[ "${BIN_ONLY}" == "true" ]]; then
    echo "warn: --bin-only with only one arch sum present; skipping -bin bump to avoid stale checksum (re-run after both arches publish)" >&2
  else
    # Fresh-version path: the source PKGBUILD's pkgver was just bumped
    # above, but the -bin PKGBUILD would diverge. Echo the divergence and
    # let the next rebuild resync (--bin-only) pick up the missing arch.
    echo "warn: only one arch sum present; skipping -bin bump to avoid stale checksum (x64=${BIN_SUM_X64:-<empty>} arm64=${BIN_SUM_ARM64:-<empty>})" >&2
  fi
else
  echo "note: no release tarball available — skipping grokbot-linux-port-bin bump (re-run: scripts/update-aur.sh ${VER})" >&2
fi

echo "done — review with: git diff aur/"
