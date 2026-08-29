#!/usr/bin/env bash
set -euo pipefail
# update-spec.sh — sync grokbot-linux-port.spec with a GitHub release
#
# Usage:
#   scripts/update-spec.sh <x.y.z>                                       # fresh version: Version=x.y.z, Release=1, re-hash tarballs
#   scripts/update-spec.sh --bump-release <x.y.z>                        # rebuild resync: keep Version, bump Release, re-hash
#   scripts/update-spec.sh --sum-x64 <sha> [--sum-arm64 <sha>] [--bump-release] <x.y.z>
#   scripts/update-spec.sh --arch arm64 --sum <sha> <x.y.z>              # legacy single-arch form
#
# --sum-x64 / --sum-arm64 exist for the same reason update-aur.sh has
# --bin-sum: the release job hashes the artifact bytes it just uploaded;
# re-hashing the published URL would race GitHub's CDN propagation and
# can bake a sum for bytes the CDN no longer serves. The spec carries BOTH
# sums in Source{0,1} so a single SRPM works for COPR's x86_64 and aarch64
# chroots; --arch (default x64) only changes which sum update-spec.sh re-hashes
# when --sum is omitted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPEC="${REPO_ROOT}/grokbot-linux-port.spec"

SUM_X64=""
SUM_ARM64=""
BUMP_RELEASE=false
ARCH="x64"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sum)
      # Legacy single-arch form: feeds the active --arch slot.
      if [[ "${ARCH}" == "arm64" ]]; then
        SUM_ARM64="${2:?'--sum requires a sha256 argument'}"
      else
        SUM_X64="${2:?'--sum requires a sha256 argument'}"
      fi
      shift 2
      ;;
    --sum-x64)
      SUM_X64="${2:?'--sum-x64 requires a sha256 argument'}"
      shift 2
      ;;
    --sum-arm64)
      SUM_ARM64="${2:?'--sum-arm64 requires a sha256 argument'}"
      shift 2
      ;;
    --bump-release)
      BUMP_RELEASE=true
      shift
      ;;
    --arch)
      ARCH="${2:?'--arch requires x64 or arm64'}"
      shift 2
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
  echo "usage: $(basename "$0") [--sum-x64 <sha>] [--sum-arm64 <sha>] [--bump-release] [--arch x64|arm64] <x.y.z>" >&2
  exit 1
fi
VER="$1"
if ! [[ "${VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version '${VER}' does not match x.y.z" >&2
  exit 1
fi
case "${ARCH}" in
  x64|arm64) ;;
  *) echo "error: --arch must be x64 or arm64 (got '${ARCH}')" >&2; exit 1 ;;
