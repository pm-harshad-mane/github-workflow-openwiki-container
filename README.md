# OpenWiki Container

Reusable container for running OpenWiki against a checked-out Git repository from CI or local Docker.

The image packages the OpenWiki runtime so application repositories do not need Node.js, npm, or OpenWiki installed locally.

## What it does

- runs `openwiki code --update --print` against a mounted repository
- writes generated documentation back into the mounted host workspace
- validates basic container preconditions before invoking OpenWiki
- preserves OpenWiki's own provider and model configuration contract

Expected generated outputs usually include:

- `openwiki/`
- `AGENTS.md`
- `CLAUDE.md`

The container does not manage Git branches, commits, pushes, or pull requests.

## Quick start

Build the image:

```bash
docker build -t openwiki-container:local .
```

Run it against a checked-out repository:

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/repo" \
  -w /repo \
  -e OPENWIKI_PROVIDER=anthropic \
  -e OPENWIKI_MODEL_ID=claude-sonnet \
  -e ANTHROPIC_API_KEY \
  openwiki-container:local \
  code --update --print
```

If the run succeeds, generated documentation appears directly in the mounted repository on the host.

Validated OpenAI example from this repo:

```bash
export OPENWIKI_PROVIDER='openai'
export OPENWIKI_MODEL_ID='gpt-4.1-mini'
export OPENAI_API_KEY='your-openai-key'

./tests/run-openwiki-e2e.sh
```

In this environment, `gpt-4.1-mini` completed successfully. `gpt-5-mini` failed because the OpenAI organization was not verified for that model, so model availability can depend on account entitlements.

## Runtime contract

The container owns only container concerns:

- default working directory: `/repo`
- writable runtime home setup for caller-provided UID/GID
- Git repository preflight check
- exit status and failure reporting

OpenWiki owns model-provider configuration.

Required in non-interactive CI-style runs:

- `OPENWIKI_PROVIDER`
- `OPENWIKI_MODEL_ID`

Provider-specific environment variables are passed through unchanged. Use the OpenWiki documentation for the pinned OpenWiki version in this image to determine the correct variables for your provider.

Common examples:

- `OPENAI_API_KEY`
- `OPENAI_BASE_URL`
- `ANTHROPIC_API_KEY`
- `ANTHROPIC_BASE_URL`
- `GEMINI_API_KEY`
- `GOOGLE_CLOUD_PROJECT`
- `GOOGLE_CLOUD_LOCATION`
- `OPENAI_COMPATIBLE_API_KEY`
- `OPENAI_COMPATIBLE_BASE_URL`
- `OPENROUTER_API_KEY`
- `BEDROCK_AWS_REGION`
- `BEDROCK_AWS_ACCESS_KEY_ID`
- `BEDROCK_AWS_SECRET_ACCESS_KEY`

## Image behavior

The current image:

- pins `openwiki@0.3.3`
- uses `node:22.22.3-bookworm-slim`
- installs only `git` and `ca-certificates` in addition to the Node/OpenWiki runtime
- runs as non-root by default
- remaps `HOME` to a writable runtime directory when the caller UID/GID cannot write to the image default home

Override pinned build inputs if needed:

```bash
docker build \
  --build-arg NODE_IMAGE=node:22.22.3-bookworm-slim \
  --build-arg OPENWIKI_VERSION=0.3.3 \
  -t openwiki-container:local .
```

## Runtime signaling

By default:

- preflight failures are written to `stderr` and exit `1`
- OpenWiki runtime failures are written to `stderr` and preserve the OpenWiki exit code
- successful runs exit `0`

Additional signaling is available:

- if `GITHUB_ACTIONS=true`, the entrypoint emits GitHub Actions annotations
- if `OPENWIKI_STATUS_FILE` is set, the container writes a JSON status file

Example with status file output:

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/repo" \
  -w /repo \
  -e OPENWIKI_PROVIDER=anthropic \
  -e OPENWIKI_MODEL_ID=claude-sonnet \
  -e ANTHROPIC_API_KEY \
  -e OPENWIKI_STATUS_FILE=.openwiki-container-status.json \
  openwiki-container:local \
  code --update --print
```

