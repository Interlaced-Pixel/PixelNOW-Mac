#!/usr/bin/env node
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const directSignalingScript = join(root, "server", "direct-signaling.mjs");
const directSignalingHost = stringEnv("PIXELNOW_REMOTE_COOP_DIRECT_BIND_HOST", "198.12.95.48");
const directSignalingPort = integerEnv("PIXELNOW_REMOTE_COOP_DIRECT_PORT", 32189);
const directSignalingPortAlternates = portCandidates(directSignalingPort, process.env.PIXELNOW_REMOTE_COOP_DIRECT_PORT_ALTERNATES);
const directSignalingEnvironment = {
  ...process.env,
  PIXELNOW_REMOTE_COOP_DIRECT_BIND_HOST: directSignalingHost,
  PIXELNOW_REMOTE_COOP_DIRECT_PORT: String(directSignalingPort),
  PIXELNOW_REMOTE_COOP_DIRECT_PORT_ALTERNATES: directSignalingPortAlternates.slice(1).join(",")
};

if (process.argv.includes("--help") || process.argv.includes("-h")) {
  printHelp();
  process.exit(0);
}

console.log("PixelNOW Remote Co-Op direct signaling service");
console.log(`  bind: ${directSignalingHost}:${directSignalingPort}${alternatePortSummary(directSignalingPortAlternates)}`);
console.log("  media path: direct WebRTC peer connection");
console.log("  fallback path: none");

const child = spawn(process.execPath, [directSignalingScript], {
  env: directSignalingEnvironment,
  stdio: ["ignore", "pipe", "pipe", "ipc"]
});
let stopping = false;

child.stdout.on("data", chunk => process.stdout.write(`[direct-signaling] ${chunk}`));
child.stderr.on("data", chunk => process.stderr.write(`[direct-signaling] ${chunk}`));
child.on("message", message => {
  if (message?.kind !== "remoteCoOpDirectSignalingListening") return;
  const protocol = message.secure === true ? "wss" : "ws";
  const endpoint = `${protocol}://${directSignalingHost}:${message.port}/remote-coop-direct`;
  console.log(`  signaling endpoint: ${endpoint}`);
  sendPanelMessage({ ...message, signalingEndpoint: endpoint });
});
child.on("error", error => stopAll(`direct signaling failed to start: ${error.message}`, 1));
child.on("exit", (code, signal) => {
  if (stopping) return;
  stopAll(`direct signaling exited${signal ? ` from ${signal}` : ""} with code ${code ?? 1}`, code ?? 1);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => stopAll(`received ${signal}`, 0));
}

function stopAll(reason, exitCode) {
  if (stopping) return;
  stopping = true;
  process.exitCode = exitCode;
  console.log(`Stopping direct signaling service (${reason}).`);
  if (child.exitCode === null) child.kill("SIGTERM");
  setTimeout(() => {
    if (child.exitCode === null) child.kill("SIGKILL");
    process.exit(process.exitCode ?? 0);
  }, 5_000).unref();
}

function sendPanelMessage(message) {
  if (typeof process.send === "function") process.send(message);
}

function stringEnv(name, fallback) {
  const value = process.env[name];
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function integerEnv(name, fallback) {
  const value = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(value) ? value : fallback;
}

function portCandidates(preferredPort, alternateValue) {
  const alternates = typeof alternateValue === "string" && alternateValue.trim()
    ? alternateValue.split(",").map(value => Number.parseInt(value.trim(), 10))
    : [preferredPort + 1, preferredPort + 2];
  return Array.from(new Set([preferredPort, ...alternates].filter(isUsablePort)));
}

function isUsablePort(value) {
  return Number.isInteger(value) && value > 0 && value <= 65_535;
}

function alternatePortSummary(candidates) {
  return candidates.length > 1 ? ` (alternates: ${candidates.slice(1).join(", ")})` : "";
}

function printHelp() {
  console.log(`Usage: node RemoteCoOp/run-servers.mjs

Starts the direct signaling service. It only coordinates room membership and
WebRTC negotiation; media and controller input travel peer-to-peer.

Environment:
  PIXELNOW_REMOTE_COOP_DIRECT_BIND_HOST       Bind host, default 198.12.95.48
  PIXELNOW_REMOTE_COOP_DIRECT_PORT            Signaling port, default 32189
  PIXELNOW_REMOTE_COOP_DIRECT_PORT_ALTERNATES Comma-separated alternate ports
  PIXELNOW_REMOTE_COOP_DIRECT_CERT            Optional TLS certificate
  PIXELNOW_REMOTE_COOP_DIRECT_KEY             Optional TLS private key`);
}
