# OpenWiki Container

Reusable container for running OpenWiki against a checked-out Git repository from CI or local Docker.

The image packages the OpenWiki runtime so application repositories do not need Node.js, npm, or OpenWiki installed locally.

## What it does

- runs OpenWiki code-documentation commands against a mounted repository
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
  code --init --print
```

If the run succeeds, OpenWiki writes its generated output directly into the mounted repository on the host.

For the first run on a repository that does not already have OpenWiki documentation, use `--init`.

For later incremental runs on a repository that already has OpenWiki documentation and new commits to document, use `--update`.

If an `init` run does not include a freeform instruction message, the container injects a built-in bootstrap prompt that tells OpenWiki to produce comprehensive, source-grounded repository documentation rather than stopping at a bare plan or next-step suggestion.

Observed behavior in a real repository:

- `code --init --print` created `openwiki/_skeleton.md` and recorded the documented Git head
- a later `code --update --print` on the same unchanged commit reported that the wiki was already current

So `--init` should currently be treated as wiki bootstrap, and `--update` should be treated as incremental maintenance after new commits.

If you want richer initial content rather than only a skeleton, try providing an explicit instruction message on the init run:

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/repo" \
  -w /repo \
  -e OPENWIKI_PROVIDER \
  -e OPENWIKI_MODEL_ID \
  -e OPENAI_API_KEY \
  openwiki-container:local \
  code --init --print "Expand the OpenWiki skeleton into full documentation pages for this repository."
```

If you want to change the container-owned default bootstrap instruction without passing a positional prompt each time, set `OPENWIKI_INIT_MESSAGE`.

The built-in image default is defined in [scripts/entrypoint.sh](scripts/entrypoint.sh) as the multiline `DEFAULT_INIT_MESSAGE` block.

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

Optional container-owned selector:

- `OPENWIKI_RUN_MODE=auto|init|update`
- `OPENWIKI_INIT_MESSAGE=<custom bootstrap instruction>`

Mode behavior:

- `auto` chooses `init` when no OpenWiki state is present
- `auto` chooses `update` when `openwiki/.last-update.json` exists
- `auto` also treats `openwiki/_skeleton.md` as initialized state and chooses `update`
- `init` forces bootstrap mode
- `update` forces incremental-update mode
- when the resolved mode is `init` and no freeform instruction message was supplied, the container appends a built-in detailed documentation brief

Prompt customization guidance:

- for normal usage, override the bootstrap prompt with `OPENWIKI_INIT_MESSAGE`
- if you maintain this container and want to change the image-wide default, edit the multiline `DEFAULT_INIT_MESSAGE` block in [scripts/entrypoint.sh](scripts/entrypoint.sh)

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
4. run the container with:
   - `OPENWIKI_RUN_MODE=auto` for normal automation
   - `OPENWIKI_RUN_MODE=init` only when forcing bootstrap
   - `OPENWIKI_RUN_MODE=update` only when forcing an incremental run
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
    OPENWIKI_RUN_MODE: auto
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
  run: |
    docker run --rm \
      --user "$(id -u):$(id -g)" \
      -v "$PWD:/repo" \
      -w /repo \
      -e OPENWIKI_PROVIDER \
      -e OPENWIKI_MODEL_ID \
      -e OPENWIKI_RUN_MODE \
      -e ANTHROPIC_API_KEY \
      openwiki-container:local \
      code --print
```

Set provider and model explicitly in CI for deterministic behavior.

For automated CI usage, prefer `OPENWIKI_RUN_MODE=auto` and a neutral command such as `code --print`. The container will choose `--init` or `--update` based on repository state.

If you want deterministic bootstrap guidance in CI across many repositories, set `OPENWIKI_INIT_MESSAGE` in the workflow env.

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

`code --update --print` did not create `openwiki/`

- use `code --init --print` for the first run on a repository that does not already have OpenWiki documentation
- use `code --update --print` only after the initial wiki has been created and new commits exist to document
- or set `OPENWIKI_RUN_MODE=auto` and let the container choose based on repository state

`code --init --print` created only `openwiki/_skeleton.md`

- this is a valid observed OpenWiki bootstrap behavior
- the container now injects a built-in detailed bootstrap instruction when no init message is supplied
- try rerunning init with an explicit instruction message, or set `OPENWIKI_INIT_MESSAGE`, if you want a different first-pass documentation emphasis
- otherwise commit the scaffold and use `code --update --print` after future repository changes

`unable to auto-select OpenWiki mode`

- this means `openwiki/` exists but the repository does not contain the expected OpenWiki state files
- set `OPENWIKI_RUN_MODE=init` or `OPENWIKI_RUN_MODE=update` explicitly for that run

`failed to connect to the docker API`

- start the Docker daemon locally
- on CI runners, verify Docker is available to the job before running tests or the container

## Repository contents

- [Dockerfile](Dockerfile)
- [scripts/entrypoint.sh](scripts/entrypoint.sh)
- [scripts/smoke-test.sh](scripts/smoke-test.sh)
- [tests/run-tests.sh](tests/run-tests.sh)
- [tests/run-openwiki-e2e.sh](tests/run-openwiki-e2e.sh)
- [.github/workflows/build.yml](.github/workflows/build.yml)
