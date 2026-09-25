const elements = {
  title: document.querySelector("#title"),
  subtitle: document.querySelector("#subtitle"),
  joinCard: document.querySelector("#join-card"),
  sessionCard: document.querySelector("#session-card"),
  inviteCode: document.querySelector("#invite-code"),
  inviteSource: document.querySelector("#invite-source"),
  displayName: document.querySelector("#display-name"),
  joinButton: document.querySelector("#join-button"),
  joinStatus: document.querySelector("#join-status"),
  modeSwitcher: document.querySelector("#mode-switcher"),
  directHostIP: document.querySelector("#direct-host-ip"),
  directPIN: document.querySelector("#direct-pin"),
  directDiscoverButton: document.querySelector("#direct-discover-button"),
  directManualButton: document.querySelector("#direct-manual-button"),
  directConnectButton: document.querySelector("#direct-connect-button"),
  directStatus: document.querySelector("#direct-status")
  state: document.querySelector("#session-state"),
  detail: document.querySelector("#session-detail"),
  dot: document.querySelector("#connection-dot"),
  gamepadName: document.querySelector("#gamepad-name"),
  gamepadDetail: document.querySelector("#gamepad-detail"),
  networkState: document.querySelector("#network-state"),
  networkDetail: document.querySelector("#network-detail"),
  diagnosticsPanel: document.querySelector("#diagnostics-panel"),
  diagnosticsToggle: document.querySelector("#diagnostics-toggle"),
  diagnosticsList: document.querySelector("#diagnostics-list"),
  copyDiagnosticsButton: document.querySelector("#copy-diagnostics-button"),
  playerBadge: document.querySelector("#player-badge"),
  playerNumber: document.querySelector("#player-number"),
  disconnectButton: document.querySelector("#disconnect-button"),
  modeSwitcher: document.querySelector("#mode-switcher"),
  directHostIP: document.querySelector("#direct-host-ip"),
  directPIN: document.querySelector("#direct-pin"),
  directDiscoverButton: document.querySelector("#direct-discover-button"),
  directManualButton: document.querySelector("#direct-manual-button"),
  directConnectButton: document.querySelector("#direct-connect-button"),
  directStatus: document.querySelector("#direct-status")
};

const url = new URL(window.location.href);
const inviteFromURL = url.searchParams.get("invite") ?? "";
let inviteToken = inviteFromURL.trim();
const serverFromURL = url.searchParams.get("server") ?? "";
let socket = null;
let invite = parseInvite(inviteToken);
const participantID = createParticipantID();
let approved = false;
let sequenceNumber = 0;
let lastSentState = "";
let lastSentAt = 0;
let lastInputChangedAt = 0;
let inputHistory = [];
let pollHandle = null;
let pollMode = "stopped";
let networkConfiguration = null;
let peerConnection = null;
let inputChannel = null;
let statsHandle = 0;
let diagnostics = initialDiagnostics();
let sessionState = "Connecting";
const playbackPromises = new WeakMap();
let connectionMode = "invite";
let directConnection = null;

renderInvite(inviteToken);
renderDiagnostics();
if (inviteFromURL && elements.inviteCode) elements.inviteCode.readOnly = true;

elements.modeSwitcher?.addEventListener("change", switchConnectionMode);
elements.directDiscoverButton?.addEventListener("click", discoverHostByPIN);
elements.directManualButton?.addEventListener("click", showManualIP);
elements.directConnectButton?.addEventListener("click", directConnect);
elements.inviteCode?.addEventListener("input", () => {
  if (!inviteFromURL) normalizeInviteCodeInput();
  renderInvite(currentInviteToken());
});
elements.joinButton.addEventListener("click", joinRoom);
elements.diagnosticsToggle?.addEventListener("click", toggleDiagnostics);
elements.copyDiagnosticsButton?.addEventListener("click", event => {
  event.preventDefault();
  event.stopPropagation();
  copyDiagnostics();
});
elements.disconnectButton?.addEventListener("click", disconnect);
window.addEventListener("gamepadconnected", event => {
  if (elements.gamepadName) elements.gamepadName.textContent = event.gamepad.id;
  if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Ready";
  updateDiagnostics({ input: "controller connected" });
});
window.addEventListener("pagehide", disconnect);
document.addEventListener("visibilitychange", restartPollingIfActive);

function renderInvite(token) {
  invite = parseInvite(token);
  if (!invite) {
    if (elements.title) elements.title.textContent = "CO-OP";
    if (elements.subtitle) elements.subtitle.textContent = "Enter an invite code and join.";
    if (elements.inviteSource) elements.inviteSource.textContent = inviteFromURL ? "INVALID" : "REMOTE CO-OP";
    if (elements.networkState) elements.networkState.textContent = "CODE";
    if (elements.networkDetail) elements.networkDetail.textContent = "Automatic";
    elements.joinStatus.textContent = token ? "Invalid" : "Code required";
    elements.joinButton.disabled = true;
    return;
  }
  inviteToken = token.trim();
  const visibleInviteToken = inviteFromURL ? invite.code ?? "LINK" : displayInviteToken(inviteToken);
  if (elements.inviteCode && elements.inviteCode.value.trim() !== visibleInviteToken) {
    elements.inviteCode.value = visibleInviteToken;
  }
  const roomLabel = invite.code ?? invite.inviteID ?? "ready";
  if (elements.title) elements.title.textContent = "CO-OP";
  if (elements.subtitle) elements.subtitle.textContent = `Room ${roomLabel}.`;
  if (elements.inviteSource) elements.inviteSource.textContent = inviteFromURL ? "LINK" : "READY";
  if (elements.networkState) elements.networkState.textContent = "READY";
  if (elements.networkDetail) elements.networkDetail.textContent = networkModeLabel(invite.transportMode);
  elements.joinStatus.textContent = "Ready";
  elements.joinButton.disabled = false;
}

function joinRoom() {
  inviteToken = currentInviteToken();
  invite = parseInvite(inviteToken);
  if (!invite) {
    elements.joinStatus.textContent = "Invalid";
    elements.joinButton.disabled = true;
    return;
  }
  if (invite.expiresAtEpochSeconds * 1000 <= Date.now()) {
    elements.joinStatus.textContent = "Expired";
    return;
  }
  const endpoint = signalingEndpoint();
  resetInputHistory();
  diagnostics = initialDiagnostics();
  updateDiagnostics({ websocket: `connecting ${endpoint}`, transportMode: invite.transportMode ?? "automatic" });
  socket = new WebSocket(endpoint);
  elements.joinButton.disabled = true;
  elements.joinStatus.textContent = "Connecting";
  socket.addEventListener("open", () => {
    updateDiagnostics({ websocket: "open" });
    send({
      kind: "guestJoinRequested",
      roomID: inviteRoomID(),
      participantID,
      inviteToken,
      displayName: displayName()
    });
    elements.joinCard.classList.add("hidden");
    elements.sessionCard.classList.remove("hidden");
    setState("Waiting", "Host", false);
  });
  socket.addEventListener("message", event => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch (error) {
      updateDiagnostics({ websocket: "invalid message" });
      setNetworkState("Error", "Broker");
      return;
    }
    handleMessage(message).catch(error => {
      setNetworkState("Error", "Peer");
      updateDiagnostics({ signaling: error.message || "WebRTC negotiation failed" });
    });
  });
  socket.addEventListener("close", () => {
    stopPolling();
    updateDiagnostics({ websocket: "closed" });
    if (!hasTerminalState()) setState("Closed", "Offline", false);
    elements.joinButton.disabled = false;
  });
  socket.addEventListener("error", () => updateDiagnostics({ websocket: "error" }));
}

