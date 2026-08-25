#!/usr/bin/env bash

set -euo pipefail

readonly SELF_NAME="openwiki-container"
readonly DEFAULT_RUNTIME_HOME="/tmp/openwiki-container-home"
readonly DEFAULT_STATUS_STAGE="container"
readonly DEFAULT_RUN_MODE="auto"
readonly DEFAULT_INIT_MESSAGE="$(cat <<'EOF'
Create the initial OpenWiki for this repository and complete the documentation work in this run.

Produce a genuinely useful first-pass wiki under /openwiki, not just a skeleton, backlog, or proposal of what could be documented later. Start with /openwiki/quickstart.md as the main entrypoint, then create the supporting pages needed to make the repository understandable to a new engineer or coding agent.

Requirements:
- Inspect the repository carefully and document only what is supported by the code, configuration, tests, scripts, and git context available in this run.
- Prioritize concrete, high-signal documentation over broad but shallow coverage.
- Prefer a small number of substantial pages over many thin placeholder pages.
- Merge weak or overlapping topics into stronger overview pages instead of creating stubs.
- If a detail is uncertain or unsupported by evidence, omit it rather than guessing.

At minimum, cover the topics that are actually present in the repository:
- repository purpose and primary use cases
- quickstart and local development workflow
- architecture and major execution flows
- major directories, modules, services, scripts, and entrypoints
- configuration files, environment variables, and runtime dependencies
- data models, state files, storage formats, or external interfaces
- build, test, CI, and release workflow behavior
- operational concerns, failure modes, and troubleshooting guidance
- important limitations, assumptions, or deferred work

Quality bar:
- Write documentation that explains how the system really works, not just what files exist.
- Include concrete file, command, and configuration references where they materially help.
- Make the wiki navigable with clear page titles, strong summaries, and useful cross-links.
- Add diagrams only where they add real explanatory value.
- Do not stop at "here is what I can do next".
- Do not return a plan instead of documentation.
- Do not create TODO-only pages, empty outlines, or placeholder sections unless absolutely necessary.

If the repository is small, keep the wiki compact.
If the repository is complex, create the additional pages needed to make it understandable, but keep every page substantive.

The goal is that after this run, a human maintainer or coding agent can use /openwiki as a practical source of truth for understanding and changing the repository.
EOF
)"

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

resolve_openwiki_mode() {
  local __mode_var_name="$1"
  local __reason_var_name="$2"
  local requested_mode
  local selected_mode
  local selected_reason

  requested_mode="${OPENWIKI_RUN_MODE:-${DEFAULT_RUN_MODE}}"

  case "${requested_mode}" in
    init)
      selected_mode="init"
      selected_reason="forced by OPENWIKI_RUN_MODE=init"
      ;;
    update)
      selected_mode="update"
      selected_reason="forced by OPENWIKI_RUN_MODE=update"
      ;;
    auto)
      if [[ -f "${PWD}/openwiki/.last-update.json" ]]; then
        selected_mode="update"
        selected_reason="detected openwiki/.last-update.json"
      elif [[ ! -d "${PWD}/openwiki" ]]; then
        selected_mode="init"
        selected_reason="openwiki/ directory not found"
      elif [[ -f "${PWD}/openwiki/_skeleton.md" ]]; then
        selected_mode="update"
        selected_reason="detected openwiki/_skeleton.md without .last-update.json; treating repository as initialized"
      else
        fail "unable to auto-select OpenWiki mode: openwiki/ exists but openwiki/.last-update.json does not. Set OPENWIKI_RUN_MODE=init or OPENWIKI_RUN_MODE=update explicitly." "preflight"
      fi
      ;;
    *)
      fail "invalid OPENWIKI_RUN_MODE '${requested_mode}'. Expected one of: auto, init, update." "preflight"
      ;;
  esac

  printf -v "${__mode_var_name}" '%s' "${selected_mode}"
  printf -v "${__reason_var_name}" '%s' "${selected_reason}"
}

