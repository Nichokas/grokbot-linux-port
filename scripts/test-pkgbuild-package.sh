#!/usr/bin/env bash
set -euo pipefail

# Smoke test for the AUR PKGBUILD's package(), built for real against a stub
# payload — the AUR half of spec-lint's stub-payload rpmbuild smoke.
#
# Every other AUR check is static: `bash -n`, `makepkg --printsrcinfo`, the
# .SRCINFO diff and `namcap PKGBUILD` all read the recipe without running it,
# so a ${pkgdir} path package() writes to without creating first survives all
# of them and only fails on the user's machine. That is how 0.36.0-4 and
# 0.39.0-4 both reached AUR with a package() that died at the LICENSE heredoc
# because nothing had created usr/share/licenses/${pkgname} (issue #12).
#
# Integrity is skipped on purpose (--skipinteg): the stub tarball is not the
# release tarball, and the digest rewriting update-aur.sh does is already
# pinned offline by test-update-aur.sh. The subject here is package() alone.
#
# Usage:
#   bash scripts/test-pkgbuild-package.sh   # on Arch, or inside the container:
#   docker run --rm -v "$PWD:/repo:ro,z" -w /repo archlinux:base-devel \
#     bash scripts/test-pkgbuild-package.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKG_DIR="${REPO_ROOT}/aur/grokbot-linux-port-bin"
[[ -f "${PKG_DIR}/PKGBUILD" ]] || { echo "error: ${PKG_DIR}/PKGBUILD missing" >&2; exit 1; }
command -v makepkg >/dev/null 2>&1 \
  || { echo "error: makepkg not found — run on Arch or in archlinux:base-devel" >&2; exit 1; }

PKGVER="$(sed -nE 's/^pkgver=(.*)/\1/p' "${PKG_DIR}/PKGBUILD")"
PKGNAME="$(sed -nE 's/^pkgname=(.*)/\1/p' "${PKG_DIR}/PKGBUILD")"

WORK="$(mktemp -d -t pkgbuild-smoke-XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT

# makepkg refuses to run as root and archlinux:base-devel is root by default;
# on a normal Arch host the current user already qualifies.
BUILD_USER=""
if [[ "${EUID}" -eq 0 ]]; then
  BUILD_USER=builder
  id -u "${BUILD_USER}" >/dev/null 2>&1 || useradd -m "${BUILD_USER}"
fi
as_builder() {
  if [[ -n "${BUILD_USER}" ]]; then
    runuser -u "${BUILD_USER}" -- bash -c "$1"
  else
    bash -c "$1"
  fi
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

for arch in x64 arm64; do
  case "${arch}" in
    x64)   carch=x86_64 ;;
    arm64) carch=aarch64 ;;
  esac

  build="${WORK}/build-${arch}"
  stage="${WORK}/stage-${arch}"
  staged="${stage}/Grok_Bot_${PKGVER}_linux_${arch}"
  mkdir -p "${build}" "${staged}/payload" "${staged}/hicolor/256x256/apps"
  cp "${PKG_DIR}/PKGBUILD" "${build}/PKGBUILD"
  printf 'grok-bot stub\n'       > "${staged}/payload/grok-bot"
  printf 'chrome-sandbox stub\n' > "${staged}/payload/chrome-sandbox"
  printf 'icon stub\n'           > "${staged}/hicolor/256x256/apps/grok-bot.png"
  # Named like the release tarball so makepkg treats it as already downloaded
  # and never reaches for the 190 MB original.
  tar -czf "${build}/Grok_Bot_${PKGVER}_linux_${arch}.tar.gz" \
    -C "${stage}" "Grok_Bot_${PKGVER}_linux_${arch}"

  # makepkg reads CARCH from makepkg.conf, which overrides the environment, so
  # the arm64 pass needs its own conf. Nothing here compiles — the point is to
  # drive package()'s CARCH -> staged-dir mapping and the per-arch source array
  # on an x86_64 runner.
  conf="${WORK}/makepkg-${arch}.conf"
  sed -E "s/^CARCH=.*/CARCH=\"${carch}\"/; s/^CHOST=.*/CHOST=\"${carch}-unknown-linux-gnu\"/" \
    /etc/makepkg.conf > "${conf}"

  if [[ -n "${BUILD_USER}" ]]; then
    chown -R "${BUILD_USER}:${BUILD_USER}" "${WORK}"
  fi

  log="${WORK}/makepkg-${arch}.log"
  status=0
  as_builder "cd '${build}' && makepkg --config '${conf}' --nodeps --skipinteg -f" \
    > "${log}" 2>&1 || status=$?
  check "${arch}: makepkg runs package() to completion" 0 "${status}"
  if [[ "${status}" -ne 0 ]]; then
    sed 's/^/    /' "${log}"
    continue
  fi

  pkgfile="$(find "${build}" -maxdepth 1 -name "${PKGNAME}-*-${carch}.pkg.tar*" -print -quit)"
  if [[ -z "${pkgfile}" ]]; then
    check "${arch}: package archive produced" "a ${carch} package" "none"
    continue
  fi

  # Listed to files, not piped: grep -q exits on its first hit and pipefail
  # would then report the SIGPIPE'd bsdtar as the failure.
  as_builder "bsdtar -tf '${pkgfile}'"  > "${WORK}/list-${arch}"
  as_builder "bsdtar -tvf '${pkgfile}'" > "${WORK}/vlist-${arch}"
  for path in \
    "opt/${PKGNAME}/grok-bot" \
    "opt/${PKGNAME}/chrome-sandbox" \
    usr/bin/grok-bot \
    usr/bin/grokbot \
    usr/share/applications/grok-bot.desktop \
    usr/share/icons/hicolor/256x256/apps/grok-bot.png \
    "usr/share/licenses/${PKGNAME}/LICENSE"
  do
    if grep -Fqx "${path}" "${WORK}/list-${arch}"; then
      printf 'PASS  %s: packages %s\n' "${arch}" "${path}"
    else
      printf 'FAIL  %s: package is missing %s\n' "${arch}" "${path}"
      fails=$((fails + 1))
    fi
  done

  # The repack bakes 4755 in and package() re-asserts it; without the setuid
  # bit Chromium's namespace sandbox falls back to --no-sandbox.
  mode="$(awk -v p="opt/${PKGNAME}/chrome-sandbox" '$NF == p { print $1 }' "${WORK}/vlist-${arch}")"
  check "${arch}: chrome-sandbox keeps its setuid bit" "-rwsr-xr-x" "${mode}"
done

if [[ "${fails}" -ne 0 ]]; then
  printf '\n%s check(s) failed.\n' "${fails}"
  exit 1
fi
echo "all checks passed"
