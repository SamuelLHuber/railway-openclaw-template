# Thin wrapper around the official OpenClaw image.
# Uses pre-built multi-arch images from GHCR — no build step needed.
# To pin a version, change the tag (e.g. ghcr.io/openclaw/openclaw:2026.3.1).
# To track latest stable: ghcr.io/openclaw/openclaw:latest
ARG OPENCLAW_VERSION=2026.3.1
FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}

# Bake a minimal Railway-compatible config.
# - dangerouslyAllowHostHeaderOriginFallback: required because Railway's domain
#   is dynamic and the gateway binds to 0.0.0.0 (non-loopback).
# - Users can override this by mounting their own config or setting
#   OPENCLAW_CONFIG_PATH to a different file.
USER root
RUN mkdir -p /app/config && \
    echo '{ gateway: { controlUi: { dangerouslyAllowHostHeaderOriginFallback: true } } }' \
    > /app/config/openclaw.json && \
    chown -R node:node /app/config

# Pre-create the /data mount point so the volume has correct ownership.
# Railway mounts the volume at /data; OPENCLAW_STATE_DIR and OPENCLAW_WORKSPACE_DIR
# point inside it.
RUN mkdir -p /data && chown node:node /data
USER node

ENV OPENCLAW_CONFIG_PATH=/app/config/openclaw.json
ENV OPENCLAW_STATE_DIR=/data/.openclaw
ENV OPENCLAW_WORKSPACE_DIR=/data/workspace

# Railway injects PORT as an env var; OpenClaw needs --port at runtime.
# We override the default CMD to use Railway's PORT and bind to 0.0.0.0 (lan).
# --allow-unconfigured lets the gateway start without a pre-existing config;
# users configure API keys via Railway env vars.
CMD ["sh", "-c", "exec node openclaw.mjs gateway --allow-unconfigured --bind lan --port ${PORT:-8080}"]
