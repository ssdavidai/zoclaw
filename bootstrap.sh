#!/usr/bin/env bash
# openclaw-tailscale-bootstrap.sh
# Run AFTER: zotail is configured + `openclaw configure` has been run.
# Patches the default openclaw config so the gateway is reachable
# via Tailscale Serve (both TUI and Control UI in browser).
# Also migrates secrets to Zo secrets and registers gateway as a
# Zo user service (supervisord).
set -euo pipefail

CONFIG="${HOME}/.openclaw/openclaw.json"
SECRETS_FILE="/root/.zo_secrets"
USER_SUPERVISOR="/etc/zo/supervisord-user.conf"

if [ ! -f "$CONFIG" ]; then
  echo "Error: $CONFIG not found. Run 'openclaw configure' first."
  exit 1
fi

# ─── 1. Patch openclaw config ─────────────────────────────────────────

echo "Patching openclaw config for Tailscale Serve..."

node -e "
  const fs = require('fs');
  const crypto = require('crypto');
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const gw = cfg.gateway ??= {};

  // Bind to loopback only (required for tailscale serve mode)
  gw.bind = 'loopback';

  // Enable OpenClaw's native Tailscale Serve integration.
  gw.tailscale = { mode: 'serve' };

  // Trust localhost as reverse proxy (Tailscale Serve → loopback).
  gw.trustedProxies = ['127.0.0.1/32'];

  // Ensure token auth is configured. The gateway token is how CLI
  // tools (tui, devices list, etc.) authenticate over WebSocket.
  // Without this, the gateway rejects all connections as 'pairing required'.
  gw.auth ??= {};
  gw.auth.mode = 'token';
  if (!gw.auth.token) {
    gw.auth.token = crypto.randomBytes(24).toString('hex');
    console.log('  gateway.auth.token -> generated');
  } else {
    console.log('  gateway.auth.token -> preserved');
  }

  // Trust Tailscale identity headers for browser access via Serve.
  gw.auth.allowTailscale = true;

  // Enable the browser Control UI
  gw.controlUi ??= {};
  gw.controlUi.enabled = true;

  // Remove invalid denyCommands (default config generates names
  // that don't match real command IDs, triggering audit warnings)
  if (gw.nodes?.denyCommands) delete gw.nodes.denyCommands;

  // Set workspace to /home/workspace/ (Zo standard workspace)
  cfg.agents ??= {};
  cfg.agents.defaults ??= {};
  cfg.agents.defaults.workspace = '/home/workspace/';

  // Fix credentials dir permissions (create if missing)
  const credDir = process.env.HOME + '/.openclaw/credentials';
  if (!fs.existsSync(credDir)) fs.mkdirSync(credDir, { recursive: true, mode: 0o700 });
  else fs.chmodSync(credDir, 0o700);

  fs.writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2) + '\n');
" "$CONFIG"

echo "  gateway.bind = loopback"
echo "  gateway.tailscale.mode = serve"
echo "  gateway.trustedProxies = [127.0.0.1/32]"
echo "  gateway.auth.mode = token"
echo "  gateway.auth.allowTailscale = true"
echo "  gateway.controlUi.enabled = true"
echo "  agents.defaults.workspace = /home/workspace/"

# ─── 2. Migrate secrets to Zo secrets ─────────────────────────────────

echo ""
echo "Migrating secrets to Zo secrets..."

# Extract gateway token from (now-patched) openclaw config
GW_TOKEN=$(node -pe "JSON.parse(require('fs').readFileSync('${CONFIG}','utf8')).gateway?.auth?.token ?? ''" 2>/dev/null || true)

