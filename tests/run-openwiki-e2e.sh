#!/usr/bin/env bash

set -euo pipefail

readonly image_tag="${IMAGE_TAG:-openwiki-container:e2e}"
readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root=""
google_credentials_mount=""
google_credentials_container_path=""

cleanup() {
  if [[ -n "${tmp_root}" && -d "${tmp_root}" ]]; then
    rm -rf "${tmp_root}"
  fi
}

new_tmp_dir() {
  mktemp -d "${tmp_root}/tmp.XXXXXX"
}

require_docker() {
  docker version >/dev/null
}

build_image() {
  docker build --tag "${image_tag}" "${repo_root}"
}

require_e2e_configuration() {
  [[ -n "${OPENWIKI_PROVIDER:-}" ]] || {
    printf 'OPENWIKI_PROVIDER must be set for the end-to-end test.\n' >&2
    exit 1
  }

  [[ -n "${OPENWIKI_MODEL_ID:-}" ]] || {
    printf 'OPENWIKI_MODEL_ID must be set for the end-to-end test.\n' >&2
    exit 1
  }
}

new_fixture_repo() {
  local destination

  destination="$(new_tmp_dir)"
  mkdir -p "${destination}/repo"
  cp -R "${repo_root}/tests/fixture-repo/." "${destination}/repo"
  git -C "${destination}/repo" init -q
  git -C "${destination}/repo" config user.name "OpenWiki Container E2E Tests"
  git -C "${destination}/repo" config user.email "openwiki-container-e2e@example.com"
  git -C "${destination}/repo" add .
  git -C "${destination}/repo" commit -q -m "Initial fixture commit"

  printf '%s\n' "${destination}/repo"
}

append_env_if_set() {
  local array_name="$1"
  local env_name="$2"

  if [[ -n "${!env_name:-}" ]]; then
    eval "$array_name+=(--env \"$env_name\")"
  fi
}

prepare_google_adc_mount() {
  local credentials_path
  local copied_credentials

  credentials_path="${GOOGLE_APPLICATION_CREDENTIALS:-}"
  if [[ -n "${credentials_path}" ]]; then
    [[ -f "${credentials_path}" ]] || {
      printf 'GOOGLE_APPLICATION_CREDENTIALS points to a missing file: %s\n' "${credentials_path}" >&2
      exit 1
    }

    copied_credentials="${tmp_root}/google-application-credentials.json"
    cp "${credentials_path}" "${copied_credentials}"
    chmod 600 "${copied_credentials}"

    google_credentials_mount="${copied_credentials}:/tmp/google-application-credentials.json:ro"
    google_credentials_container_path="/tmp/google-application-credentials.json"
    return 0
  fi

  if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS_JSON:-}" ]]; then
    copied_credentials="${tmp_root}/google-application-credentials.json"
    printf '%s' "${GOOGLE_APPLICATION_CREDENTIALS_JSON}" >"${copied_credentials}"
    chmod 600 "${copied_credentials}"

    google_credentials_mount="${copied_credentials}:/tmp/google-application-credentials.json:ro"
    google_credentials_container_path="/tmp/google-application-credentials.json"
  fi
}

assert_generated_artifacts() {
  local repo_dir="$1"

  [[ -f "${repo_dir}/AGENTS.md" ]] || {
    printf 'expected OpenWiki to generate AGENTS.md\n' >&2
    exit 1
  }

  [[ -f "${repo_dir}/CLAUDE.md" ]] || {
    printf 'expected OpenWiki to generate CLAUDE.md\n' >&2
    exit 1
  }

  [[ -d "${repo_dir}/openwiki" ]] || {
    printf 'expected OpenWiki to generate the openwiki directory\n' >&2
    exit 1
  }
}

main() {
  local repo_dir
  local output_file
  local -a docker_args
  local -a provider_env_vars

  tmp_root="$(mktemp -d)"
  trap cleanup EXIT

  require_docker
  require_e2e_configuration

  if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    build_image
  fi

  prepare_google_adc_mount
  repo_dir="$(new_fixture_repo)"
  output_file="$(mktemp "${tmp_root}/output.XXXXXX")"

  docker_args=(
    docker
    run
    --rm
    --user "$(id -u):$(id -g)"
    --volume "${repo_dir}:/repo"
    --workdir /repo
    --env OPENWIKI_PROVIDER
    --env OPENWIKI_MODEL_ID
    --env OPENWIKI_PROVIDER_RETRY_ATTEMPTS
  )

  provider_env_vars=(
    OPENAI_API_KEY
    OPENAI_BASE_URL
    ANTHROPIC_API_KEY
    ANTHROPIC_BASE_URL
    GEMINI_API_KEY
    GOOGLE_CLOUD_PROJECT
    GOOGLE_CLOUD_LOCATION
    BEDROCK_AWS_REGION
    BEDROCK_AWS_ACCESS_KEY_ID
    BEDROCK_AWS_SECRET_ACCESS_KEY
    AWS_REGION
    AWS_DEFAULT_REGION
    OPENAI_COMPATIBLE_API_KEY
    OPENAI_COMPATIBLE_BASE_URL
    OPENROUTER_API_KEY
    COPILOT_API_KEY
    COPILOT_BASE_URL
    BASETEN_API_KEY
    BASETEN_BASE_URL
    FIREWORKS_API_KEY
    FIREWORKS_BASE_URL
    NEBIUS_API_KEY
    NVIDIA_API_KEY
    NVIDIA_BASE_URL
    LANGSMITH_API_KEY
    LANGCHAIN_PROJECT
    LANGCHAIN_TRACING_V2
  )

  for env_name in "${provider_env_vars[@]}"; do
    append_env_if_set docker_args "${env_name}"
  done

  if [[ -n "${google_credentials_mount}" ]]; then
    docker_args+=(--volume "${google_credentials_mount}")
    docker_args+=(--env "GOOGLE_APPLICATION_CREDENTIALS=${google_credentials_container_path}")
  fi

  docker_args+=("${image_tag}" code --update --print)

  "${docker_args[@]}" >"${output_file}" 2>&1 || {
    cat "${output_file}" >&2
    exit 1
  }

  assert_generated_artifacts "${repo_dir}"

  printf 'OpenWiki end-to-end test passed for %s\n' "${image_tag}"
}

main "$@"
