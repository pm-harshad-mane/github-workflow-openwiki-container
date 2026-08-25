# Using This Container In Another Repository

This guide is for a repository that wants to generate and maintain `openwiki/` documentation by running this container from GitHub Actions.

## Runtime model

The intended deployment model is ephemeral:

- GitHub Actions starts a fresh runner for the workflow job.
- The runner executes `docker run --rm ...` for the OpenWiki container.
- The container writes documentation changes into the checked-out repository workspace.
- The container exits when the OpenWiki run is finished.
- The `--rm` flag removes the container immediately after it exits.
- On GitHub-hosted runners, the runner VM is also discarded after the job completes.

So yes: GitHub instantiates the container only for the run, and the instance goes away after the work is done.

## What the container expects

The container expects:

- a checked-out Git repository mounted at `/repo`
- explicit provider selection through `OPENWIKI_PROVIDER`
- explicit model selection through `OPENWIKI_MODEL_ID`
- provider-specific credentials for the chosen provider

Useful container variables:

- `OPENWIKI_RUN_MODE=auto|init|update`
- `OPENWIKI_INIT_MESSAGE=<custom bootstrap instruction>`
- `OPENWIKI_STATUS_FILE=<path>` for machine-readable success/failure output

Recommended default for automation:

- `OPENWIKI_RUN_MODE=auto`
- invoke the container with `code --print`

That lets the wrapper decide whether the repository needs an initial `--init` run or an incremental `--update` run.

## What gets written

A successful run can create or update:

- `openwiki/`
- `AGENTS.md`
- `CLAUDE.md`

If you do not want `AGENTS.md` and `CLAUDE.md` committed in the target repository, add them to that repository's `.gitignore`.

## One-time setup in the target repository

### 1. Decide how the image will be referenced

Use one of these patterns:

1. A published image, for example `ghcr.io/<owner>/<image>:<tag>`
2. A locally built image while validating the setup

Replace the image reference in the examples below with your real published image once registry publishing is in place.

### 2. Add provider configuration

At minimum, configure:

- one repository or organization variable for `OPENWIKI_PROVIDER`
- one repository or organization variable for `OPENWIKI_MODEL_ID`
- one secret for the provider credential

Example for OpenAI:

- Repository variable: `OPENWIKI_PROVIDER=openai`
- Repository variable: `OPENWIKI_MODEL_ID=gpt-4.1-mini`
- Repository secret: `OPENAI_API_KEY=<your key>`

Examples for other providers:

- Anthropic: `ANTHROPIC_API_KEY`
- Gemini: `GEMINI_API_KEY`
- OpenRouter: `OPENROUTER_API_KEY`
- OpenAI-compatible gateway: `OPENAI_COMPATIBLE_API_KEY` and usually `OPENAI_COMPATIBLE_BASE_URL`
- Bedrock: `BEDROCK_AWS_REGION`, `BEDROCK_AWS_ACCESS_KEY_ID`, `BEDROCK_AWS_SECRET_ACCESS_KEY`

Use the OpenWiki documentation for the pinned OpenWiki version in the image to decide the correct variables for your provider.

### 3. Optionally define a repo-specific bootstrap brief

If you want the initial wiki generation to follow repository-specific priorities, set:

- repository variable `OPENWIKI_INIT_MESSAGE`, or
- commit `openwiki/INSTRUCTIONS.md` after the first run and let OpenWiki use that as the repository-specific brief

Recommended split:

- `OPENWIKI_INIT_MESSAGE` for organization-wide bootstrap defaults
- `openwiki/INSTRUCTIONS.md` for repo-specific scope and priorities

## Recommended GitHub Actions workflow

Create `.github/workflows/openwiki.yml` in the target repository:

```yaml
name: OpenWiki

on:
  workflow_dispatch:
    inputs:
      run_mode:
        description: "auto, init, or update"
        required: false
        default: "auto"
      init_message:
        description: "Optional bootstrap message override for init runs"
        required: false
        default: ""

jobs:
  openwiki:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    env:
      OPENWIKI_PROVIDER: ${{ vars.OPENWIKI_PROVIDER }}
      OPENWIKI_MODEL_ID: ${{ vars.OPENWIKI_MODEL_ID }}
      OPENWIKI_RUN_MODE: ${{ github.event.inputs.run_mode || 'auto' }}
      OPENWIKI_INIT_MESSAGE: ${{ github.event.inputs.init_message }}
      OPENWIKI_STATUS_FILE: .openwiki-container-status.json
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}
      OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
      OPENAI_COMPATIBLE_API_KEY: ${{ secrets.OPENAI_COMPATIBLE_API_KEY }}
      OPENAI_COMPATIBLE_BASE_URL: ${{ secrets.OPENAI_COMPATIBLE_BASE_URL }}
      BEDROCK_AWS_REGION: ${{ vars.BEDROCK_AWS_REGION }}
      BEDROCK_AWS_ACCESS_KEY_ID: ${{ secrets.BEDROCK_AWS_ACCESS_KEY_ID }}
      BEDROCK_AWS_SECRET_ACCESS_KEY: ${{ secrets.BEDROCK_AWS_SECRET_ACCESS_KEY }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run OpenWiki container
        run: |
          docker run --rm \
            --user "$(id -u):$(id -g)" \
            -v "$PWD:/repo" \
            -w /repo \
            -e GITHUB_ACTIONS=true \
            -e OPENWIKI_PROVIDER \
            -e OPENWIKI_MODEL_ID \
            -e OPENWIKI_RUN_MODE \
            -e OPENWIKI_INIT_MESSAGE \
            -e OPENWIKI_STATUS_FILE \
            -e OPENAI_API_KEY \
            -e ANTHROPIC_API_KEY \
            -e GEMINI_API_KEY \
            -e OPENROUTER_API_KEY \
            -e OPENAI_COMPATIBLE_API_KEY \
            -e OPENAI_COMPATIBLE_BASE_URL \
            -e BEDROCK_AWS_REGION \
            -e BEDROCK_AWS_ACCESS_KEY_ID \
            -e BEDROCK_AWS_SECRET_ACCESS_KEY \
            ghcr.io/<owner>/<image>:<tag> \
            code --print

      - name: Show generated changes
        run: git status --short

      - name: Upload status file
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: openwiki-status
          path: .openwiki-container-status.json
          if-no-files-found: ignore
```

