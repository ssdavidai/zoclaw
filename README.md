# zoclaw

Run AI agents on your [Zo](https://zo.computer) machine and control them from anywhere on your private network.

zoclaw connects [OpenClaw](https://openclaw.ai) (an open-source AI agent platform) to [Tailscale](https://tailscale.com) (a private mesh VPN) on a Zo machine. After setup, you get:

- **A terminal UI** to chat with your AI agent over SSH or directly on the machine
- **A browser Control UI** accessible from any device on your tailnet (laptop, phone, tablet) — no port forwarding, no public exposure
- **A supervised gateway** that auto-restarts on crash or container reboot
- **Zo-native secrets management** — API keys and tokens stored in `/root/.zo_secrets`, not scattered across config files

## Quick start

```bash
npm install -g @ssdavidai/zoclaw
zoclaw init
```

The setup walks you through five steps:

1. **Tailscale auth key** — prompts for one, or reuses the key already in zo secrets
2. **Tailscale install** — sets up the VPN sidecar via [zotail](https://github.com/ssdavidai/zotail)
3. **OpenClaw install** — installs the agent platform
4. **Onboarding** — interactive wizard to pick your AI provider and model
5. **Bootstrap** — configures the gateway for secure tailnet access and registers it as a service

At the end, you'll see your Control UI URL and can launch the TUI immediately.

### First browser connection

The first time you open the Control UI from another device on your tailnet, you need to approve the device once:

```bash
openclaw devices list
openclaw devices approve <request-id>
```

Refresh the browser and you're in. This is a one-time step per device.

## Development channel

To test in-development versions:

```bash
npm install -g @ssdavidai/zoclaw@next
zoclaw init --next
```

The `--next` flag pulls `@next` versions of dependencies. Without it, stable `@latest` versions are used.

## Managing the gateway

The gateway runs as a supervised service — it starts automatically and restarts on failure.

```bash
# Check status
supervisorctl -c /etc/zo/supervisord-user.conf status openclaw-gateway

# Restart
supervisorctl -c /etc/zo/supervisord-user.conf restart openclaw-gateway

# View logs
tail /dev/shm/openclaw-gateway.log
```

## How it works

A fresh `openclaw configure` on Zo doesn't work with Tailscale out of the box. Tailscale Serve terminates TLS on the edge and proxies to your gateway as plain HTTP on loopback. The gateway sees a localhost socket but a remote-looking `Host` header (your `.ts.net` hostname), misclassifies the connection, and rejects it.

zoclaw fixes this by patching the gateway config to:

- Use OpenClaw's native Tailscale Serve integration (`gateway.tailscale.mode: "serve"`)
- Trust Tailscale identity headers for browser connections (`gateway.auth.allowTailscale`)
- Trust localhost as a reverse proxy (`gateway.trustedProxies`) so forwarded headers are honored
- Enable the browser Control UI
- Set the agent workspace to `/home/workspace/` (Zo standard)
- Migrate secrets (gateway token, API keys) to zo secrets

The bootstrap uses a **two-phase restart** because `trustedProxies` and local device auto-pairing conflict. When `127.0.0.1` is listed as a trusted proxy, the gateway treats direct CLI connections as proxy traffic and can't auto-pair them. So the bootstrap starts the gateway *without* `trustedProxies` first (allowing the local CLI to auto-pair), then adds it and restarts.

No insecure flags (`allowInsecureAuth`, `dangerouslyDisableDeviceAuth`) are used. Browser access goes through proper Ed25519 device pairing.

## Commands

| Command | What it does |
|---|---|
| `zoclaw init` | Full setup from scratch |
| `zoclaw init --next` | Full setup using development channel |
| `zoclaw bootstrap` | Re-apply config patches only (if already installed) |

## License

MIT
