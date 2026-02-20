# zoclaw

Bootstrap script for running [OpenClaw](https://openclaw.ai) on a [Zo](https://zo.computer) instance with Tailscale access.

## The problem

After a fresh `openclaw configure` on Zo, the default gateway config doesn't work properly with Tailscale. You'll hit a series of issues:

1. **"requires HTTPS or localhost"** -- Tailscale Serve terminates TLS externally and proxies to the gateway as plain HTTP on loopback. The gateway sees a localhost socket but a non-local `Host` header (your `.ts.net` hostname), so it treats the connection as remote and rejects it.

2. **"device identity required"** -- The Control UI in the browser needs to complete device pairing, but the gateway doesn't recognize the browser as a trusted client without proper proxy configuration.

3. **CLI pairing scope mismatch** -- The initial onboarding pairs the CLI with read-only scopes (`operator.read`), but the CLI needs full admin scopes (`operator.admin`, `operator.approvals`, `operator.pairing`) to function.

4. **Security audit failures** -- The default config ships with invalid `denyCommands` entries and overly permissive credentials directory permissions.

## What the bootstrap script does

| Issue | Fix |
|---|---|
| Gateway doesn't trust Tailscale Serve | Sets `gateway.auth.allowTailscale: true` |
| `.ts.net` Host header rejected as remote | Sets `gateway.trustedProxies: ["127.0.0.1/32"]` so the gateway trusts Tailscale Serve's forwarded headers |
| Control UI not enabled | Sets `gateway.controlUi.enabled: true` |
| CLI paired with read-only scopes | Upgrades paired device scopes to full admin |
| Invalid `denyCommands` entries | Removes the ineffective default entries |
| Credentials dir readable by others | `chmod 700 ~/.openclaw/credentials` |

The script does **not** set `allowInsecureAuth` or `dangerouslyDisableDeviceAuth` -- those are insecure workarounds. Instead, it configures `trustedProxies` so the gateway properly recognizes Tailscale Serve connections as secure, and the browser goes through proper Ed25519 device pairing.

## Prerequisites

- A Zo computer instance
- Tailscale configured via [zotail](https://github.com/nichochar/zo-tailscale) (auth key in zo secrets, installed and running)
- OpenClaw installed and `openclaw configure` already run

## Usage

```bash
# Clone
git clone https://github.com/ssdavidai/zoclaw.git
cd zoclaw

# Run the bootstrap
./bootstrap.sh
```

The script will output something like:

```
Patching openclaw config for Tailscale access...
  gateway.auth.allowTailscale = true
  gateway.controlUi.enabled = true
  nodes.denyCommands -> removed (invalid defaults)
  gateway.trustedProxies = ["127.0.0.1/32"]
  credentials dir -> 700
  Upgraded paired device scopes to full admin
Restarting gateway...

Ready!
  TUI:     openclaw tui
  Browser: https://your-machine.tailnet-name.ts.net/?token=your-token
```

### After running the script

**TUI** works immediately:

```bash
openclaw tui
```

**Browser** -- open the URL the script prints (includes `?token=...`). On first load, the Control UI will request device pairing. Approve it once from the CLI:

```bash
openclaw devices list
openclaw devices approve <request-id>
```

After approving, the browser is permanently paired. The token is saved in browser localStorage so you won't need the `?token=` parameter again.

## Full setup from scratch

```bash
# 1. Install OpenClaw
npm install -g openclaw
openclaw configure

# 2. Set up Tailscale (add TAILSCALE_AUTH_KEY to zo secrets first)
# See: https://github.com/nichochar/zo-tailscale

# 3. Run the bootstrap
git clone https://github.com/ssdavidai/zoclaw.git
./zoclaw/bootstrap.sh

# 4. Use it
openclaw tui                           # terminal UI
# or open the browser URL from step 3 output
```

## Security

Running `openclaw security audit` after bootstrap should show **0 critical findings**. The script uses `trustedProxies` + proper device pairing instead of insecure bypasses.

## License

MIT
