#!/usr/bin/env bash
# setup.sh — Full OpenClaw + Tailscale setup for Zo
# Installs everything from scratch on a fresh Zo instance.
set -euo pipefail

SECRETS_FILE="${HOME}/.zo_secrets"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/bootstrap.sh"
USER_SUPERVISOR="/etc/zo/supervisord-user.conf"
NPM_TAG="${ZOCLAW_CHANNEL:-latest}"

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

echo ""
echo "  Choose authentication method:"
echo "    1) Auth key (reusable, 90-day expiry)"
echo "    2) Interactive (browser-based, no key needed)"
echo "    3) Skip (if already configured)"
echo ""
read -rp "  Choose option [1]: " auth_choice
auth_choice="${auth_choice:-1}"

if [ "$auth_choice" = "2" ]; then
  echo "  Using interactive authentication..."
  echo "  zotail will prompt you to open a browser URL."
  # Don't set TAILSCALE_AUTHKEY - zotail will handle interactive auth
elif [ "$auth_choice" = "3" ]; then
  echo "  Skipping auth setup..."
else
  # Original auth key flow
  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    echo "  Found TAILSCALE_AUTHKEY in zo secrets, using existing key."
  else
    echo "  No TAILSCALE_AUTHKEY found in zo secrets."
    echo "  Generate one at: https://login.tailscale.com/admin/settings/keys"
    echo ""
    read -rp "  Enter your Tailscale auth key: " ts_key
    if [ -z "$ts_key" ]; then
      echo "  Error: auth key cannot be empty."
      exit 1
    fi
    echo "export TAILSCALE_AUTHKEY=\"${ts_key}\"" >> "$SECRETS_FILE"
    export TAILSCALE_AUTHKEY="$ts_key"
    echo "  Saved to zo secrets."
  fi
fi

# ─── Step 2: Install and configure Tailscale via zotail ──────────────

step 2 "Tailscale (zotail)"

echo "  Installing zotail@${NPM_TAG}..."
# Using linked zotail from source
  # npm install -g "@timothyjlaurent/zotail@${NPM_TAG}" 2>&1 | tail -1

echo "  Running zotail setup..."
zotail setup

# ─── Step 3: Install OpenClaw ────────────────────────────────────────

step 3 "OpenClaw"

if command -v openclaw &>/dev/null; then
  echo "  ✓ openclaw already installed ($(openclaw --version 2>/dev/null || echo 'unknown version'))"
else
  echo "  Installing openclaw..."
  npm install -g openclaw@latest 2>&1 | tail -1
fi

# ─── Step 4: OpenClaw onboarding ─────────────────────────────────────

step 4 "OpenClaw onboarding"

if [ -f "${HOME}/.openclaw/openclaw.json" ]; then
  echo "  ✓ OpenClaw already configured, skipping onboarding."
else
  echo "  Running interactive setup..."
  echo "  (When the onboarding finishes, setup will continue automatically.)"
  echo ""
  openclaw onboard --skip-daemon
fi

# ─── Step 5: Bootstrap (config + secrets + service) ──────────────────

step 5 "Bootstrap"

if [ ! -f "$BOOTSTRAP" ]; then
  echo "  Error: bootstrap.sh not found at ${BOOTSTRAP}"
  exit 1
fi

bash "$BOOTSTRAP"

# ─── Done ────────────────────────────────────────────────────────────

TS_HOSTNAME=$(tailscale status --json 2>/dev/null | node -pe "
  const s = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
  (s.Self.DNSName || '').replace(/\\\.\$/, '')
" 2>/dev/null || true)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Setup complete!"
echo ""
echo "  Secrets:   /root/.zo_secrets"
echo "  Workspace: /home/workspace/"
echo "  Gateway:   managed by supervisord (user)"
echo "  Manage:    supervisorctl -c $USER_SUPERVISOR restart openclaw-gateway"
echo ""
if [ -n "$TS_HOSTNAME" ]; then
  echo "  Control UI: https://${TS_HOSTNAME}/"
  echo ""
  echo "  (On first browser load, approve device pairing from the CLI:"
  echo "   openclaw devices list && openclaw devices approve <id>)"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

read -rp "  Launch the TUI now? [Y/n] " launch_tui
launch_tui="${launch_tui:-Y}"

# Source zo_secrets so OPENCLAW_GATEWAY_TOKEN is available for CLI tools
source "$SECRETS_FILE" 2>/dev/null || true

if [[ "$launch_tui" =~ ^[Yy]$ ]]; then
  exec openclaw tui
else
  echo "  Run 'openclaw tui' whenever you're ready."
fi
