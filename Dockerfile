# syntax=docker/dockerfile:1.7

ARG OPENCLAW_EXTENSIONS=""
ARG OPENCLAW_VARIANT=default
ARG OPENCLAW_NODE_BOOKWORM_IMAGE="node:22-bookworm@sha256:b501c082306a4f528bc4038cbf2fbb58095d583d0419a259b2114b5ac53d12e9"
ARG OPENCLAW_NODE_BOOKWORM_DIGEST="sha256:b501c082306a4f528bc4038cbf2fbb58095d583d0419a259b2114b5ac53d12e9"
ARG OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE="node:22-bookworm-slim@sha256:9c2c405e3ff9b9afb2873232d24bb06367d649aa3e6259cbe314da59578e81e9"
ARG OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST="sha256:9c2c405e3ff9b9afb2873232d24bb06367d649aa3e6259cbe314da59578e81e9"

FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS ext-deps
ARG OPENCLAW_EXTENSIONS
COPY extensions /tmp/extensions
RUN mkdir -p /out && \
    for ext in $OPENCLAW_EXTENSIONS; do \
      if [ -f "/tmp/extensions/$ext/package.json" ]; then \
        mkdir -p "/out/$ext" && \
        cp "/tmp/extensions/$ext/package.json" "/out/$ext/package.json"; \
      fi; \
    done

FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS build

# ── Custom tools build ──────────────────────────────────────────
# Build and install Google/WhatsApp CLI tools from source:
#   - gogcli   v0.11.0 (Google Suite: Gmail, GCal, GDrive, GContacts)
#   - goplaces v0.3.0  (Google Places)
#   - wacli    v0.2.0  (WhatsApp — requires CGO + SQLite FTS5)
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      make gcc libsqlite3-dev ca-certificates curl tar && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* && \
    curl -fL https://go.dev/dl/go1.23.6.linux-amd64.tar.gz \
      | tar -xz -C /usr/local && \
    export PATH="/usr/local/go/bin:$PATH" && \
    mkdir -p /tmp/gogcli && \
    curl -fL https://github.com/steipete/gogcli/archive/refs/tags/v0.11.0.tar.gz \
      | tar -xz -C /tmp/gogcli --strip-components=1 && \
    cd /tmp/gogcli && make && \
    cp bin/gog /usr/local/bin/gog && chmod 755 /usr/local/bin/gog && \
    rm -rf /tmp/gogcli && \
    mkdir -p /tmp/goplaces && \
    curl -fL https://github.com/steipete/goplaces/archive/refs/tags/v0.3.0.tar.gz \
      | tar -xz -C /tmp/goplaces --strip-components=1 && \
    cd /tmp/goplaces && \
    /usr/local/go/bin/go build -trimpath -o /usr/local/bin/goplaces ./cmd/goplaces && \
    chmod 755 /usr/local/bin/goplaces && \
    rm -rf /tmp/goplaces && \
    mkdir -p /tmp/wacli && \
    curl -fL https://github.com/steipete/wacli/archive/refs/tags/v0.2.0.tar.gz \
      | tar -xz -C /tmp/wacli --strip-components=1 && \
    cd /tmp/wacli && \
    CGO_ENABLED=1 CGO_CFLAGS="-Wno-error=missing-braces" \
    /usr/local/go/bin/go build -tags sqlite_fts5 -trimpath -o /usr/local/bin/wacli ./cmd/wacli && \
    chmod 755 /usr/local/bin/wacli && \
    rm -rf /tmp/wacli && \
    rm -rf /usr/local/go /root/go /root/.cache/go-build && \
    apt-get purge -y make gcc && \
    apt-get autoremove -y

RUN npm install -g @steipete/summarize

RUN curl -fsSL https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv \
    && chmod 755 /usr/local/bin/uv

# ── OpenClaw build ──────────────────────────────────────────────
RUN corepack enable

WORKDIR /app

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY --from=ext-deps /out/ ./extensions/

RUN --mount=type=cache,id=openclaw-pnpm-store,target=/root/.local/share/pnpm/store,sharing=locked \
    NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile

COPY . .

RUN for dir in /app/extensions /app/.agent /app/.agents; do \
      if [ -d "$dir" ]; then \
        find "$dir" -type d -exec chmod 755 {} +; \
        find "$dir" -type f -exec chmod 644 {} +; \
      fi; \
    done

RUN pnpm canvas:a2ui:bundle || \
    (echo "A2UI bundle: creating stub (non-fatal)" && \
     mkdir -p src/canvas-host/a2ui && \
     echo "/* A2UI bundle unavailable in this build */" > src/canvas-host/a2ui/a2ui.bundle.js && \
     echo "stub" > src/canvas-host/a2ui/.bundle.hash && \
     rm -rf vendor/a2ui apps/shared/OpenClawKit/Tools/CanvasA2UI)

RUN pnpm build:docker

ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

FROM build AS runtime-assets
RUN CI=true pnpm prune --prod && \
    find dist -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' \) -delete

FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS base-default
ARG OPENCLAW_NODE_BOOKWORM_DIGEST
LABEL org.opencontainers.image.base.name="docker.io/library/node:22-bookworm" \
  org.opencontainers.image.base.digest="${OPENCLAW_NODE_BOOKWORM_DIGEST}"

FROM ${OPENCLAW_NODE_BOOKWORM_SLIM_IMAGE} AS base-slim
ARG OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST
LABEL org.opencontainers.image.base.name="docker.io/library/node:22-bookworm-slim" \
  org.opencontainers.image.base.digest="${OPENCLAW_NODE_BOOKWORM_SLIM_DIGEST}"

FROM base-${OPENCLAW_VARIANT}
ARG OPENCLAW_VARIANT

LABEL org.opencontainers.image.source="https://github.com/openclaw/openclaw" \
  org.opencontainers.image.url="https://openclaw.ai" \
  org.opencontainers.image.documentation="https://docs.openclaw.ai/install/docker" \
  org.opencontainers.image.licenses="MIT" \
  org.opencontainers.image.title="OpenClaw" \
  org.opencontainers.image.description="OpenClaw gateway and CLI runtime container image"

WORKDIR /app

RUN --mount=type=cache,id=openclaw-bookworm-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=openclaw-bookworm-apt-lists,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      procps hostname curl git openssl libsqlite3-dev

RUN chown node:node /app

# ── Copy custom binaries from build stage ───────────────────────
COPY --from=build /usr/local/bin/gog /usr/local/bin/gog
COPY --from=build /usr/local/bin/goplaces /usr/local/bin/goplaces
COPY --from=build /usr/local/bin/wacli /usr/local/bin/wacli
COPY --from=build /usr/local/bin/uv /usr/local/bin/uv
COPY --from=build /usr/local/lib/node_modules/@steipete/summarize /usr/local/lib/node_modules/@steipete/summarize

COPY --from=runtime-assets --chown=node:node /app/dist ./dist
COPY --from=runtime-assets --chown=node:node /app/node_modules ./node_modules
COPY --from=runtime-assets --chown=node:node /app/package.json .
COPY --from=runtime-assets --chown=node:node /app/openclaw.mjs .
COPY --from=runtime-assets --chown=node:node /app/extensions ./extensions
COPY --from=runtime-assets --chown=node:node /app/skills ./skills
COPY --from=runtime-assets --chown=node:node /app/docs ./docs

ENV COREPACK_HOME=/usr/local/share/corepack
RUN install -d -m 0755 "$COREPACK_HOME" && \
    corepack enable && \
    corepack prepare "$(node -p "require('./package.json').packageManager")" --activate && \
    chmod -R a+rX "$COREPACK_HOME"

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN --mount=type=cache,id=openclaw-bookworm-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=openclaw-bookworm-apt-lists,target=/var/lib/apt,sharing=locked \
    if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES; \
    fi

ARG OPENCLAW_INSTALL_BROWSER=""
RUN --mount=type=cache,id=openclaw-bookworm-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=openclaw-bookworm-apt-lists,target=/var/lib/apt,sharing=locked \
    if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
      mkdir -p /home/node/.cache/ms-playwright && \
      PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
      chown -R node:node /home/node/.cache/ms-playwright; \
    fi

ARG OPENCLAW_INSTALL_DOCKER_CLI=""
ARG OPENCLAW_DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
RUN --mount=type=cache,id=openclaw-bookworm-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=openclaw-bookworm-apt-lists,target=/var/lib/apt,sharing=locked \
    if [ -n "$OPENCLAW_INSTALL_DOCKER_CLI" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg && \
      install -m 0755 -d /etc/apt/keyrings && \
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /tmp/docker.gpg.asc && \
      expected_fingerprint="$(printf '%s' "$OPENCLAW_DOCKER_GPG_FINGERPRINT" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')" && \
      actual_fingerprint="$(gpg --batch --show-keys --with-colons /tmp/docker.gpg.asc | awk -F: '$1 == "fpr" { print toupper($10); exit }')" && \
      if [ -z "$actual_fingerprint" ] || [ "$actual_fingerprint" != "$expected_fingerprint" ]; then \
        echo "ERROR: Docker apt key fingerprint mismatch (expected $expected_fingerprint, got ${actual_fingerprint:-<empty>})" >&2; \
        exit 1; \
      fi && \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg.asc && \
      rm -f /tmp/docker.gpg.asc && \
      chmod a+r /etc/apt/keyrings/docker.gpg && \
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable\n' \
        "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/docker.list && \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        docker-ce-cli docker-compose-plugin; \
    fi

RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw \
 && chmod 755 /app/openclaw.mjs

# crea wrapper script openclaw
RUN printf '#!/bin/sh\nexec node /app/openclaw.mjs "$@"\n' > /usr/local/bin/openclaw \
    && chmod 755 /usr/local/bin/openclaw

ENV NODE_ENV=production

USER node

HEALTHCHECK --interval=3m --timeout=10s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:18789/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
