# OpenClaw + Telegram Forum Topics (Personal Claw) — End-to-end setup

This guide is a **tested, working** setup for running OpenClaw on Kubernetes via the Helm chart and routing Telegram forum topics to specific agents.

It is optimized for this target behavior:

- ✅ DM access only for the owner
- ✅ Group access only in explicitly allowed Telegram groups
- ✅ Everyone in allowed group(s) can chat with the bot
- ✅ Per-topic agent routing (one topic = one agent)

---

## 0) Important model details

### Helm chart security mode

By default, the OpenClaw app container runs non-root.
If you want OpenClaw to install tools with `apt`/system package managers at runtime, enable root mode:

```bash
helm upgrade --install openclaw charts/openclaw \
  --namespace openclaw \
  --reuse-values \
  --set openclaw.runtimeAsRoot=true
```

> ⚠️ Running root is less hardened. Use intentionally.

### Config persistence

OpenClaw runtime config lives at:

- `/data/.openclaw/openclaw.json` (PVC-backed)

The chart seeds this file only on first boot. After that, edits to this file persist and are **not** overwritten by normal restarts.

---

## 1) Prerequisites

- A running Helm release (`openclaw`) in namespace (`openclaw`)
- Kubernetes access (`kubectl`, `helm`)
- Bot token from `@BotFather`
- `jq` installed locally (on your machine; not required in-container)

Optional env vars for command reuse:

```bash
export KUBECONFIG=~/.kube/hoth
export NS=openclaw
export RELEASE=openclaw
```

---

## 2) Put Telegram token into Kubernetes secret

Assuming chart uses `openclaw-secret`:

```bash
read -s TELEGRAM_BOT_TOKEN
kubectl -n "$NS" patch secret openclaw-secret \
  --type merge \
  -p "{\"stringData\":{\"TELEGRAM_BOT_TOKEN\":\"$TELEGRAM_BOT_TOKEN\"}}"
unset TELEGRAM_BOT_TOKEN
```

Restart:

```bash
kubectl -n "$NS" rollout restart deploy/$RELEASE
kubectl -n "$NS" rollout status deploy/$RELEASE --timeout=300s
```

---

## 3) Telegram-side settings (critical)

In `@BotFather` for your bot:

1. **Group Privacy** → **Disable**
2. **Allow Groups** (`/setjoingroups`) → **Enable**

Why:

- If privacy is ON, DMs work but most group/topic messages are invisible to bot.
- If join groups is OFF, bot cannot be added to group.

Verify quickly:

```bash
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | jq '.result | {username, can_join_groups, can_read_all_group_messages}'
```

Expected:

- `can_join_groups: true`
- `can_read_all_group_messages: true`

---

## 4) Create/prepare forum supergroup

- Create Telegram **supergroup**
- Enable **Topics** in group settings
- Add bot to the group
- Send at least one message in each topic you want to use

---

## 5) Discover required Telegram IDs

Use Bot API updates:

```bash
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" | jq .
```

Find:

- Owner user id: `message.from.id`
- Group id: `message.chat.id` (looks like `-100...`)
- Topic id(s): `message.message_thread_id`

Example from a working setup:

- owner: `974700529`
- group: `-1003906838118`
- topic `1` (General)
- topic `3` (`executive-assistant`)

---

## 6) Check available OpenClaw agents

Inspect agent list in runtime config:

```bash
kubectl -n "$NS" exec deploy/$RELEASE -c openclaw -- \
  sh -lc 'cat /data/.openclaw/openclaw.json'
```

Look at `agents.list[].id`.

Example:

- `main`
- `executive-assistant`

---

## 7) Apply Telegram routing config safely

### 7.1 Backup current config locally

```bash
TMP=$(mktemp)
kubectl -n "$NS" exec deploy/$RELEASE -c openclaw -- \
  sh -lc 'cat /data/.openclaw/openclaw.json' > "$TMP"
cp "$TMP" "${TMP}.bak"
```

### 7.2 Patch `channels.telegram`

This pattern gives:

- DMs allowlisted to owner only
- All groups disabled by default
- One explicit forum group enabled
- Allowed forum group open to all members
- Topic→agent mapping

