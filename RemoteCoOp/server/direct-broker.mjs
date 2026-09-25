import { createServer as createHTTPServer } from "node:http";
import { createServer as createHTTPSServer } from "node:https";
import { createHash, createHmac } from "node:crypto";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const productionHost = "198.12.95.48";
const port = integerEnv("PIXELNOW_REMOTE_COOP_DIRECT_PORT", 32189);
const portAlternates = portCandidates(port, environmentValue("PIXELNOW_REMOTE_COOP_DIRECT_PORT_ALTERNATES"));
const bindHost = stringEnv("PIXELNOW_REMOTE_COOP_DIRECT_BIND_HOST", productionHost);
const brokerCertificatePath = stringEnv("PIXELNOW_REMOTE_COOP_DIRECT_CERT", "") || stringEnv("PIXELNOW_REMOTE_COOP_DIRECT_TLS_CERT", "");
const brokerKeyPath = stringEnv("PIXELNOW_REMOTE_COOP_DIRECT_KEY", "") || stringEnv("PIXELNOW_REMOTE_COOP_DIRECT_TLS_KEY", "");
const brokerTLSEnabled = Boolean(brokerCertificatePath && brokerKeyPath);
const brokerHTTPProtocol = brokerTLSEnabled ? "https" : "http";
const brokerWebSocketProtocol = brokerTLSEnabled ? "wss" : "ws";
const networkLoggingEnabled = booleanEnv("PIXELNOW_REMOTE_COOP_DIRECT_LOG_NETWORK", true);
const messageFlowLoggingEnabled = booleanEnv("PIXELNOW_REMOTE_COOP_DIRECT_LOG_MESSAGES", false);
const rateLimitWindowMs = integerEnv("PIXELNOW_REMOTE_COOP_DIRECT_RATE_LIMIT_WINDOW_MS", 5_000);
const rateLimitMaxMessages = integerEnv("PIXELNOW_REMOTE_COOP_DIRECT_RATE_LIMIT_MAX_MESSAGES", 420);
const pinAttemptsLimit = integerEnv("PIXELNOW_REMOTE_COOP_DIRECT_PIN_ATTEMPTS", 3);
const pinExpirationMs = integerEnv("PIXELNOW_REMOTE_COOP_DIRECT_PIN_EXPIRATION_MS", 300_000);
const hostTimeoutMs = integerEnv("PIXELNOW_REMOTE_COOP_DIRECT_HOST_TIMEOUT_MS", 3600_000);
const rooms = new Map();
const sockets = new Set();
const pendingPINs = new Map();
let nextSocketID = 1;

if (Boolean(brokerCertificatePath) !== Boolean(brokerKeyPath)) {
  console.error("PixelNOW Remote Co-Op direct broker HTTPS requires both PIXELNOW_REMOTE_COOP_DIRECT_CERT and PIXELNOW_REMOTE_COOP_DIRECT_KEY.");
  process.exit(1);
}

const server = await makeDirectBrokerServer(async (request, response) => {
  const startedAt = Date.now();
  const remote = socketAddress(request.socket);
  try {
    const url = new URL(request.url ?? "/", `${brokerHTTPProtocol}://${request.headers.host ?? "localhost"}`);
    response.on("finish", () => logNetwork("http.request", {
      method: request.method ?? "GET",
      path: url.pathname,
      status: response.statusCode,
      durationMs: Date.now() - startedAt,
      remote,
      forwardedFor: request.headers["x-forwarded-for"]
    }));
    if (url.pathname === "/health") {
      response.writeHead(200, { "content-type": "application/json; charset=utf-8" }).end(JSON.stringify({ status: "ok", mode: "direct" }));
      return;
    }
    response.writeHead(404).end("Not found");
  } catch (error) {
    logNetwork("http.error", { remote, error: error.message || "not_found" });
    response.writeHead(500).end("Internal Server Error");
  }
});

