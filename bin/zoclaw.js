#!/usr/bin/env node
const { execFileSync } = require("child_process");
const path = require("path");

const args = process.argv.slice(2);
const command = args.find((a) => !a.startsWith("-"));
const flags = args.filter((a) => a.startsWith("-"));
const scriptsDir = path.join(__dirname, "..", "scripts");

const commands = {
  init: "setup.sh",
  bootstrap: "bootstrap.sh",
};

if (!command || !commands[command]) {
  console.log("Usage: zoclaw <command> [options]\n");
  console.log("Commands:");
  console.log("  init        Full setup (Tailscale + OpenClaw + bootstrap)");
  console.log("  bootstrap   Config patches only (if already installed)");
  console.log("\nOptions:");
  console.log("  --next      Use @next (dev) channel for dependencies");
  process.exit(command ? 1 : 0);
}

const script = path.join(scriptsDir, commands[command]);
const env = { ...process.env };

if (flags.includes("--next")) {
  env.ZOCLAW_CHANNEL = "next";
}

try {
  execFileSync("bash", [script], { stdio: "inherit", env });
} catch (err) {
  process.exit(err.status ?? 1);
}
