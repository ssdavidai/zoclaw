#!/usr/bin/env bash
# openclaw-tailscale-bootstrap.sh
# Run AFTER: zotail is configured + `openclaw configure` has been run.
# Patches the default openclaw config so the gateway is reachable
# via Tailscale Serve (both TUI and Control UI in browser).
# Also migrates secrets to Zo secrets and registers gateway as a
# Zo user service (supervisord).
#
# IMPORTANT: trustedProxies must be added AFTER the local device has
# auto-paired. When trustedProxies includes 127.0.0.1/32, the gateway
# treats direct loopback connections as reverse-proxy traffic and looks
# for x-forwarded-for headers. Direct CLI connections don't send those
# headers, so the gateway can't resolve their IP → isLocalClient=false
# → the built-in local auto-pair never fires → deadlock.
#
# The fix: two-phase config patching.
#   Phase 1: Everything except trustedProxies → start gateway → auto-pair
#   Phase 2: Add trustedProxies → restart gateway
set -euo pipefail

CONFIG="${HOME}/.openclaw/openclaw.json"
SECRETS_FILE="/root/.zo_secrets"
USER_SUPERVISOR="/etc/zo/supervisord-user.conf"

if [ ! -f "$CONFIG" ]; then
  echo "Error: $CONFIG not found. Run 'openclaw configure' first."
  exit 1
fi

# ─── 1. Patch config (Phase 1: without trustedProxies) ────────────────

echo "Patching openclaw config (phase 1)..."

node -e "
  const fs = require('fs');
  const crypto = require('crypto');
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const gw = cfg.gateway ??= {};

  gw.bind = 'loopback';
  gw.tailscale = { mode: 'serve' };

  // Do NOT set trustedProxies yet — local auto-pair must happen first.
  // If a previous run left it in, remove it.
  delete gw.trustedProxies;

  gw.auth ??= {};
  gw.auth.mode = 'token';
  if (!gw.auth.token) {
    gw.auth.token = crypto.randomBytes(24).toString('hex');
    console.log('  gateway.auth.token -> generated');
  } else {
    console.log('  gateway.auth.token -> preserved');
  }
  gw.auth.allowTailscale = true;

  gw.controlUi ??= {};
  gw.controlUi.enabled = true;

  if (gw.nodes?.denyCommands) delete gw.nodes.denyCommands;

  cfg.agents ??= {};
  cfg.agents.defaults ??= {};
  cfg.agents.defaults.workspace = '/home/workspace/';

  const credDir = process.env.HOME + '/.openclaw/credentials';
  if (!fs.existsSync(credDir)) fs.mkdirSync(credDir, { recursive: true, mode: 0o700 });
  else fs.chmodSync(credDir, 0o700);

  fs.writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2) + '\n');
" "$CONFIG"

echo "  gateway.bind = loopback"
echo "  gateway.tailscale.mode = serve"
echo "  gateway.trustedProxies = (deferred to phase 2)"
echo "  gateway.auth.mode = token"
echo "  gateway.auth.allowTailscale = true"
echo "  gateway.controlUi.enabled = true"
echo "  agents.defaults.workspace = /home/workspace/"

# ─── 2. Migrate secrets to Zo secrets ─────────────────────────────────

echo ""
echo "Migrating secrets to Zo secrets..."

GW_TOKEN=$(node -pe "JSON.parse(require('fs').readFileSync('${CONFIG}','utf8')).gateway?.auth?.token ?? ''" 2>/dev/null || true)

AGENT_AUTH="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"
OR_KEY=""
if [ -f "$AGENT_AUTH" ]; then
  OR_KEY=$(node -pe "
    const p = JSON.parse(require('fs').readFileSync('${AGENT_AUTH}','utf8'));
    const k = Object.values(p.profiles || {}).find(v => v.provider === 'openrouter');
    k?.key ?? ''
  " 2>/dev/null || true)
fi

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

# Ensure future shell sessions source zo_secrets (for OPENCLAW_GATEWAY_TOKEN).
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  if [ -f "$rc" ] && ! grep -q 'source.*\.zo_secrets' "$rc" 2>/dev/null; then
    echo "" >> "$rc"
    echo '# Zo secrets (API keys, tokens)' >> "$rc"
    echo 'source ~/.zo_secrets 2>/dev/null || true' >> "$rc"
    echo "  Added 'source ~/.zo_secrets' to $(basename "$rc")"
  fi
done

source "$SECRETS_FILE" 2>/dev/null || true

# ─── 3. Register gateway as Zo user service ───────────────────────────

echo ""
echo "Registering gateway as Zo user service..."

openclaw daemon uninstall 2>/dev/null || true

pkill -f "openclaw gateway run" 2>/dev/null || true
pkill -f "openclaw-gateway" 2>/dev/null || true
sleep 1

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

# ─── 4. Phase 1: Start gateway, auto-pair local device ───────────────

echo ""
echo "Starting gateway (phase 1: local device pairing)..."

supervisorctl -c "$USER_SUPERVISOR" reread > /dev/null 2>&1 || true
supervisorctl -c "$USER_SUPERVISOR" update > /dev/null 2>&1 || true
sleep 2
supervisorctl -c "$USER_SUPERVISOR" restart openclaw-gateway > /dev/null 2>&1 || \
  supervisorctl -c "$USER_SUPERVISOR" start openclaw-gateway > /dev/null 2>&1 || true
sleep 5

# Trigger a local CLI connection to auto-pair the local device.
# Without trustedProxies, the gateway sees 127.0.0.1 as a direct
# local client → isLocalClient=true → silent pairing → auto-approved.
echo "Pairing local device..."
if openclaw gateway health > /dev/null 2>&1; then
  echo "  Local device paired."
else
  echo "  Warning: local device pairing may have failed."
  echo "  If the CLI doesn't work, run: openclaw gateway health"
fi

# ─── 5. Phase 2: Add trustedProxies, restart ─────────────────────────

echo ""
echo "Adding trustedProxies for Tailscale Serve (phase 2)..."

node -e "
  const fs = require('fs');
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  cfg.gateway.trustedProxies = ['127.0.0.1/32'];
  fs.writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2) + '\n');
" "$CONFIG"

echo "  gateway.trustedProxies = [127.0.0.1/32]"

echo "Restarting gateway (phase 2: Tailscale proxy support)..."
supervisorctl -c "$USER_SUPERVISOR" restart openclaw-gateway > /dev/null 2>&1 || true
sleep 5

if supervisorctl -c "$USER_SUPERVISOR" status openclaw-gateway 2>/dev/null | grep -q RUNNING; then
  echo "  Gateway running (supervised)"
else
  echo "  Warning: gateway may not be running."
  echo "  Check: supervisorctl -c $USER_SUPERVISOR status openclaw-gateway"
  echo "  Logs:  tail /dev/shm/openclaw-gateway.log /dev/shm/openclaw-gateway_err.log"
fi

# ─── 6. Provision HTTPS certificate ───────────────────────────────────

TS_HOSTNAME=$(tailscale status --json 2>/dev/null | node -pe "
  const s = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  (s.Self.DNSName || '').replace(/\\.\$/g, '')
" 2>/dev/null || true)

if [ -n "$TS_HOSTNAME" ]; then
  echo ""
  echo "Provisioning HTTPS certificate..."
  if tailscale cert "$TS_HOSTNAME" 2>/dev/null; then
    echo "  Certificate ready for ${TS_HOSTNAME}"
  else
    echo "  Warning: certificate provisioning failed."
    echo "  Ensure HTTPS certificates are enabled at https://login.tailscale.com/admin/dns"
  fi
fi

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
