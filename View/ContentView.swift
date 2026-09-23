//
//  ContentView.swift
//  PixelNOW
//
//  Created by Jayian on 6/14/26.
//

import Combine
import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    private static let defaultWindowTitle = "PixelNOW"

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoginAccount.lastLoginAt, order: .reverse) private var accounts: [LoginAccount]
    @Query(sort: \LoginSession.issuedAt, order: .reverse) private var sessions: [LoginSession]
    @Query private var devices: [LoginDeviceRegistration]

    @StateObject private var viewModel = LoginViewModel()
    @State private var windowTitle = Self.defaultWindowTitle
    @State private var didBootstrap = false
    @State private var isShowingStartupLoading = true

    var body: some View {
        ZStack {
            LoginView(viewModel: viewModel, accounts: accounts) { title in
                windowTitle = title ?? Self.defaultWindowTitle
            }
            .accessibilityHidden(isShowingStartupLoading)

            if isShowingStartupLoading {
                StartupLoadingView()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
            .frame(minWidth: 980, minHeight: 660)
            .frame(idealWidth: 1200, idealHeight: 760)
            .background(WindowTitleConfigurator(title: windowTitle))
            .task {
                await bootstrapAppStartIfNeeded()
            }
            .onChange(of: accounts.count) { _, _ in syncViewModel() }
            .onChange(of: sessions.count) { _, _ in syncViewModel() }
            .onChange(of: devices.count) { _, _ in syncViewModel() }
            .onOpenURL { url in handleOpenURL(url) }
            .onReceive(NotificationCenter.default.publisher(for: .didOpenFile)) { notification in
                guard let url = notification.object as? URL else { return }
                viewModel.handleOpenedFile(url)
            }
    }

    private func bootstrapAppStartIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        syncViewModel()
        viewModel.bootstrap()
        drainOpenedFiles()
        await dismissStartupLoading()
    }

    private func dismissStartupLoading() async {
        do {
            try await Task.sleep(nanoseconds: StartupAnimation.dismissalDelayNanoseconds)
        } catch {
            isShowingStartupLoading = false
            return
        }
        withAnimation(.easeInOut(duration: StartupAnimation.fadeDuration)) {
            isShowingStartupLoading = false
        }
    }

    private func drainOpenedFiles() {
        for url in FileOpenCoordinator.shared.drainPendingFileURLs() {
            viewModel.handleOpenedFile(url)
        }
    }

    private func syncViewModel() {
        viewModel.update(modelContext: modelContext, accounts: accounts, sessions: sessions, devices: devices)
    }

    private func handleOpenURL(_ url: URL) {
        viewModel.handleOAuthCallback(url)
    }
}

private struct WindowTitleConfigurator: NSViewRepresentable {
    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowConfigurationView {
        let view = WindowConfigurationView(frame: .zero)
        let coordinator = context.coordinator
        view.onWindowChanged = { window in coordinator.attach(window) }
        return view
    }

    func updateNSView(_ view: WindowConfigurationView, context: Context) {
        context.coordinator.update(title: title)
    }

    static func dismantleNSView(_ nsView: WindowConfigurationView, coordinator: Coordinator) {
        nsView.onWindowChanged = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        nonisolated static let autosaveName: NSWindow.FrameAutosaveName = "PixelNOWMainWindow"
        private weak var window: NSWindow?
        private var configuredWindow: ObjectIdentifier?
        private var title = ""
        private var observerTokens: [NSObjectProtocol] = []

        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            removeObservers()
            self.window = window
            configuredWindow = nil
            guard let window else { return }
            configure(window)
            addObservers(for: window)
            update(title: title)
        }

        func update(title: String) {
            self.title = title
            guard let window else { return }
            configure(window)
            if window.title != title {
                window.title = title
            }
        }

        func detach() {
            removeObservers()
            window = nil
            configuredWindow = nil
        }

        private func configure(_ window: NSWindow) {
            let windowIdentifier = ObjectIdentifier(window)
            guard configuredWindow != windowIdentifier else { return }
            configuredWindow = windowIdentifier
            
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }

            window.setFrameAutosaveName(Self.autosaveName)
            if !window.setFrameUsingName(Self.autosaveName) {
                window.center()
            }
        }

        private func addObservers(for window: NSWindow) {
            let notificationCenter = NotificationCenter.default
            let notifications: [Notification.Name] = [
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            let autosaveName = Self.autosaveName
            observerTokens = notifications.map { name in
                notificationCenter.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    Task { @MainActor [weak window] in
                        guard let window, !window.styleMask.contains(.fullScreen) else { return }
                        window.saveFrame(usingName: autosaveName)
                    }
                }
            }
        }

        private func removeObservers() {
            let notificationCenter = NotificationCenter.default
            for token in observerTokens {
                notificationCenter.removeObserver(token)
            }
            observerTokens = []
        }
    }

    final class WindowConfigurationView: NSView {
        var onWindowChanged: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAreaView {
        DragAreaView(frame: .zero)
    }

    func updateNSView(_ nsView: DragAreaView, context: Context) {}

    final class DragAreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self, CatalogImageCacheEntry.self], inMemory: true)
}
