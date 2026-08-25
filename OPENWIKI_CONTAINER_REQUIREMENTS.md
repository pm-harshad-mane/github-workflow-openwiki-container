# OpenWiki Documentation Container — Starter Requirements

## 1. Purpose

Build a lightweight, reusable container that can generate and update OpenWiki documentation for arbitrary source-code repositories.

The container will be developed and maintained centrally and used from CI workflows. Application repositories may contain C, C++, Java, Go, Python, or other technologies and **must not need to install Node.js, npm, OpenWiki, or other OpenWiki-specific tooling locally**.

The goal is to keep OpenWiki-generated documentation synchronized with repository code while keeping the integration simple, secure, and low-maintenance.

---

## 2. Primary Goals

The solution must:

1. Run OpenWiki against any checked-out Git repository.
2. Require **no OpenWiki runtime dependencies in the application repository**.
3. Require **no OpenWiki tooling on developer laptops**.
4. Package the OpenWiki runtime and required dependencies inside one centrally managed container image.
5. Work with **self-hosted GitHub Enterprise / GitHub Actions runners**.
6. Support mounting the repository workspace into the container and modifying generated documentation in that workspace.
7. Keep API credentials outside the image and outside repository source code.
8. Minimize runtime and image dependencies.
9. Allow the container image to be versioned, scanned, approved, and distributed through an internal container registry.
10. Be suitable for reuse across many repositories.

---

## 3. Non-Goals

The initial version does **not** need to:

- install OpenWiki on developer machines;
- modify application build systems;
- require Node.js/npm in application repositories;
- provide a GitHub Actions runner inside the container;
- create or manage GitHub Enterprise pull requests itself unless explicitly added later;
- contain GitHub credentials;
- contain LLM API keys;
- run continuously as a service;
- provide a web UI;
- run OpenWiki on every developer commit before a PR exists.

The first version should remain a simple, short-lived CLI container.

---

## 4. Intended Architecture

```text
Developer repository
        │
        │ PR event
        ▼
Self-hosted GitHub Actions runner
        │
        │ checkout repository with full Git history
        ▼
Central OpenWiki container
        │
        │ repository mounted as /repo
        ▼
openwiki code --update --print
        │
        ▼
Generated/updated files written
into the checked-out repository
        │
        ▼
CI workflow handles git diff /
commit / push / PR behavior
```

The OpenWiki container is responsible only for generating/updating documentation.

Git operations related to creating branches, committing changes, pushing, or creating PRs should remain outside the container unless there is a strong reason to add them later.

---

## 5. Container Responsibilities

The container should:

- accept a Git repository mounted into the container;
- use `/repo` as the default working directory;
- run OpenWiki code mode against the mounted repository;
- support incremental updates using:

```bash
openwiki code --update --print
```

- write generated documentation back into the mounted repository;
- return a non-zero exit code when OpenWiki execution fails;
- print useful execution logs to stdout/stderr;
- avoid storing repository contents after the container exits;
- avoid storing credentials after the container exits.

---

## 6. Minimal Dependency Principle

The container should include only what is required to run OpenWiki reliably.

Initial expected dependencies:

- Node.js 22 runtime
- OpenWiki
- Git
- CA certificates

Optional dependencies should **not** be installed unless required.

For example, Mermaid/jsdom support should only be included if OpenWiki requires them for repositories using Mermaid diagram validation.

Avoid adding:

- GitHub CLI unless necessary;
- Python unless OpenWiki requires it;
- compilers/build toolchains;
- application-language runtimes;
- Docker CLI;
- SSH server;
- cron;
- process supervisors;
- unnecessary shell utilities.

Prefer a small supported Node base image such as a Debian slim image over a full development image.

---

## 7. Initial Dockerfile Direction

The first implementation can start from a structure similar to:

```dockerfile
FROM node:22-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install --global openwiki@<PINNED_VERSION>

WORKDIR /repo

ENTRYPOINT ["openwiki"]
```

The OpenWiki version must be explicitly pinned.

Do not use:

```dockerfile
RUN npm install --global openwiki
```

without a version.

We want reproducible container builds.

---

## 8. Container Invocation

Expected basic usage:

```bash
docker run --rm \
  -v "$PWD:/repo" \
  -w /repo \
  -e OPENWIKI_PROVIDER=<PROVIDER> \
  -e OPENWIKI_MODEL_ID=<MODEL_ID> \
  -e <PROVIDER_SPECIFIC_ENV_1> \
  -e <PROVIDER_SPECIFIC_ENV_2> \
  company-registry/openwiki:<VERSION> \
  code --update --print
```

The repository must remain outside the container and be mounted into `/repo`.

The container must not clone repositories itself in the initial version.

Repository checkout should be performed by the CI runner.

