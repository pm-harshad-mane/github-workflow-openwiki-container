#!/usr/bin/env bash

set -euo pipefail

readonly image_tag="${IMAGE_TAG:-openwiki-container:local}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  docker build --tag "${image_tag}" .
fi

docker run --rm "${image_tag}" --version