```bash
OWNER_ID="974700529"
GROUP_ID="-1003906838118"

jq --arg owner "$OWNER_ID" --arg group "$GROUP_ID" '
  .channels.telegram = (
    (.channels.telegram // {}) + {
      enabled: true,
      dmPolicy: "allowlist",
      allowFrom: [$owner],

      # deny-by-default for groups
      groupPolicy: "allowlist",
      groupAllowFrom: [$owner],
      groups: {
        "*": { enabled: false },
        ($group): {
          enabled: true,
          groupPolicy: "open",
          requireMention: false,
          topics: {
            "1": { enabled: true, agentId: "main" },
            "3": { enabled: true, agentId: "executive-assistant" }
          }
        }
      }
    }
  )
' "$TMP" > "${TMP}.new"
```

### 7.3 Write patched config back to pod

```bash
kubectl -n "$NS" exec -i deploy/$RELEASE -c openclaw -- \
  sh -lc 'cat > /data/.openclaw/openclaw.json' < "${TMP}.new"
```

### 7.4 Restart OpenClaw

```bash
kubectl -n "$NS" rollout restart deploy/$RELEASE
kubectl -n "$NS" rollout status deploy/$RELEASE --timeout=300s
```

---

## 8) Validation checklist

### DM path

- DM bot from owner account → should respond
- DM from non-allowlisted account → should not be authorized

### Group/topic path

- In allowed forum group, topic 1 → routed to `main`
- In allowed forum group, topic 3 → routed to `executive-assistant`
- In any non-allowed group → no response

### Channel status probe

```bash
kubectl -n "$NS" exec deploy/$RELEASE -c openclaw -- \
  sh -lc 'openclaw channels status --probe'
```

---

## 9) Troubleshooting (real issues encountered + fixes)

### Problem: DM works, forum topics do not

**Cause:** Telegram privacy mode still enabled.

**Fix:** In BotFather disable Group Privacy and verify:

```bash
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | jq '.result.can_read_all_group_messages'
```

Must be `true`.

---

### Problem: Cannot add bot back to group

**Cause:** BotFather “Allow Groups?” disabled.

**Fix:** Enable `/setjoingroups` for the bot.

---

### Problem: `jq` command returns null for bot flags

Use the correct query path:

```bash
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | jq '.result | {can_join_groups, can_read_all_group_messages}'
```

---

### Problem: No response in one specific topic

**Cause:** Missing or wrong `message_thread_id` mapping.

**Fix:** Re-read `getUpdates`, find correct `message_thread_id`, update:

- `channels.telegram.groups.<groupId>.topics.<threadId>.agentId`

Then restart deployment.

---

### Problem: Bot can send test messages but still no inbound handling

Check in this order:

1. Privacy OFF (`can_read_all_group_messages=true`)
2. Bot is in correct supergroup
3. Topic IDs correctly mapped
4. Group is explicitly allowed in config
5. OpenClaw restarted after config change
6. Live logs while sending message:

```bash
kubectl -n "$NS" logs -f deploy/$RELEASE -c openclaw | grep -i telegram
```

---

## 10) Minimal working `channels.telegram` block

```json
{
  "enabled": true,
  "dmPolicy": "allowlist",
  "allowFrom": ["974700529"],
  "groupPolicy": "allowlist",
  "groupAllowFrom": ["974700529"],
  "groups": {
    "*": { "enabled": false },
    "-1003906838118": {
      "enabled": true,
      "groupPolicy": "open",
      "requireMention": false,
      "topics": {
        "1": { "enabled": true, "agentId": "main" },
        "3": { "enabled": true, "agentId": "executive-assistant" }
      }
    }
  }
}
```

---

## 11) Operational notes

- Keep `openclaw.json` backups before edits.
- Treat bot token like a password.
- If running root mode for runtime `apt` installs, monitor security posture.
- If you want deterministic tooling across restarts, prefer building a custom image.

---

## 12) Quick runbook (copy/paste)

```bash
# 1) Restart after config/token changes
kubectl -n openclaw rollout restart deploy/openclaw
kubectl -n openclaw rollout status deploy/openclaw --timeout=300s

# 2) Verify telegram channel from inside pod
kubectl -n openclaw exec deploy/openclaw -c openclaw -- sh -lc 'openclaw channels status --probe'

# 3) Verify telegram bot flags
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | jq '.result | {username, can_join_groups, can_read_all_group_messages}'

# 4) Inspect updates for IDs/topics
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" | jq .
```
