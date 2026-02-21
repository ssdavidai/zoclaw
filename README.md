# zoclaw

Set up [OpenClaw](https://openclaw.ai) on a [Zo](https://zo.computer) instance with Tailscale access in one command.

## Quick start

On a fresh Zo instance:

```bash
npm install -g @ssdavidai/zoclaw && zoclaw init
```

For the development channel:

```bash
npm install -g @ssdavidai/zoclaw@next && zoclaw init --next
```

The `--next` flag installs `@next` versions of dependencies (like [zotail](https://github.com/ssdavidai/zotail)). Without it, stable `@latest` versions are used.

## What it does

The setup script walks you through everything:

1. Prompts for your Tailscale auth key (or uses the one already in zo secrets)
2. Installs and configures Tailscale via [zotail](https://github.com/ssdavidai/zotail)
3. Installs OpenClaw
4. Runs the OpenClaw onboarding wizard
5. Bootstraps the gateway config, migrates secrets, and registers the gateway as a supervised service

### After setup

- **Gateway** is managed by supervisord — it auto-restarts on crash or container reboot
- **Secrets** (gateway token, API keys) are stored in `/root/.zo_secrets`
- **Workspace** is set to `/home/workspace/`
- **Control UI** is accessible from any device on your tailnet

On first browser load, the Control UI will request device pairing. Approve it once from the CLI:

```bash
openclaw devices list
openclaw devices approve <request-id>
```

After that, the browser is permanently paired.

### Managing the gateway

```bash
# Status
supervisorctl -c /etc/zo/supervisord-user.conf status openclaw-gateway

# Restart
supervisorctl -c /etc/zo/supervisord-user.conf restart openclaw-gateway

# Logs
tail /dev/shm/openclaw-gateway.log /dev/shm/openclaw-gateway_err.log
```

## Why this exists

After a fresh `openclaw configure` on Zo, the default gateway config doesn't work with Tailscale. You'll hit a series of issues:

1. **"requires HTTPS or localhost"** -- Tailscale Serve terminates TLS externally and proxies to the gateway as plain HTTP on loopback. The gateway sees a localhost socket but a non-local `Host` header (your `.ts.net` hostname), so it treats the connection as remote and rejects it.

2. **"device identity required"** -- The Control UI in the browser needs to complete device pairing, but the gateway doesn't recognize the browser as a trusted client without proper proxy configuration.

3. **Security audit failures** -- The default config ships with invalid `denyCommands` entries and overly permissive credentials directory permissions.

## What the bootstrap patches

| Setting | Value | Why |
|---|---|---|
| `gateway.bind` | `loopback` | Required for Tailscale Serve mode |
| `gateway.tailscale.mode` | `serve` | Native Tailscale Serve integration |
| `gateway.trustedProxies` | `["127.0.0.1/32"]` | Trust Tailscale Serve's forwarded headers (added in phase 2, after local device auto-pairs) |
| `gateway.auth.mode` | `token` | Token-based auth for CLI/TUI connections |
| `gateway.auth.allowTailscale` | `true` | Trust Tailscale identity for browser access |
| `gateway.controlUi.enabled` | `true` | Enable browser Control UI |
| `gateway.nodes.denyCommands` | removed | Default entries are invalid and trigger audit warnings |
| `agents.defaults.workspace` | `/home/workspace/` | Zo standard workspace |
| `credentials dir` | `chmod 700` | Fix permissions |

### Two-phase trustedProxies

The bootstrap uses a two-phase approach because `trustedProxies` and local auto-pairing conflict:

- **Phase 1**: Apply everything *except* `trustedProxies` → start gateway → local CLI connects from 127.0.0.1 → gateway sees direct local client → auto-pairs silently
- **Phase 2**: Add `trustedProxies` → restart gateway → Tailscale Serve gets proper IP resolution, and the CLI is already paired

Without this split, `trustedProxies` causes the gateway to treat direct loopback connections as reverse-proxy traffic. Since the CLI doesn't send `x-forwarded-for` headers, the gateway can't resolve the client IP, `isLocalClient` becomes false, and the auto-pair mechanism never fires — locking out all CLI tools.

The script does **not** set `allowInsecureAuth` or `dangerouslyDisableDeviceAuth`. Instead, it uses `trustedProxies` so the gateway properly recognizes Tailscale Serve connections as secure, and the browser goes through proper Ed25519 device pairing.

## Scripts

| Command | Purpose |
|---|---|
| `zoclaw init` | Full setup from scratch (Tailscale + OpenClaw + bootstrap) |
| `zoclaw init --next` | Same, but uses `@next` channel for dependencies |
| `zoclaw bootstrap` | Config patches only (if OpenClaw and Tailscale are already installed) |

## Security

Running `openclaw security audit` after setup should show **0 critical findings**. The setup uses `trustedProxies` + proper device pairing instead of insecure bypasses.

## License

MIT
