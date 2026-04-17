# Thin wrapper around the official OpenClaw image.
# Uses pre-built multi-arch images from GHCR — no build step needed.
# To pin a version, change the tag (e.g. ghcr.io/openclaw/openclaw:2026.3.1).
# To track latest stable: ghcr.io/openclaw/openclaw:latest
ARG OPENCLAW_VERSION=2026.4.15
FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}

# Base image runs as `node` — switch to root for all build steps.
USER root

# Install Homebrew (Linuxbrew) — useful for installing additional tools via
# `brew install` when SSH'd into the container (e.g. jq, ripgrep, fzf).
# We install as the `node` user and symlink to /usr/local/bin so brew is on PATH
# for both root and node.
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential procps file && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /home/linuxbrew/.linuxbrew && \
    chown -R node:node /home/linuxbrew && \
    su - node -c 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' && \
    ln -sf /home/linuxbrew/.linuxbrew/bin/brew /usr/local/bin/brew
ENV HOMEBREW_NO_AUTO_UPDATE=1

# Pre-create the /data mount point so the volume has correct ownership.
# Railway mounts the volume at /data; OPENCLAW_STATE_DIR and OPENCLAW_WORKSPACE_DIR
# point inside it.
RUN mkdir -p /data && chown node:node /data

ENV OPENCLAW_STATE_DIR=/data/.openclaw
ENV OPENCLAW_WORKSPACE_DIR=/data/workspace
ENV HOME=/data
# Tell the CLI which port the gateway listens on (must match PORT / gateway.port).
# Without this the CLI defaults to 18789 and `devices list` etc. fail.
ENV OPENCLAW_GATEWAY_PORT=8080

# Railway injects PORT as an env var; OpenClaw needs --port at runtime.
# We override the default CMD to use Railway's PORT and bind to 0.0.0.0 (lan).
# --allow-unconfigured lets the gateway start without a pre-existing config;
# users configure API keys via Railway env vars.
#
# Startup sequence:
# 1. Ensure /data subdirs exist
# 2. Seed config into the volume if none exists yet
#    - require password auth for the public Control UI / gateway
#    - explicitly allow the configured HTTPS origin
# 3. Start the gateway (runs as root — isolated Railway container)
CMD ["sh", "-c", "\
  export HOME=/data && \
  mkdir -p /data/.openclaw /data/workspace && \
  if [ ! -f /data/.openclaw/openclaw.json ]; then \
    : \"${OPENCLAW_GATEWAY_PASSWORD:?Set OPENCLAW_GATEWAY_PASSWORD}\" && \
    : \"${OPENCLAW_ALLOWED_ORIGIN:?Set OPENCLAW_ALLOWED_ORIGIN (for example https://your-app.up.railway.app)}\" && \
    printf '%s\n' \
      '{' \
      '  agents: { defaults: { model: { primary: "openai/gpt-5.4" } } },' \
      '  gateway: {' \
      '    port: 8080,' \
      '    auth: { mode: "password", password: "'"${OPENCLAW_GATEWAY_PASSWORD}"'" },' \
      '    controlUi: { allowedOrigins: ["'"${OPENCLAW_ALLOWED_ORIGIN}"'"] }' \
      '  }' \
      '}' \
      > /data/.openclaw/openclaw.json; \
  fi && \
  exec node openclaw.mjs gateway --allow-unconfigured --bind lan --port ${PORT:-8080}"]
