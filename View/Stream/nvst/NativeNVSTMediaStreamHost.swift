import Foundation
import AppKit
import SwiftUI
import Combine

typealias NativeNVSTMediaStreamCompletion = NativeNVSTMediaStreamEndCallback
typealias NativeNVSTMediaStreamProgressHandler = NativeNVSTMediaStreamProgressCallback

enum NativeNVSTStreamLaunchLoadingStage {
    static func label(stepIndex: Int, queuePosition: Int? = nil) -> String {
        if let queuePosition, queuePosition > 0 { return "Waiting in queue" }
        switch stepIndex {
        case StreamLaunchStep.checkNetworkRoute.rawValue: return "Checking connection"
        case StreamLaunchStep.allocateCloudSession.rawValue: return "Finding a server"
        case StreamLaunchStep.receiveStreamOffer.rawValue: return "Preparing stream"
        case StreamLaunchStep.negotiateNVST.rawValue: return "Connecting"
        case StreamLaunchStep.connected.rawValue: return "Ready"
        default: return "Starting"
        }
    }
}

extension PreparedLaunchConfiguration {
    var nativeNVSTLoadingArtworkURL: URL? {
        let urls = (metadata["loadingScreenshotUrls"] ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return nil }
        let seed = id.uuidString.utf8.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1) }
        return URL(string: urls[Int(seed % UInt(urls.count))])
    }
}

struct NativeNVSTStreamLaunchLoadingScreen<Accessory: View>: View {
    let title: String
    let stage: String
    let message: String
    let artworkURL: URL?
    let currentStepIndex: Int
    let queuePosition: Int?
    let accessoryPresented: Bool
    let cancelAction: (() -> Void)?
    private let accessory: Accessory

