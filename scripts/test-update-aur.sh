#!/usr/bin/env bash
set -euo pipefail

# Hermetic regression test for update-aur.sh, no network and no makepkg.
#
# The stub PATH carries only the tools the script shells out to, so
# `command -v makepkg` fails exactly like it does on the release runner and
# the .SRCINFO fallback is the path under test. The curl stub stands in for
# the release CDN serving bytes that differ from the sums the release job
# hands over, which is the propagation race --bin-sum-* exists to dodge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKG_SRC="${REPO_ROOT}/aur/grokbot-linux-port-bin"

SUM_X64="$(printf 'x64-bytes-the-release-job-uploaded' | sha256sum | awk '{print $1}')"
SUM_ARM64="$(printf 'arm64-bytes-the-release-job-uploaded' | sha256sum | awk '{print $1}')"
CDN_BYTES='stale-bytes-the-cdn-still-serves'
SUM_CDN="$(printf '%s' "${CDN_BYTES}" | sha256sum | awk '{print $1}')"
[[ "${SUM_CDN}" != "${SUM_X64}" && "${SUM_CDN}" != "${SUM_ARM64}" ]] \
  || { echo "fixture error: CDN sum collides with a caller sum" >&2; exit 1; }

WORK="$(mktemp -d -t update-aur-test-XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
STUB_BIN="${WORK}/bin"
mkdir -p "${STUB_BIN}"
for tool in bash sed awk python3 sha256sum mktemp mv rm cat head basename dirname; do
  tool_path="$(command -v "${tool}")" \
    || { echo "error: required tool '${tool}' not found" >&2; exit 1; }
  ln -s "${tool_path}" "${STUB_BIN}/${tool}"
done

cat > "${STUB_BIN}/curl" <<CURLSTUB
#!/bin/sh
for arg in "\$@"; do
  if [ "\${arg}" = "--head" ]; then
    [ -n "\${STUB_NO_RELEASE:-}" ] && exit 22
    exit 0
  fi
done
printf '%s' '${CDN_BYTES}'
CURLSTUB
chmod +x "${STUB_BIN}/curl"

fake_repo() {
  local ver="$1" rel="$2" root="${WORK}/repo"
  rm -rf "${root}"
  mkdir -p "${root}/scripts" "${root}/aur/grokbot-linux-port-bin"
  cp "${REPO_ROOT}/scripts/update-aur.sh" "${root}/scripts/update-aur.sh"
  cp "${PKG_SRC}/PKGBUILD" "${PKG_SRC}/.SRCINFO" "${root}/aur/grokbot-linux-port-bin/"
  sed -i -E "s/^pkgver=.*/pkgver=${ver}/; s/^pkgrel=.*/pkgrel=${rel}/" \
    "${root}/aur/grokbot-linux-port-bin/PKGBUILD"
  sed -i -E "s/^([[:space:]]*)pkgver = .*/\1pkgver = ${ver}/; s/^([[:space:]]*)pkgrel = .*/\1pkgrel = ${rel}/" \
    "${root}/aur/grokbot-linux-port-bin/.SRCINFO"
  printf '%s' "${root}"
}

SCENARIO=""
run_update() {
  local root="$1"; shift
  printf '\n--- %s\n' "${SCENARIO}" >> "${WORK}/log"
  ( cd "${root}" && env -i PATH="${STUB_BIN}" HOME="${WORK}" \
      STUB_NO_RELEASE="${STUB_NO_RELEASE:-}" bash scripts/update-aur.sh "$@" ) \
    >> "${WORK}/log" 2>&1 || echo "update-aur.sh exited $?" >> "${WORK}/log"
}

fails=0
check() {
  if [[ "$2" == "$3" ]]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n        expected: %s\n        got:      %s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}
field()   { sed -nE "s/^$2=(.*)/\1/p" "$1/aur/grokbot-linux-port-bin/PKGBUILD"; }
sums()    { sed -nE "s/^$2=\('([^']*)'\).*/\1/p" "$1/aur/grokbot-linux-port-bin/PKGBUILD"; }
srcinfo() { sed -nE "s/^[[:space:]]*$2 = (.*)/\1/p" "$1/aur/grokbot-linux-port-bin/.SRCINFO"; }

SCENARIO="version bump from 0.36.0-4 to 0.39.0"
root="$(fake_repo 0.36.0 4)"
run_update "${root}" --bin-sum-x64 "${SUM_X64}" --bin-sum-arm64 "${SUM_ARM64}" 0.39.0
check 'version bump sets pkgver'                    0.39.0         "$(field "${root}" pkgver)"
check 'version bump resets pkgrel to 1'             1              "$(field "${root}" pkgrel)"
check 'version bump keeps the x64 sum it was given' "${SUM_X64}"   "$(sums "${root}" sha256sums_x86_64)"
check 'version bump keeps the arm64 sum it was given' "${SUM_ARM64}" "$(sums "${root}" sha256sums_aarch64)"
check '.SRCINFO tracks pkgver'                      0.39.0         "$(srcinfo "${root}" pkgver)"
check '.SRCINFO tracks the reset pkgrel'            1              "$(srcinfo "${root}" pkgrel)"
check '.SRCINFO tracks the x64 sum'                 "${SUM_X64}"   "$(srcinfo "${root}" sha256sums_x86_64)"

SCENARIO="re-running the same bump at 0.39.0-2"
root="$(fake_repo 0.39.0 2)"
run_update "${root}" --bin-sum-x64 "${SUM_X64}" --bin-sum-arm64 "${SUM_ARM64}" 0.39.0
check 'a repeated bump leaves pkgrel alone'         2              "$(field "${root}" pkgrel)"
check 'a repeated bump leaves pkgver alone'         0.39.0         "$(field "${root}" pkgver)"

SCENARIO="rebuild resync at 0.39.0-1"
root="$(fake_repo 0.39.0 1)"
run_update "${root}" --bin-only --bin-sum-x64 "${SUM_X64}" --bin-sum-arm64 "${SUM_ARM64}" 0.39.0
check 'rebuild resync bumps pkgrel'                 2              "$(field "${root}" pkgrel)"
check 'rebuild resync keeps pkgver'                 0.39.0         "$(field "${root}" pkgver)"
check 'rebuild resync .SRCINFO tracks pkgrel'       2              "$(srcinfo "${root}" pkgrel)"

SCENARIO="half-published release, arm64 tarball absent"
root="$(fake_repo 0.36.0 4)"
STUB_NO_RELEASE=1 run_update "${root}" --bin-sum-x64 "${SUM_X64}" 0.39.0
check 'a missing arch sum leaves pkgver untouched'  0.36.0         "$(field "${root}" pkgver)"
check 'a missing arch sum leaves pkgrel untouched'  4              "$(field "${root}" pkgrel)"

if [[ "${fails}" -ne 0 ]]; then
  printf '\n%s check(s) failed. update-aur.sh output follows.\n' "${fails}"
  cat "${WORK}/log"
  exit 1
fi
echo "all checks passed"
