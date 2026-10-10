# syntax=docker/dockerfile:1
#
# Lucairn tool runner image (Preview — UNRELEASED: no image is published yet).
#
# The runner source is not vendored in this kit. The image is built from a
# source tarball of one runner commit, pinned by its sha256:
#
#   git -C <runner checkout> archive --format=tar.gz \
#       --prefix=lucairn-tool-runner/ -o runner-src.tar.gz <commit>
#   shasum -a 256 runner-src.tar.gz
#   docker build -f apps/tool-runner/Dockerfile \
#       --build-arg RUNNER_TARBALL=runner-src.tar.gz \
#       --build-arg RUNNER_SHA256=<sha256 of the tarball> \
#       -t lucairn-tool-runner:0.1.0 .
#
# Run it from the kit root: the build context must hold the tarball (its path
# relative to the kit root is RUNNER_TARBALL) and apps/tool-runner/entrypoint.mjs.
# RUNNER_CODE_DIGEST is optional: when given, the build fails unless the
# unpacked runner has exactly that code digest (`lucairn-tool-runner digest`).
#
# Node 22 LTS, 22.13 or newer (the runner's receipt store is node:sqlite).
ARG NODE_IMAGE=node:22-alpine

FROM ${NODE_IMAGE} AS build
ARG RUNNER_TARBALL=runner-src.tar.gz
ARG RUNNER_SHA256
ARG RUNNER_CODE_DIGEST=""
WORKDIR /build
COPY ${RUNNER_TARBALL} /build/runner-src.tar.gz
COPY apps/tool-runner/entrypoint.mjs /opt/lucairn-kit/entrypoint.mjs
RUN set -eu; \
    node -e 'const [a,b]=process.versions.node.split(".").map(Number); if (a!==22||b<13) { console.error("Node 22.13+ (22.x LTS) is required, found "+process.versions.node); process.exit(1); }'; \
    test -n "${RUNNER_SHA256}" || { echo "RUNNER_SHA256 build arg is required (sha256 of the runner source tarball)" >&2; exit 1; }; \
    echo "${RUNNER_SHA256}  /build/runner-src.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/lucairn-tool-runner; \
    tar -xzf /build/runner-src.tar.gz -C /opt/lucairn-tool-runner --strip-components=1 --no-same-owner; \
    cd /opt/lucairn-tool-runner; \
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund; \
    # Keep only what the runner executes: no tests, proofs, evidence or fixtures in the image.
    rm -rf test proof evidence fixtures docs .gitignore; \
    node /opt/lucairn-kit/entrypoint.mjs --print-code-digest /opt/lucairn-tool-runner > /opt/lucairn-kit/runner-code-digest; \
    test "$(node bin/lucairn-tool-runner.mjs digest)" = "$(cat /opt/lucairn-kit/runner-code-digest)" || { echo "code digest: the kit entrypoint and the runner disagree" >&2; exit 1; }; \
    if [ -n "${RUNNER_CODE_DIGEST}" ]; then test "${RUNNER_CODE_DIGEST}" = "$(cat /opt/lucairn-kit/runner-code-digest)" || { echo "code digest: not the expected RUNNER_CODE_DIGEST" >&2; exit 1; }; fi; \
    chmod -R a-w,a+rX /opt/lucairn-tool-runner /opt/lucairn-kit

FROM ${NODE_IMAGE}
LABEL org.opencontainers.image.title="lucairn-tool-runner" \
      org.opencontainers.image.description="Lucairn tool runner (Preview): policy-governed ServiceNow access for AI agents over MCP" \
      org.opencontainers.image.vendor="Lucairn"
COPY --from=build --chown=0:0 /opt/lucairn-tool-runner /opt/lucairn-tool-runner
COPY --from=build --chown=0:0 /opt/lucairn-kit /opt/lucairn-kit
RUN printf '#!/bin/sh\nexec node /opt/lucairn-tool-runner/bin/lucairn-tool-runner.mjs "$@"\n' > /usr/local/bin/lucairn-tool-runner \
    && chmod 0555 /usr/local/bin/lucairn-tool-runner \
    && mkdir -p /var/lib/lucairn-tool-runner /run/tool-runner /etc/lucairn-tool-runner \
    && chown 10001:10001 /var/lib/lucairn-tool-runner /run/tool-runner \
    && chmod 0700 /var/lib/lucairn-tool-runner /run/tool-runner
ENV NODE_ENV=production
USER 10001:10001
WORKDIR /var/lib/lucairn-tool-runner
VOLUME ["/var/lib/lucairn-tool-runner"]
# No EXPOSE: the MCP endpoint is a unix socket (/run/tool-runner/mcp.sock), not a network port.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
  CMD ["node", "/opt/lucairn-kit/entrypoint.mjs", "--healthcheck"]
ENTRYPOINT ["node", "/opt/lucairn-kit/entrypoint.mjs"]
