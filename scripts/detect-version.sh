#!/usr/bin/env bash
set -euo pipefail

# detect-version.sh — version-anchored HEAD-probing discovery for Grok Bot
#
# Reads the current base version from the VERSION file, generates an ordered
# semver candidate set covering non-linear jumps, HEAD-probes each artifact URL
# on win32-x64 (and optionally darwin-x64 for cross-platform confirmation),
# selects the highest semver candidate returning HTTP 200 as the latest version,
# and emits outputs suitable for both local invocation and GitHub Actions.
#
# Usage:
#   scripts/detect-version.sh                  # autonomous probing
#   scripts/detect-version.sh 0.19.0           # validate explicit version (workflow_dispatch)
#   INPUT_VERSION=0.19.0 scripts/detect-version.sh  # Actions input passthrough
#
# Rationale for HEAD probing: the Grok Bot distribution bucket at
# downloads.cursor.com does not expose S3 ?list-type=2 listings (AccessDenied)
# nor a latest.yml manifest (403). Direct HEAD against the deterministic
# artifact path is the sole reliable existence signal.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"

WIN32_URL_TEMPLATE="https://downloads.cursor.com/grokbot/stable/win32-x64/%s/Grok_Bot_%s_Setup.exe"
DARWIN_URL_TEMPLATE="https://downloads.cursor.com/grokbot/stable/darwin-x64/%s/Grok_Bot_%s_x64.dmg"

# ---------------------------------------------------------------------------
# Resolve current base version
# ---------------------------------------------------------------------------
read_base_version() {
  if [[ -f "${VERSION_FILE}" ]]; then
    # shellcheck disable=SC2002
    cat "${VERSION_FILE}" | tr -d '[:space:]'
  else
    echo "0.18.0"
  fi
}

# ---------------------------------------------------------------------------
# Resolve dispatched version (CLI arg > INPUT_VERSION env > empty)
# ---------------------------------------------------------------------------
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
# HEAD probe — returns 0 when the artifact exists (HTTP 200)
# ---------------------------------------------------------------------------
probe_url() {
  local url="$1"
  local code
  code="$(curl --head --fail --silent --location --max-time 10 --retry 2 \
    -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || true)"
  [[ "${code}" == "200" ]]
}

probe_version() {
  local ver="$1"
  local win32_url darwin_url
  # shellcheck disable=SC2059
  win32_url="$(printf "${WIN32_URL_TEMPLATE}" "${ver}" "${ver}")"
  if probe_url "${win32_url}"; then
    return 0
  fi
  # Optional cross-platform confirmation — darwin artifact occasionally
  # appears first; probing it prevents false negatives on win32 propagation
  # lag. Failure on both platforms is treated as non-existence.
  darwin_url="$(printf "${DARWIN_URL_TEMPLATE}" "${ver}" "${ver}")"
  probe_url "${darwin_url}"
}

# ---------------------------------------------------------------------------
# Generate semver candidates from base x.y.z
#
# Strategy (bound to ~25 candidates to cap Actions wall time):
#   1. Patch sweep:  x.y.(z+1) .. x.y.(z+10)
#   2. Minor sweep:  x.(y+1).0 .. x.(y+10).0  (covers 0.18.0 -> 0.19.0 where
#      patch-only probing would miss the jump entirely)
#   3. Next-patch of each minor: x.(y+n).1 for n=1..5
#   4. Major sweep:  (x+1).0.0 when x < 1, else (x+1).0.0
# Deduplicate, then sort descending with sort -V so probing order is
# deterministic and selection is trivially max(sort -V).
# ---------------------------------------------------------------------------
generate_candidates() {
  local base="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "${base}"

  # Guard against non-numeric parse
  if ! [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ && "${patch}" =~ ^[0-9]+$ ]]; then
    echo "error: cannot parse base version '${base}' as x.y.z" >&2
    exit 1
  fi

  local -a raw=()

  # 1. Patch sweep
  for i in $(seq 1 10); do
    raw+=("${major}.${minor}.$((patch + i))")
  done

  # 2. Minor sweep (y+1 .. y+10)
  for i in $(seq 1 10); do
    raw+=("${major}.$((minor + i)).0")
  done

  # 3. Next-patch of each upcoming minor (y+1 .. y+5) — catches 0.19.1 etc.
  for i in $(seq 1 5); do
    raw+=("${major}.$((minor + i)).1")
  done

  # 4. Major sweep (only meaningful while x < 1)
  raw+=("$((major + 1)).0.0")

  # Deduplicate while preserving version semantics, then sort descending
  printf '%s\n' "${raw[@]}" | sort -u -V -r
}

# ---------------------------------------------------------------------------
# Emit outputs: stdout + $GITHUB_OUTPUT when running in Actions
# ---------------------------------------------------------------------------
emit_outputs() {
  local version="$1"
  local is_new="$2"

  # Human-readable stdout (Actions log + local run)
  echo "version=${version}"
  echo "is_new=${is_new}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "version=${version}"
      echo "is_new=${is_new}"
    } >> "${GITHUB_OUTPUT}"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local base dispatch latest is_new
  base="$(read_base_version)"
  dispatch="$(resolve_dispatch_version "${1:-}")"

  # --- Dispatched / pinned version path ----------------------------------
  if [[ -n "${dispatch}" ]]; then
    echo "Dispatch version requested: ${dispatch}" >&2
    if probe_version "${dispatch}"; then
      echo "Dispatch version ${dispatch} verified (HTTP 200)." >&2
      # Dispatched version bypasses the > base gate — if it probes 200 it is
      # authoritative regardless of candidate set, per the fallback contract.
      if [[ "${dispatch}" == "${base}" ]]; then
        is_new="false"
      else
        # Treat any verified dispatched version differing from base as actionable.
        is_new="true"
      fi
      emit_outputs "${dispatch}" "${is_new}"
      # Also emit bare version on stdout for capture via $(detect-version.sh)
      # callers that parse the last line.
      printf '%s\n' "${dispatch}"
      exit 0
    else
      echo "error: dispatched version ${dispatch} did not return HTTP 200 for win32 or darwin artifact" >&2
      exit 1
    fi
  fi

  # --- Autonomous candidate probing path -----------------------------------
  echo "Base version: ${base}" >&2

  local candidates
  candidates="$(generate_candidates "${base}")"
  echo "Probing candidates (descending semver):" >&2
  echo "${candidates}" | while read -r c; do echo "  - ${c}" >&2; done

  local -a passing=()
  while IFS= read -r cand; do
    [[ -z "${cand}" ]] && continue
    if probe_version "${cand}"; then
      echo "  HIT  ${cand}" >&2
      passing+=("${cand}")
    else
      echo "  miss ${cand}" >&2
    fi
  done <<< "${candidates}"

  if [[ ${#passing[@]} -eq 0 ]]; then
    echo "No candidate newer than ${base} returned HTTP 200 — base remains latest." >&2
    emit_outputs "${base}" "false"
    printf '%s\n' "${base}"
    exit 0
  fi

  # Highest passing candidate via semver sort — sort -V respects semver ordering
  latest="$(printf '%s\n' "${passing[@]}" | sort -V | tail -n 1)"
  echo "Latest passing candidate: ${latest}" >&2

  # Strictly greater than base?
  local sorted_max
  sorted_max="$(printf '%s\n' "${base}" "${latest}" | sort -V | tail -n 1)"
  if [[ "${sorted_max}" == "${latest}" && "${latest}" != "${base}" ]]; then
    is_new="true"
  else
    is_new="false"
  fi

  emit_outputs "${latest}" "${is_new}"
  printf '%s\n' "${latest}"
}

main "${1:-}"