This workflow does not commit anything by itself. It only runs the container and leaves the changed files in the Actions workspace.

## If you want the workflow to open a PR

Add a follow-up step after the container run.

Example:

```yaml
      - name: Create pull request
        uses: peter-evans/create-pull-request@v7
        with:
          commit-message: "Update OpenWiki documentation"
          title: "Update OpenWiki documentation"
          body: |
            Automated OpenWiki documentation refresh.
          branch: openwiki/update-docs
          delete-branch: true
```

That is the cleanest pattern when you want human review before merging documentation changes.

## If you want the workflow to commit directly to the branch

That is also possible, but less safe. If you choose to do it, add explicit git commit/push steps after the container run and only do it in branches where direct pushes are acceptable.

## Manual run behavior

With the `workflow_dispatch` example above, a user can trigger the workflow whenever they want from the GitHub Actions UI.

Recommended usage:

- `run_mode=auto` for normal use
- `run_mode=init` only when intentionally bootstrapping or rebuilding the wiki
- `run_mode=update` only when you know the repo already has valid OpenWiki state

If the user leaves `init_message` empty and the run resolves to `init`, the container uses its built-in `DEFAULT_INIT_MESSAGE`.

## First-run recommendation

For the first run in a new repository:

1. Use `workflow_dispatch`
2. Set `run_mode=init` or leave it as `auto`
3. Optionally provide a repo-specific `init_message`
4. Review the generated `openwiki/`, `AGENTS.md`, and `CLAUDE.md`
5. Commit only what you want to keep

If you want `AGENTS.md` and `CLAUDE.md` excluded, add them to `.gitignore` before committing.

## Failure handling

The container already provides stronger runtime signaling:

- non-zero exit code on failure
- GitHub Actions error annotations when `GITHUB_ACTIONS=true`
- optional JSON status file through `OPENWIKI_STATUS_FILE`

Recommended setting:

- `OPENWIKI_STATUS_FILE=.openwiki-container-status.json`

Example failure payload:

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

This is useful if you want later workflow steps to inspect or upload the result.

## Local validation before wiring GitHub Actions

You can test against a local repository first:

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "/absolute/path/to/your-repo:/repo" \
  -w /repo \
  -e OPENWIKI_PROVIDER \
  -e OPENWIKI_MODEL_ID \
  -e OPENAI_API_KEY \
  -e OPENWIKI_RUN_MODE=auto \
  -e OPENWIKI_STATUS_FILE=.openwiki-container-status.json \
  openwiki-container:local \
  code --print
```

For a guaranteed first bootstrap run, use:

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "/absolute/path/to/your-repo:/repo" \
  -w /repo \
  -e OPENWIKI_PROVIDER \
  -e OPENWIKI_MODEL_ID \
  -e OPENAI_API_KEY \
  -e OPENWIKI_RUN_MODE=init \
  openwiki-container:local \
  code --print
```

## Recommended repository policy

For most target repositories:

- commit `openwiki/`
- decide deliberately whether to commit `AGENTS.md`
- decide deliberately whether to commit `CLAUDE.md`
- keep `OPENWIKI_PROVIDER` and `OPENWIKI_MODEL_ID` as repository or organization variables
- keep provider credentials as secrets
- use `workflow_dispatch` for on-demand runs
- use PR creation rather than direct push for generated documentation changes

## Summary

The normal downstream setup is:

1. publish this image to a registry
2. add provider variables and secrets in the target repository
3. add a GitHub Actions workflow that checks out the repo and runs `docker run --rm`
4. trigger it manually with `workflow_dispatch` or extend it later with schedule/PR events
5. review and commit the generated documentation changes

That gives you an ephemeral, on-demand OpenWiki documentation job with no persistent container runtime to manage.