server.on("upgrade", (request, socket) => {
  const url = new URL(request.url ?? "/", `${brokerHTTPProtocol}://${request.headers.host ?? "localhost"}`);
  if (url.pathname !== "/remote-coop-direct") {
    logNetwork("ws.upgrade.rejected", { remote: socketAddress(socket), path: url.pathname, reason: "invalid_path" });
    socket.destroy();
    return;
  }
  const key = request.headers["sec-websocket-key"];
  if (typeof key !== "string") {
    logNetwork("ws.upgrade.rejected", { remote: socketAddress(socket), path: url.pathname, reason: "missing_key" });
    socket.destroy();
    return;
  }
  const accept = createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
  socket.write([
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${accept}`,
    "",
    ""
  ].join("\r\n"));
  logNetwork("ws.upgrade.accepted", { remote: socketAddress(socket), path: url.pathname, forwardedFor: request.headers["x-forwarded-for"] });
  attachSocket(socket);
});

listenOnAvailablePort(0);

function listenOnAvailablePort(index) {
  const candidate = portAlternates[index];
  const onError = error => {
    server.off("listening", onListening);
    if (error.code === "EADDRINUSE" && index + 1 < portAlternates.length) {
      console.warn(`PixelNOW Remote Co-Op direct broker port ${candidate} is in use; trying ${portAlternates[index + 1]}.`);
      listenOnAvailablePort(index + 1);
      return;
    }
    console.error(`PixelNOW Remote Co-Op direct broker failed to listen on ${bindHost}:${candidate}: ${error.message}`);
    process.exit(1);
  };
  const onListening = () => {
    server.off("error", onError);
    const address = server.address();
    const actualPort = typeof address === "object" && address ? address.port : candidate;
    console.log(`PixelNOW Remote Co-Op direct broker listening on ${brokerHTTPProtocol}://${bindHost}:${actualPort}`);
    if (typeof process.send === "function") process.send({ kind: "remoteCoOpDirectBrokerListening", bindHost, port: actualPort, requestedPort: port, secure: brokerTLSEnabled });
  };
  server.once("error", onError);
  server.once("listening", onListening);
  server.listen(candidate, bindHost);
}

server.on("listening", () => {
  console.log(`Remote Co-Op Direct broker: mode=direct brokerWebSocket=${brokerWebSocketProtocol}`);
  console.log(`Remote Co-Op Direct logging: network=${networkLoggingEnabled ? "enabled" : "disabled"} messageFlow=${messageFlowLoggingEnabled ? "enabled" : "disabled"}`);
  sendBrokerStats();
});

setInterval(() => {
  const now = Date.now();
  for (const [roomID, room] of rooms) {
    if (room.host && room.host.lastSeenAt > 0 && now - room.host.lastSeenAt > hostTimeoutMs) {
      logNetwork("host.timeout", { roomID, host: socketLogFields(room.host) });
      broadcast(room, { kind: "hostTimeout", roomID });
      closeRoom(roomID, "host_timeout");
    }
  }
  for (const state of sockets) {
    if (now - state.lastSeenAt > 45_000) {
      logNetwork("socket.timeout", socketLogFields(state));
      state.socket.destroy();
    } else {
      send(state, { kind: "heartbeat", roomID: state.roomID });
    }
  }
}, 10_000).unref();

function attachSocket(socket) {
  const state = { id: nextSocketID++, socket, buffer: Buffer.alloc(0), role: "unknown", roomID: null, participantID: null, connectedAt: Date.now(), lastSeenAt: Date.now(), messageTimes: [], bytesIn: 0, detached: false };
  sockets.add(state);
  logNetwork("socket.open", socketLogFields(state));
  socket.on("data", chunk => {
    state.bytesIn += chunk.length;
    state.buffer = Buffer.concat([state.buffer, chunk]);
    parseFrames(state);
  });
  socket.on("close", () => detachSocket(state, "close"));
  socket.on("error", error => detachSocket(state, "error", error));
}

function detachSocket(state, reason = "close", error = null) {
  if (state.detached) return;
  state.detached = true;
  sockets.delete(state);
  logNetwork("socket.close", { ...socketLogFields(state), reason, error: error?.message, durationMs: Date.now() - state.connectedAt, bytesIn: state.bytesIn });
  if (!state.roomID) return;
  const room = rooms.get(state.roomID);
  if (!room) return;
  if (state.role === "host" && room.host === state) {
    logNetwork("host.disconnected", { ...socketLogFields(state) });
    broadcast(room, { kind: "hostDisconnected", roomID: state.roomID });
    closeRoom(state.roomID, "host_disconnected");
    return;
  }
  if (state.role === "guest" && state.participantID) {
    room.guests.delete(state.participantID);
    logNetwork("guest.disconnected", { ...socketLogFields(state), hostConnected: Boolean(room.host) });
    if (room.host) send(room.host, { kind: "guestDisconnected", roomID: state.roomID, participantID: state.participantID });
    sendBrokerStats();
  }
}

function parseFrames(state) {
  while (state.buffer.length >= 2) {
    const first = state.buffer[0];
    const second = state.buffer[1];
    const opcode = first & 0x0f;
    const masked = (second & 0x80) === 0x80;
    let length = second & 0x7f;
    let offset = 2;
    if (length === 126) {
      if (state.buffer.length < offset + 2) return;
      length = state.buffer.readUInt16BE(offset);
      offset += 2;
    } else if (length === 127) {
      if (state.buffer.length < offset + 8) return;
      const high = state.buffer.readUInt32BE(offset);
      const low = state.buffer.readUInt32BE(offset + 4);
      length = high * 2 ** 32 + low;
      offset += 8;
    }
    const maskOffset = offset;
    if (masked) offset += 4;
    if (state.buffer.length < offset + length) return;
    let payload = state.buffer.subarray(offset, offset + length);
    if (masked) {
      const mask = state.buffer.subarray(maskOffset, maskOffset + 4);
      payload = Buffer.from(payload.map((value, index) => value ^ mask[index % 4]));
    }
    state.buffer = state.buffer.subarray(offset + length);
    handleFrame(state, opcode, payload);
  }
}

function handleFrame(state, opcode, payload) {
  state.lastSeenAt = Date.now();
  if (opcode === 0x8) {
    logNetwork("socket.close-frame", socketLogFields(state));
    state.socket.end();
    return;
  }
  if (opcode === 0x9) {
    logNetwork("socket.ping", socketLogFields(state));
    sendFrame(state.socket, 0xA, payload);
    return;
  }
  if (opcode !== 0x1) {
    logNetwork("socket.frame.ignored", { ...socketLogFields(state), opcode });
    return;
  }
  if (isRateLimited(state)) {
    logNetwork("socket.rate_limited", socketLogFields(state));
    send(state, { kind: "error", reason: "Rate limit exceeded" });
    state.socket.destroy();
    return;
  }
  try {
    handleMessage(state, JSON.parse(payload.toString("utf8")));
  } catch (error) {
    logNetwork("message.invalid_json", { ...socketLogFields(state), error: error.message });
    send(state, { kind: "error", reason: "Invalid JSON message" });
  }
}

function handleMessage(state, message) {
  logMessageFlow("in", state, message);
  if (message.kind === "heartbeat") return;
  if (message.kind === "hostJoinRequested") {
    registerHost(state, message);
    return;
  }
  if (message.kind === "guestJoinRequested") {
    registerGuest(state, message);
    return;
  }
  if (message.kind === "peerSignal") {
    if (state.role === "host") {
      relayHostSignal(state, message);
    } else {
      relayGuestSignal(state, message);
    }
    return;
  }
  if (message.kind === "pinAuthRequested") {
    requestPINAuth(state, message);
    return;
  }
  if (message.kind === "pinAuthResponse") {
    validatePINAuth(state, message);
    return;
  }
}

function registerHost(state, message) {
  const roomID = stringValue(message.roomID);
  if (!roomID) {
    logNetwork("host.rejected", { ...socketLogFields(state), reason: "missing_room" });
    send(state, { kind: "hostJoinRejected", reason: "Missing room ID" });
    return;
  }
  const room = roomFor(roomID);
  if (room.host) {
    logNetwork("host.rejected", { ...socketLogFields(state), reason: "already_registered" });
    send(state, { kind: "hostJoinRejected", reason: "Host already registered" });
    return;
  }
  room.host = state;
  state.role = "host";
  state.roomID = roomID;
  state.lastSeenAt = Date.now();
  logNetwork("host.registered", { ...socketLogFields(state), guests: room.guests.size });
  send(state, { kind: "hostJoinAccepted", roomID });
  sendBrokerStats();
}

function registerGuest(state, message) {
  const roomID = stringValue(message.roomID);
  if (!roomID) {
    logNetwork("guest.rejected", { ...socketLogFields(state), reason: "missing_room" });
    send(state, { kind: "guestJoinRejected", reason: "Missing room ID" });
    return;
  }
  const room = roomFor(roomID);
  if (!room.host) {
    logNetwork("guest.rejected", { ...socketLogFields(state), reason: "no_host" });
    send(state, { kind: "guestJoinRejected", reason: "Host not connected" });
    return;
  }
  state.role = "guest";
  state.roomID = roomID;
  state.participantID = message.participantID;
  room.guests.set(state.participantID, state);
  room.maxGuests = Math.max(room.maxGuests, room.guests.size);
  logNetwork("guest.registered", { ...socketLogFields(state), hostConnected: Boolean(room.host) });
  send(state, { kind: "guestJoinAccepted", roomID });
  send(room.host, { kind: "guestConnected", roomID, participantID: state.participantID });
  sendBrokerStats();
}

function requestPINAuth(state, message) {
  const roomID = stringValue(message.roomID);
  if (!roomID) {
    logNetwork("pinAuth.rejected", { ...socketLogFields(state), reason: "missing_room" });
    send(state, { kind: "pinAuthRejected", reason: "Missing room ID" });
    return;
  }
  const room = rooms.get(roomID);
  if (!room || !room.host) {
    logNetwork("pinAuth.rejected", { ...socketLogFields(state), reason: "no_host" });
    send(state, { kind: "pinAuthRejected", reason: "Host not connected" });
    return;
  }
  const pin = generatePIN();
  const expiresAt = Date.now() + pinExpirationMs;
  pendingPINs.set(pin, { roomID, expiresAt, attempts: 0 });
  send(room.host, { kind: "pinAuthRequested", roomID, pin, guestParticipantID: state.participantID });
  send(state, { kind: "pinAuthWaiting", roomID });
}

function validatePINAuth(state, message) {
  const pin = stringValue(message.pin);
  if (!pin) {
    logNetwork("pinAuth.invalid", { ...socketLogFields(state), reason: "missing_pin" });
    send(state, { kind: "pinAuthRejected", reason: "Missing PIN" });
    return;
  }
  const pinState = pendingPINs.get(pin);
  if (!pinState) {
    logNetwork("pinAuth.invalid", { ...socketLogFields(state), reason: "invalid_pin" });
    send(state, { kind: "pinAuthRejected", reason: "Invalid PIN" });
    return;
  }
  if (pinState.expiresAt <= Date.now()) {
    pendingPINs.delete(pin);
    logNetwork("pinAuth.expired", { ...socketLogFields(state) });
    send(state, { kind: "pinAuthRejected", reason: "PIN expired" });
    return;
  }
  if (pinState.attempts >= pinAttemptsLimit) {
    pendingPINs.delete(pin);
    logNetwork("pinAuth.too_many_attempts", { ...socketLogFields(state) });
    send(state, { kind: "pinAuthRejected", reason: "Too many attempts" });
    return;
  }
  const room = rooms.get(pinState.roomID);
  if (!room || !room.host) {
    pendingPINs.delete(pin);
    logNetwork("pinAuth.rejected", { ...socketLogFields(state), reason: "room_not_found" });
    send(state, { kind: "pinAuthRejected", reason: "Host not available" });
    return;
  }
  pinState.attempts += 1;
  if (pinState.attempts < pinAttemptsLimit) {
    const remaining = pinAttemptsLimit - pinState.attempts;
    send(room.host, { kind: "pinAuthFailed", roomID: pinState.roomID, attemptsRemaining: remaining });
  } else {
    pendingPINs.delete(pin);
  }
  if (pinState.attempts === pinAttemptsLimit) {
    logNetwork("pinAuth.rejected.too_many", { ...socketLogFields(state) });
    send(state, { kind: "pinAuthRejected", reason: "Too many failed attempts" });
    return;
  }
  logNetwork("pinAuth.success", { ...socketLogFields(state) });
  send(state, { kind: "pinAuthAccepted", roomID: pinState.roomID });
  send(room.host, { kind: "pinAuthSuccess", roomID: pinState.roomID, guestParticipantID: state.participantID });
}

function relayGuestSignal(state, message) {
  const room = state.roomID ? rooms.get(state.roomID) : null;
  if (state.role !== "guest" || !room?.host) {
    logNetwork("guest.signal.rejected", { ...socketLogFields(state), reason: "not_connected_or_no_host" });
    send(state, { kind: "error", reason: "Not connected to host" });
    return;
  }
  logNetwork("guest.signal.relayed", { ...socketLogFields(state), signalKind: message.peerSignal?.kind ?? "unknown" });
  send(room.host, { ...message, roomID: state.roomID, fromParticipantID: state.participantID });
}

function relayHostSignal(state, message) {
  const roomID = stringValue(message.roomID ?? state.roomID);
  const room = roomID ? rooms.get(roomID) : null;
  if (state.role !== "host" || !room || room.host !== state) {
    logNetwork("host.signal.rejected", { ...socketLogFields(state), kind: message.kind ?? "unknown", reason: "not_host" });
    send(state, { kind: "error", reason: "Not registered as host" });
    return;
  }
  const participantID = stringValue(message.toParticipantID);
  if (participantID && room.guests.has(participantID)) {
    logNetwork("host.signal.relayed", { ...socketLogFields(state), kind: message.peerSignal?.kind ?? "unknown", participantID });
    send(room.guests.get(participantID), { ...message, roomID, toParticipantID: participantID });
  } else if (message.toAllGuests) {
    logNetwork("host.signal.broadcast", { ...socketLogFields(state), kind: message.peerSignal?.kind ?? "unknown", guests: room.guests.size });
    for (const guest of room.guests.values()) {
      send(guest, { ...message, roomID, toParticipantID: guest.participantID });
    }
  }
}

function send(state, message) {
  if (!state || state.socket.destroyed) return;
  logMessageFlow("out", state, message);
  sendFrame(state.socket, 0x1, Buffer.from(JSON.stringify({ protocolVersion: 1, sentAtEpochMilliseconds: Date.now(), ...message }), "utf8"));
}

function sendFrame(socket, opcode, payload) {
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.from([0x80 | opcode, length]);
  } else if (length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeUInt32BE(0, 2);
    header.writeUInt32BE(length, 6);
  }
  socket.write(Buffer.concat([header, payload]));
}

function broadcast(room, message, except = null) {
  if (room.host && room.host !== except) send(room.host, message);
  for (const guest of room.guests.values()) {
    if (guest !== except) send(guest, message);
  }
}

function closeRoom(roomID, reason = "closed") {
  const room = rooms.get(roomID);
  if (!room) return;
  logNetwork("room.closed", { roomID, hostConnected: Boolean(room.host), guests: room.guests.size });
  if (room.host) room.host.roomID = null;
  for (const guest of room.guests.values()) guest.roomID = null;
  rooms.delete(roomID);
  sendBrokerStats();
}

function roomFor(roomID) {
  const existing = rooms.get(roomID);
  if (existing) return existing;
  const room = { host: null, guests: new Map(), createdAtMs: Date.now(), maxGuests: 0 };
  rooms.set(roomID, room);
  return room;
}

function generatePIN() {
  const digits = [];
  for (let i = 0; i < 6; i++) {
    digits.push(String(Math.floor(Math.random() * 10)));
  }
  return digits.join("");
}

function brokerStats() {
  const allRooms = Array.from(rooms.values());
  const activeRooms = allRooms.filter(room => room.host !== null);
  return {
    kind: "remoteCoOpDirectBrokerStats",
    activeSessions: activeRooms.length,
    activeGuests: activeRooms.reduce((total, room) => total + room.guests.size, 0),
    totalRooms: allRooms.length,
    updatedAt: new Date().toISOString()
  };
}

function sendBrokerStats() {
  if (typeof process.send === "function") process.send(brokerStats());
}

function stringValue(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function logMessageFlow(direction, state, message) {
  if (!messageFlowLoggingEnabled) return;
  const participantID = stringValue(message.participantID) ?? "none";
  const roomID = stringValue(message.roomID ?? state.roomID) ?? "none";
  const signalKind = message.peerSignal?.kind ? ` signal=${message.peerSignal.kind}` : "";
  console.log(`[flow] ${direction} role=${state.role} kind=${message.kind ?? "unknown"}${signalKind} room=${roomID} participant=${participantID}`);
}

function logNetwork(event, fields = {}) {
  if (!networkLoggingEnabled) return;
  const details = Object.entries(fields)
    .filter(([, value]) => value !== null && value !== undefined && value !== "")
    .map(([key, value]) => `${key}=${logValue(value)}`)
    .join(" ");
  console.log(`[network] ${new Date().toISOString()} event=${event}${details ? ` ${details}` : ""}`);
}

function socketLogFields(state) {
  return {
    socketID: state.id,
    remote: socketAddress(state.socket),
    role: state.role,
    roomID: state.roomID ?? "none",
    participantID: state.participantID ?? "none"
  };
}

function socketAddress(socket) {
  return `${socket.remoteAddress ?? "unknown"}:${socket.remotePort ?? "unknown"}`;
}

function logValue(value) {
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) return JSON.stringify(value.map(String));
  return JSON.stringify(String(value));
}

function isRateLimited(state) {
  const now = Date.now();
  state.messageTimes = state.messageTimes.filter(time => now - time < rateLimitWindowMs);
  state.messageTimes.push(now);
  return state.messageTimes.length > rateLimitMaxMessages;
}

function splitEnv(name, fallback) {
  return (environmentValue(name) ?? fallback)
    .split(",")
    .map(value => value.trim())
    .filter(Boolean);
}

function integerEnv(name, fallback) {
  const value = Number.parseInt(environmentValue(name) ?? "", 10);
  return Number.isFinite(value) ? value : fallback;
}

function stringEnv(name, fallback) {
  const value = environmentValue(name);
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function booleanEnv(name, fallback) {
  const value = environmentValue(name);
  if (typeof value !== "string") return fallback;
  return !["0", "false", "no", "off", ""].includes(value.trim().toLowerCase());
}

function environmentValue(name) {
  const value = process.env[name];
  if (typeof value === "string" && value.trim()) return value;
  return undefined;
}

function portCandidates(preferredPort, alternateValue) {
  const parsedAlternates = typeof alternateValue === "string" && alternateValue.trim()
    ? alternateValue.split(",").map(value => Number.parseInt(value.trim(), 10))
    : [preferredPort + 1, preferredPort + 2];
  const candidates = Array.from(new Set([preferredPort, ...parsedAlternates].filter(isUsablePort)));
  return candidates.length > 0 ? candidates : [32189, 32190, 32191];
}

function isUsablePort(value) {
  return Number.isInteger(value) && value > 0 && value <= 65_535;
}

async function makeDirectBrokerServer(handler) {
  if (!brokerTLSEnabled) return createHTTPServer(handler);
  try {
    return createHTTPSServer({ cert: await readFile(brokerCertificatePath), key: await readFile(brokerKeyPath) }, handler);
  } catch (error) {
    console.error(`PixelNOW Remote Co-Op direct broker failed to load HTTPS certificate/key: ${error.message}`);
    process.exit(1);
  }
}