async function handleMessage(message) {
  if (message.kind === "heartbeat") {
    if (message.roomID && invite) invite.inviteID = message.roomID;
    send({ kind: "heartbeat", roomID: inviteRoomID(), participantID });
    return;
  }
  if (message.kind === "networkConfiguration") {
    if (message.roomID && invite) invite.inviteID = message.roomID;
    updateDiagnostics({ signaling: "network configuration received" });
    configurePeerConnection(message.networkConfiguration);
    return;
  }
  if (message.kind === "peerSignal") {
    if (!isForThisParticipant(message)) return;
    updateDiagnostics({ signaling: `peer signal ${message.peerSignal?.kind ?? "unknown"}` });
    await handlePeerSignal(message.peerSignal);
    return;
  }
  if (message.kind === "participantUpdated" && sameParticipantID(message.participant?.id, participantID)) {
    approved = message.participant.connectionState === "connected" && message.participant.inputEnabled === true;
    if (approved) {
      const playerNumber = (message.participant.playerIndex ?? 1) + 1;
      setState("Approved", `P${playerNumber}`, true, playerNumber);
      updateDiagnostics({ approval: "approved", playerSlot: `player ${playerNumber}` });
      startPolling();
    } else {
      setState("Waiting", "Host", false);
      updateDiagnostics({ approval: "waiting" });
    }
    return;
  }
  if (message.kind === "participantRemoved") {
    if (!isForThisParticipant(message)) return;
    setState("Removed", "Host", false);
    updateDiagnostics({ approval: "removed" });
    disconnect();
    return;
  }
  if (message.kind === "guestRejected") {
    if (!isForThisParticipant(message)) return;
    setState("Rejected", message.reason ?? "Host", false);
    updateDiagnostics({ approval: `rejected: ${message.reason ?? "host rejected join"}` });
    disconnect(false);
    return;
  }
  if (message.kind === "inputRejected") {
    if (!isForThisParticipant(message)) return;
    if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Rejected";
    updateDiagnostics({ input: `rejected: ${message.inputRejection ?? "unknown"}` });
    return;
  }
  if (message.kind === "inviteEnded") {
    setState("Ended", message.reason ?? "Host", false);
    updateDiagnostics({ approval: `ended: ${message.reason ?? "host ended invite"}` });
    disconnect();
  }
}

function isForThisParticipant(message) {
  const target = message.participantID ?? message.participant?.id;
  return !target || sameParticipantID(target, participantID);
}

function sameParticipantID(left, right) {
  return typeof left === "string" && typeof right === "string" && left.toLowerCase() === right.toLowerCase();
}

function startPolling() {
  if (pollHandle) return;
  const poll = time => {
    if (!approved || socket?.readyState !== WebSocket.OPEN) return;
    const gamepad = navigator.getGamepads().find(Boolean);
    if (!gamepad) {
      if (elements.gamepadName) elements.gamepadName.textContent = "Controller";
      if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Waiting";
      return;
    }
    if (elements.gamepadName) elements.gamepadName.textContent = gamepad.id;
    const input = inputPacket(gamepad, time);
    const state = inputStateKey(input);
    const changed = state !== lastSentState;
    if (changed) lastInputChangedAt = time;
    if (!changed && !shouldSendUnchangedInput(time)) return;
    lastSentState = state;
    lastSentAt = time;
    sendInput(input);
    if (elements.gamepadDetail) elements.gamepadDetail.textContent = "Live";
  };
  const interval = inputPollIntervalMilliseconds();
  if (interval > 0) {
    pollMode = "interval";
    pollHandle = window.setInterval(() => poll(performance.now()), interval);
    updateDiagnostics({ inputSampling: `${Math.round(1_000 / interval)} Hz interval` });
    poll(performance.now());
    return;
  }
  pollMode = "animationFrame";
  updateDiagnostics({ inputSampling: "display frame" });
  const frame = time => {
    poll(time);
    pollHandle = requestAnimationFrame(frame);
  };
  pollHandle = requestAnimationFrame(frame);
}

function stopPolling() {
  if (!pollHandle) return;
  if (pollMode === "interval") {
    clearInterval(pollHandle);
  } else {
    cancelAnimationFrame(pollHandle);
  }
  pollHandle = null;
  pollMode = "stopped";
  updateDiagnostics({ inputSampling: "stopped" });
}

function restartPollingIfActive() {
  if (!approved || !pollHandle) return;
  stopPolling();
  startPolling();
}

function inputPollIntervalMilliseconds() {
  if (latencyMode() !== "lowLatency") return 0;
  return document.visibilityState === "visible" ? 4 : 16;
}

function shouldSendUnchangedInput(time) {
  if (latencyMode() !== "lowLatency") return time - lastSentAt >= 250;
  return time - lastInputChangedAt <= inputRecoveryWindowMilliseconds();
}

function inputHistoryLimit() {
  return latencyMode() === "lowLatency" ? 8 : 1;
}

function inputRecoveryWindowMilliseconds() {
  return 96;
}

function inputPacket(gamepad, sampledAtMilliseconds = performance.now()) {
  return {
    participantID,
    sequenceNumber: ++sequenceNumber,
    buttons: buttonMask(gamepad),
    leftTrigger: analogButton(gamepad, 6),
    rightTrigger: analogButton(gamepad, 7),
    leftStickX: axis(gamepad, 0),
    leftStickY: axis(gamepad, 1),
    rightStickX: axis(gamepad, 2),
    rightStickY: axis(gamepad, 3),
    sentAtNanoseconds: Math.round(sampledAtMilliseconds * 1_000_000),
    sampledAtMilliseconds
  };
}

function inputStateKey(input) {
  return JSON.stringify({
    buttons: input.buttons,
    leftTrigger: input.leftTrigger,
    rightTrigger: input.rightTrigger,
    leftStickX: input.leftStickX,
    leftStickY: input.leftStickY,
    rightStickX: input.rightStickX,
    rightStickY: input.rightStickY
  });
}

function buttonMask(gamepad) {
  const map = new Map([[0, 0], [1, 1], [2, 2], [3, 3], [4, 4], [5, 5], [8, 6], [9, 7], [10, 8], [11, 9], [12, 10], [13, 11], [14, 12], [15, 13]]);
  let mask = 0;
  for (const [buttonIndex, bit] of map) {
    if (gamepad.buttons[buttonIndex]?.pressed) mask |= 1 << bit;
  }
  return mask;
}

function analogButton(gamepad, index) {
  const value = gamepad.buttons[index]?.value ?? 0;
  return clamp(value, 0, 1);
}

function axis(gamepad, index) {
  return clamp(gamepad.axes[index] ?? 0, -1, 1);
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, Number.isFinite(value) ? value : 0));
}

function send(message) {
  if (socket?.readyState !== WebSocket.OPEN) return;
  socket.send(JSON.stringify({ protocolVersion: 1, sentAtEpochMilliseconds: Date.now(), ...message }));
}

