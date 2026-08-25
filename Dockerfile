# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:22.22.3-bookworm-slim
FROM ${NODE_IMAGE}

ARG OPENWIKI_VERSION=0.3.3

ENV OPENWIKI_CONTAINER_HOME=/tmp/openwiki-container-home \
    OPENWIKI_IMAGE_OPENWIKI_VERSION=${OPENWIKI_VERSION} \
    OPENWIKI_REQUIRE_EXPLICIT_SELECTION=1 \
    OPENWIKI_VALIDATE_GIT_REPO=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
    && npm install --global --no-audit --no-fund "openwiki@${OPENWIKI_VERSION}" \
    && npm cache clean --force \
    && mkdir -p /repo \
    && chown -R node:node /repo \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /repo

COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/openwiki-container-entrypoint

USER node

ENTRYPOINT ["openwiki-container-entrypoint"]
CMD ["code", "--update", "--print"]
