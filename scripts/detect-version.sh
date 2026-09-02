#!/usr/bin/env bash
set -euo pipefail

# detect-version.sh — read the current Grok Bot version from api2's canonical
# download JSON
#
# Historically this script HEAD-probed semver candidates against the win32
# bucket because upstream exposed no listing and no manifest. That is no
# longer necessary: api2 serves the canonical download manifest for the
# Linux builds at
#   https://api2.cursor.sh/updates/api/download/stable/linux-<arch>/sand
# (app name "sand", per the deb's Provides: sand), whose JSON carries
# version, commitSha and the AppImage/deb/rpm URLs for the current release.
# One GET per arch replaces the whole candidate sweep; the two arches must
# agree, which also catches a half-republished upstream.
#
# Usage:
#   scripts/detect-version.sh                  # resolve latest
#   scripts/detect-version.sh 0.30.0           # validate explicit version (workflow_dispatch)
#   INPUT_VERSION=0.30.0 scripts/detect-version.sh  # Actions input passthrough
#
# Outputs (stdout + $GITHUB_OUTPUT when present): version, is_new, rebuild.
# The bare version is also the script's last stdout line for $(...) callers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"

API_JSON_URL_TEMPLATE="https://api2.cursor.sh/updates/api/download/stable/%s/sand"

read_base_version() {
  if [[ -f "${VERSION_FILE}" ]]; then
    # shellcheck disable=SC2002
    cat "${VERSION_FILE}" | tr -d '[:space:]'
  else
    echo "0.30.0"
  fi
}

resolve_dispatch_version() {
  if [[ $# -gt 0 && -n "${1:-}" ]]; then
    printf '%s' "$1"
    return
  fi
  if [[ -n "${INPUT_VERSION:-}" ]]; then
    printf '%s' "${INPUT_VERSION}"
    return
  fi
  printf ''
}

# ---------------------------------------------------------------------------
# fetch_arch_json — GET the canonical manifest for one arch and print the
# "version commitSha" pair (whitespace-free fields) on stdout.
# ---------------------------------------------------------------------------
fetch_arch_json() {
  local arch="$1" json ver sha
  # shellcheck disable=SC2059
  json="$(curl --fail --silent --show-error --max-time 30 --retry 3 \
    "$(printf "${API_JSON_URL_TEMPLATE}" "linux-${arch}")")" \
    || { echo "error: api2 manifest unavailable for linux-${arch}" >&2; return 1; }
  ver="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' <<<"${json}" | head -n 1)"
  sha="$(sed -n 's/.*"commitSha":"\([^"]*\)".*/\1/p' <<<"${json}" | head -n 1)"
  [[ -n "${ver}" && -n "${sha}" ]] \
    || { echo "error: cannot parse version/commitSha from linux-${arch} JSON: ${json}" >&2; return 1; }
  printf '%s %s' "${ver}" "${sha}"
}

emit_outputs() {
  local version="$1"
  local is_new="$2"
  local rebuild="${3:-false}"
  local commit="${4:-}"

  echo "version=${version}"
  echo "is_new=${is_new}"
  echo "rebuild=${rebuild}"
  echo "commit=${commit}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "version=${version}"
      echo "is_new=${is_new}"
      echo "rebuild=${rebuild}"
      echo "commit=${commit}"
    } >> "${GITHUB_OUTPUT}"
  fi
}

main() {
  local base dispatch x64 arm64 ver sha
  base="$(read_base_version)"
  dispatch="$(resolve_dispatch_version "${1:-}")"

  # Both arches must resolve and agree. A disagreement means upstream is
  # mid-republish; failing here makes the scheduled run retry on the next
  # cron tick instead of building two tarballs with different versions.
  x64="$(fetch_arch_json x64)" || exit 1
  arm64="$(fetch_arch_json arm64)" || exit 1
  if [[ "${x64}" != "${arm64}" ]]; then
    echo "error: api2 x64/arm64 manifests disagree (x64: ${x64}; arm64: ${arm64}) — upstream mid-republish?" >&2
    exit 1
  fi
  ver="${x64%% *}"; sha="${x64#* }"

  # The dispatched version must be what upstream actually serves; a typo or
  # a stale manual input must not force a build of a version that does not
  # exist as Linux artefacts.
  if [[ -n "${dispatch}" && "${dispatch}" != "${ver}" ]]; then
    echo "error: dispatched version ${dispatch} does not match api2's ${ver} (commit ${sha})" >&2
    exit 1
  fi

  echo "api2 stable: version=${ver} commit=${sha} (base: ${base})" >&2

  local is_new="false" rebuild="false"
  # Only a strictly greater semver is new: an upstream rollback (VERSION says
  # 0.31.0, api2 serves 0.30.1) must not "update" the packages to an older
  # version — package managers would never offer it as an upgrade.
  if [[ "${ver}" != "${base}" && "$(printf '%s\n' "${base}" "${ver}" | sort -V | tail -n 1)" == "${ver}" ]]; then
    is_new="true"
  elif [[ -n "${dispatch}" ]]; then
    # Dispatching the current base version means "rebuild it": repack or
    # packaging fixes never reach users otherwise, since scheduled runs only
    # fire on newer upstream versions. The release job re-uploads the
    # artefacts and the AUR/spec bumps take the resync path.
    rebuild="true"
  fi

  emit_outputs "${ver}" "${is_new}" "${rebuild}" "${sha}"
  printf '%s\n' "${ver}"
}

main "${1:-}"