In CI, `OPENWIKI_PROVIDER` and `OPENWIKI_MODEL_ID` should be set explicitly for deterministic behavior.

The container should not define its own provider-specific credential contract. It should accept whatever provider-specific environment variables are supported by the pinned OpenWiki version and pass them through unchanged.

---

## 9. Credentials

Credentials must never be baked into the image.

Forbidden:

```dockerfile
ENV OPENAI_API_KEY=...
```

Forbidden:

- API keys in source control;
- API keys in `.env` files committed to repositories;
- credentials embedded into shell scripts;
- credentials included in image layers.

Credentials should be injected at runtime from GitHub Enterprise Actions secrets or another enterprise secret-management system.

Example:

```yaml
env:
  OPENWIKI_PROVIDER: anthropic
  OPENWIKI_MODEL_ID: claude-sonnet
  ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

and passed into the container:

```bash
docker run \
  -e OPENWIKI_PROVIDER \
  -e OPENWIKI_MODEL_ID \
  -e ANTHROPIC_API_KEY \
  ...
```

The same model applies to other OpenWiki-supported providers and credential types.

The container documentation should refer users to the upstream OpenWiki documentation for the provider-specific variables supported by the pinned OpenWiki version included in the image.

---

## 10. Corporate / Enterprise Networking

The container should be designed to work in an enterprise environment.

Potential requirements include:

- internal container registry;
- internal npm proxy such as Artifactory or Nexus;
- corporate HTTP/HTTPS proxy;
- corporate root CA certificates;
- internal LLM gateway;
- restricted outbound internet access.

Do not assume direct access to public npm or external LLM endpoints.

Where possible, these should be configurable rather than hard-coded.

---

## 11. Git History Requirement

CI must check out the repository with full Git history.

Example:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
```

This is important because incremental OpenWiki updates may need Git history to determine changes since the previously documented commit.

The container should validate that `/repo` appears to be a Git repository and fail with a useful error if it is not.

---

## 12. PR Lifecycle

The intended initial CI behavior includes both automatic PR-driven runs and manual user-triggered runs.

Automatic PR behavior is:

```text
Developer works on branch
        │
        │ no OpenWiki yet
        ▼
PR opened
        │
        ▼
OpenWiki runs
        │
Developer pushes another commit
        │
        ▼
PR synchronize event
        │
        ▼
OpenWiki runs again
        │
additional PR commits
        │
        ▼
OpenWiki runs after each update
        │
PR merged
        │
        ▼
final OpenWiki update against
the canonical/main branch
```

Recommended PR events:

```yaml
on:
  pull_request:
    types:
      - opened
      - synchronize
      - reopened
      - closed
```

Rules:

- `opened` → run OpenWiki;
- `synchronize` → run whenever new commits are pushed to the active PR branch;
- `reopened` → run OpenWiki again;
- abandoned/closed-but-not-merged PR → no final update required;
- merged PR → perform final OpenWiki update against `main`/`master`.

The workflow logic belongs outside the container.

The workflow should also support manual invocation by an authorized user whenever needed, independent of PR lifecycle events.

Recommended manual trigger:

```yaml
on:
  workflow_dispatch:
    inputs:
      ref:
        description: Git ref to document
        required: false
      openwiki_provider:
        description: OpenWiki provider
        required: false
      openwiki_model_id:
        description: OpenWiki model ID
        required: false
```

Rules for manual runs:

- a user should be able to trigger the workflow on demand even when no PR event exists;
- a manual run may target the default branch, a feature branch, or another explicit Git ref according to repository policy;
- a manual run should use the same container interface as PR-driven runs;
- provider/model selection should still be explicit for deterministic behavior;
- repository-specific policy for whether manual runs may commit changes, push branches, or only report diffs belongs in the workflow layer, not the container.

---

## 13. PR Branch Checkout

For PR updates, CI should explicitly check out the PR head commit rather than relying on GitHub's synthetic merge ref.

Example:

```yaml
- uses: actions/checkout@v4
  with:
    ref: ${{ github.event.pull_request.head.sha }}
    fetch-depth: 0
```

This allows OpenWiki to document the actual state of the developer branch.

---

## 14. Final Update After Merge

When a PR is closed, CI should determine whether it was merged.

Conceptually:

```yaml
if: >
  github.event.action == 'closed' &&
  github.event.pull_request.merged == true
```

If merged:

1. checkout the canonical branch;
2. run OpenWiki one final time;
3. persist the canonical OpenWiki documentation according to the repository's CI policy.

If the PR was simply abandoned, no final OpenWiki run is required.

---

## 15. Separation of Responsibilities

### Application Repository

Owns:

