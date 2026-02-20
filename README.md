# zoclaw

Set up [OpenClaw](https://openclaw.ai) on a [Zo](https://zo.computer) instance with Tailscale access in one command.

## Quick start

On a fresh Zo instance:

```bash
git clone https://github.com/ssdavidai/zoclaw.git
cd zoclaw
./setup.sh
```

That's it. The setup script walks you through everything:

1. Prompts for your Tailscale auth key (or uses the one already in zo secrets)
2. Installs and configures Tailscale via [zotail](https://github.com/ssdavidai/zotail)
3. Installs OpenClaw
4. Runs the OpenClaw onboarding wizard
5. Patches the config for secure Tailscale access
6. Prints your Control UI URL and offers to launch the TUI

### After setup

On first browser load, the Control UI will request device pairing. Approve it once from the CLI:

```bash
openclaw devices list
openclaw devices approve <request-id>
```

After that, the browser is permanently paired.

## Why this exists

After a fresh `openclaw configure` on Zo, the default gateway config doesn't work with Tailscale. You'll hit a series of issues:

1. **"requires HTTPS or localhost"** -- Tailscale Serve terminates TLS externally and proxies to the gateway as plain HTTP on loopback. The gateway sees a localhost socket but a non-local `Host` header (your `.ts.net` hostname), so it treats the connection as remote and rejects it.

2. **"device identity required"** -- The Control UI in the browser needs to complete device pairing, but the gateway doesn't recognize the browser as a trusted client without proper proxy configuration.

3. **CLI pairing scope mismatch** -- The initial onboarding pairs the CLI with read-only scopes (`operator.read`), but the CLI needs full admin scopes (`operator.admin`, `operator.approvals`, `operator.pairing`) to function.

4. **Security audit failures** -- The default config ships with invalid `denyCommands` entries and overly permissive credentials directory permissions.

## What the bootstrap patches

| Issue | Fix |
|---|---|
| Gateway doesn't trust Tailscale Serve | Sets `gateway.auth.allowTailscale: true` |
| `.ts.net` Host header rejected as remote | Sets `gateway.trustedProxies: ["127.0.0.1/32"]` so the gateway trusts Tailscale Serve's forwarded headers |
| Control UI not enabled | Sets `gateway.controlUi.enabled: true` |
| CLI paired with read-only scopes | Upgrades paired device scopes to full admin |
| Invalid `denyCommands` entries | Removes the ineffective default entries |
| Credentials dir readable by others | `chmod 700 ~/.openclaw/credentials` |

The script does **not** set `allowInsecureAuth` or `dangerouslyDisableDeviceAuth` -- those are insecure workarounds. Instead, it configures `trustedProxies` so the gateway properly recognizes Tailscale Serve connections as secure, and the browser goes through proper Ed25519 device pairing.

## Scripts

| Script | Purpose |
|---|---|
| `setup.sh` | Full setup from scratch (Tailscale + OpenClaw + bootstrap) |
| `bootstrap.sh` | Config patches only (if OpenClaw and Tailscale are already installed) |

## Security

Running `openclaw security audit` after setup should show **0 critical findings**. The setup uses `trustedProxies` + proper device pairing instead of insecure bypasses.

## License

MIT
