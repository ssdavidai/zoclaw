#!/usr/bin/env node
const { execFileSync } = require("child_process");
const path = require("path");

const command = process.argv[2];
const scriptsDir = path.join(__dirname, "..", "scripts");

const commands = {
  init: "setup.sh",
  bootstrap: "bootstrap.sh",
};

if (!command || !commands[command]) {
  console.log("Usage: zoclaw <command>\n");
  console.log("Commands:");
  console.log("  init        Full setup (Tailscale + OpenClaw + bootstrap)");
  console.log("  bootstrap   Config patches only (if already installed)");
  process.exit(command ? 1 : 0);
}

const script = path.join(scriptsDir, commands[command]);

try {
  execFileSync("bash", [script], { stdio: "inherit" });
} catch (err) {
  process.exit(err.status ?? 1);
}
