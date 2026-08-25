#!/usr/bin/env bash

set -euo pipefail

readonly image_tag="${IMAGE_TAG:-openwiki-container:test}"
readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root=""

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

new_fixture_repo() {
  local destination

  destination="$(new_tmp_dir)"
  mkdir -p "${destination}/repo"
  cp -R "${repo_root}/tests/fixture-repo/." "${destination}/repo"
  git -C "${destination}/repo" init -q
  git -C "${destination}/repo" config user.name "OpenWiki Container Tests"
  git -C "${destination}/repo" config user.email "openwiki-container-tests@example.com"
  git -C "${destination}/repo" add .
  git -C "${destination}/repo" commit -q -m "Initial fixture commit"

  printf '%s\n' "${destination}/repo"
}

assert_contains() {
  local file="$1"
  local expected="$2"

  if ! grep -Fq "${expected}" "${file}"; then
    printf 'expected output to contain: %s\n' "${expected}" >&2
    cat "${file}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"

  if grep -Fq "${unexpected}" "${file}"; then
    printf 'did not expect output to contain: %s\n' "${unexpected}" >&2
    cat "${file}" >&2
    exit 1
  fi
}

run_expect_failure() {
  local output_file="$1"
  shift

  set +e
  "$@" >"${output_file}" 2>&1
  local status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    printf 'expected command to fail but it succeeded\n' >&2
    cat "${output_file}" >&2
    exit 1
  fi
}

test_version_command() {
  docker run --rm "${image_tag}" --version >/dev/null
}

test_help_command_without_repo_or_credentials() {
  docker run --rm "${image_tag}" code --help >/dev/null
}

test_git_repo_validation() {
  local workdir
  local output_file

  workdir="$(new_tmp_dir)"
  output_file="$(mktemp "${tmp_root}/output.XXXXXX")"

  run_expect_failure "${output_file}" \
    docker run --rm \
      -v "${workdir}:/repo" \
      -w /repo \
      -e OPENWIKI_PROVIDER=openai \
      -e OPENWIKI_MODEL_ID=gpt-5.6-terra \
      "${image_tag}" \
      code --update --print

  assert_contains "${output_file}" "is not a git repository"
}

test_explicit_provider_requirement() {
  local repo_dir
  local output_file

  repo_dir="$(new_fixture_repo)"
  output_file="$(mktemp "${tmp_root}/output.XXXXXX")"

  run_expect_failure "${output_file}" \
    docker run --rm \
      -v "${repo_dir}:/repo" \
      -w /repo \
      "${image_tag}" \
      code --update --print

  assert_contains "${output_file}" "OPENWIKI_PROVIDER must be set explicitly"
}

test_explicit_model_requirement() {
  local repo_dir
  local output_file

  repo_dir="$(new_fixture_repo)"
  output_file="$(mktemp "${tmp_root}/output.XXXXXX")"

  run_expect_failure "${output_file}" \
    docker run --rm \
      -v "${repo_dir}:/repo" \
      -w /repo \
      -e OPENWIKI_PROVIDER=openai \
      "${image_tag}" \
      code --update --print

  assert_contains "${output_file}" "OPENWIKI_MODEL_ID must be set explicitly"
}

test_mounted_file_writes_are_visible() {
  local repo_dir
  local output_file
  local written_file

  repo_dir="$(new_fixture_repo)"
  output_file="$(mktemp "${tmp_root}/output.XXXXXX")"
  written_file="${repo_dir}/.container-write-test"

  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --entrypoint /bin/sh \
    -v "${repo_dir}:/repo" \
    -w /repo \
    "${image_tag}" \
    -c 'printf "ok\n" > /repo/.container-write-test' \
    >"${output_file}" 2>&1

  [[ -f "${written_file}" ]] || {
    printf 'expected mounted file to be created: %s\n' "${written_file}" >&2
    exit 1
  }

  [[ -O "${written_file}" ]] || {
    printf 'expected mounted file to be owned by the invoking host user: %s\n' "${written_file}" >&2
    exit 1
  }

  assert_not_contains "${output_file}" "Permission denied"
}

