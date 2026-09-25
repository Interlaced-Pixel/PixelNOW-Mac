export class DirectGuestConnection {
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
        throw new Error("_HOST_IP or PIN required for connection");
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

export class DiscoveryService {
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

export class PINValidator {
  static isValid(pin) {
    return /^[A-Z0-9]{6}$/.test(pin?.trim().toUpperCase());
  }

  static normalize(pin) {
    return pin?.trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
  }
}

export class IPValidator {
  static isValid(ip) {
    const ipv4Regex = /^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/;
    return ipv4Regex.test(ip?.trim());
  }
}
