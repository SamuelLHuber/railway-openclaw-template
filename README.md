# OpenClaw on Railway

Deploy [OpenClaw](https://github.com/openclaw/openclaw) to [Railway](https://railway.com) in one click — fast, using the official pre-built Docker image.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template?template=https://github.com/SamuelLHuber/railway-openclaw-template)

---

## Table of contents

- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [Step-by-step setup](#step-by-step-setup)
- [Post-deploy: configure via Control UI](#post-deploy-configure-via-control-ui)
- [Adding model providers](#adding-model-providers)
- [Adding channels](#adding-channels)
- [Persistent storage](#persistent-storage)
- [Upgrading OpenClaw](#upgrading-openclaw)
- [Environment variable reference](#environment-variable-reference)
- [Health checks](#health-checks)
- [Troubleshooting](#troubleshooting)
- [vs codetitlan/openclaw-railway-template](#vs-codetitlanopenclaw-railway-template)
- [Upstream documentation](#upstream-documentation)

---

## How it works

This repo is a **thin wrapper** around the official OpenClaw Docker image. There is no source build — Railway pulls the pre-built image, so deploys take **seconds, not minutes**.

```
┌──────────────────────────────────┐
│  This repo                       │
│  ├─ Dockerfile (5 lines)         │  FROM ghcr.io/openclaw/openclaw
│  ├─ railway.toml                 │  health check + restart policy
│  └─ env vars (Railway dashboard) │  API keys, tokens
└───────────┬──────────────────────┘
            │ docker pull (~30s)
            ▼
┌──────────────────────────────────┐
│  ghcr.io/openclaw/openclaw       │  Official multi-arch image
│  Published on every release      │  by upstream CI
└──────────────────────────────────┘
```

The Dockerfile does two things:

1. `FROM ghcr.io/openclaw/openclaw:<version>` — pulls the official image
2. Overrides `CMD` to bind to `0.0.0.0` (required for Railway networking) and use Railway's injected `$PORT`

---

## Quick start

1. Fork this repo → connect it to a new Railway service
2. Add a **volume** mounted at `/data` (Railway → service → Settings → Volumes)
3. Set `OPENCLAW_GATEWAY_TOKEN` env var + configure at least one model provider (API key or [Codex OAuth](#option-2-openai-codex-subscription-oauth))
4. Add a public domain in Railway settings
5. Open `https://<your-domain>/overview` → enter your gateway token → click **Connect** → approve device pairing with `railway ssh`

---

## Step-by-step setup

### 1. Create a Railway project

1. Go to [railway.com](https://railway.com) and create a new project
2. Choose **Deploy from GitHub repo** and select your fork of this repo
3. Railway detects the `Dockerfile` and starts building

### 2. Set environment variables

In your Railway service, go to **Variables** and add:

| Variable | Required | Description |
|---|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | ✅ | Auth token for the gateway API. Generate: `openssl rand -hex 32` |
| `PORT` | Recommended | Port the gateway listens on. Default: `8080`. Railway auto-detects this. |
| At least one provider key | See [providers](#adding-model-providers) | Without a provider key the gateway starts but can't answer messages. |

> **Note:** `OPENCLAW_STATE_DIR` and `OPENCLAW_WORKSPACE_DIR` are baked into the Dockerfile pointing at `/data/.openclaw` and `/data/workspace`. You don't need to set them manually — just add a volume at `/data`.

### 3. Add a volume

In **Settings → Volumes**:

- Click **Add Volume**
- Set the mount path to `/data`

This is **required** — without it, all config, sessions, and credentials are lost on every redeploy. The `railway.toml` enforces this via `requiredMountPath`.

### 4. Configure networking

In **Settings → Networking**:

- **Generate a domain** (e.g. `myclaw.up.railway.app`) or attach a custom domain
- Railway automatically handles HTTPS termination

### 5. Deploy

Push to your repo (or click **Deploy** in Railway). The first deploy pulls the Docker image and starts the gateway. Subsequent deploys are near-instant.

### 6. Open the Control UI

Visit `https://<your-railway-domain>/overview` in your browser.

1. Enter your `OPENCLAW_GATEWAY_TOKEN` and click **Connect**
2. On first connect you'll see `disconnected (1008): pairing required` — this is normal. Approve the device using `railway ssh`:
   ```bash
   railway ssh
   node openclaw.mjs devices list
   node openclaw.mjs devices approve <requestId>
   ```

---

## Post-deploy: configure via Control UI

Once the gateway is running, open `https://<your-domain>/` to access the **Control UI** — a browser-based dashboard for managing OpenClaw.

From the Control UI you can:

- Chat directly with your AI (WebChat)
- Configure models, channels, tools, and agents
- View sessions and conversation history

### Editing the config

There are two ways to change the OpenClaw configuration:

**Option A: Control UI (Config tab)** — open the Config tab in the Control UI to view and edit `openclaw.json` directly in the browser. Changes are validated and saved to the persistent volume.

**Option B: CLI via `railway ssh`** — use `config set` to change individual values:

```bash
railway ssh
node openclaw.mjs config set <path> <value>
```

Examples:

```bash
# Set the primary model
node openclaw.mjs config set agents.defaults.model.primary "openai-codex/gpt-5.4"

# Enable a channel
node openclaw.mjs config set channels.whatsapp.dmPolicy pairing

# View a config value
node openclaw.mjs config get agents.defaults.model
```

> **Note:** Some config changes (especially adding new channels) require a gateway restart to take effect. Redeploy from the Railway dashboard or run `railway up`. Model and agent config changes typically hot-reload without a restart.

### Device pairing

When you connect from a new browser, you'll see: `disconnected (1008): pairing required`.

This is a security measure. To approve the device, use `railway ssh`:

```bash
railway ssh
node openclaw.mjs devices list
node openclaw.mjs devices approve <requestId>
```

---

## Adding model providers

There are two ways to authenticate with model providers: **API keys** (usage-based billing) or **subscription OAuth** (e.g. ChatGPT/Codex subscription).

### Option 1: API keys (usage-based billing)

Set one or more provider API keys as Railway environment variables. OpenClaw auto-detects available providers.

| Provider | Env variable | Get a key |
|---|---|---|
| Anthropic | `ANTHROPIC_API_KEY` | [console.anthropic.com](https://console.anthropic.com/) |
| OpenAI | `OPENAI_API_KEY` | [platform.openai.com](https://platform.openai.com/) |
| Google Gemini | `GEMINI_API_KEY` | [aistudio.google.com](https://aistudio.google.com/) |
| OpenRouter | `OPENROUTER_API_KEY` | [openrouter.ai](https://openrouter.ai/) |
| Mistral | `MISTRAL_API_KEY` | [console.mistral.ai](https://console.mistral.ai/) |

Additional providers (Bedrock, Ollama, vLLM, Together, etc.) are supported — see the [upstream providers docs](https://docs.openclaw.ai/providers).

### Option 2: OpenAI Codex subscription (OAuth)

If you have a ChatGPT/Codex subscription, you can use OAuth instead of an API key. Run the login flow via `railway ssh`:

```bash
railway ssh
node openclaw.mjs models auth login --provider openai-codex
```

Or use the onboarding wizard:

```bash
node openclaw.mjs onboard --auth-choice openai-codex
```

Then set the model in config:

```json5
{
  agents: {
    defaults: {
      model: { primary: "openai-codex/gpt-5.4" },
    },
  },
}
```

> **Note:** Codex cloud requires ChatGPT sign-in, while the Codex CLI supports ChatGPT or API key sign-in. OpenClaw maps `openai-codex/gpt-5.4` for ChatGPT/Codex OAuth usage.

### Model configuration

You can configure models via the Control UI (Config tab), CLI, or `openclaw.json`. Set the model to match the provider you've configured:

```json5
// Codex subscription example
{
  agents: { defaults: { model: { primary: "openai-codex/gpt-5.4" } } },
}

// API key example (set OPENAI_API_KEY env var)
{
  agents: { defaults: { model: { primary: "openai/gpt-5.2" } } },
}

// Anthropic example (set ANTHROPIC_API_KEY env var)
{
  agents: { defaults: { model: { primary: "anthropic/claude-sonnet-4-5" } } },
}
```

> **Important:** Only set models for providers you've actually configured (API key or OAuth). If you set a fallback model without the matching provider credentials, the gateway will error when the primary is unavailable.
```

---

## Adding channels

Channels let OpenClaw send and receive messages on Telegram, Discord, Slack, WhatsApp, and [many more](https://docs.openclaw.ai/channels).

### Telegram

1. Message [@BotFather](https://t.me/BotFather) on Telegram → `/newbot`
2. Copy the bot token (e.g. `123456789:AA...`)
3. Add `TELEGRAM_BOT_TOKEN` as a Railway env var, **or** configure it in the Control UI

Docs: [docs.openclaw.ai/channels/telegram](https://docs.openclaw.ai/channels/telegram)

### Discord

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications) → **New Application**
2. **Bot** → **Add Bot** → **enable MESSAGE CONTENT INTENT** (under Privileged Gateway Intents)
3. Copy the bot token
4. Add `DISCORD_BOT_TOKEN` as a Railway env var
5. Invite the bot to your server (OAuth2 URL Generator; scopes: `bot`, `applications.commands`)

Docs: [docs.openclaw.ai/channels/discord](https://docs.openclaw.ai/channels/discord)

### Slack

1. Create a Slack app at [api.slack.com/apps](https://api.slack.com/apps)
2. Enable Socket Mode → copy the **App-Level Token** (`xapp-...`)
3. Add bot scopes and install to your workspace → copy the **Bot Token** (`xoxb-...`)
4. Set `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN` as Railway env vars

Docs: [docs.openclaw.ai/channels/slack](https://docs.openclaw.ai/channels/slack)

### WhatsApp

WhatsApp requires configuration _and_ a QR code login via CLI — the Control UI's "Link" button won't work in headless environments.

**Step 1: Add WhatsApp config** — either edit the config in the Control UI (Config tab) or via `railway ssh`:

```bash
railway ssh
node openclaw.mjs config set channels.whatsapp.dmPolicy pairing
```

Minimal config block (add via Control UI → Config tab):

```json5
{
  channels: {
    whatsapp: {
      dmPolicy: "pairing",        // or "allowlist"
      allowFrom: ["+15551234567"], // your phone number
    },
  },
}
```

**Step 2: Restart the gateway** so it picks up the new channel config. Redeploy from the Railway dashboard or run `railway up`.

**Step 3: Link WhatsApp** via `railway ssh`:

```bash
railway ssh
node openclaw.mjs channels login --channel whatsapp
```

Scan the QR code with your phone (WhatsApp → Linked Devices → Link a Device).

> **Note:** WhatsApp credentials are stored on the persistent volume at `/data/.openclaw/credentials/whatsapp/`. They survive redeploys but you'll need to re-link if you delete the volume.

Docs: [docs.openclaw.ai/channels/whatsapp](https://docs.openclaw.ai/channels/whatsapp)

### All channels

Signal, iMessage, Matrix, Mattermost, MS Teams, Google Chat, IRC, Line, Nostr, Twitch, Zalo, and more — see the [full channels list](https://docs.openclaw.ai/channels).

---

## Persistent storage

The Dockerfile bakes in `OPENCLAW_STATE_DIR=/data/.openclaw` and `OPENCLAW_WORKSPACE_DIR=/data/workspace`. The `railway.toml` sets `requiredMountPath = "/data"` so Railway prompts you to add a volume.

If you haven't added a volume yet:

1. In Railway, go to your service → **Settings → Volumes**
2. Click **Add Volume**
3. Set the mount path to `/data`

This preserves:

- `openclaw.json` configuration
- Conversation history and sessions
- Channel credentials (WhatsApp auth, etc.)
- Agent workspaces

### Backups

Back up your persistent volume regularly. The key paths are:

- `/data/.openclaw/openclaw.json` — configuration
- `/data/.openclaw/agents/` — sessions and agent state
- `/data/.openclaw/credentials/` — channel credentials

---

## Upgrading OpenClaw

The `OPENCLAW_VERSION` build arg in the Dockerfile controls which image tag is used:

```dockerfile
ARG OPENCLAW_VERSION=2026.3.1
```

### Option A: Automatic (recommended)

The included GitHub Actions workflow (`.github/workflows/check-update.yml`) checks GHCR daily for new releases. When a new version is found, it opens a PR. Merge the PR → Railway redeploys automatically.

> **Note:** Enable GitHub Actions on your fork for this to work.

### Option B: Manual script

```bash
# Fetch and apply the latest version
./scripts/upgrade.sh

# Or pin a specific version
./scripts/upgrade.sh 2026.3.2
```

Then commit and push — Railway redeploys on push.

### Option C: Track latest (not recommended for production)

Change the Dockerfile:

```dockerfile
ARG OPENCLAW_VERSION=latest
```

This always pulls the newest image but you lose reproducibility and rollback ability.

---

## Environment variable reference

### Core

| Variable | Required | Description |
|---|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | ✅ | Auth token for the gateway. Generate: `openssl rand -hex 32` |
| `PORT` | Recommended | Port for the gateway (default: `8080`) |
| `OPENCLAW_STATE_DIR` | Baked in | State directory (default: `/data/.openclaw`) |
| `OPENCLAW_WORKSPACE_DIR` | Baked in | Workspace directory (default: `/data/workspace`) |

### Model providers

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `OPENAI_API_KEY` | OpenAI (GPT) |
| `GEMINI_API_KEY` | Google Gemini |
| `OPENROUTER_API_KEY` | OpenRouter (multi-provider) |
| `MISTRAL_API_KEY` | Mistral |

### Channels

| Variable | Description |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `DISCORD_BOT_TOKEN` | Discord bot token |
| `SLACK_BOT_TOKEN` | Slack bot user token (`xoxb-...`) |
| `SLACK_APP_TOKEN` | Slack app-level token (`xapp-...`) |

### Tools

| Variable | Description |
|---|---|
| `BRAVE_API_KEY` | Brave Search API |
| `PERPLEXITY_API_KEY` | Perplexity search |
| `FIRECRAWL_API_KEY` | Firecrawl web scraping |

See [`.env.example`](.env.example) for the complete list.

---

## Health checks

The gateway exposes built-in health endpoints (no auth required):

| Endpoint | Purpose |
|---|---|
| `/healthz` | Liveness probe — "is the process running?" |
| `/readyz` | Readiness probe — "are channels connected?" |
| `/health` | Alias for `/healthz` |
| `/ready` | Alias for `/readyz` |

Railway is configured to probe `/healthz` via `railway.toml`.

---

## Troubleshooting

### Gateway starts but no AI responses

- Verify at least one model provider API key is set correctly
- Check Railway logs for auth errors
- In the Control UI, go to the Config tab and verify model settings

### "disconnected (1008): pairing required"

This is normal on first connection. See [device pairing](#device-pairing).

### "ECONNREFUSED" or health check failures

- Ensure the Dockerfile CMD binds to `lan` (0.0.0.0), not loopback — this is the default in this template
- Check that Railway's `PORT` env var is being passed through

### Channel not connecting

- Verify the channel token env var is set (check for typos)
- Check Railway logs for channel-specific errors
- For WhatsApp: you must complete QR login via CLI shell

### Need more help

- Run diagnostics from a Railway shell: `node openclaw.mjs doctor`
- Check health: `node openclaw.mjs health --json`
- View status: `node openclaw.mjs status --all`

---

## vs codetitlan/openclaw-railway-template

| | This template | codetitlan template |
|---|---|---|
| **Deploy time** | ~30s build + ~30s health check | 10-15+ minutes (full source build) |
| **How it works** | `FROM ghcr.io/openclaw/openclaw` | Clones repo, `pnpm install`, TypeScript build, UI bundle |
| **Upgrades** | Change version tag, redeploy | Re-clone, rebuild everything |
| **Auto-updates** | GitHub Actions PR workflow | Manual |
| **Image size** | Same (official image) | Same (but built on Railway's infra) |

---

## Upstream documentation

| Topic | Link |
|---|---|
| **Getting started** | [docs.openclaw.ai/start/getting-started](https://docs.openclaw.ai/start/getting-started) |
| **Configuration** | [docs.openclaw.ai/gateway/configuration](https://docs.openclaw.ai/gateway/configuration) |
| **Configuration examples** | [docs.openclaw.ai/gateway/configuration-examples](https://docs.openclaw.ai/gateway/configuration-examples) |
| **Configuration reference** | [docs.openclaw.ai/gateway/configuration-reference](https://docs.openclaw.ai/gateway/configuration-reference) |
| **Docker install guide** | [docs.openclaw.ai/install/docker](https://docs.openclaw.ai/install/docker) |
| **Railway deploy guide** | [docs.openclaw.ai/install/railway](https://docs.openclaw.ai/install/railway) |
| **Control UI** | [docs.openclaw.ai/web/control-ui](https://docs.openclaw.ai/web/control-ui) |
| **Channels overview** | [docs.openclaw.ai/channels](https://docs.openclaw.ai/channels) |
| **Model providers** | [docs.openclaw.ai/providers](https://docs.openclaw.ai/providers) |
| **Authentication** | [docs.openclaw.ai/gateway/authentication](https://docs.openclaw.ai/gateway/authentication) |
| **Health checks** | [docs.openclaw.ai/gateway/health](https://docs.openclaw.ai/gateway/health) |
| **Troubleshooting** | [docs.openclaw.ai/gateway/troubleshooting](https://docs.openclaw.ai/gateway/troubleshooting) |
| **Sandboxing** | [docs.openclaw.ai/gateway/sandboxing](https://docs.openclaw.ai/gateway/sandboxing) |
| **Security** | [docs.openclaw.ai/security](https://docs.openclaw.ai/security) |
| **FAQ** | [docs.openclaw.ai/help/faq](https://docs.openclaw.ai/help/faq) |
| **Discord community** | [discord.gg/clawd](https://discord.gg/clawd) |

---

## License

This Railway wrapper is MIT-licensed. OpenClaw itself is [MIT-licensed](https://github.com/openclaw/openclaw/blob/main/LICENSE).