# Extract OpenRouter API key from agent auth profiles
AGENT_AUTH="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"
OR_KEY=""
if [ -f "$AGENT_AUTH" ]; then
  OR_KEY=$(node -pe "
    const p = JSON.parse(require('fs').readFileSync('${AGENT_AUTH}','utf8'));
    const k = Object.values(p.profiles || {}).find(v => v.provider === 'openrouter');
    k?.key ?? ''
  " 2>/dev/null || true)
fi

# Helper: add or update a key in zo_secrets
upsert_secret() {
  local key="$1" val="$2"
  if [ -z "$val" ]; then return; fi
  if grep -q "^export ${key}=" "$SECRETS_FILE" 2>/dev/null; then
    sed -i "s|^export ${key}=.*|export ${key}=\"${val}\"|" "$SECRETS_FILE"
    echo "  ${key} -> updated"
  else
    echo "export ${key}=\"${val}\"" >> "$SECRETS_FILE"
    echo "  ${key} -> added"
  fi
}

if [ -n "$GW_TOKEN" ]; then
  upsert_secret "OPENCLAW_GATEWAY_TOKEN" "$GW_TOKEN"
else
  echo "  Warning: no gateway token found in config"
fi

if [ -n "$OR_KEY" ]; then
  upsert_secret "OPENROUTER_API_KEY" "$OR_KEY"
else
  echo "  No OpenRouter API key found (skipping)"
fi

# ─── 3. Register gateway as Zo user service ───────────────────────────

echo ""
echo "Registering gateway as Zo user service..."

# Remove any openclaw daemon (from --install-daemon during onboarding)
# that would conflict with our supervisor-managed gateway.
openclaw daemon uninstall 2>/dev/null || true

# Kill any existing background gateway process
pkill -f "openclaw gateway run" 2>/dev/null || true
pkill -f "openclaw-gateway" 2>/dev/null || true
sleep 1

# Add [program:openclaw-gateway] to user supervisor config if not present.
# The gateway reads its config (including auth token) from ~/.openclaw/openclaw.json.
# We do NOT pass OPENCLAW_GATEWAY_TOKEN via env — that would override
# the config file token and is only needed for the gateway startup, not
# for CLI tools that read the token from the same config file.
if ! grep -q "\[program:openclaw-gateway\]" "$USER_SUPERVISOR" 2>/dev/null; then
  cat >> "$USER_SUPERVISOR" << 'SUPERVISOR'
[program:openclaw-gateway]
command=openclaw gateway run
directory=/home/workspace
environment=HOME="/root"
autostart=true
autorestart=true
startretries=10
startsecs=5
stdout_logfile=/dev/shm/openclaw-gateway.log
stderr_logfile=/dev/shm/openclaw-gateway_err.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stopwaitsecs=10
stopsignal=TERM
stopasgroup=true
killasgroup=true
SUPERVISOR
  echo "  Added [program:openclaw-gateway] to user supervisor"
else
  echo "  [program:openclaw-gateway] already in user supervisor"
fi

# Reload supervisor config and start/restart the gateway
supervisorctl -c "$USER_SUPERVISOR" reread > /dev/null 2>&1 || true
supervisorctl -c "$USER_SUPERVISOR" update > /dev/null 2>&1 || true
sleep 2

# Restart to pick up any config changes
supervisorctl -c "$USER_SUPERVISOR" restart openclaw-gateway > /dev/null 2>&1 || \
  supervisorctl -c "$USER_SUPERVISOR" start openclaw-gateway > /dev/null 2>&1 || true
sleep 5

# Verify gateway is running
if supervisorctl -c "$USER_SUPERVISOR" status openclaw-gateway 2>/dev/null | grep -q RUNNING; then
  echo "  Gateway running (supervised)"
else
  echo "  Warning: gateway may not be running."
  echo "  Check: supervisorctl -c $USER_SUPERVISOR status openclaw-gateway"
  echo "  Logs:  tail /dev/shm/openclaw-gateway.log /dev/shm/openclaw-gateway_err.log"
fi

# Quick gateway health check
echo ""
echo "Gateway health:"
openclaw gateway health 2>&1 | head -5 || echo "  (health check unavailable)"

# ─── 4. Print access info ─────────────────────────────────────────────

TS_HOSTNAME=$(tailscale status --json 2>/dev/null | node -pe "
  const s = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  (s.Self.DNSName || '').replace(/\\.\$/g, '')
" 2>/dev/null || true)

echo ""
echo "Ready!"
echo "  TUI:     openclaw tui"
echo "  Manage:  supervisorctl -c $USER_SUPERVISOR restart openclaw-gateway"
if [ -n "$TS_HOSTNAME" ]; then
  echo "  Browser: https://${TS_HOSTNAME}/"
  echo ""
  echo "  To access from another device on your tailnet:"
  echo "    1. Open the URL above in your browser"
  echo "    2. Run: openclaw devices list"
  echo "    3. Run: openclaw devices approve <request-id>"
  echo "    4. Refresh the browser"
  echo ""
  echo "  This is a one-time pairing per browser."
fi