function sendInput(input) {
  const sampledAtMilliseconds = input.sampledAtMilliseconds ?? performance.now();
  const wireInput = { ...input };
  delete wireInput.sampledAtMilliseconds;
  pushInputHistory(wireInput);
  const message = { kind: "guestInput", roomID: inviteRoomID(), participantID, input: wireInput, inputs: inputHistory };
  if (inputChannel?.readyState === "open") {
    inputChannel.send(JSON.stringify({ protocolVersion: 1, sentAtEpochMilliseconds: Date.now(), ...message }));
    recordInputSent(input, "data channel", sampledAtMilliseconds);
    return;
  }
  if (networkConfiguration?.websocketInputFallbackEnabled !== false && latencyMode() !== "lowLatency") {
    send({ kind: "guestInput", roomID: inviteRoomID(), participantID, input: wireInput });
    recordInputSent(input, "WebSocket fallback", sampledAtMilliseconds);
  } else {
    updateDiagnostics({ input: "blocked: waiting for low latency data channel" });
  }
}

function pushInputHistory(input) {
  inputHistory.push(input);
  inputHistory = inputHistory.slice(-inputHistoryLimit());
}

function resetInputHistory() {
  sequenceNumber = 0;
  lastSentState = "";
  lastSentAt = 0;
  lastInputChangedAt = 0;
  inputHistory = [];
}

function configurePeerConnection(configuration) {
  networkConfiguration = configuration ?? automaticFallbackConfiguration();
  closePeerConnection();
  updateDiagnostics({
    transportMode: networkConfiguration.transportMode ?? "automatic",
    latencyMode: latencyMode(),
    icePolicy: networkConfiguration.iceTransportPolicy ?? "all",
    iceServers: describeIceServers(networkConfiguration.iceServers ?? []),
    localCandidates: 0,
    remoteCandidates: 0,
    selectedRoute: "waiting",
    inputChannel: networkConfiguration.dataChannelInputEnabled === false ? "disabled by configuration" : "creating",
    signaling: "creating peer connection"
  });
  const rtcConfiguration = {
    iceServers: networkConfiguration.iceServers ?? [],
    iceTransportPolicy: networkConfiguration.iceTransportPolicy ?? "all"
  };
  peerConnection = new RTCPeerConnection(rtcConfiguration);
  configureReceiverLatency(peerConnection.addTransceiver("video", { direction: "recvonly" }).receiver);
  configureReceiverLatency(peerConnection.addTransceiver("audio", { direction: "recvonly" }).receiver);
  if (networkConfiguration.dataChannelInputEnabled !== false) bindInputChannel(peerConnection.createDataChannel("input", { ordered: false, maxRetransmits: 0 }));
  peerConnection.addEventListener("datachannel", event => bindInputChannel(event.channel));
  peerConnection.addEventListener("icecandidate", event => {
    if (!event.candidate) return;
    updateDiagnostics({ localCandidates: diagnostics.localCandidates + 1 });
    send({
      kind: "peerSignal",
      roomID: inviteRoomID(),
      participantID,
      peerSignal: {
        kind: "iceCandidate",
        candidate: event.candidate.candidate,
        sdpMid: event.candidate.sdpMid,
        sdpMLineIndex: event.candidate.sdpMLineIndex
      }
    });
  });
  peerConnection.addEventListener("connectionstatechange", () => updatePeerConnectionState());
  peerConnection.addEventListener("iceconnectionstatechange", () => updatePeerConnectionState());
  peerConnection.addEventListener("icegatheringstatechange", () => updatePeerConnectionState());
  peerConnection.addEventListener("signalingstatechange", () => updatePeerConnectionState());
  peerConnection.addEventListener("track", event => attachRemoteTrack(event.track, event.receiver));
  setNetworkState(networkLabel(), networkConfiguration.directPeerCandidateWarning || connectionDetail());
  updatePeerConnectionState();
  startStatsPolling();
}

async function handlePeerSignal(signal) {
  if (!signal) return;
  if (!peerConnection) configurePeerConnection(automaticFallbackConfiguration());
  if (signal.kind === "offer") {
    updateDiagnostics({ signaling: "offer received" });
    await peerConnection.setRemoteDescription({ type: "offer", sdp: signal.sdp });
    const answer = await peerConnection.createAnswer();
    await peerConnection.setLocalDescription(answer);
    send({ kind: "peerSignal", roomID: inviteRoomID(), participantID, peerSignal: { kind: "answer", sdp: answer.sdp } });
    setNetworkState(networkLabel(), "ICE");
    updateDiagnostics({ signaling: "answer sent" });
    return;
  }
  if (signal.kind === "answer") {
    await peerConnection.setRemoteDescription({ type: "answer", sdp: signal.sdp });
    updateDiagnostics({ signaling: "answer received" });
    return;
  }
  if (signal.kind === "iceCandidate" && signal.candidate) {
    updateDiagnostics({ remoteCandidates: diagnostics.remoteCandidates + 1, signaling: "remote ICE candidate received" });
    await peerConnection.addIceCandidate({ candidate: signal.candidate, sdpMid: signal.sdpMid ?? null, sdpMLineIndex: signal.sdpMLineIndex ?? null });
  }
}

function bindInputChannel(channel) {
  inputChannel = channel;
  updateDiagnostics({ inputChannel: `${channel.label || "input"} ${channel.readyState}` });
  channel.addEventListener("open", () => {
    setNetworkState(networkLabel(), "Input data channel connected.");
    updateDiagnostics({ inputChannel: `${channel.label || "input"} open`, input: "data channel ready" });
  });
  channel.addEventListener("close", () => {
    setNetworkState(networkLabel(), "Fallback");
    updateDiagnostics({ inputChannel: `${channel.label || "input"} closed` });
  });
  channel.addEventListener("error", () => updateDiagnostics({ inputChannel: `${channel.label || "input"} error` }));
}

function closePeerConnection() {
  stopStatsPolling();
  inputChannel?.close();
  inputChannel = null;
  peerConnection?.close();
  peerConnection = null;
  updateDiagnostics({ rtcConnection: "closed", iceConnection: "closed", inputChannel: "closed" });
}

function automaticFallbackConfiguration() {
  const mode = invite?.latencyMode ?? "quality";
  return {
    transportMode: invite?.transportMode ?? "automatic",
    iceTransportPolicy: invite?.transportMode === "relayOnly" ? "relay" : "all",
    latencyMode: mode,
    iceServers: [],
    dataChannelInputEnabled: true,
    websocketInputFallbackEnabled: mode !== "lowLatency",
    directPeerCandidateWarning: "Using invite defaults until the broker provides ICE settings."
  };
}

function networkLabel() {
  const mode = networkConfiguration?.transportMode ?? invite?.transportMode ?? "automatic";
  if (mode === "relayOnly") return "Relay";
  if (mode === "directOnly") return "Direct";
  return "Auto";
}

function connectionDetail() {
  const connection = peerConnection?.connectionState ?? "new";
  const ice = peerConnection?.iceConnectionState ?? "new";
  return `${connection}/${ice}`;
}

function setNetworkState(title, detail) {
  if (elements.networkState) elements.networkState.textContent = title;
  if (elements.networkDetail) elements.networkDetail.textContent = detail;
}

function initialDiagnostics() {
  return {
    websocket: "idle",
    approval: "not joined",
    playerSlot: "unassigned",
    transportMode: invite?.transportMode ?? "automatic",
    latencyMode: invite?.latencyMode ?? "quality",
    playoutDelay: "default",
    icePolicy: "all",
    iceServers: "not received",
    rtcConnection: "not started",
    rtcSignaling: "not started",
    iceConnection: "not started",
    iceGathering: "not started",
    signaling: "idle",
    localCandidates: 0,
    remoteCandidates: 0,
    selectedRoute: "not selected",
    inputChannel: "not created",
    input: "waiting",
    inputSampling: "stopped",
    inputPackets: 0,
    lastInputSequence: 0,
    lastInputSentAt: 0,
    lastInputSampleToSendMs: 0,
    video: "waiting",
    audio: "waiting",
    stats: "waiting"
  };
}