    @Environment(\.displayScale) private var displayScale
    @State private var diagnosticsPresented = false
    @State private var diagnosticText = ""
    @State private var artwork: NSImage?
    @State private var loadedArtworkURL: String?
    private let diagnosticRefreshTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(title: String,
         stage: String,
         message: String = "",
         artworkURL: URL?,
         currentStepIndex: Int = -1,
         queuePosition: Int? = nil,
         accessoryPresented: Bool = false,
         cancelAction: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title.isEmpty ? "GeForce NOW" : title
        self.stage = stage
        self.message = message
        self.artworkURL = artworkURL
        self.currentStepIndex = currentStepIndex
        self.queuePosition = queuePosition
        self.accessoryPresented = accessoryPresented
        self.cancelAction = cancelAction
        self.accessory = accessory()
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620
            let targetPixelSize = CGSize(
                width: min(proxy.size.width * displayScale, 4096),
                height: min(proxy.size.height * displayScale, 4096)
            )
            ZStack {
                Color.black
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.08), location: 0),
                        .init(color: .clear, location: 0.32),
                        .init(color: .black.opacity(0.18), location: 0.58),
                        .init(color: .black.opacity(0.80), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                if accessoryPresented {
                    VStack {
                        Spacer(minLength: 24)
                        accessory
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: 920, maxHeight: compact ? 300 : 520)
                        Spacer(minLength: 24)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: artworkTaskKey(targetPixelSize: targetPixelSize)) {
                guard let artworkURL else {
                    artwork = nil
                    loadedArtworkURL = nil
                    return
                }
                if loadedArtworkURL != artworkURL.absoluteString {
                    artwork = nil
                    loadedArtworkURL = artworkURL.absoluteString
                }
                guard let original = await CatalogImageCache.shared.image(for: artworkURL), !Task.isCancelled else { return }
                artwork = original.image
                let result = await CatalogImageCache.shared.loadingArtwork(for: artworkURL, targetPixelSize: targetPixelSize)
                guard !Task.isCancelled else { return }
                artwork = result?.image ?? original.image
            }
            .overlay(alignment: .bottomLeading) {
                launchStatusRail(compact: compact)
                    .frame(maxWidth: compact ? 420 : 560, alignment: .leading)
                    .padding(.horizontal, compact ? 22 : 48)
                    .padding(.bottom, compact ? 26 : 42)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    if diagnosticsPresented {
                        diagnosticPanel(compact: compact)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            diagnosticsPresented.toggle()
                            if diagnosticsPresented {
                                diagnosticText = NativeNVSTMediaLog.currentLogText()
                            }
                        }
                    } label: {
                        Label(
                            diagnosticsPresented ? "Hide diagnostics" : "Show diagnostics",
                            systemImage: diagnosticsPresented ? "chevron.down.circle" : "terminal"
                        )
                        .font(.nvidia(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(.black.opacity(0.56), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(diagnosticsPresented ? "Hide launch diagnostics" : "Show launch diagnostics")
                }
                .padding(.horizontal, compact ? 18 : 28)
                .padding(.bottom, compact ? 16 : 24)
            }
        }
        .background(.black)
        .onReceive(diagnosticRefreshTimer) { _ in
            guard diagnosticsPresented else { return }
            diagnosticText = NativeNVSTMediaLog.currentLogText()
        }
    }

    private func artworkTaskKey(targetPixelSize: CGSize) -> String {
        let url = artworkURL?.absoluteString ?? "none"
        return "\(url)|\(Int(targetPixelSize.width))x\(Int(targetPixelSize.height))"
    }

    private func launchStatusRail(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 11) {
            HStack(alignment: .center, spacing: 10) {
                if !accessoryPresented {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.pixelNowGreen)
                        .frame(width: 17, height: 17)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.nvidia(size: compact ? 17 : 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.pixelNowGreen)
                            .frame(width: 6, height: 6)
                            .shadow(color: Color.pixelNowGreen.opacity(0.7), radius: 4)
                        Text(stage.uppercased())
                            .font(.nvidia(size: 10, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.82))
                        if let queuePosition, queuePosition > 0 {
                            Text("· QUEUE \(queuePosition)")
                                .font(.nvidia(size: 10, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(.white.opacity(0.70))
                        }
                    }
                }
                Spacer(minLength: 8)
                if let cancelAction {
                    Button("Cancel", action: cancelAction)
                        .font(.nvidia(size: 11, weight: .bold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.90))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(.black.opacity(0.32), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.30), lineWidth: 1))
                        .accessibilityLabel("Cancel stream launch")
                }
            }
            if !message.isEmpty {
                Text(message)
                    .font(.nvidia(size: compact ? 10 : 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                ForEach(StreamLaunchStep.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step.rawValue <= currentStepIndex ? Color.pixelNowGreen : Color.white.opacity(0.30))
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            if step.rawValue == currentStepIndex && currentStepIndex < StreamLaunchStep.connected.rawValue {
                                Capsule()
                                    .fill(Color.white.opacity(0.85))
                                    .frame(width: 14, height: 3)
                                    .offset(x: 0)
                            }
                        }
                }
            }
            .accessibilityHidden(true)
            if accessoryPresented {
                Text("SPONSORED MESSAGE")
                    .font(.nvidia(size: 9, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(.top, compact ? 12 : 16)
        .padding(.horizontal, compact ? 13 : 17)
        .padding(.bottom, compact ? 12 : 15)
        .background(.black.opacity(0.40), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.pixelNowGreen.opacity(0.90))
                .frame(width: 2)
                .padding(.vertical, 10)
        }
        .shadow(color: .black.opacity(0.26), radius: 16, y: 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(stage). \(message)")
        .accessibilityValue("Launch step \(max(0, currentStepIndex + 1)) of \(StreamLaunchStep.allCases.count)")
    }

    private func diagnosticPanel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NVST DIAGNOSTICS")
                    .font(.nvidia(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Color.pixelNowGreen)
                Spacer(minLength: 12)
                Text("LIVE")
                    .font(.nvidia(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.58))
            }
            ScrollView(.vertical) {
                Text(diagnosticText.isEmpty ? "Waiting for NVST diagnostics…" : diagnosticText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.84))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: compact ? 110 : 170, maxHeight: compact ? 180 : 250)
        }
        .padding(12)
        .frame(maxWidth: compact ? 430 : 620, alignment: .leading)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.pixelNowGreen.opacity(0.42), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

struct NativeNVSTMediaStreamHostView: View {
    let configuration: PreparedLaunchConfiguration
    let onProgress: NativeNVSTMediaStreamProgressHandler?
    let onEnd: NativeNVSTMediaStreamCompletion
    private let coordinator: StreamSessionCoordinator

    init(configuration: PreparedLaunchConfiguration,
         onProgress: NativeNVSTMediaStreamProgressHandler?,
         onEnd: @escaping NativeNVSTMediaStreamCompletion) {
        self.configuration = configuration
        self.onProgress = onProgress
        self.onEnd = onEnd
        coordinator = StreamSessionCoordinator(
            adPresenter: NativeNVSTInlineStreamSessionAdPresenter(handler: nil),
            progressHandler: { progress in
                Task { @MainActor in onProgress?(progress) }
            }
        )
    }

    var body: some View {
        NativeNVSTMediaStreamSurface(
            configuration: configuration,
            sessionProvider: coordinator,
            preventDisplaySleep: Self.preventDisplaySleepWhileStreaming(applicationID: configuration.applicationID),
            onProgress: { progress in
                onProgress?(progress)
            },
            onEnd: { success, message, report in
                onEnd(success, message, report)
            }
        )
    }

    private static func preventDisplaySleepWhileStreaming(applicationID: String) -> Bool {
        let profile = StreamPreferences.launchProfile(forGame: applicationID, capabilities: StreamPreferences.loadDeviceCapabilities())
        return profile.preventDisplaySleepWhileStreaming
    }
}

private struct NativeNVSTInlineStreamSessionAdPresenter: StreamSessionAdPresenter {
    let handler: (@Sendable (StreamSessionAdPresentation) async throws -> Int)?

    func playRequiredSessionAd(_ ad: StreamSessionAdPresentation) async throws -> Int {
        throw StreamSessionError.sessionAllocationFailed("Required ad playback is not available for native NVST.")
    }
}
