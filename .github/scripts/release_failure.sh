#!/usr/bin/env bash

# Shared diagnostics for Apple release workflows. The caller may enable set -euo.

release_failure_escape() {
  local value="$1"
  value=${value//'%'/'%25'}
  value=${value//$'\r'/'%0D'}
  value=${value//$'\n'/'%0A'}
  printf '%s' "$value"
}

release_failure_markdown() {
  local value="$1"
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  value=${value//'|'/'\\|'}
  printf '%s' "$value"
}

release_fail() {
  local category="$1"
  local cause="$2"
  local remediation="$3"
  local escaped_cause escaped_remediation step
  escaped_cause="$(release_failure_escape "$cause")"
  escaped_remediation="$(release_failure_escape "$remediation")"
  printf '::error title=Apple release failed (%s)::%s Remediation: %s\n' \
    "$(release_failure_escape "$category")" "$escaped_cause" "$escaped_remediation" >&2

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    step="${GITHUB_STEP_NAME:-${GITHUB_JOB:-Apple release}}"
    {
      printf '\n## Apple release failed\n\n'
      printf '| Step | Category | Cause | Remediation |\n'
      printf '| --- | --- | --- | --- |\n'
      printf '| %s | %s | %s | %s |\n' \
        "$(release_failure_markdown "$step")" \
        "$(release_failure_markdown "$category")" \
        "$(release_failure_markdown "$cause")" \
        "$(release_failure_markdown "$remediation")"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
}

retry_command() {
  local attempts="$1"
  local delay_seconds="$2"
  local description="$3"
  shift 3
  [[ "${1:-}" == "--" ]] || {
    echo "retry_command requires -- before the command" >&2
    return 64
  }
  shift
  [[ "$attempts" =~ ^[1-9][0-9]*$ && "$delay_seconds" =~ ^[0-9]+$ && "$#" -gt 0 ]] || {
    echo "retry_command received invalid attempts, delay, or command" >&2
    return 64
  }

  local attempt=1 exit_status
  while (( attempt <= attempts )); do
    if "$@"; then
      return 0
    else
      exit_status=$?
    fi
    if (( attempt == attempts )); then
      return "$exit_status"
    fi
    printf '::warning::%s failed on attempt %d/%d (exit %d); retrying in %ss.\n' \
      "$description" "$attempt" "$attempts" "$exit_status" "$delay_seconds" >&2
    sleep "$delay_seconds"
    delay_seconds=$((delay_seconds * 2))
    attempt=$((attempt + 1))
  done
}