function updateDiagnostics(patch) {
  diagnostics = { ...diagnostics, ...patch };
  renderDiagnostics();
}

function renderDiagnostics() {
  if (!elements.diagnosticsList) return;
  const fragment = document.createDocumentFragment();
  for (const [label, value] of diagnosticsRows()) {
    const title = document.createElement("dt");
    title.textContent = label;
    const detail = document.createElement("dd");
    detail.textContent = value;
    fragment.append(title, detail);
  }
  elements.diagnosticsList.replaceChildren(fragment);
}

function diagnosticsRows() {
  return [
    ["WebSocket", diagnostics.websocket],
    ["Approval", `${diagnostics.approval}; ${diagnostics.playerSlot}`],
    ["Transport", `${diagnostics.transportMode}; ${diagnostics.latencyMode}; policy ${diagnostics.icePolicy}; ${diagnostics.iceServers}`],
    ["WebRTC", `connection ${diagnostics.rtcConnection}; signaling ${diagnostics.rtcSignaling}; ICE ${diagnostics.iceConnection}; gathering ${diagnostics.iceGathering}`],
    ["Signaling", diagnostics.signaling],
    ["Candidates", `local ${diagnostics.localCandidates}; remote ${diagnostics.remoteCandidates}`],
    ["Selected route", diagnostics.selectedRoute],
    ["Media", `video ${diagnostics.video}; audio ${diagnostics.audio}; playout ${diagnostics.playoutDelay}`],
    ["Input", inputDiagnosticsDetail()],
    ["Stats", diagnostics.stats]
  ];
}

function inputDiagnosticsDetail() {
  if (!diagnostics.lastInputSentAt) return `${diagnostics.input}; sampling ${diagnostics.inputSampling}; channel ${diagnostics.inputChannel}; 0 packets`;
  const ageMilliseconds = Math.max(0, Math.round(performance.now() - diagnostics.lastInputSentAt));
  return `${diagnostics.input}; sampling ${diagnostics.inputSampling}; channel ${diagnostics.inputChannel}; ${diagnostics.inputPackets} packets; last sequence ${diagnostics.lastInputSequence}; sample-to-send ${diagnostics.lastInputSampleToSendMs} ms; ${ageMilliseconds} ms ago`;
}

async function copyDiagnostics() {
  const text = diagnosticsRows().map(([label, value]) => `${label}: ${value}`).join("\n");
  try {
    await navigator.clipboard.writeText(text);
    if (!elements.copyDiagnosticsButton) return;
    const previous = elements.copyDiagnosticsButton.textContent;
    elements.copyDiagnosticsButton.textContent = "Copied";
    setTimeout(() => { elements.copyDiagnosticsButton.textContent = previous; }, 1_200);
  } catch (error) {
    updateDiagnostics({ stats: `copy failed: ${error.message || "clipboard unavailable"}` });
  }
}

function toggleDiagnostics() {
  if (!elements.diagnosticsPanel || !elements.diagnosticsToggle) return;
  const isOpen = elements.diagnosticsToggle.getAttribute("aria-expanded") === "true";
  elements.diagnosticsToggle.setAttribute("aria-expanded", String(!isOpen));
  elements.diagnosticsPanel.hidden = isOpen;
}

function updatePeerConnectionState() {
  if (!peerConnection) return;
  updateDiagnostics({
    rtcConnection: peerConnection.connectionState ?? "unknown",
    rtcSignaling: peerConnection.signalingState ?? "unknown",
    iceConnection: peerConnection.iceConnectionState ?? "unknown",
    iceGathering: peerConnection.iceGatheringState ?? "unknown"
  });
  setNetworkState(networkLabel(), connectionDetail());
}

function recordInputSent(input, transport, sampledAtMilliseconds = performance.now()) {
  updateDiagnostics({
    input: transport,
    inputPackets: diagnostics.inputPackets + 1,
    lastInputSequence: input.sequenceNumber,
    lastInputSentAt: performance.now(),
    lastInputSampleToSendMs: Math.max(0, Math.round((performance.now() - sampledAtMilliseconds) * 10) / 10)
  });
}

function currentInviteToken() {
  if (inviteFromURL) return inviteFromURL.trim();
  return elements.inviteCode?.value.trim().toUpperCase() ?? "";
}

function normalizeInviteCodeInput() {
  if (!elements.inviteCode) return;
  const normalized = elements.inviteCode.value.toUpperCase().replace(/[^A-Z0-9.\-_]/g, "");
  if (elements.inviteCode.value !== normalized) elements.inviteCode.value = normalized;
}

function displayInviteToken(token) {
  const trimmed = token.trim();
  return /^[A-Z0-9]{6}$/i.test(trimmed) ? trimmed.toUpperCase() : trimmed;
}

function networkModeLabel(mode) {
  if (mode === "relayOnly") return "Relay";
  if (mode === "directOnly") return "Direct";
  return "Auto";
}

function describeIceServers(servers) {
  const counts = { stun: 0, turn: 0, turns: 0 };
  for (const server of servers) {
    for (const value of iceServerURLs(server)) {
      if (value.startsWith("stun:")) counts.stun += 1;
      if (value.startsWith("turn:")) counts.turn += 1;
      if (value.startsWith("turns:")) counts.turns += 1;
    }
  }
  const parts = [];
  if (counts.stun > 0) parts.push(`${counts.stun} STUN`);
  if (counts.turn > 0) parts.push(`${counts.turn} TURN`);
  if (counts.turns > 0) parts.push(`${counts.turns} TURNS`);
  return parts.length > 0 ? parts.join(", ") : "no ICE servers";
}

function iceServerURLs(server) {
  if (Array.isArray(server.urls)) return server.urls;
  return typeof server.urls === "string" ? [server.urls] : [];
}

function startStatsPolling() {
  if (statsHandle) return;
  samplePeerStats();
  statsHandle = setInterval(samplePeerStats, 1_500);
}

function stopStatsPolling() {
  if (!statsHandle) return;
  clearInterval(statsHandle);
  statsHandle = 0;
}

async function samplePeerStats() {
  if (!peerConnection) return;
  try {
    const report = await peerConnection.getStats();
    updateDiagnostics({
      selectedRoute: selectedRouteFromStats(report),
      stats: inboundStatsSummary(report)
    });
  } catch (error) {
    updateDiagnostics({ stats: `stats failed: ${error.message || "getStats failed"}` });
  }
}

function selectedRouteFromStats(report) {
  let pair = null;
  for (const stats of report.values()) {
    if (stats.type === "transport" && stats.selectedCandidatePairId) {
      pair = report.get(stats.selectedCandidatePairId);
      break;
    }
  }
  if (!pair) {
    for (const stats of report.values()) {
      if (stats.type === "candidate-pair" && (stats.selected || (stats.nominated && stats.state === "succeeded"))) {
        pair = stats;
        break;
      }
    }
  }
  if (!pair) return diagnostics.selectedRoute;
  const local = report.get(pair.localCandidateId);
  const remote = report.get(pair.remoteCandidateId);
  const rtt = typeof pair.currentRoundTripTime === "number" ? `; RTT ${Math.round(pair.currentRoundTripTime * 1_000)} ms` : "";
  return `${candidateSummary(local)} -> ${candidateSummary(remote)}${rtt}`;
}

function candidateSummary(candidate) {
  if (!candidate) return "unknown";
  const type = candidate.candidateType ?? "candidate";
  const protocol = candidate.protocol ? `/${candidate.protocol}` : "";
  const relay = candidate.relayProtocol ? `/${candidate.relayProtocol}` : "";
  return `${type}${protocol}${relay}`;
}