esac
for v in SUM_X64 SUM_ARM64; do
  if [[ -n "${!v}" && ! "${!v}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: ${v} '${!v}' is not a lowercase sha256 hex digest" >&2
    exit 1
  fi
done
[[ -f "${SPEC}" ]] || { echo "error: ${SPEC} not found" >&2; exit 1; }

# If a sum for the active arch was not supplied, re-hash the release tarball.
# The other arch is left untouched unless --sum-* is given for it.
if [[ -z "${SUM_X64}" && "${ARCH}" == "x64" ]]; then
  URL_X64="https://github.com/Nichokas/grokbot-linux-port/releases/download/v${VER}/Grok_Bot_${VER}_linux_x64.tar.gz"
  echo "Hashing release tarball: ${URL_X64}" >&2
  SUM_X64="$(curl --fail --silent --show-error --location --retry 2 --max-time 300 "${URL_X64}" | sha256sum | awk '{print $1}')"
  echo "  -> ${SUM_X64}" >&2
fi
if [[ -z "${SUM_ARM64}" && "${ARCH}" == "arm64" ]]; then
  URL_ARM64="https://github.com/Nichokas/grokbot-linux-port/releases/download/v${VER}/Grok_Bot_${VER}_linux_arm64.tar.gz"
  echo "Hashing release tarball: ${URL_ARM64}" >&2
  SUM_ARM64="$(curl --fail --silent --show-error --location --retry 2 --max-time 300 "${URL_ARM64}" | sha256sum | awk '{print $1}')"
  echo "  -> ${SUM_ARM64}" >&2
fi

CUR_VER="$(sed -nE 's/^Version:[[:space:]]+([^[:space:]]+).*/\1/p' "${SPEC}")"
CUR_REL="$(sed -nE 's/^Release:[[:space:]]+([0-9]+).*/\1/p' "${SPEC}")"
CUR_SUM_X64="$(sed -nE 's/^echo "([0-9a-f]{64})  %\{_sourcedir\}\/Grok_Bot_.*_linux_x64\.tar\.gz".*/\1/p' "${SPEC}" | head -n1)"
CUR_SUM_ARM64="$(sed -nE 's/^echo "([0-9a-f]{64})  %\{_sourcedir\}\/Grok_Bot_.*_linux_arm64\.tar\.gz".*/\1/p' "${SPEC}" | head -n1)"

if [[ "${BUMP_RELEASE}" == "true" ]]; then
  REL=$(( ${CUR_REL:-1} + 1 ))
else
  REL=1
fi

# Idempotency: a re-dispatch of the same version+bytes must not stack
# duplicate changelog entries or produce a noisy no-op commit. Only check
# the sum we actually have a value for; an empty slot means "leave the
# existing digest alone" and is not a no-op trigger.
idempotent=true
[[ "${CUR_VER}" == "${VER}" && "${CUR_REL}" == "${REL}" ]] || idempotent=false
if [[ -n "${SUM_X64}" && "${CUR_SUM_X64}" != "${SUM_X64}" ]]; then
  idempotent=false
fi
if [[ -n "${SUM_ARM64}" && "${CUR_SUM_ARM64}" != "${SUM_ARM64}" ]]; then
  idempotent=false
fi
if [[ "${idempotent}" == "true" ]]; then
  echo "spec already carries ${VER}-${REL} with these checksums — nothing to do"
  exit 0
fi

DATE="$(LC_ALL=C date -u '+%a %b %d %Y')"
if [[ "${BUMP_RELEASE}" == "true" ]]; then
  ENTRY_MSG_PARTS=("- Rebuild: resync release tarball checksum")
  [[ -n "${SUM_X64}" ]] && ENTRY_MSG_PARTS+=("(x64 sha256 ${SUM_X64})")
  [[ -n "${SUM_ARM64}" && "${SUM_ARM64}" != "${SUM_X64}" ]] && ENTRY_MSG_PARTS+=("(arm64 sha256 ${SUM_ARM64})")
  ENTRY_MSG="$(IFS=' '; echo "${ENTRY_MSG_PARTS[*]}")."
else
  ENTRY_MSG_PARTS=("- Sync with upstream release v${VER}")
  [[ -n "${SUM_X64}" ]] && ENTRY_MSG_PARTS+=("(x64 sha256 ${SUM_X64})")
  [[ -n "${SUM_ARM64}" && "${SUM_ARM64}" != "${SUM_X64}" ]] && ENTRY_MSG_PARTS+=("(arm64 sha256 ${SUM_ARM64})")
  ENTRY_MSG="$(IFS=' '; echo "${ENTRY_MSG_PARTS[*]}")."
fi

SPEC_PATH="${SPEC}" VER="${VER}" REL="${REL}" SUM_X64="${SUM_X64}" SUM_ARM64="${SUM_ARM64}" DATE="${DATE}" ENTRY_MSG="${ENTRY_MSG}" python3 - <<'PYEOF'
import os, pathlib, re
spec = pathlib.Path(os.environ["SPEC_PATH"])
ver = os.environ["VER"]
rel = os.environ["REL"]
sum_x64 = os.environ["SUM_X64"]
sum_arm64 = os.environ["SUM_ARM64"]
date = os.environ["DATE"]
msg = os.environ["ENTRY_MSG"]
t = spec.read_text()
t = re.sub(r"(?m)^Version:\s+\S+\s*$", f"Version:        {ver}", t, count=1)
t = re.sub(r"(?m)^Release:\s+\S+\s*$", f"Release:        {rel}%{{?dist}}", t, count=1)
# Update the x64 sha line. The line is the FIRST echo "..." in %prep that
# points at the _x64 tarball.
if sum_x64:
    t = re.sub(
        r'(?m)^echo "[0-9a-f]{64}  %\{_sourcedir\}/Grok_Bot_[^/"]*_linux_x64\.tar\.gz"',
        f'echo "{sum_x64}  %{{_sourcedir}}/Grok_Bot_{ver}_linux_x64.tar.gz"',
        t,
        count=1,
    )
# Update the arm64 sha line. Matching runs to end of line so the whole
# `echo "<digest>  <path>" | sha256sum -c -` is replaced; an anchor that
# stopped at the closing quote silently left stale digests behind.
if sum_arm64:
    t = re.sub(
        r'(?m)^echo "[0-9a-f]{64}  %\{_sourcedir\}/Grok_Bot_[^"]*_linux_arm64\.tar\.gz"[^\n]*$',
        f'echo "{sum_arm64}  %{{_sourcedir}}/Grok_Bot_{ver}_linux_arm64.tar.gz" | sha256sum -c -',
        t,
        count=1,
    )
t = re.sub(
    r"(?m)^%changelog\s*$",
    f"%changelog\n* {date} Nichokas <nichokas@users.noreply.github.com> - {ver}-{rel}\n{msg}\n",
    t,
    count=1,
)
# A digest line left on an older version makes %prep run sha256sum against a
# tarball the SRPM does not carry, so that chroot fails. Fail here instead.
stale = sorted(set(re.findall(r"Grok_Bot_(\d+\.\d+\.\d+)_linux_(?:x64|arm64)\.tar\.gz", t)) - {ver})
if stale:
    raise SystemExit(f"error: spec still pins tarball version(s) {', '.join(stale)} after rewrite")
spec.write_text(t)
parts = [f"Version={ver}", f"Release={rel}"]
if sum_x64:
    parts.append(f"sha256(x64)={sum_x64[:12]}…")
if sum_arm64:
    parts.append(f"sha256(arm64)={sum_arm64[:12]}…")
print(f"updated {spec.name}: " + " ".join(parts))
PYEOF

echo "done — review with: git diff grokbot-linux-port.spec"
