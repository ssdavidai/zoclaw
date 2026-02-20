#!/usr/bin/env bash
# openclaw-tailscale-bootstrap.sh
# Run AFTER: zotail is configured + `openclaw configure` has been run.
# Patches the default openclaw config so the gateway is reachable
# via Tailscale (both TUI and Control UI in browser).
set -euo pipefail

CONFIG="${HOME}/.openclaw/openclaw.json"
PAIRED="${HOME}/.openclaw/devices/paired.json"
PENDING="${HOME}/.openclaw/devices/pending.json"

if [ ! -f "$CONFIG" ]; then
  echo "Error: $CONFIG not found. Run 'openclaw configure' first."
  exit 1
fi

echo "Patching openclaw config for Tailscale access..."

# Patch gateway config
node -e "
  const fs = require('fs');
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const gw = cfg.gateway ??= {};

  // Trust Tailscale identity headers on serve connections
  gw.auth ??= {};
  gw.auth.allowTailscale = true;

  // Enable control UI
  gw.controlUi ??= {};
  gw.controlUi.enabled = true;

  // Remove invalid denyCommands entries (default config generates
  // names that don't match real command IDs, triggering audit warnings)
  if (gw.nodes?.denyCommands) delete gw.nodes.denyCommands;

  // Trust localhost as a reverse proxy (Tailscale serve proxies
  // HTTPS -> HTTP on loopback and forwards X-Forwarded-For).
  // This lets the gateway recognize .ts.net Host headers as local.
  gw.trustedProxies = ['127.0.0.1/32'];

  // Fix credentials dir permissions (create if missing)
  const credDir = process.env.HOME + '/.openclaw/credentials';
  if (!fs.existsSync(credDir)) fs.mkdirSync(credDir, { recursive: true, mode: 0o700 });
  else fs.chmodSync(credDir, 0o700);

  fs.writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2) + '\n');
" "$CONFIG"

echo "  gateway.auth.allowTailscale = true"
echo "  gateway.controlUi.enabled = true"
echo "  gateway.trustedProxies = [\"127.0.0.1/32\"]"
echo "  nodes.denyCommands -> removed (invalid defaults)"
echo "  credentials dir -> 700"

# Upgrade any existing paired devices to full admin scopes
if [ -f "$PAIRED" ]; then
  node -e "
    const fs = require('fs');
    const paired = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const scopes = ['operator.read','operator.admin','operator.approvals','operator.pairing'];
    for (const dev of Object.values(paired)) {
      dev.clientId = 'cli';
      dev.clientMode = 'cli';
      dev.scopes = scopes;
      for (const tok of Object.values(dev.tokens ?? {})) tok.scopes = scopes;
    }
    fs.writeFileSync(process.argv[1], JSON.stringify(paired, null, 2) + '\n');
  " "$PAIRED"
  echo "  Upgraded paired device scopes to full admin"
fi

# Clear stale pairing requests
[ -f "$PENDING" ] && echo '{}' > "$PENDING"

# Restart gateway to pick up config changes.
# Do NOT use --force as it regenerates the gateway identity
# and invalidates all existing device pairings.
echo "Restarting gateway..."
pkill -f openclaw-gateway 2>/dev/null || true
sleep 2
openclaw gateway run > /dev/null 2>&1 &
sleep 5

if ! pgrep -f openclaw-gateway > /dev/null 2>&1; then
  echo "Warning: gateway is not running. Try 'openclaw gateway run' manually."
  exit 1
fi

# Read gateway port from config (default 18789)
GW_PORT=$(node -pe "JSON.parse(require('fs').readFileSync('${CONFIG}','utf8')).gateway?.port ?? 18789")
TOKEN=$(node -pe "JSON.parse(require('fs').readFileSync('${CONFIG}','utf8')).gateway?.auth?.token ?? ''")

# Set up tailscale serve to expose the gateway Control UI on the tailnet
echo "Configuring Tailscale Serve..."
tailscale serve --bg --https=443 "http://127.0.0.1:${GW_PORT}" 2>/dev/null && \
  echo "  ✓ Tailscale Serve → localhost:${GW_PORT}" || \
  echo "  Warning: could not configure tailscale serve"

# Get the MagicDNS name for this machine
TS_HOSTNAME=$(tailscale status --json 2>/dev/null | node -pe "
  const s = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  (s.Self.DNSName || '').replace(/\\.\$/, '')
" 2>/dev/null || true)

echo ""
echo "Ready!"
echo "  TUI:     openclaw tui"
if [ -n "$TS_HOSTNAME" ] && [ -n "$TOKEN" ]; then
  echo "  Browser: https://${TS_HOSTNAME}?token=${TOKEN}"
  echo ""
  echo "  Accessible from any device on your tailnet."
fi