function inboundStatsSummary(report) {
  const parts = [];
  for (const stats of report.values()) {
    if (stats.type !== "inbound-rtp" || stats.isRemote) continue;
    const kind = stats.kind ?? stats.mediaType;
    if (kind === "video") parts.push(videoStatsSummary(stats));
    if (kind === "audio") parts.push(audioStatsSummary(stats));
  }
  return parts.length > 0 ? parts.join("; ") : diagnostics.stats;
}

function videoStatsSummary(stats) {
  const size = stats.frameWidth && stats.frameHeight ? `${stats.frameWidth}x${stats.frameHeight}` : "size pending";
  const fps = typeof stats.framesPerSecond === "number" ? `${Math.round(stats.framesPerSecond)} fps` : "fps pending";
  const loss = stats.packetsLost > 0 ? `, ${stats.packetsLost} lost` : "";
  const jitterFrames = stats.jitterBufferEmittedCount ?? 0;
  const jitterDelay = jitterFrames > 0 && typeof stats.jitterBufferDelay === "number" ? `, jitter buffer ${Math.round((stats.jitterBufferDelay / jitterFrames) * 1_000)} ms` : "";
  const decodedFrames = stats.framesDecoded ?? 0;
  const decodeDelay = decodedFrames > 0 && typeof stats.totalDecodeTime === "number" ? `, decode ${Math.round((stats.totalDecodeTime / decodedFrames) * 1_000)} ms` : "";
  const dropped = stats.framesDropped > 0 ? `, ${stats.framesDropped} dropped` : "";
  return `video ${size} ${fps}, ${formatBytes(stats.bytesReceived ?? 0)} received${loss}${dropped}${jitterDelay}${decodeDelay}`;
}

function audioStatsSummary(stats) {
  const jitter = typeof stats.jitter === "number" ? `, jitter ${Math.round(stats.jitter * 1_000)} ms` : "";
  const loss = stats.packetsLost > 0 ? `, ${stats.packetsLost} lost` : "";
  return `audio ${formatBytes(stats.bytesReceived ?? 0)} received${jitter}${loss}`;
}

function latencyMode() {
  return networkConfiguration?.latencyMode ?? invite?.latencyMode ?? "quality";
}

function configureReceiverLatency(receiver) {
  if (!receiver || latencyMode() !== "lowLatency") return;
  try {
    if ("playoutDelayHint" in receiver) {
      receiver.playoutDelayHint = 0;
      updateDiagnostics({ playoutDelay: "0 ms hint" });
    } else {
      updateDiagnostics({ playoutDelay: "unsupported" });
    }
  } catch (error) {
    updateDiagnostics({ playoutDelay: `hint failed: ${error.message || "unavailable"}` });
  }
}

function formatBytes(value) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)} MB`;
  if (value >= 1_000) return `${Math.round(value / 1_000)} KB`;
  return `${value} B`;
}

function updateMediaDiagnostics(track, media, state) {
  const descriptor = track.kind === "video" ? videoDescriptor(media, state) : audioDescriptor(track, state);
  updateDiagnostics(track.kind === "video" ? { video: descriptor } : { audio: descriptor });
}

function videoDescriptor(media, state) {
  const size = media.videoWidth && media.videoHeight ? ` ${media.videoWidth}x${media.videoHeight}` : "";
  return `${state}${size}`;
}

function audioDescriptor(track, state) {
  return `${state}; ${track.readyState}`;
}

function attachRemoteTrack(track, receiver) {
  configureReceiverLatency(receiver);
  const media = track.kind === "audio" ? remoteAudioElement() : remoteVideoElement();
  media.autoplay = true;
  media.playsInline = true;
  media.controls = false;
  media.muted = track.kind === "video";
  const stream = appendTrack(media.srcObject, track);
  if (media.srcObject !== stream) media.srcObject = stream;
  updateMediaDiagnostics(track, media, "attached");
  track.addEventListener("mute", () => updateMediaDiagnostics(track, media, "muted"));
  track.addEventListener("unmute", () => updateMediaDiagnostics(track, media, "live"));
  track.addEventListener("ended", () => updateMediaDiagnostics(track, media, "ended"));
  media.addEventListener("loadedmetadata", () => {
    updateMediaDiagnostics(track, media, "metadata loaded");
    requestMediaPlayback(track, media);
  });
  media.addEventListener("canplay", () => requestMediaPlayback(track, media));
  media.addEventListener("playing", () => updateMediaDiagnostics(track, media, "playing"));
  requestMediaPlayback(track, media);
}

function requestMediaPlayback(track, media, attempt = 0) {
  if (!media.play || (!media.paused && !media.ended) || playbackPromises.has(media)) return;
  const playback = media.play();
  if (!playback) return;
  playbackPromises.set(media, playback);
  playback.then(() => {
    if (playbackPromises.get(media) === playback) playbackPromises.delete(media);
    updateMediaDiagnostics(track, media, "playing");
  }).catch(error => {
    if (playbackPromises.get(media) === playback) playbackPromises.delete(media);
    const message = error?.message || "user gesture required";
    if (error?.name === "AbortError" && attempt < 5) {
      updateMediaDiagnostics(track, media, `play retry ${attempt + 1}: ${message}`);
      window.setTimeout(() => requestMediaPlayback(track, media, attempt + 1), 120 * (attempt + 1));
      return;
    }
    const prefix = error?.name === "NotAllowedError" ? "autoplay blocked" : "playback failed";
    updateMediaDiagnostics(track, media, `${prefix}: ${message}`);
  });
}

function remoteVideoElement() {
  const existing = document.querySelector("#remote-video");
  if (existing) return existing;
  const media = document.createElement("video");
  media.id = "remote-video";
  const container = document.querySelector(".video-placeholder");
  container?.classList.add("streaming");
  container?.replaceChildren(media);
  return media;
}

function remoteAudioElement() {
  const existing = document.querySelector("#remote-audio");
  if (existing) return existing;
  const media = document.createElement("audio");
  media.id = "remote-audio";
  document.body.append(media);
  return media;
}

function appendTrack(currentObject, track) {
  const mediaStream = currentObject instanceof MediaStream ? currentObject : new MediaStream();
  if (!mediaStream.getTracks().some(existing => existing.id === track.id)) mediaStream.addTrack(track);
  return mediaStream;
}

function disconnect(notifyHost = true) {
  approved = false;
  stopPolling();
  resetInputHistory();
  closePeerConnection();
  if (notifyHost && socket?.readyState === WebSocket.OPEN) send({ kind: "guestDisconnected", roomID: inviteRoomID(), participantID });
  socket?.close();
  socket = null;
}

function setState(title, detail, connected, playerNumber = null) {
  sessionState = title;
  if (elements.state) elements.state.textContent = title;
  if (elements.detail) elements.detail.textContent = detail;
  elements.dot?.classList.toggle("connected", connected);
  if (!elements.state && elements.networkState && elements.networkDetail) {
    elements.networkState.textContent = title;
    elements.networkDetail.textContent = detail;
  }
  updatePlayerBadge(title, playerNumber);
}

function hasTerminalState() {
  return ["Ended", "Rejected", "Removed"].includes(sessionState);
}

function updatePlayerBadge(state, playerNumber = null) {
  if (!elements.playerBadge || !elements.playerNumber) return;
  if (Number.isInteger(playerNumber)) {
    elements.playerNumber.textContent = `P${playerNumber}`;
    elements.playerBadge.setAttribute("aria-label", `Controller player ${playerNumber}`);
    return;
  }
  if (["Rejected", "Removed", "Ended", "Disconnected"].includes(state)) {
    elements.playerNumber.textContent = "!";
    elements.playerBadge.setAttribute("aria-label", state);
    return;
  }
  elements.playerNumber.textContent = "P?";
  elements.playerBadge.setAttribute("aria-label", "Waiting for controller assignment");
}

function displayName() {
  const value = elements.displayName.value.trim();
  return value.length > 0 ? value : "Guest";
}

function createParticipantID() {
  const cryptoProvider = globalThis.crypto;
  if (typeof cryptoProvider?.randomUUID === "function") return cryptoProvider.randomUUID();

  const bytes = new Uint8Array(16);
  if (typeof cryptoProvider?.getRandomValues === "function") {
    cryptoProvider.getRandomValues(bytes);
  } else {
    for (let index = 0; index < bytes.length; index += 1) bytes[index] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  return Array.from(bytes, (byte, index) => {
    const value = byte.toString(16).padStart(2, "0");
    return [4, 6, 8, 10].includes(index) ? `-${value}` : value;
  }).join("");
}

function signalingEndpoint() {
  if (serverFromURL) return serverFromURL;
  const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${window.location.host}/remote-coop`;
}