test_runtime_home_is_writable_for_user_mapped_runs() {
  local output_file
  local runtime_home
  local state_dir
  local marker_file

  output_file="$(mktemp "${tmp_root}/output.XXXXXX")"

  docker run --rm \
    --user "$(id -u):$(id -g)" \
    "${image_tag}" \
    container-self-check \
    >"${output_file}" 2>&1

  runtime_home="$(grep '^HOME=' "${output_file}" | head -n 1 | cut -d= -f2-)"
  state_dir="$(grep '^OPENWIKI_STATE_DIR=' "${output_file}" | head -n 1 | cut -d= -f2-)"
  marker_file="$(grep '^MARKER=' "${output_file}" | head -n 1 | cut -d= -f2-)"

  [[ -n "${runtime_home}" ]] || {
    printf 'expected self-check to print HOME\n' >&2
    cat "${output_file}" >&2
    exit 1
  }

  [[ "${runtime_home}" == /tmp/* ]] || {
    printf 'expected runtime home to be remapped under /tmp for caller-mapped users, got: %s\n' "${runtime_home}" >&2
    cat "${output_file}" >&2
    exit 1
  }

  [[ "${state_dir}" == "${runtime_home}/.openwiki" ]] || {
    printf 'expected OpenWiki state dir under runtime home, got: %s\n' "${state_dir}" >&2
    cat "${output_file}" >&2
    exit 1
  }

  [[ "${marker_file}" == "${state_dir}/.container-self-check" ]] || {
    printf 'expected self-check marker under OpenWiki state dir, got: %s\n' "${marker_file}" >&2
    cat "${output_file}" >&2
    exit 1
  }

  assert_not_contains "${output_file}" "Permission denied"
}

test_preflight_failure_does_not_log_secret_values() {
  local repo_dir
  local output_file

  repo_dir="$(new_fixture_repo)"
  output_file="$(mktemp "${tmp_root}/output.XXXXXX")"

  run_expect_failure "${output_file}" \
    docker run --rm \
      -v "${repo_dir}:/repo" \
      -w /repo \
      -e OPENWIKI_PROVIDER=openai \
      -e OPENAI_API_KEY=super-secret-test-value \
      "${image_tag}" \
      code --update --print

  assert_contains "${output_file}" "OPENWIKI_MODEL_ID must be set explicitly"
  assert_not_contains "${output_file}" "super-secret-test-value"
}

test_status_file_for_preflight_failure() {
  local repo_dir
  local output_file
  local status_file

  repo_dir="$(new_fixture_repo)"
  output_file="$(mktemp "${tmp_root}/output.XXXXXX")"
  status_file="${repo_dir}/.openwiki-container-status.json"

  run_expect_failure "${output_file}" \
    docker run --rm \
      -v "${repo_dir}:/repo" \
      -w /repo \
      -e OPENWIKI_STATUS_FILE=.openwiki-container-status.json \
      "${image_tag}" \
      code --update --print

  [[ -f "${status_file}" ]] || {
    printf 'expected status file to be created: %s\n' "${status_file}" >&2
    exit 1
  }

  assert_contains "${status_file}" '"status": "failed"'
  assert_contains "${status_file}" '"stage": "preflight"'
  assert_contains "${status_file}" '"exit_code": 1'
  assert_contains "${status_file}" 'OPENWIKI_PROVIDER must be set explicitly'
}

test_github_actions_error_annotation() {
  local repo_dir
  local output_file

  repo_dir="$(new_fixture_repo)"
  output_file="$(mktemp "${tmp_root}/output.XXXXXX")"

  run_expect_failure "${output_file}" \
    docker run --rm \
      -v "${repo_dir}:/repo" \
      -w /repo \
      -e GITHUB_ACTIONS=true \
      "${image_tag}" \
      code --update --print

  assert_contains "${output_file}" '::error title=OpenWiki container::OPENWIKI_PROVIDER must be set explicitly'
}

main() {
  tmp_root="$(mktemp -d)"
  trap cleanup EXIT

  require_docker

  if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    build_image
  fi

  test_version_command
  test_help_command_without_repo_or_credentials
  test_git_repo_validation
  test_explicit_provider_requirement
  test_explicit_model_requirement
  test_mounted_file_writes_are_visible
  test_runtime_home_is_writable_for_user_mapped_runs
  test_preflight_failure_does_not_log_secret_values
  test_status_file_for_preflight_failure
  test_github_actions_error_annotation

  printf 'All container tests passed for %s\n' "${image_tag}"
}

main "$@"
