#!/usr/bin/env bash
# setup.sh — Full OpenClaw + Tailscale setup for Zo
# Installs everything from scratch on a fresh Zo instance.
set -euo pipefail

SECRETS_FILE="${HOME}/.zo_secrets"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/bootstrap.sh"

# ─── Helpers ──────────────────────────────────────────────────────────

step() { echo -e "\n\033[1;36m[$1/5]\033[0m \033[1m$2\033[0m"; }

ensure_secrets_file() {
  if [ ! -f "$SECRETS_FILE" ]; then
    touch "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
  fi
}

# ─── Step 1: Tailscale auth key ──────────────────────────────────────

step 1 "Tailscale auth key"

ensure_secrets_file
source "$SECRETS_FILE" 2>/dev/null || true

if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
  echo "  Found TAILSCALE_AUTH_KEY in zo secrets, using existing key."
else
  echo "  No TAILSCALE_AUTH_KEY found in zo secrets."
  echo "  Generate one at: https://login.tailscale.com/admin/settings/keys"
  echo ""
  read -rp "  Enter your Tailscale auth key: " ts_key
  if [ -z "$ts_key" ]; then
    echo "  Error: auth key cannot be empty."
    exit 1
  fi
  echo "export TAILSCALE_AUTH_KEY=\"${ts_key}\"" >> "$SECRETS_FILE"
  export TAILSCALE_AUTH_KEY="$ts_key"
  echo "  Saved to zo secrets."
fi

# ─── Step 2: Install and configure Tailscale via zotail ──────────────

step 2 "Tailscale (zotail)"

echo "  Installing zotail..."
npm install -g @ssdavidai/zotail 2>&1 | tail -1

echo "  Running zotail setup..."
zotail setup

# ─── Step 3: Install OpenClaw ────────────────────────────────────────

step 3 "OpenClaw"

echo "  Installing openclaw..."
npm install -g openclaw@latest 2>&1 | tail -1

# ─── Step 4: OpenClaw onboarding ─────────────────────────────────────

step 4 "OpenClaw onboarding"

echo "  Running interactive setup..."
echo "  (When the onboarding finishes, setup will continue automatically.)"
echo ""
openclaw onboard --install-daemon

# ─── Step 5: Bootstrap Tailscale config ──────────────────────────────

step 5 "Tailscale bootstrap"

if [ ! -f "$BOOTSTRAP" ]; then
  echo "  Error: bootstrap.sh not found at ${BOOTSTRAP}"
  exit 1
fi

bash "$BOOTSTRAP"

# ─── Done ────────────────────────────────────────────────────────────

CONFIG="${HOME}/.openclaw/openclaw.json"
TOKEN=$(node -pe "JSON.parse(require('fs').readFileSync('${CONFIG}','utf8')).gateway?.auth?.token ?? ''" 2>/dev/null || true)
TS_URL=$(tailscale serve status 2>/dev/null | grep -oP 'https://\S+' | head -1 || true)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Setup complete!"
echo ""
if [ -n "$TS_URL" ] && [ -n "$TOKEN" ]; then
  echo "  Control UI: ${TS_URL}?token=${TOKEN}"
  echo ""
  echo "  (On first browser load, approve device pairing from the CLI:"
  echo "   openclaw devices list && openclaw devices approve <id>)"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

read -rp "  Launch the TUI now? [Y/n] " launch_tui
launch_tui="${launch_tui:-Y}"

if [[ "$launch_tui" =~ ^[Yy]$ ]]; then
  exec openclaw tui
else
  echo "  Run 'openclaw tui' whenever you're ready."
fi
