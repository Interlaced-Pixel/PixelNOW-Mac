import AppKit
import Combine
import SwiftUI

@MainActor
final class UpdateProgressController: ObservableObject {
    @Published var progressState: UpdateProgressState = .initial
    @Published var errorMessage: String?
    @Published var canCancel: Bool = true

    private var sheetWindow: NSWindow?
    private weak var parentWindow: NSWindow?
    private var onCancelHandler: (() -> Void)?

    func show(release: GitHubRelease, onCancel: @escaping () -> Void) {
        self.onCancelHandler = onCancel
        self.progressState = .initial
        self.errorMessage = nil
        self.canCancel = true

        let rootView = UpdateProgressView(release: release, controller: self)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled]
        window.title = "Software Update"
        window.isMovableByWindowBackground = true
        self.sheetWindow = window

        let candidateParent = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.styleMask.contains(.fullScreen) })
        if let candidateParent {
            self.parentWindow = candidateParent
            candidateParent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func updateProgress(_ state: UpdateProgressState) {
        self.progressState = state
        switch state.stage {
        case .initialStart, .downloading:
            self.canCancel = true
        case .extracting, .relaunching:
            self.canCancel = false
        }
    }

    func showError(_ message: String) {
        self.errorMessage = message
        self.canCancel = true
    }

    func cancel() {
        let handler = onCancelHandler
        onCancelHandler = nil
        handler?()
        dismiss()
    }

    func dismiss() {
        if let parent = parentWindow, let sheet = sheetWindow {
            parent.endSheet(sheet)
        } else {
            sheetWindow?.close()
        }
        sheetWindow = nil
        parentWindow = nil
        onCancelHandler = nil
    }
}