function inviteRoomID() {
  return invite?.inviteID || undefined;
}

function parseInvite(token) {
  const decoded = decodeInvite(token);
  if (decoded) return decoded;
  const code = token.trim().toUpperCase();
  if (!/^[A-Z0-9]{6}$/.test(code)) return null;
  return {
    inviteID: null,
    code,
    expiresAtEpochSeconds: Number.POSITIVE_INFINITY,
    requireHostApproval: true,
    transportMode: "automatic",
    latencyMode: "lowLatency"
  };
}

function decodeInvite(token) {
  const payload = token.trim().split(".")[0];
  if (!payload) return null;
  try {
    return JSON.parse(new TextDecoder().decode(base64URLDecode(payload)));
  } catch {
    return null;
  }
}

function base64URLDecode(value) {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(value.length + (4 - (value.length % 4 || 4)), "=");
  return Uint8Array.from(atob(base64), character => character.charCodeAt(0));
}

class DirectGuestConnection {
  #pin;
  #hostIP;
  #wsURL;
  #peerConnection;
  #dataChannel;
  #isConnected = false;
  #onConnected;
  #onDisconnected;
  #onError;
  #signalCallback;
  #iceCallback;
  #statsCallback;
  #candidateGathered = false;
  #ws = null;

  constructor(options = {}) {
    this.#pin = options.pin || null;
    this.#hostIP = options.hostIP || null;
    this.#onConnected = options.onConnected || null;
    this.#onDisconnected = options.onDisconnected || null;
    this.#onError = options.onError || null;
    this.#signalCallback = options.onSignal || null;
    this.#iceCallback = options.onICE || null;
    this.#statsCallback = options.onStats || null;
  }

  get isConnected() {
    return this.#isConnected;
  }

  get wsURL() {
    return this.#wsURL;
  }

  set hostIP(ip) {
    this.#hostIP = ip;
  }

  set pin(pin) {
    this.#pin = pin;
  }

  async connect() {
    try {
      this.#updateStatus("Connecting to host...");
      
      if (!this.#hostIP && !this.#pin) {
        throw new Error("HOST_IP or PIN required for connection");
      }

      if (this.#pin) {
        await this.#discoverWithPIN();
      }

      if (!this.#hostIP) {
        throw new Error("Unable to discover host");
      }

      await this.#establishWebSocket();
      await this.#setupWebRTC();
      
      this.#isConnected = true;
      this.#updateStatus("Connected successfully");
      this.#onConnected?.();
      return true;
    } catch (error) {
      this.#updateStatus(`Connection failed: ${error.message}`);
      this.#onError?.(error);
      return false;
    }
  }

  async disconnect() {
    this.#isConnected = false;
    await this.#closePeerConnection();
    await this.#closeWebSocket();
    this.#updateStatus("Disconnected");
    this.#onDisconnected?.();
  }

