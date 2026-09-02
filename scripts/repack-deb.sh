#!/usr/bin/env bash
set -euo pipefail

# repack-deb.sh — repackage the official Grok Bot Linux .deb as the release
# tarball consumed by the AUR -bin package and the RPM spec
#
# xAI publishes native Linux builds (x64 + arm64) as .deb (FPM-built). The
# downstream packages in this repo consume a tar.gz, so this script resolves
# the current .deb through api2's canonical JSON (app name "sand", per the
# deb's Provides: sand), downloads it, and repackages the /opt payload as
# dist/Grok_Bot_<version>_linux_<arch>.tar.gz.
#
# The win32 NSIS extraction + Electron fusion this repo used to perform is
# gone: the official .deb already ships Linux ELF binaries with its native
# modules compiled (app.asar.unpacked/dist/deps/), so a repack is the whole
# job. No runner needs to match the target arch — the payload is copied
# verbatim, never executed or linked.
#
# Usage:
#   scripts/repack-deb.sh                                # resolve + build both arches
#   scripts/repack-deb.sh --arch x64                     # single arch
#   scripts/repack-deb.sh --deb-x64 <file> --deb-arm64 <file>   # local debs (CI cache)
#
# Prerequisites: curl, ar (binutils), tar, xz.

API_JSON_URL_TEMPLATE="https://api2.cursor.sh/updates/api/download/stable/%s/sand"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTDIR="${OUTDIR:-${REPO_ROOT}/dist}"
CACHE_DIR="${GROKBOT_CACHE_DIR:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --arch <x64|arm64>             Build only this arch (default: both)
  --deb-x64 <file>               Use a local x64 .deb instead of downloading
  --deb-arm64 <file>              Use a local arm64 .deb instead of downloading
  --version <x.y.z[+sha]>          Require the resolved version to equal this,
                                  optionally with the commitSha appended after
                                  '+' so a manifest change between the detect
                                  job and this repack fails here instead of
                                  mixing commits under one release
  -h, --help                      Show this help
EOF
}

die() { echo "error: $*" >&2; exit 1; }

ARCHES=(x64 arm64)
declare -A DEB_OVERRIDE=()
EXPECT_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ "${2:-}" == x64 || "${2:-}" == arm64 ]] || die "--arch expects x64 or arm64"
      ARCHES=("$2"); shift 2 ;;
    --deb-x64)  DEB_OVERRIDE[x64]="${2:?--deb-x64 requires a path}";  shift 2 ;;
    --deb-arm64) DEB_OVERRIDE[arm64]="${2:?--deb-arm64 requires a path}"; shift 2 ;;
    --version) EXPECT_VERSION="${2:?--version requires x.y.z or x.y.z+<commitSha>}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