- application source code;
- OpenWiki-generated documentation;
- optional repository-specific OpenWiki configuration;
- a minimal workflow invocation if required.

Does **not** own:

- Node installation;
- npm installation;
- OpenWiki installation;
- container build;
- OpenWiki runtime maintenance.

### Central Platform / DevInfra

Owns:

- Dockerfile;
- OpenWiki version;
- Node runtime version;
- container build pipeline;
- vulnerability scanning;
- image publishing;
- enterprise CA/proxy support;
- internal npm configuration;
- shared/reusable GitHub workflow;
- credential integration.

---

## 16. GitHub Enterprise Compatibility

The environment uses self-hosted GitHub Enterprise.

The design should avoid unnecessary dependencies on third-party GitHub Marketplace actions.

In particular, the OpenWiki reference workflow uses:

```text
peter-evans/create-pull-request
```

This is a third-party GitHub Action and should **not be required by this project**.

If branch creation, commits, pushes, or PR creation are needed, prefer:

1. native `git`;
2. GitHub Enterprise REST API;
3. internally approved/mirrored Actions.

The OpenWiki container itself should remain independent of GitHub Marketplace Actions.

---

## 17. Generated Files

OpenWiki may modify files such as:

```text
openwiki/
AGENTS.md
CLAUDE.md
```

The container must not assume that all three necessarily exist before execution.

It should simply allow OpenWiki to create/update the files it manages.

The CI layer can later decide which generated files should be committed.

---

## 18. Versioning

The image should use semantic or explicit version tags.

Examples:

```text
company/openwiki:0.1.0
company/openwiki:0.2.0
company/openwiki:openwiki-0.3.3
```

Do not rely solely on:

```text
company/openwiki:latest
```

Production workflows should reference an immutable or controlled version.

Ideally publish both:

```text
company/openwiki:0.1.0
company/openwiki:<IMAGE_DIGEST>
```

---

## 19. Build Pipeline

Expected container release flow:

```text
Dockerfile change
      │
      ▼
CI build
      │
      ▼
unit/smoke tests
      │
      ▼
vulnerability scan
      │
      ▼
internal security checks
      │
      ▼
publish
      │
      ▼
internal container registry
```

The image should be built centrally rather than independently by each application repository.

---

## 20. Security Requirements

The implementation should:

- run as a non-root user where practical;
- use a minimal base image;
- pin OpenWiki version;
- avoid unnecessary packages;
- avoid embedding credentials;
- avoid storing repository data inside the image;
- avoid daemon processes;
- avoid exposing network ports;
- not run an SSH server;
- not require privileged container mode;
- not mount the Docker socket;
- support read/write access only to the mounted repository workspace as required;
- support corporate CA certificates;
- support internal npm registries;
- produce auditable versioned images.

Consider pinning the base image by digest for production releases.

---

## 21. Container User / File Permissions

Because the repository workspace is mounted from a self-hosted runner, generated files must remain writable by the runner after the container exits.

The implementation must account for UID/GID differences between:

- host runner user;
- container user.

Potential approaches:

```bash
docker run \
  --user "$(id -u):$(id -g)" \
  ...
```

or an entrypoint that safely maps permissions.

Avoid leaving generated files owned by root on the runner.

---

## 22. Configuration

Prefer environment variables for runtime configuration.

Required selectors in CI:

```text
OPENWIKI_PROVIDER
OPENWIKI_MODEL_ID
```

Provider-specific OpenWiki environment variables should pass through transparently.

Examples include:

```text
OPENAI_API_KEY
ANTHROPIC_API_KEY
GEMINI_API_KEY
OPENAI_COMPATIBLE_API_KEY
OPENAI_COMPATIBLE_BASE_URL
GOOGLE_CLOUD_PROJECT
GOOGLE_CLOUD_LOCATION
BEDROCK_AWS_REGION
BEDROCK_AWS_ACCESS_KEY_ID
BEDROCK_AWS_SECRET_ACCESS_KEY
AWS_REGION
AWS_DEFAULT_REGION
OPENROUTER_API_KEY
COPILOT_API_KEY
BASETEN_API_KEY
FIREWORKS_API_KEY
NEBIUS_API_KEY
NVIDIA_API_KEY
```

The container must not attempt to re-document, rename, normalize, or validate the full provider-specific environment-variable surface area beyond minimal container-level checks.

The supported provider-specific variables are whatever the pinned OpenWiki version supports.

Do not hard-code a particular LLM provider into the image.

The image should work with any provider supported by OpenWiki.

---

## 23. Entrypoint Behavior

Keep the entrypoint minimal.

Preferred:

```dockerfile
ENTRYPOINT ["openwiki"]
```

This enables:

```bash
docker run company/openwiki:<VERSION> code --update --print
```

