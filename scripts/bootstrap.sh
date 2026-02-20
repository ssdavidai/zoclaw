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

  // Fix credentials dir permissions
  fs.chmodSync(process.env.HOME + '/.openclaw/credentials', 0o700);

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

# Restart gateway
echo "Restarting gateway..."
pkill -f openclaw-gateway 2>/dev/null || true
sleep 2
openclaw gateway run --force > /dev/null 2>&1 &
sleep 5

# Verify
if pgrep -f openclaw-gateway > /dev/null 2>&1; then
  TOKEN=$(node -pe "JSON.parse(require('fs').readFileSync('${CONFIG}','utf8')).gateway?.auth?.token ?? ''")
  TS_URL=$(tailscale serve status 2>/dev/null | grep -oP 'https://\S+' | head -1 || true)

  echo ""
  echo "Ready!"
  echo "  TUI:     openclaw tui"
  if [ -n "$TS_URL" ] && [ -n "$TOKEN" ]; then
    echo "  Browser: ${TS_URL}?token=${TOKEN}"
    echo ""
    echo "  On first browser load, the Control UI will request device pairing."
    echo "  Approve it from the TUI or CLI:"
    echo "    openclaw devices list"
    echo "    openclaw devices approve <request-id>"
  fi
else
  echo "Warning: gateway did not start. Check 'openclaw gateway run --force' manually."
fi