print_resolved_mode() {
  local resolved_mode
  local resolved_reason

  resolve_openwiki_mode resolved_mode resolved_reason
  printf 'MODE=%s\n' "${resolved_mode}"
  printf 'REASON=%s\n' "${resolved_reason}"
}

default_init_message() {
  printf '%s\n' "${OPENWIKI_INIT_MESSAGE:-${DEFAULT_INIT_MESSAGE}}"
}

command_has_instruction_message() {
  local arg
  shift 2

  for arg in "$@"; do
    if [[ "${arg}" != -* ]]; then
      return 0
    fi
  done

  return 1
}

normalize_openwiki_args() {
  local resolved_mode="$1"
  shift

  local arg
  local init_message
  local saw_code=0
  local -a normalized_args=()

  for arg in "$@"; do
    case "${arg}" in
      --init | --update)
        continue
        ;;
    esac
    normalized_args+=("${arg}")
  done

  if [[ "${#normalized_args[@]}" -gt 0 && "${normalized_args[0]}" == "code" ]]; then
    saw_code=1
  fi

  if [[ "${saw_code}" -eq 0 ]]; then
    normalized_args=("code" "${normalized_args[@]}")
  fi

  case "${resolved_mode}" in
    init)
      normalized_args=("code" "--init" "${normalized_args[@]:1}")
      if ! command_has_instruction_message "${normalized_args[@]}"; then
        init_message="$(default_init_message)"
        normalized_args+=("${init_message}")
      fi
      ;;
    update)
      normalized_args=("code" "--update" "${normalized_args[@]:1}")
      ;;
    *)
      fail "internal error: unsupported resolved mode '${resolved_mode}'." "container"
      ;;
  esac

  printf '%s\0' "${normalized_args[@]}"
}

print_preview_command() {
  local resolved_mode
  local resolved_reason
  local index=0
  local -a command_args

  resolve_openwiki_mode resolved_mode resolved_reason
  mapfile -d '' -t command_args < <(normalize_openwiki_args "${resolved_mode}" "$@")

  printf 'MODE=%s\n' "${resolved_mode}"
  printf 'REASON=%s\n' "${resolved_reason}"
  for arg in "${command_args[@]}"; do
    printf 'ARG[%s]=%s\n' "${index}" "${arg}"
    index=$((index + 1))
  done
}

main() {
  local arg
  local command_text
  local resolved_mode
  local resolved_reason
  local -a command_args
  local openwiki_version
  local start_seconds
  local status

  if [[ "${1:-}" == "container-self-check" ]]; then
    run_self_check
    exit 0
  fi

  if [[ "${1:-}" == "container-resolve-mode" ]]; then
    print_resolved_mode
    exit 0
  fi

  if [[ "${1:-}" == "container-preview-command" ]]; then
    shift
    print_preview_command "$@"
    exit 0
  fi

  ensure_runtime_home

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

  resolve_openwiki_mode resolved_mode resolved_reason
  log "mode=${resolved_mode} (${resolved_reason})"

  mapfile -d '' -t command_args < <(normalize_openwiki_args "${resolved_mode}" "$@")
  command_text="openwiki ${command_args[*]}"

  openwiki_version="$(openwiki --version 2>/dev/null | head -n 1 || true)"
  log "starting OpenWiki ${openwiki_version:-unknown} in ${PWD}"
  log "runtime-home=${HOME}"
  log "provider=${OPENWIKI_PROVIDER} model=${OPENWIKI_MODEL_ID}"
  log "command=${command_text}"

  start_seconds="${SECONDS}"
  set +e
  openwiki "${command_args[@]}"
  status=$?
  set -e

  finish_with_status \
    "${status}" \
    "openwiki-run" \
    "completed with exit code ${status} after $((SECONDS - start_seconds))s" \
    "${command_text}"
}

main "$@"
