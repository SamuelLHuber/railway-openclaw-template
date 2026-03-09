# Thin wrapper around the official OpenClaw image.
# Uses pre-built multi-arch images from GHCR — no build step needed.
# To pin a version, change the tag (e.g. ghcr.io/openclaw/openclaw:2026.3.1).
# To track latest stable: ghcr.io/openclaw/openclaw:latest
ARG OPENCLAW_VERSION=2026.3.1
FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}

# Store the seed config inside the image. At runtime, CMD copies it to the
# persistent volume (if no config exists yet) so the Control UI can edit it.
USER root
RUN mkdir -p /app/seed && \
    echo '{ gateway: { port: 8080, controlUi: { dangerouslyAllowHostHeaderOriginFallback: true } } }' \
    > /app/seed/openclaw.json

# Pre-create the /data mount point so the volume has correct ownership.
# Railway mounts the volume at /data; OPENCLAW_STATE_DIR and OPENCLAW_WORKSPACE_DIR
# point inside it.
RUN mkdir -p /data && chown node:node /data

ENV OPENCLAW_STATE_DIR=/data/.openclaw
ENV OPENCLAW_WORKSPACE_DIR=/data/workspace
# Tell the CLI which port the gateway listens on (must match PORT / gateway.port).
# Without this the CLI defaults to 18789 and `devices list` etc. fail.
ENV OPENCLAW_GATEWAY_PORT=8080

# Railway injects PORT as an env var; OpenClaw needs --port at runtime.
# We override the default CMD to use Railway's PORT and bind to 0.0.0.0 (lan).
# --allow-unconfigured lets the gateway start without a pre-existing config;
# users configure API keys via Railway env vars.
#
# Startup sequence:
# 1. Fix /data ownership (Railway volumes mount as root)
# 2. Seed config into the volume if none exists yet
# 3. Drop to `node` user and start the gateway
USER root
CMD ["sh", "-c", "\
  chown node:node /data && \
  mkdir -p /data/.openclaw /data/workspace && \
  chown -R node:node /data/.openclaw /data/workspace && \
  if [ ! -f /data/.openclaw/openclaw.json ]; then \
    cp /app/seed/openclaw.json /data/.openclaw/openclaw.json && \
    chown node:node /data/.openclaw/openclaw.json; \
  fi && \
  export HOME=/home/node && \
  exec su --preserve-environment -s /bin/sh node -c \
    'exec node openclaw.mjs gateway --allow-unconfigured --bind lan --port ${PORT:-8080}'"]