  async sendSignal(signal) {
    if (!this.#wsURL) {
      throw new Error("WebSocket not established");
    }
    
    const message = JSON.stringify({
      kind: "peerSignal",
      pin: this.#pin,
      signal
    });

    try {
      await fetch(`${this.#wsURL}/signal`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: message
      });
    } catch (error) {
      this.#onError?.(error);
      throw error;
    }
  }

  sendICECandidate(candidate) {
    this.sendSignal({
      kind: "iceCandidate",
      candidate
    }).catch(() => {});
  }

  async createOffer() {
    if (!this.#peerConnection) {
      throw new Error("WebRTC not initialized");
    }

    const offer = await this.#peerConnection.createOffer();
    await this.#peerConnection.setLocalDescription(offer);
    return offer;
  }

  async setAnswer(answer) {
    if (!this.#peerConnection) {
      throw new Error("WebRTC not initialized");
    }
    
    await this.#peerConnection.setRemoteDescription(answer);
  }

  async getStats() {
    if (!this.#peerConnection) {
      return null;
    }
    return this.#peerConnection.getStats();
  }

  async fetchDataChannel() {
    return this.#dataChannel;
  }

  #updateStatus(message) {
    console.log(`[DirectGuest] ${message}`);
  }

  async #discoverWithPIN() {
    this.#updateStatus("Discovering host via PIN...");

    const pin = this.#pin.trim().toUpperCase();
    if (!/^[A-Z0-9]{6}$/.test(pin)) {
      throw new Error("Invalid PIN format. Must be 6 alphanumeric characters.");
    }

    try {
      const response = await fetch(`/api/discover/${pin}`, {
        method: "GET",
        headers: {
          "Accept": "application/json"
        }
      });

      if (!response.ok) {
        throw new Error(`Discovery failed: ${response.status}`);
      }

      const data = await response.json();
      
      if (!data.hostIP) {
        throw new Error("Host not found for PIN");
      }

      this.#hostIP = data.hostIP;
      this.#wsURL = `ws://${this.#hostIP}:32188/remote-coop`;
      
      this.#updateStatus(`Host discovered: ${this.#hostIP}`);
    } catch (error) {
      this.#updateStatus(`Discovery failed: ${error.message}. Enter manual IP.`);
      throw error;
    }
  }

  async #establishWebSocket() {
    this.#updateStatus(`Connecting to WebSocket at ws://${this.#hostIP}:32188/remote-coop...`);

    return new Promise((resolve, reject) => {
      this.#ws = new WebSocket(`ws://${this.#hostIP}:32188/remote-coop`);
      
      this.#ws.onopen = () => {
        this.#updateStatus("WebSocket connected");
        
        const joinMessage = {
          kind: "guestJoinRequested",
          roomID: this.#pin,
          participantID: this.#generateParticipantID(),
          displayName: "Direct Guest",
          directMode: true
        };

        this.#ws.send(JSON.stringify(joinMessage));
        resolve(this.#ws);
      };

      this.#ws.onclose = () => {
        this.#updateStatus("WebSocket disconnected");
        reject(new Error("WebSocket connection closed"));
      };

      this.#ws.onerror = (error) => {
        this.#updateStatus("WebSocket error");
        reject(error);
      };
    });
  }

  async #setupWebRTC() {
    this.#updateStatus("Setting up WebRTC connection...");

    this.#peerConnection = new RTCPeerConnection({
      iceServers: [
        { urls: ["stun:stun.l.google.com:19302"] }
      ]
    });

    this.#peerConnection.addEventListener("icecandidate", (event) => {
      if (event.candidate) {
        this.#candidateGathered = true;
        this.sendICECandidate(event.candidate);
        this.#iceCallback?.(event.candidate);
      }
    });

    this.#peerConnection.addEventListener("iceconnectionstatechange", () => {
      this.#updateStatus(`ICE connection state: ${this.#peerConnection.iceConnectionState}`);
      
      if (this.#peerConnection.iceConnectionState === "connected" || 
          this.#peerConnection.iceConnectionState === "completed") {
        this.#onConnected?.();
      }
      
      if (this.#peerConnection.iceConnectionState === "failed") {
        this.#onError?.(new Error("ICE connection failed"));
      }
    });

    this.#peerConnection.addEventListener("connectionstatechange", () => {
      this.#updateStatus(`Connection state: ${this.#peerConnection.connectionState}`);
    });

    this.#peerConnection.addEventListener("datachannel", (event) => {
      this.#bindDataChannel(event.channel);
    });

    const videoTransceiver = this.#peerConnection.addTransceiver("video", {
      direction: "recvonly"
    });

    const audioTransceiver = this.#peerConnection.addTransceiver("audio", {
      direction: "recvonly"
    });

    videoTransceiver.receiver.addEventListener("track", (event) => {
      this.#handleRemoteTrack(event.track, event.receiver, "video");
    });

    audioTransceiver.receiver.addEventListener("track", (event) => {
      this.#handleRemoteTrack(event.track, event.receiver, "audio");
    });

    this.#dataChannel = this.#peerConnection.createDataChannel("input", {
      ordered: false,
      maxRetransmits: 0
    });

    this.#bindDataChannel(this.#dataChannel);
  }

  #bindDataChannel(channel) {
    this.#dataChannel = channel;
    
    channel.addEventListener("open", () => {
      this.#updateStatus("Data channel opened");
    });

    channel.addEventListener("close", () => {
      this.#updateStatus("Data channel closed");
    });

    channel.addEventListener("error", (error) => {
      this.#onError?.(error);
    });
  }

  #handleRemoteTrack(track, receiver, kind) {
    const mediaElement = kind === "video" ? document.querySelector("#remote-video") : document.querySelector("#remote-audio");
    
    if (mediaElement) {
      const stream = mediaElement.srcObject || new MediaStream();
      if (!stream.getTracks().some(t => t.id === track.id)) {
        stream.addTrack(track);
      }
      mediaElement.srcObject = stream;
      mediaElement.autoplay = true;
      mediaElement.playsInline = true;
      mediaElement.muted = kind === "video";
    }

    if (kind === "video" && this.#statsCallback) {
      this.#pollStats(receiver);
    }
  }

  async #pollStats(receiver) {
    try {
      const report = await this.#peerConnection.getStats();
      this.#statsCallback?.(report);
    } catch (error) {
      this.#onError?.(error);
    }
  }

  async #closePeerConnection() {
    if (this.#peerConnection) {
      this.#peerConnection.close();
      this.#peerConnection = null;
    }
  }

  async #closeWebSocket() {
    if (this.#ws) {
      this.#ws.close();
      this.#ws = null;
    }
  }

  #generateParticipantID() {
    if (typeof crypto.randomUUID === "function") {
      return crypto.randomUUID();
    }
    
    const bytes = new Uint8Array(16);
    if (typeof crypto.getRandomValues === "function") {
      crypto.getRandomValues(bytes);
    } else {
      for (let i = 0; i < bytes.length; i++) {
        bytes[i] = Math.floor(Math.random() * 256);
      }
    }
    
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    return Array.from(bytes, (byte, index) => {
      const value = byte.toString(16).padStart(2, "0");
      return [4, 6, 8, 10].includes(index) ? `-${value}` : value;
    }).join("");
  }
}

class DiscoveryService {
  static async discoverByPIN(pin) {
    const response = await fetch(`/api/discover/${pin}`, {
      method: "GET",
      headers: { "Accept": "application/json" }
    });

    if (!response.ok) {
      throw new Error("Host not found");
    }

    return response.json();
  }

  static async discoverMDNS() {
    try {
      const response = await fetch("/api/discover/mdns", {
        method: "GET",
        headers: { "Accept": "application/json" }
      });

      if (!response.ok) {
        return [];
      }

      return response.json();
    } catch {
      return [];
    }
  }
}

class PINValidator {
  static isValid(pin) {
    return /^[A-Z0-9]{6}$/.test(pin?.trim().toUpperCase());
  }

  static normalize(pin) {
    return pin?.trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
  }
}

class IPValidator {
  static isValid(ip) {
    const ipv4Regex = /^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/;
    return ipv4Regex.test(ip?.trim());
  }
}


function switchConnectionMode(event) {
  const button = event.target.closest("[data-mode]");
  if (!button) return;

  const mode = button.dataset.mode;
  if (mode === connectionMode) return;

  connectionMode = mode;

  const tabs = document.querySelectorAll(".mode-tab");
  for (const tab of tabs) {
    const isActive = tab.dataset.mode === mode;
    tab.classList.toggle("active", isActive);
    tab.setAttribute("aria-selected", String(isActive));
  }

  if (mode === "direct") {
    elements.joinCard.classList.add("hidden");
    const newJoinCard = document.createElement("section");
    newJoinCard.id = "join-card";
    newJoinCard.className = "home";
    newJoinCard.setAttribute("aria-label", "Direct P2P Connection");
    
    const header = document.createElement("header");
    header.className = "topbar";
    header.innerHTML = `
      <a class="brand" href="./" aria-label="PixelNOW Remote Co-Op home">
        <span class="brand-mark" aria-hidden="true"></span>
        <span class="brand-text">PixelNOW</span>
      </a>
      <span class="mode-pill" id="network-state">DIRECT</span>
    `;
    
    const entryStage = document.createElement("section");
    entryStage.className = "entry-stage";
    entryStage.setAttribute("aria-labelledby", "title");
    
    const signalMark = document.createElement("div");
    signalMark.className = "signal-mark";
    signalMark.setAttribute("aria-hidden", "true");
    signalMark.innerHTML = '<span></span><span></span><span></span>';
    
    const directConsole = document.createElement("section");
    directConsole.className = "join-console";
    directConsole.setAttribute("aria-label", "Direct P2P Connection");
    directConsole.innerHTML = `
      <p class="eyebrow" id="invite-source">DIRECT P2P</p>
      <h1 id="title">P2P</h1>
      <p id="subtitle" class="sr-only">Enter PIN for direct connection.</p>
      
      <label class="field code-field" for="direct-pin">
        <span>PIN</span>
        <input id="direct-pin" inputmode="text" maxlength="6" spellcheck="false" placeholder="ABC123">
      </label>

      <label class="field" for="direct-host-ip">
        <span>Host IP (optional)</span>
        <input id="direct-host-ip" inputmode="numeric" maxlength="15" spellcheck="false" placeholder="192.168.1.100">
      </label>

      <div class="direct-actions">
        <button id="direct-discover-button" type="button">Discover</button>
        <button id="direct-manual-button" type="button">Manual IP</button>
      </div>

      <button id="direct-connect-button" type="button">Connect</button>
      <p class="status" id="direct-status" role="status">Select PIN or enter IP</p>
    `;
    
    const microStatus = document.createElement("section");
    microStatus.className = "micro-status";
    microStatus.setAttribute("aria-label", "Direct P2P status");
    microStatus.innerHTML = `
      <span id="network-detail">Direct</span>
      <span id="gamepad-name">Controller</span>
      <span id="gamepad-detail">Waiting</span>
      <span id="session-state">Home</span>
      <span id="session-detail">Idle</span>
    `;
    
    entryStage.appendChild(signalMark);
    entryStage.appendChild(directConsole);
    newJoinCard.appendChild(header);
    newJoinCard.appendChild(entryStage);
    newJoinCard.appendChild(microStatus);
    
    document.querySelector("main").replaceChildren(newJoinCard);
  } else {
    const currentCard = document.querySelector("#join-card");
    const header = currentCard.querySelector(".topbar");
    const entryStage = currentCard.querySelector(".entry-stage");
    const microStatus = currentCard.querySelector(".micro-status");
    const visibleCode = currentCard.querySelector("#invite-code");
    
    header.querySelector(".mode-pill").textContent = "CODE";
    header.querySelector(".brand-mark").innerHTML = "";
    header.querySelector(".brand-text").textContent = "PixelNOW";
    
    entryStage.innerHTML = `
      <div class="signal-mark" aria-hidden="true">
        <span></span>
        <span></span>
        <span></span>
      </div>

      <section class="join-console" aria-label="Join Remote Co-Op room">
        <p class="eyebrow" id="invite-source">REMOTE CO-OP</p>
        <h1 id="title">CO-OP</h1>
        <p id="subtitle" class="sr-only">Enter an invite code and join.</p>

        <label class="field code-field" for="invite-code">
          <span>Code</span>
          <input id="invite-code" inputmode="text" autocomplete="one-time-code" maxlength="128" spellcheck="false" placeholder="ABC123" aria-describedby="join-status">
        </label>

        <label class="field" for="display-name">
          <span>Player</span>
          <input id="display-name" autocomplete="nickname" maxlength="32" placeholder="Guest">
        </label>

        <button id="join-button" type="button">Join</button>
        <p class="status" id="join-status" role="status">Code required</p>
      </section>
    `;
    
    document.querySelector("#join-button").addEventListener("click", joinRoom);
    
    if (currentCard.querySelector(".micro-status")) {
      currentCard.replaceChildren(header, entryStage, microStatus);
    }
  }
}

