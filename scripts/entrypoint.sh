#!/usr/bin/env bash

set -euo pipefail

readonly SELF_NAME="openwiki-container"
readonly DEFAULT_RUNTIME_HOME="/tmp/openwiki-container-home"
readonly DEFAULT_STATUS_STAGE="container"

log() {
  printf '[%s] %s\n' "${SELF_NAME}" "$*" >&2
}

emit_github_annotation() {
  local level="$1"
  local message="$2"

  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::%s title=OpenWiki container::%s\n' "${level}" "${message}" >&2
  fi
}

write_status_file() {
  local run_status="$1"
  local stage="$2"
  local exit_code="$3"
  local message="$4"
  local command_text="$5"
  local status_file_path
  local status_file_dir

  status_file_path="${OPENWIKI_STATUS_FILE:-}"
  if [[ -z "${status_file_path}" ]]; then
    return 0
  fi

  if [[ "${status_file_path}" != /* ]]; then
    status_file_path="${PWD}/${status_file_path}"
  fi

  status_file_dir="$(dirname "${status_file_path}")"
  mkdir -p "${status_file_dir}" || {
    log "error: unable to create status file directory '${status_file_dir}'."
    return 1
  }

  node -e '
    const fs = require("fs");
    const payload = {
      status: process.argv[1],
      stage: process.argv[2],
      exit_code: Number(process.argv[3]),
      message: process.argv[4],
      command: process.argv[5],
      timestamp: new Date().toISOString(),
    };
    fs.writeFileSync(process.argv[6], JSON.stringify(payload, null, 2) + "\n", { mode: 0o600 });
  ' "${run_status}" "${stage}" "${exit_code}" "${message}" "${command_text}" "${status_file_path}" || {
    log "error: unable to write status file '${status_file_path}'."
    return 1
  }
}

finish_with_status() {
  local exit_code="$1"
  local stage="$2"
  local message="$3"
  local command_text="${4:-}"

  if [[ "${exit_code}" -eq 0 ]]; then
    write_status_file "succeeded" "${stage}" "${exit_code}" "${message}" "${command_text}" || true
    emit_github_annotation "notice" "${message}"
    log "${message}"
    exit 0
  fi

  write_status_file "failed" "${stage}" "${exit_code}" "${message}" "${command_text}" || true
  emit_github_annotation "error" "${message}"
  log "error: ${message}"
  exit "${exit_code}"
}

fail() {
  local message="$1"
  local stage="${2:-${DEFAULT_STATUS_STAGE}}"
  local exit_code="${3:-1}"

  finish_with_status "${exit_code}" "${stage}" "${message}" ""
}

ensure_runtime_home() {
  local candidate_home
  local openwiki_state_dir

  candidate_home="${HOME:-}"
  if [[ -z "${candidate_home}" || ! -d "${candidate_home}" || ! -w "${candidate_home}" ]]; then
    candidate_home="${OPENWIKI_CONTAINER_HOME:-${DEFAULT_RUNTIME_HOME}}"
  fi

  mkdir -p "${candidate_home}" || fail "unable to create writable runtime home at '${candidate_home}'."
  [[ -w "${candidate_home}" ]] || fail "runtime home '${candidate_home}' is not writable by the current container user."

  export HOME="${candidate_home}"

  openwiki_state_dir="${HOME}/.openwiki"
  mkdir -p "${openwiki_state_dir}" || fail "unable to create OpenWiki state directory at '${openwiki_state_dir}'."
  [[ -w "${openwiki_state_dir}" ]] || fail "OpenWiki state directory '${openwiki_state_dir}' is not writable by the current container user."
}

run_self_check() {
  local marker_file

  ensure_runtime_home

  marker_file="${HOME}/.openwiki/.container-self-check"
  printf 'ok\n' >"${marker_file}" || fail "unable to write self-check marker at '${marker_file}'."

  printf 'HOME=%s\n' "${HOME}"
  printf 'OPENWIKI_STATE_DIR=%s\n' "${HOME}/.openwiki"
  printf 'MARKER=%s\n' "${marker_file}"
}

main() {
  local arg
  local command_text
  local openwiki_version
  local start_seconds
  local status

  if [[ "${1:-}" == "container-self-check" ]]; then
    run_self_check
    exit 0
  fi

  ensure_runtime_home
  command_text="openwiki $*"

  for arg in "$@"; do
    case "${arg}" in
      "--help" | "-h")
        exec openwiki "$@"
        ;;
      "--version" | "-v")
        printf 'openwiki-container (openwiki %s)\n' "${OPENWIKI_IMAGE_OPENWIKI_VERSION:-unknown}"
        exit 0
        ;;
    esac
  done

  case "${1:-}" in
    "" | "help")
      exec openwiki "$@"
      ;;
    "version")
      printf 'openwiki-container (openwiki %s)\n' "${OPENWIKI_IMAGE_OPENWIKI_VERSION:-unknown}"
      exit 0
      ;;
  esac

  if [[ "${OPENWIKI_REQUIRE_EXPLICIT_SELECTION:-1}" == "1" ]]; then
    [[ -n "${OPENWIKI_PROVIDER:-}" ]] || fail "OPENWIKI_PROVIDER must be set explicitly for non-interactive container runs." "preflight"
    [[ -n "${OPENWIKI_MODEL_ID:-}" ]] || fail "OPENWIKI_MODEL_ID must be set explicitly for non-interactive container runs." "preflight"
  fi

  if [[ "${OPENWIKI_VALIDATE_GIT_REPO:-1}" == "1" ]]; then
    git -C "${PWD}" rev-parse --show-toplevel >/dev/null 2>&1 \
      || fail "mounted working directory '${PWD}' is not a git repository. Mount a checked-out repository at /repo." "preflight"
  fi

  [[ -w "${PWD}" ]] || fail "mounted working directory '${PWD}' is not writable by the current container user." "preflight"

  openwiki_version="$(openwiki --version 2>/dev/null | head -n 1 || true)"
  log "starting OpenWiki ${openwiki_version:-unknown} in ${PWD}"
  log "runtime-home=${HOME}"
  log "provider=${OPENWIKI_PROVIDER} model=${OPENWIKI_MODEL_ID}"
  log "command=${command_text}"

  start_seconds="${SECONDS}"
  set +e
  openwiki "$@"
  status=$?
  set -e

  finish_with_status \
    "${status}" \
    "openwiki-run" \
    "completed with exit code ${status} after $((SECONDS - start_seconds))s" \
    "${command_text}"
}

main "$@"
