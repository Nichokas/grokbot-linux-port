#!/usr/bin/env bash
set -euo pipefail
# update-spec.sh — sync grokbot-linux-port.spec with a GitHub release
#
# Usage:
#   scripts/update-spec.sh <x.y.z>                          # fresh version: Version=x.y.z, Release=1, re-hash tarball
#   scripts/update-spec.sh --bump-release <x.y.z>           # rebuild resync: keep Version, bump Release, re-hash
#   scripts/update-spec.sh --sum <sha256> [--bump-release] <x.y.z>
#
# --sum exists for the same reason update-aur.sh has --bin-sum: the release
# job hashes the artifact bytes it just uploaded; re-hashing the published
# URL would race GitHub's CDN propagation and can bake a sum for bytes the
# CDN no longer serves.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPEC="${REPO_ROOT}/grokbot-linux-port.spec"

SUM=""
BUMP_RELEASE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sum)
      SUM="${2:?'--sum requires a sha256 argument'}"
      shift 2
      ;;
    --bump-release)
      BUMP_RELEASE=true
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
  echo "usage: $(basename "$0") [--sum <sha256>] [--bump-release] <x.y.z>" >&2
  exit 1
fi
VER="$1"
if ! [[ "${VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version '${VER}' does not match x.y.z" >&2
  exit 1
fi
if [[ -n "${SUM}" && ! "${SUM}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "error: --sum '${SUM}' is not a lowercase sha256 hex digest" >&2
  exit 1
fi
[[ -f "${SPEC}" ]] || { echo "error: ${SPEC} not found" >&2; exit 1; }

if [[ -z "${SUM}" ]]; then
  URL="https://github.com/Nichokas/grokbot-linux-port/releases/download/v${VER}/Grok_Bot_${VER}_linux_x64.tar.gz"
  echo "Hashing release tarball: ${URL}" >&2
  SUM="$(curl --fail --silent --show-error --location --retry 2 --max-time 300 "${URL}" | sha256sum | awk '{print $1}')"
  echo "  -> ${SUM}" >&2
fi

CUR_VER="$(sed -nE 's/^Version:[[:space:]]+([^[:space:]]+).*/\1/p' "${SPEC}")"
CUR_REL="$(sed -nE 's/^Release:[[:space:]]+([0-9]+).*/\1/p' "${SPEC}")"
CUR_SUM="$(sed -nE 's/^echo "([0-9a-f]{64})  %\{_sourcedir\}.*/\1/p' "${SPEC}")"

if [[ "${BUMP_RELEASE}" == "true" ]]; then
  REL=$(( ${CUR_REL:-1} + 1 ))
else
  REL=1
fi

# Idempotency: a re-dispatch of the same version+bytes must not stack
# duplicate changelog entries or produce a noisy no-op commit.
if [[ "${CUR_VER}" == "${VER}" && "${CUR_REL}" == "${REL}" && "${CUR_SUM}" == "${SUM}" ]]; then
  echo "spec already carries ${VER}-${REL} with this checksum — nothing to do"
  exit 0
fi

DATE="$(LC_ALL=C date -u '+%a %b %d %Y')"
if [[ "${BUMP_RELEASE}" == "true" ]]; then
  ENTRY_MSG="- Rebuild: resync release tarball checksum (sha256 ${SUM})."
else
  ENTRY_MSG="- Sync with upstream release v${VER} (tarball sha256 ${SUM})."
fi

SPEC_PATH="${SPEC}" VER="${VER}" REL="${REL}" SUM="${SUM}" DATE="${DATE}" ENTRY_MSG="${ENTRY_MSG}" python3 - <<'PYEOF'
import os, pathlib, re
spec = pathlib.Path(os.environ["SPEC_PATH"])
ver, rel, sum_, date, msg = (os.environ[k] for k in ("VER", "REL", "SUM", "DATE", "ENTRY_MSG"))
t = spec.read_text()
t = re.sub(r"(?m)^Version:\s+\S+\s*$", f"Version:        {ver}", t, count=1)
t = re.sub(r"(?m)^Release:\s+\S+\s*$", f"Release:        {rel}%{{?dist}}", t, count=1)
t = re.sub(r'(?m)^echo "[0-9a-f]{64}  %\{_sourcedir\}', f'echo "{sum_}  %{{_sourcedir}}', t, count=1)
t = re.sub(
    r"(?m)^%changelog\s*$",
    f"%changelog\n* {date} Nichokas <nichokas@users.noreply.github.com> - {ver}-{rel}\n{msg}\n",
    t,
    count=1,
)
spec.write_text(t)
print(f"updated {spec.name}: Version={ver} Release={rel} sha256={sum_[:12]}…")
PYEOF

echo "done — review with: git diff grokbot-linux-port.spec"