async function discoverHostByPIN() {
  const pinInput = connectionMode === "direct" ? document.querySelector("#direct-pin") : elements.inviteCode;
  const statusOutput = connectionMode === "direct" ? document.querySelector("#direct-status") : elements.joinStatus;
  const pin = (pinInput?.value || "").trim().toUpperCase();

  if (!/^[A-Z0-9]{6}$/.test(pin)) {
    if (statusOutput) statusOutput.textContent = "Invalid PIN format";
    return;
  }

  if (statusOutput) statusOutput.textContent = "Discovering host...";
  
  try {
    const response = await fetch(`/api/discover/${pin}`, {
      method: "GET",
      headers: { "Accept": "application/json" }
    });

    if (!response.ok) {
      throw new Error(`Discovery failed: ${response.status}`);
    }

    const data = await response.json();

    if (!data.hostIP) {
      throw new Error("Host not found for PIN");
    }

    if (connectionMode === "direct") {
      const hostIPInput = document.querySelector("#direct-host-ip");
      if (hostIPInput) hostIPInput.value = data.hostIP;
      
      if (statusOutput) statusOutput.textContent = `Host found: ${data.hostIP}`;
    }
  } catch (error) {
    if (statusOutput) statusOutput.textContent = `Discovery failed: ${error.message}`;
  }
}

function showManualIP() {
  const hostIPInput = connectionMode === "direct" ? document.querySelector("#direct-host-ip") : null;
  if (hostIPInput) hostIPInput.focus();
}

async function directConnect() {
  const pinInput = connectionMode === "direct" ? document.querySelector("#direct-pin") : null;
  const hostIPInput = connectionMode === "direct" ? document.querySelector("#direct-host-ip") : null;
  const statusOutput = connectionMode === "direct" ? document.querySelector("#direct-status") : null;
  
  const pin = (pinInput?.value || "").trim().toUpperCase();
  const hostIP = (hostIPInput?.value || "").trim();
  
  if (!hostIP && !pin) {
    if (statusOutput) statusOutput.textContent = "Enter PIN or IP";
    return;
  }

  if (statusOutput) statusOutput.textContent = "Connecting...";
  
  directConnection?.disconnect();
  
  directConnection = new DirectGuestConnection({
    pin: pin || null,
    hostIP: hostIP || null,
    onConnected: () => {
      if (statusOutput) statusOutput.textContent = "Connected!";
    },
    onDisconnected: () => {
      if (statusOutput) statusOutput.textContent = "Disconnected";
    },
    onError: (error) => {
      if (statusOutput) statusOutput.textContent = `Error: ${error.message}`;
    },
    onSignal: (signal) => {
      if (socket?.readyState === WebSocket.OPEN) {
        send({
          kind: "peerSignal",
          roomID: pin || undefined,
          participantID,
          peerSignal: signal
        });
      }
    },
    onICE: (candidate) => {
      if (socket?.readyState === WebSocket.OPEN) {
        send({
          kind: "peerSignal",
          roomID: pin || undefined,
          participantID,
          peerSignal: {
            kind: "iceCandidate",
            candidate
          }
        });
      }
    },
    onStats: (report) => {
      try {
        const selected = selectedRouteFromStats(report);
        const statsSummary = inboundStatsSummary(report);
        
        if (elements.networkDetail) {
          elements.networkDetail.textContent = selected || "Connected";
        }
        
        if (diagnostics.selectedRoute !== selected || !diagnostics.stats.includes(statsSummary)) {
          updateDiagnostics({
            selectedRoute: selected,
            stats: statsSummary
          });
        }
      } catch {
        // Ignore stats errors
      }
    }
  });

  const connected = await directConnection.connect();
  
  if (!connected) {
    if (statusOutput) statusOutput.textContent = "Connection failed";
    return;
  }

  const wsUrl = directConnection.wsURL;
  
  resetInputHistory();
  diagnostics = initialDiagnostics();
  updateDiagnostics({ websocket: `direct connection`, transportMode: "directOnly", latencyMode: "lowLatency" });
  
  const ws = new WebSocket(wsUrl);
  socket = ws;
  
  elements.joinButton.disabled = true;
  elements.joinStatus.textContent = "Connecting";
  
  ws.addEventListener("open", () => {
    updateDiagnostics({ websocket: "open" });
    send({
      kind: "guestJoinRequested",
      roomID: pin || undefined,
      participantID,
      inviteToken: pin || undefined,
      displayName: displayName(),
      directMode: true
    });
    
    if (elements.joinCard) elements.joinCard.classList.add("hidden");
    if (elements.sessionCard) elements.sessionCard.classList.remove("hidden");
    
    setState("Waiting", "Host", false);
  });

  ws.addEventListener("message", (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      updateDiagnostics({ websocket: "invalid message" });
      setNetworkState("Error", "Broker");
      return;
    }
    
    handleMessage(message).catch((error) => {
      setNetworkState("Error", "Peer");
      updateDiagnostics({ signaling: error.message || "WebRTC negotiation failed" });
    });
  });

  ws.addEventListener("close", () => {
    stopPolling();
    updateDiagnostics({ websocket: "closed" });
    if (!hasTerminalState()) setState("Closed", "Offline", false);
    elements.joinButton.disabled = false;
  });

  ws.addEventListener("error", () => updateDiagnostics({ websocket: "error" }));
}
