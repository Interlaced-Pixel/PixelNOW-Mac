import Foundation
import SwiftUI

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
    let artworkURL: URL?
    let queuePosition: Int?
    let accessoryPresented: Bool
    let cancelAction: (() -> Void)?
    private let accessory: Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String,
         stage: String,
         artworkURL: URL?,
         queuePosition: Int? = nil,
         accessoryPresented: Bool = false,
         cancelAction: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title.isEmpty ? "GeForce NOW" : title
        self.stage = stage
        self.artworkURL = artworkURL
        self.queuePosition = queuePosition
        self.accessoryPresented = accessoryPresented
        self.cancelAction = cancelAction
        self.accessory = accessory()
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620
            ZStack {
                Color.black
                if let artworkURL {
                    AsyncImage(url: artworkURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        }
                    }
                }
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.54), location: 0),
                        .init(color: .black.opacity(0.20), location: 0.42),
                        .init(color: .black.opacity(0.78), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [Color.pixelNowBlue.opacity(0.18), .clear],
                    center: .center,
                    startRadius: 12,
                    endRadius: compact ? 260 : 480
                )
                .blendMode(.screen)
                VStack(spacing: compact ? 16 : 22) {
                    Spacer(minLength: 24)
                    if accessoryPresented {
                        accessory
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: 920, maxHeight: compact ? 300 : 520)
                    } else {
                        NativeNVSTStreamLaunchSignal(reduceMotion: reduceMotion)
                            .frame(width: compact ? 68 : 84, height: compact ? 68 : 84)
                    }
                    VStack(spacing: 8) {
                        Text(title)
                            .font(.nvidia(size: compact ? 24 : 32, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.pixelNowGreen)
                                .frame(width: 6, height: 6)
                                .shadow(color: Color.pixelNowGreen, radius: 6)
                            Text(stage.uppercased())
                                .font(.nvidia(size: 11, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                    if let queuePosition, queuePosition > 0 {
                        Text("Position \(queuePosition)")
                            .font(.nvidia(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(.black.opacity(0.48), in: Capsule())
                            .overlay(Capsule().stroke(Color.pixelNowGreen.opacity(0.38), lineWidth: 1))
                    }
                    if let cancelAction {
                        Button("Cancel", action: cancelAction)
                            .font(.nvidia(size: 12, weight: .bold))
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.68))
                            .padding(.horizontal, 18)
                            .frame(height: 34)
                            .overlay(Capsule().stroke(.white.opacity(0.20), lineWidth: 1))
                            .accessibilityLabel("Cancel stream launch")
                    }
                    Spacer(minLength: 24)
                    if !accessoryPresented {
                        VendorIndeterminateProgressBar()
                            .frame(width: compact ? 190 : 280, height: 3)
                            .padding(.bottom, compact ? 22 : 34)
                    }
                }
                .padding(.horizontal, compact ? 22 : 40)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(.black)
    }
}

private struct NativeNVSTStreamLaunchSignal: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let rotation = reduceMotion ? 0 : cycle * 360
            ZStack {
                Circle()
                    .fill(Color.pixelNowGreen.opacity(0.12))
                    .blur(radius: 14)
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 1)
                Circle()
                    .trim(from: 0.06, to: 0.70)
                    .stroke(Color.pixelNowGreen, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
                Circle()
                    .trim(from: 0.12, to: 0.42)
                    .stroke(.white.opacity(0.64), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .padding(9)
                    .rotationEffect(.degrees(-rotation * 0.72))
                Circle()
                    .fill(Color.pixelNowGreen)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.pixelNowGreen, radius: 8)
            }
        }
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