Avoid a large custom shell entrypoint unless we discover configuration or permission handling that genuinely requires one.

If an entrypoint script is added, it should:

- be short;
- use `set -euo pipefail`;
- avoid hiding OpenWiki exit codes;
- contain no credentials;
- avoid repository-specific behavior.

---

## 24. Observability

The container should write logs to stdout/stderr only.

At minimum CI should be able to see:

- OpenWiki version;
- repository being processed;
- command executed;
- whether OpenWiki succeeded or failed;
- execution duration if easy to provide.

Do not log secret environment variable values.

---

## 25. Initial Testing Requirements

Create automated tests covering at least:

### Image smoke test

```bash
docker run --rm company/openwiki:<VERSION> --version
```

### Repository mount test

Mount a small fixture Git repository and verify OpenWiki can access it.

### File-write test

Verify generated/modified files are visible on the host after container exit.

### Non-root/permissions test

Verify generated files remain usable by the self-hosted runner user.

### Missing Git repository

Running against a non-Git directory should fail clearly.

### Missing credentials

Failure should be understandable and must not print secret material.

---

## 26. Suggested Repository Structure

Start with:

```text
openwiki-container/
├── Dockerfile
├── README.md
├── .dockerignore
├── scripts/
│   └── smoke-test.sh
├── tests/
│   └── fixture-repo/
└── .github/
    └── workflows/
        └── build.yml
```

Keep the initial repository intentionally small.

Do not add application frameworks or unnecessary abstractions.

---

## 27. `.dockerignore`

At minimum:

```text
.git
.github
tests
README.md
*.log
.env
.env.*
```

Adjust if test assets need to be copied during a dedicated test stage.

---

## 28. Desired Developer Experience

For an application developer, OpenWiki should effectively be invisible.

A developer working in a C/C++ repository should **not** need to know that OpenWiki uses Node.js.

Their normal workflow should remain:

```text
write code
   ↓
commit
   ↓
open PR
   ↓
continue updating PR
   ↓
merge
```

The CI/platform infrastructure handles OpenWiki automatically.

When needed, repository users should also be able to trigger an OpenWiki run manually without waiting for a PR event.

---

## 29. Desired CI Experience

Ultimately, application repositories should need no more than a small reusable-workflow invocation, or ideally an enterprise-level centrally managed trigger.

Example future integration:

```yaml
jobs:
  openwiki:
    uses: company/platform-workflows/.github/workflows/openwiki.yml@v1
```

The reusable workflow would:

1. checkout repository;
2. start the approved OpenWiki container;
3. inject secrets;
4. run OpenWiki;
5. inspect changes;
6. commit/push/create PR according to company policy.

The reusable workflow should also support manual dispatch so a user can run OpenWiki on demand against a chosen branch or ref.

For example, the reusable workflow may accept inputs such as:

1. target ref;
2. OpenWiki provider;
3. OpenWiki model ID;
4. optional mode flags such as dry-run vs persist-changes.

The reusable workflow itself is outside the scope of the initial container implementation but should influence the container interface.

---

## 30. Phase 1 Deliverables

Codex should initially implement:

1. minimal Dockerfile;
2. pinned Node base image/version;
3. pinned OpenWiki version;
4. Git + CA certificate support;
5. `/repo` working directory;
6. `openwiki` entrypoint;
7. non-root execution where feasible;
8. README with build/run examples;
9. `.dockerignore`;
10. smoke-test script;
11. test for mounted-repository writes;
12. example invocation showing runtime secret injection;
13. basic CI workflow for building/testing the container itself.

Do **not** build the full enterprise GitHub workflow yet.

Keep Phase 1 focused on producing a secure, reproducible OpenWiki execution container.

---

## 31. Acceptance Criteria

Phase 1 is complete when the following works:

```bash
git clone <some-test-repository>
cd <some-test-repository>

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$PWD:/repo" \
  -w /repo \
  -e OPENWIKI_PROVIDER \
  -e OPENWIKI_MODEL_ID \
  -e <PROVIDER_SPECIFIC_ENV_VARS> \
  company/openwiki:<VERSION> \
  code --update --print
```

and:

- OpenWiki executes successfully;
- generated documentation appears in the host repository;
- no Node/OpenWiki installation is required on the developer machine other than Docker for local testing;
- CI runners can execute the same container;
- credentials are not stored inside the image;
- files are not left owned by root;
- image dependencies remain minimal;
- CI behavior is deterministic because provider and model are selected explicitly;
- the container has no dependency on `peter-evans/create-pull-request` or other third-party GitHub Marketplace actions.

---

## 32. Design Principle

> OpenWiki is documentation infrastructure, not an application dependency.

Application teams should own their code and generated documentation.

The platform should own the runtime required to generate that documentation.
