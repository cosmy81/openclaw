FROM node:22-bookworm

RUN apt-get update && apt-get install -y socat && rm -rf /var/lib/apt/lists/*

# Example binary 1: Gmail CLI
#RUN curl -L https://github.com/steipete/gogcli/archive/refs/tags/v0.11.0.tar.gz \
#  | tar -xz -C /usr/local/bin && chmod +x /usr/local/bin/gogcli

# Example binary 2: Google Places CLI
#RUN curl -L https://github.com/steipete/goplaces/releases/latest/download/goplaces_Linux_x86_64.tar.gz \
#  | tar -xz -C ./goplaces && cd goplaces && make

# Example binary 3: WhatsApp CLI
#RUN curl -L https://github.com/steipete/wacli/releases/latest/download/wacli_Linux_x86_64.tar.gz \
#  | tar -xz -C /usr/local/bin && chmod +x /usr/local/bin/wacli

#Blocco unico di installazione
# Build and install Google/WhatsApp CLI tools from source:
#   - gogcli   v0.11.0 (Google Suite: Gmail, GCal, GDrive, GContacts)
#   - goplaces v0.3.0  (Google Places)
#   - wacli    v0.2.0  (WhatsApp — requires CGO + SQLite FTS5)
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      make gcc libsqlite3-dev ca-certificates curl tar && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* && \
    \
    # Install Go 1.23 from official source (apt version is too old)
    curl -fL https://go.dev/dl/go1.23.6.linux-amd64.tar.gz \
      | tar -xz -C /usr/local && \
    export PATH="/usr/local/go/bin:$PATH" && \
    go version && \
    \
    # gogcli
    mkdir -p /tmp/gogcli && \
    curl -fL https://github.com/steipete/gogcli/archive/refs/tags/v0.11.0.tar.gz \
      | tar -xz -C /tmp/gogcli --strip-components=1 && \
    cd /tmp/gogcli && make && \
    cp bin/gog /usr/local/bin/gog && chmod 755 /usr/local/bin/gog && \
    rm -rf /tmp/gogcli && \
    \
    # goplaces
    mkdir -p /tmp/goplaces && \
    curl -fL https://github.com/steipete/goplaces/archive/refs/tags/v0.3.0.tar.gz \
      | tar -xz -C /tmp/goplaces --strip-components=1 && \
    cd /tmp/goplaces && \
    /usr/local/go/bin/go build -trimpath -o /usr/local/bin/goplaces ./cmd/goplaces && \
    chmod 755 /usr/local/bin/goplaces && \
    rm -rf /tmp/goplaces && \
    \
    # wacli (CGO + SQLite FTS5)
    mkdir -p /tmp/wacli && \
    curl -fL https://github.com/steipete/wacli/archive/refs/tags/v0.2.0.tar.gz \
      | tar -xz -C /tmp/wacli --strip-components=1 && \
    cd /tmp/wacli && \
    CGO_ENABLED=1 CGO_CFLAGS="-Wno-error=missing-braces" \
    /usr/local/go/bin/go build -tags sqlite_fts5 -trimpath -o /usr/local/bin/wacli ./cmd/wacli && \
    chmod 755 /usr/local/bin/wacli && \
    rm -rf /tmp/wacli && \
    \
    # Remove Go toolchain and build cache (~500MB saved)
    rm -rf /usr/local/go /root/go /root/.cache/go-build && \
    apt-get purge -y make gcc && \
    apt-get autoremove -y

RUN npm install -g @steipete/summarize


    # Install uv (Python package manager, required for nano-banana-pro)
RUN curl -fsSL https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv \
    && chmod 755 /usr/local/bin/uv

# Add more binaries below using the same pattern

WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY scripts ./scripts

RUN corepack enable
RUN pnpm install --frozen-lockfile

COPY . .
RUN pnpm build
RUN pnpm ui:install
RUN pnpm ui:build

ENV NODE_ENV=production

# crea l'eseguibile openclaw
RUN printf '#!/bin/sh\nexec node /app/openclaw.mjs "$@"\n' > /usr/local/bin/openclaw \
    && chmod 755 /usr/local/bin/openclaw

CMD ["node","dist/index.js"]
