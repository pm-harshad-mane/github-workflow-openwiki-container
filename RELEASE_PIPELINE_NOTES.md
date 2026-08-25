# Release Pipeline Notes

This note captures the deferred work for release publishing, registry distribution, and vulnerability-scan pipeline setup for the OpenWiki container.

## What to add

### 1. Release versioning

- Choose a version source. Manual Git tags such as `v0.1.0` are the simplest starting point.
- Make image tags deterministic:
  - `company/openwiki:0.1.0`
  - `company/openwiki:openwiki-0.3.3`
  - `company/openwiki:sha-<gitsha>`
- Do not rely on ad hoc local tags such as `:local`, `:test`, or `:e2e`.

### 2. Registry publishing

- Add CI authentication to the internal container registry.
- Build once in CI and push immutable tags on:
  - Git tag pushes
  - optionally `main` pushes for prerelease tags such as `:main` or `:edge`
- Keep pull request workflows build-and-test only. Do not publish from pull requests.

### 3. Vulnerability scanning

- Scan the built image before publish.
- Gate release on a severity policy, for example:
  - fail on `critical`
  - fail on `high` unless explicitly waived
- Scan both OS packages and Node dependencies.
- Store scan results as CI artifacts.

### 4. SBOM and provenance

- Generate an SBOM for the image.
- Attach build provenance or attestation if required by the organization.
- This supports internal approvals and audits.

### 5. Image signing

- Sign the published image with the organization’s standard signing method.
- Verify signatures before downstream deployment or use.

### 6. Base image and dependency hardening

- Pin the base image by digest, not only by tag.
- Keep `openwiki` pinned exactly.
- Add a dependency update process:
  - scheduled PR for Node base refresh
  - scheduled PR for OpenWiki version refresh
  - rerun scans and tests on every bump

### 7. Release workflow structure

- `pull_request`: build, smoke test, container test suite, no publish
- `push main`: build, scan, optional prerelease push
- `tag v*`: build, test, scan, sign, publish
- optional manual `workflow_dispatch` for controlled republish

### 8. Release notes

Record the following for each release:

- image version
- pinned OpenWiki version
- pinned Node image digest
- notable runtime or interface changes
- known limitations

## Practical CI stages

1. Checkout
2. Compute version and tag set
3. Docker build
4. Smoke test
5. Container test suite
6. Optional credentialed E2E test
7. SBOM generation
8. Vulnerability scan
9. Sign image
10. Push to internal registry
11. Publish metadata and artifacts

## Organization decisions still needed

- Which internal registry to use
- Which scanner to use
- What severities block release
- Whether `main` publishes prereleases
- Whether the E2E test is required for release or only optional
- Which signing or attestation standard the platform team requires

## Minimal first implementation

If the goal is the smallest useful release pipeline first:

- publish only on Git tags
- push semantic tag plus Git SHA tag
- run smoke test and container test suite
- run one vulnerability scan
- fail on critical findings
- defer signing and SBOM only if the organization truly does not require them yet