Example status file:

```json
{
  "status": "failed",
  "stage": "preflight",
  "exit_code": 1,
  "message": "OPENWIKI_PROVIDER must be set explicitly for non-interactive container runs.",
  "command": "",
  "timestamp": "2026-08-25T12:34:56.000Z"
}
```

Possible `stage` values:

- `preflight`
- `openwiki-run`
- `container`

## CI usage

The intended CI pattern is:

1. check out the repository with full Git history
2. mount that workspace into the container at `/repo`
3. inject provider/model selection and provider credentials at runtime
4. run the container
5. inspect the resulting Git diff outside the container

Minimal GitHub Actions shape:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0

- name: Run OpenWiki
  env:
    OPENWIKI_PROVIDER: anthropic
    OPENWIKI_MODEL_ID: claude-sonnet
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
  run: |
    docker run --rm \
      --user "$(id -u):$(id -g)" \
      -v "$PWD:/repo" \
      -w /repo \
      -e OPENWIKI_PROVIDER \
      -e OPENWIKI_MODEL_ID \
      -e ANTHROPIC_API_KEY \
      openwiki-container:local \
      code --update --print
```

Set provider and model explicitly in CI for deterministic behavior.

## Testing

Smoke test:

```bash
./scripts/smoke-test.sh
```

Container behavior test suite:

```bash
./tests/run-tests.sh
```

Credentialed end-to-end OpenWiki run:

```bash
OPENWIKI_PROVIDER=openai \
OPENWIKI_MODEL_ID=gpt-4.1-mini \
OPENAI_API_KEY=... \
./tests/run-openwiki-e2e.sh
```

The E2E test is opt-in because it requires live provider credentials.

In GitHub Actions, the included workflow can run the E2E path when:

- `OPENWIKI_E2E_ENABLED=true`, or
- `workflow_dispatch` is invoked with `run_openwiki_e2e=true`

Expected CI variables/secrets for the E2E path:

- `OPENWIKI_E2E_PROVIDER`
- `OPENWIKI_E2E_MODEL_ID`
- matching provider secrets
- `GOOGLE_APPLICATION_CREDENTIALS_JSON` for Google ADC / Vertex AI file-based credentials when needed

## Troubleshooting

`OPENWIKI_PROVIDER must be set explicitly`

- set `OPENWIKI_PROVIDER` in the invoking shell or workflow env

`OPENWIKI_MODEL_ID must be set explicitly`

- set `OPENWIKI_MODEL_ID` explicitly in the invoking shell or workflow env

`mounted working directory '/repo' is not a git repository`

- mount a checked-out Git repository
- in CI, make sure checkout happened before `docker run`

`mounted working directory '/repo' is not writable`

- run with `--user "$(id -u):$(id -g)"`
- verify the mounted workspace permissions on the host runner

Provider authentication or model errors from OpenWiki

- verify the provider-specific env vars required by the pinned OpenWiki version
- verify that the selected model is valid for the chosen provider
- verify that required network access or internal gateway configuration exists

`failed to connect to the docker API`

- start the Docker daemon locally
- on CI runners, verify Docker is available to the job before running tests or the container

## Repository contents

- [Dockerfile](/Users/harshadmane/Desktop/GitHub/github-workflow-openwiki-container/Dockerfile)
- [scripts/entrypoint.sh](/Users/harshadmane/Desktop/GitHub/github-workflow-openwiki-container/scripts/entrypoint.sh)
- [scripts/smoke-test.sh](/Users/harshadmane/Desktop/GitHub/github-workflow-openwiki-container/scripts/smoke-test.sh)
- [tests/run-tests.sh](/Users/harshadmane/Desktop/GitHub/github-workflow-openwiki-container/tests/run-tests.sh)
- [tests/run-openwiki-e2e.sh](/Users/harshadmane/Desktop/GitHub/github-workflow-openwiki-container/tests/run-openwiki-e2e.sh)
- [.github/workflows/build.yml](/Users/harshadmane/Desktop/GitHub/github-workflow-openwiki-container/.github/workflows/build.yml)