# ---------------------------------------------------------------------------
# resolve_arch — canonical download JSON for one arch.
# Prints "version commitSha debUrl" (whitespace-free fields) on stdout.
# ---------------------------------------------------------------------------
resolve_arch() {
  local api_arch="$1" json ver sha url
  api_arch="linux-${1}"
  # shellcheck disable=SC2059
  json="$(curl --fail --silent --show-error --max-time 30 --retry 3 \
    "$(printf "${API_JSON_URL_TEMPLATE}" "${api_arch}")")" \
    || die "api2 download JSON unavailable for ${api_arch}"
  ver="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' <<<"${json}" | head -n 1)"
  sha="$(sed -n 's/.*"commitSha":"\([^"]*\)".*/\1/p' <<<"${json}" | head -n 1)"
  url="$(sed -n 's/.*"debUrl":"\([^"]*\)".*/\1/p' <<<"${json}" | head -n 1)"
  [[ -n "${ver}" && -n "${sha}" && -n "${url}" ]] || die "cannot parse version/commitSha/debUrl from ${api_arch} JSON: ${json}"
  [[ "${url}" == *.deb ]] || die "${api_arch} debUrl is not a .deb: ${url}"
  printf '%s %s %s' "${ver}" "${sha}" "${url}"
}

# ---------------------------------------------------------------------------
# fetch — download url, using GROKBOT_CACHE_DIR when set (CI volume), and
# print the stored path on stdout. A cached file must still carry the ar
# magic or it is re-fetched: a truncated earlier download must not poison
# the release tarball. The cache IS the storage (no second copy elsewhere),
# so cache-on/cache-off only changes where the deb lives.
# ---------------------------------------------------------------------------
fetch() {
  local url="$1" dst
  if [[ -n "${CACHE_DIR}" ]]; then
    mkdir -p "${CACHE_DIR}"
    dst="${CACHE_DIR}/$(basename "${url}")"
    if [[ -s "${dst}" ]] && head -c 8 "${dst}" | grep -q '^!<arch>'; then
      echo "cache hit: ${dst}" >&2
      printf '%s' "${dst}"
      return
    fi
  else
    dst="$(mktemp -t grokbot-deb-XXXXXX.deb)"
  fi
  curl --fail --silent --show-error --location --max-time 600 --retry 3 \
    --output "${dst}.tmp" "${url}"
  mv "${dst}.tmp" "${dst}"
  [[ -s "${dst}" ]] || die "download produced empty ${dst}"
  printf '%s' "${dst}"
}

# ---------------------------------------------------------------------------
# repack — one deb -> dist/Grok_Bot_<ver>_linux_<arch>.tar.gz
# ---------------------------------------------------------------------------
repack() {
  local arch="$1" deb="$2" version="$3"
  local root="Grok_Bot_${version}_linux_${arch}"
  local workdir
  workdir="$(mktemp -d -t grokbot-repack-XXXXXX)"
  # Cleanup without a RETURN trap: a trap set inside a function leaks into
  # every later function (bash does not scope RETURN traps), and the rm
  # would then expand variables that no longer exist.
  cleanup() { rm -rf "${workdir}"; }

  mkdir "${workdir}/ar" "${workdir}/${root}"
  ( cd "${workdir}/ar" && ar x "${deb}" ) || die "ar cannot read ${deb}"

  if [[ ! -f "${workdir}/ar/data.tar.xz" ]]; then
    die "no data.tar.xz in ${deb} [members: $(ls "${workdir}/ar" | tr '\n' ' ')]"
  fi
  tar -xJf "${workdir}/ar/data.tar.xz" -C "${workdir}/${root}" \
      './opt/Grok Bot' ./usr/share/icons ./usr/share/doc \
    || die "data.tar.xz lacks the expected members: /opt/Grok Bot, /usr/share/icons"

  local staged="${workdir}/${root}"
  local payload="opt/Grok Bot"
  [[ -x "${staged}/${payload}/grok-bot" ]] || die "payload has no executable grok-bot"
  [[ -f "${staged}/${payload}/chrome-sandbox" ]] || die "payload has no chrome-sandbox"

  # Deb control Version vs api2 JSON: a half-republished api2 (JSON bumped,
  # CDN still serving old bytes) must fail here with a clear message, not
  # ship old bytes under a new name.
  local ctrl_ver
  ctrl_ver="$(tar -xJOf "${workdir}/ar/control.tar.xz" ./control 2>/dev/null \
    | sed -n 's/^Version: *//p' | head -n 1)"
  [[ "${ctrl_ver}" == "${version}" ]] || die "deb control Version '${ctrl_ver}' != api2 version '${version}'"

  # The api2 arch label and the payload ELF must agree; a swapped build
  # surfaces on users as a dlopen failure far from the packaging that
  # mislabelled it. e_machine: 0x3e = x86-64, 0xb7 = aarch64.
  local elf_machine
  elf_machine="$(od -An -tx1 -j 18 -N 2 < "${staged}/${payload}/grok-bot" | tr -d ' \n')"
  case "${arch}:${elf_machine}" in
    x64:3e00|arm64:b700) ;;
    *) die "${arch} deb carries grok-bot with ELF machine 0x${elf_machine}" ;;
  esac

  # FPM strips setuid from chrome-sandbox (the deb's postinst chmods it at
  # install time); bake 4755 into the tarball so consumers that extract as
  # root get a working sandbox without a post-install step.
  chmod 4755 "${staged}/${payload}/chrome-sandbox"

  # Ship the deb's changelog at the payload root (self-describing tarball)
  # and drop the /usr tree — the hicolor icons move under the payload in a
  # moment and packages own /usr/share themselves.
  local doc="usr/share/doc/grok-bot"
  [[ -f "${staged}/${doc}/changelog.gz" ]] && cp "${staged}/${doc}/changelog.gz" "${staged}/${payload}/changelog.gz"
  mv "${staged}/usr/share/icons/hicolor" "${staged}/hicolor"
  rm -rf "${staged}/usr"
  mv "${staged}/${payload}" "${staged}/payload"
  # opt/ is now an empty husk: the payload moved out of it above.
  rmdir "${staged}/opt"

  # Deterministic bytes: identical input deb -> identical tarball, so a CI
  # re-run re-uploading a release asset keeps the AUR/spec sha256 stable
  # unless upstream bytes actually moved.
  mkdir -p "${OUTDIR}"
  tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
      --pax-option=delete=atime,delete=ctime \
      -cf - -C "${workdir}" "${root}" | gzip -n > "${OUTDIR}/${root}.tar.gz"

  # Verify the artifact that ships, not the staged tree. Both greps run on a
  # saved listing: `grep -q` closes the pipe after the first hit, and with
  # pipefail that SIGPIPE'd tar reads as the check failing.
  local listing="${workdir}/tarball.list"
  tar -tzvf "${OUTDIR}/${root}.tar.gz" > "${listing}"
  if grep -q '^d[r-][a-z-]---' "${listing}"; then
    die "tarball contains non-world-readable directories"
  fi
  grep -q '^-rwsr-xr-x' "${listing}" \
    || die "chrome-sandbox lost its setuid bit in the tarball"

  cleanup
  echo "repacked ${arch}: ${OUTDIR}/${root}.tar.gz [$(du -h "${OUTDIR}/${root}.tar.gz" | cut -f1)]" >&2
}

main() {
  local -a resolved=()
  local arch line
  for arch in "${ARCHES[@]}"; do resolved+=("$(resolve_arch "${arch}")"); done

  # A partial upstream republication must not yield two tarballs with
  # different versions — or different commits under one version — in a
  # single release. This re-resolves the manifest the detect job already
  # validated, so a change between detect and repack fails here too.
  # Keyed on "version commit"; the URL differs per arch by design.
  local -a keys=()
  local r_ver r_sha r_url
  for line in "${resolved[@]}"; do
    read -r r_ver r_sha r_url <<<"${line}"
    keys+=("${r_ver} ${r_sha}")
  done
  local -A seen=()
  for line in "${keys[@]}"; do seen["${line}"]=1; done
  [[ ${#seen[@]} -eq 1 ]] || die "api2 disagrees on version/commit across arches: ${keys[*]}"
  local version="${resolved[0]%% *}"
  local commit="${resolved[0]#* }"; commit="${commit%% *}"
  local expect="${EXPECT_VERSION%%+*}"
  [[ -z "${expect}" || "${expect}" == "${version}" ]] \
    || die "resolved ${version} but expected ${expect}"
  local expect_commit="${EXPECT_VERSION#*+}"
  if [[ "${EXPECT_VERSION}" == *+* ]]; then
    [[ "${expect_commit}" == "${commit}" ]] \
      || die "resolved commit ${commit} but expected ${expect_commit}"
  fi

  local i url deb_path
  for i in "${!ARCHES[@]}"; do
    arch="${ARCHES[$i]}"; line="${resolved[$i]}"
    version="${line%% *}"; url="${line##* }"
    if [[ -n "${DEB_OVERRIDE[${arch}]:-}" ]]; then
      deb_path="${DEB_OVERRIDE[${arch}]}"
      [[ -f "${deb_path}" ]] || die "--deb: ${deb_path} does not exist"
    else
      deb_path="$(fetch "${url}")"
    fi
    repack "${arch}" "${deb_path}" "${version}"
  done
}

main
