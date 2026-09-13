import AppKit
import QuartzCore

@MainActor
private final class NativeNVSTVideoSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        for subview in subviews {
            subview.frame = bounds
        }
    }
}

@MainActor
private final class NativeNVSTRendererWindow: NSWindow {
    var hdrPresentationRequested = false
    var codecSupportsHDR = false
    var keyboardFocusEnabled = false

    override var canBecomeKey: Bool { keyboardFocusEnabled }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class NativeNVSTStreamView: NSView, @preconcurrency NSTextInputClient {
    static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    public var onInputEvent: ((UserInputEvent) -> Void)?
    public var onAbsoluteMouseMove: ((NativeNVSTAbsoluteMouseEvent) -> Void)?
    public var onGamepadTopologyChanged: ((NativeNVSTGamepadTopology) -> Void)?
    public var onPointerLockChanged: ((Bool) -> Void)?
    public var onCommand: ((NativeNVSTMediaStreamCommand) -> Void)?
    public var shouldHandleCommand: ((NativeNVSTMediaStreamCommand) -> Bool)?
    var cursorAssociationHandler: (Bool) -> CGError = {
        CGAssociateMouseAndMouseCursorPosition(boolean_t($0 ? 1 : 0))
    }
    var cursorLocationProvider: () -> CGPoint = {
        NSEvent.mouseLocation
    }
    public private(set) var isPointerLocked = false
    public private(set) var isEmittingNeutralizingAbsolutePosition = false
    public var isCursorCaptured: Bool { isPointerLocked }
    public var isFrontmostInputTarget: Bool {
        NSApplication.shared.isActive && window?.isKeyWindow == true
    }
    public var locksPointerWhenRelativeModeSelected = false
    public var mouseInputMode: NativeNVSTStreamMouseInputMode = .relative {
        willSet {
            guard newValue != mouseInputMode else { return }
            if mouseInputMode == .absolute, !pressedMouseButtons.isEmpty {
                emitCurrentAbsoluteMousePosition(timestamp: Self.timestamp())
            }
            releasePressedMouseButtons()
            preciseScrollRemainder = 0
        }
        didSet {
            guard oldValue != mouseInputMode else { return }
            if mouseInputMode == .absolute {
                disablePointerLock()
            } else {
                restoreInputFocus()
            }
            applyLocalCursorPolicy()
        }
    }
    public var remoteInputEnabled = true {
        willSet {
            if remoteInputEnabled && !newValue {
                releasePressedInputs()
                setPointerLocked(false)
            }
        }
        didSet {
            if !oldValue && remoteInputEnabled {
                gamepadMonitor.refreshInputState()
                restoreInputFocus()
            }
            applyLocalCursorPolicy()
        }
    }
    public var directMouseInputEnabled = true {
        didSet {
            guard oldValue != directMouseInputEnabled else { return }
            if !directMouseInputEnabled, mouseInputMode == .absolute { setPointerLocked(false) }
            applyLocalCursorPolicy()
        }
    }
    public var cursorPolicy: OPNCursorPolicy = .auto {
        didSet {
            guard oldValue != cursorPolicy else { return }
            applyLocalCursorPolicy()
        }
    }
    public internal(set) var manualPointerCaptureOverride = false
    public internal(set) var remoteCursorWantsPointer: Bool? {
        didSet {
            guard oldValue != remoteCursorWantsPointer else { return }
            applyLocalCursorPolicy()
        }
    }
    public internal(set) var seatCompositesCursor = true {
        didSet {
            guard oldValue != seatCompositesCursor else { return }
            applyLocalCursorPolicy()
        }
    }
    public var localOverlayCapturesInput = false {
        didSet {
            guard oldValue != localOverlayCapturesInput else { return }
            applyLocalCursorPolicy()
        }
    }
    public var hidesCursorWhilePointerLocked = true {
        didSet {
            guard isPointerLocked else { return }
            updatePointerLockCursorVisibility()
        }
    }
    private var hidesLocalCursorOverVideo = false
    private var lastEmittedAbsoluteMouseEvent: NativeNVSTAbsoluteMouseEvent?
    private var trackingArea: NSTrackingArea?
    private var keyEquivalentMonitor: Any?
    private var pointerLockMonitor: Any?
    private var pointerLockNotificationTokens: [NSObjectProtocol] = []
    private var pointerLockRestoreLocation: CGPoint?
    private var pointerLockCursorHidden = false
    private var cursorAssociationGeneration: UInt = 0
    private var preciseScrollRemainder = 0.0
    private var pressedKeyboardEvents: [UInt16: KeyboardEvent] = [:]
    private var textInputState = NativeNVSTTextInputState()
    private var textInputKeyCodes: Set<UInt16> = []
    private var pushToTalkState: NativeNVSTPushToTalkState?
    private var pressedMouseButtons: Set<MouseButton> = []
    private var activeGamepadStates: [Int: GamepadState] = [:]
    private var streamContentSize = CGSize.zero
    private let videoSurface = NativeNVSTVideoSurfaceView(frame: .zero)
    private let nativeNVSTRendererWindow = NativeNVSTRendererWindow(
        contentRect: .zero,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    private weak var nativeNVSTRendererParentWindow: NSWindow?
    private weak var nativeNVSTMetalView: NSView?
    private var nativeNVSTDisplayNotificationTokens: [NSObjectProtocol] = []
    private var nativeNVSTRendererEnabled = false
    private var nativeNVSTRendererPreparedForShutdown = false
    private var nativeNVSTVideoVisible = false
    private let gamepadMonitor = NativeNVSTGamepadMonitor()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(videoSurface)
        nativeNVSTRendererWindow.backgroundColor = .clear
        nativeNVSTRendererWindow.contentView = NativeNVSTVideoSurfaceView(frame: .zero)
        nativeNVSTRendererWindow.hasShadow = false
        nativeNVSTRendererWindow.ignoresMouseEvents = true
        nativeNVSTRendererWindow.isOpaque = false
        nativeNVSTRendererWindow.alphaValue = 0
        nativeNVSTRendererWindow.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        gamepadMonitor.onInputEvent = { [weak self] event in
            guard let self, self.remoteInputEnabled else { return }
            guard case .gamepad(let state) = event else { return }
            self.receiveGamepadState(state)
        }
        gamepadMonitor.onTopologyChanged = { [weak self] topology in
            guard let self else { return }
            self.activeGamepadStates = self.activeGamepadStates.filter { topology.playerIndices.contains($0.key) }
            self.onGamepadTopologyChanged?(topology)
        }
        gamepadMonitor.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override var acceptsFirstResponder: Bool { true }

    public func configurePushToTalk(keyCode: Int?, modifierMask: Int = 0, onChange: @escaping (Bool) -> Void) {
        if let keyCode, pushToTalkState?.update(keyCode: keyCode, modifierMask: modifierMask, onChange: onChange) == true { return }
        pushToTalkState?.release()
        pushToTalkState = keyCode.map { NativeNVSTPushToTalkState(keyCode: $0, modifierMask: modifierMask, onChange: onChange) }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        return self
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if nativeNVSTRendererEnabled {
            updateNativeNVSTRendererWindowParent()
            updateNativeNVSTPresentation()
        }
        installNativeNVSTDisplayNotifications()
        restoreInputFocus()
        window?.acceptsMouseMovedEvents = true
        if window == nil {
            prepareNativeNVSTRendererForShutdown()
            removeKeyEquivalentMonitor()
            gamepadMonitor.stop()
            handleFocusLoss()
            removePointerLockNotifications()
        } else {
            installKeyEquivalentMonitor()
            installPointerLockNotifications()
            gamepadMonitor.start()
        }
    }

    public func setStreamContentSize(width: Int, height: Int) {
        let contentSize = CGSize(width: max(1, width), height: max(1, height))
        guard streamContentSize != contentSize else { return }
        streamContentSize = contentSize
        needsLayout = true
    }

    public var gamepadTopology: NativeNVSTGamepadTopology {
        gamepadMonitor.topology
    }

    public func playHaptic(_ command: NativeNVSTHapticCommand) {
        gamepadMonitor.playHaptic(command)
    }

    public func stopHaptics() {
        gamepadMonitor.stopHaptics()
    }

    public func nativeVideoView() -> NSView {
        videoSurface
    }

    private var nvstCoreRenderer: NVSTCoreVideoRenderer?

    public func attachNVSTCoreRenderer(targetFps: Int32) -> NVSTCoreVideoRenderer {
        nvstCoreRenderer?.detach()
        let renderer = NVSTCoreVideoRenderer(parentView: videoSurface, targetFps: targetFps)
        nvstCoreRenderer = renderer
        nativeNVSTRendererEnabled = true
        nativeNVSTRendererPreparedForShutdown = false
        renderer.layoutVideoView()
        return renderer
    }

    public func attachNvstBifrostFreeRenderer(targetFps: Int32) -> NVSTCoreVideoRenderer {
        attachNVSTCoreRenderer(targetFps: targetFps)
    }

    public func detachNVSTCoreRenderer() {
        nvstCoreRenderer?.detach()
        nvstCoreRenderer = nil
    }

    public func detachNvstBifrostFreeRenderer() {
        detachNVSTCoreRenderer()
    }

    private func _unusedAttach(targetFps: Int32) -> NVSTCoreVideoRenderer {
        nvstCoreRenderer?.detach()
        let renderer = NVSTCoreVideoRenderer(parentView: videoSurface, targetFps: targetFps)
        nvstCoreRenderer = renderer
        nativeNVSTRendererEnabled = true
        nativeNVSTRendererPreparedForShutdown = false
        renderer.layoutVideoView()
        return renderer
    }

    public func nativeNVSTVideoWindow() -> NSWindow? {
        guard window != nil else { return nil }
        layoutSubtreeIfNeeded()
        guard videoSurface.bounds.width >= 1, videoSurface.bounds.height >= 1 else { return nil }
        nativeNVSTRendererEnabled = true
        nativeNVSTRendererPreparedForShutdown = false
        updateNativeNVSTRendererWindowParent()
        updateNativeNVSTRendererWindowFrame()
        updateNativeNVSTPresentation()
        synchronizeSDLKeyboardFocus()
        return nativeNVSTRendererWindow
    }

    static func configureNativeNVSTPresentation(window: NSWindow, requestedHDR: Bool, codecSupportsHDR: Bool) {
        guard let rendererWindow = window as? NativeNVSTRendererWindow else { return }
        rendererWindow.hdrPresentationRequested = requestedHDR
        rendererWindow.codecSupportsHDR = codecSupportsHDR
        let screenSupportsEDR = rendererWindow.parent?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? rendererWindow.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let usesEDR = nativeNVSTPresentationUsesEDR(requestedHDR: requestedHDR, codecSupportsHDR: codecSupportsHDR, screenSupportsEDR: screenSupportsEDR > 1)
        rendererWindow.colorSpace = usesEDR ? nil : .sRGB
        rendererWindow.contentView?.layer?.wantsExtendedDynamicRangeContent = usesEDR
    }

    static func nativeNVSTPresentationUsesEDR(requestedHDR: Bool, codecSupportsHDR: Bool, screenSupportsEDR: Bool) -> Bool {
        requestedHDR && codecSupportsHDR && screenSupportsEDR
    }

    public func setNativeNVSTVideoVisible(_ visible: Bool) {
        nativeNVSTVideoVisible = visible
        if visible { nativeNVSTRendererPreparedForShutdown = false }
        nvstCoreRenderer?.setVideoVisible(visible)
        nvstCoreRenderer?.layoutVideoView()
        if !nativeNVSTRendererPreparedForShutdown { _ = embedNativeNVSTMetalViewIfAvailable() }
        nativeNVSTMetalView?.isHidden = !visible
        nativeNVSTRendererWindow.alphaValue = 0
    }

    public var nativeNVSTRendererSurfaceReady: Bool {
        if let renderer = nvstCoreRenderer {
            return renderer.isSurfaceReady
        }
        guard nativeNVSTRendererEnabled, nativeNVSTVideoVisible, !nativeNVSTRendererPreparedForShutdown,
              let metalView = nativeNVSTMetalView, metalView.superview === videoSurface,
              let metalLayer = metalView.layer as? CAMetalLayer else { return false }
        return metalLayer.drawableSize.width >= 1 && metalLayer.drawableSize.height >= 1
    }

    public func prepareNativeNVSTRendererForShutdown() {
        detachNVSTCoreRenderer()
        removePointerLockNotifications()
        if isPointerLocked {
            disablePointerLock()
        } else {
            removePointerLockMonitor()
        }
        nativeNVSTVideoVisible = false
        nativeNVSTRendererPreparedForShutdown = true
        nativeNVSTRendererWindow.keyboardFocusEnabled = false
        if nativeNVSTRendererWindow.isKeyWindow {
            window?.makeKeyAndOrderFront(nil)
        }
        nativeNVSTRendererWindow.alphaValue = 0
        if let nativeNVSTRendererParentWindow {
            nativeNVSTRendererParentWindow.removeChildWindow(nativeNVSTRendererWindow)
            self.nativeNVSTRendererParentWindow = nil
        }
        nativeNVSTRendererWindow.orderOut(nil)
        removeNativeNVSTDisplayNotifications()
        guard let metalView = nativeNVSTMetalView,
              let rendererContentView = nativeNVSTRendererWindow.contentView else { return }
        metalView.isHidden = true
        metalView.removeFromSuperview()
        metalView.frame = rendererContentView.bounds
        metalView.autoresizingMask = [.width, .height]
        rendererContentView.addSubview(metalView)
        nativeNVSTMetalView = nil
    }

    public var streamWindowHasInputFocus: Bool {
        guard NSApplication.shared.isActive, let window else { return false }
        return NSApplication.shared.keyWindow === window
    }

    public func restoreInputFocus() {
        guard remoteInputEnabled, !localOverlayCapturesInput, isFrontmostInputTarget else { return }
        window?.makeFirstResponder(self)
        if locksPointerWhenRelativeModeSelected, mouseInputMode == .relative {
            setPointerLocked(true)
        }
    }

    public func setRemoteCursorVisible(_ isVisible: Bool) {
        remoteCursorWantsPointer = isVisible
        guard !manualPointerCaptureOverride else { return }
        let mode: NativeNVSTStreamMouseInputMode = isVisible ? .absolute : .relative
        mouseInputMode = mode
        if mode == .relative {
            if remoteInputEnabled { setPointerLocked(true) }
        } else if isPointerLocked {
            setPointerLocked(false)
        }
    }

    public func applyServerCursorVisibility(_ visible: Bool) {
        setRemoteCursorVisible(visible)
    }

    public func setManualPointerCapture(_ captured: Bool) {
        setPointerLocked(captured)
        manualPointerCaptureOverride = captured && isPointerLocked
    }

    public func synchronizeRelativePointerCapture() {
        guard remoteInputEnabled, mouseInputMode == .relative else { return }
        window?.makeFirstResponder(self)
        setPointerLocked(true)
    }

    static func hidesLocalCursorOverVideo(policy: OPNCursorPolicy,
                                          mode: NativeNVSTStreamMouseInputMode,
                                          isPointerLocked: Bool,
                                          remoteInputEnabled: Bool,
                                          localOverlayCapturesInput: Bool,
                                          seatCompositesCursor: Bool,
                                          remoteCursorWantsPointer: Bool?,
                                          isApplicationActive: Bool,
                                          isWindowKey: Bool) -> Bool {
        guard !isPointerLocked, mode == .absolute, remoteInputEnabled, !localOverlayCapturesInput,
              isApplicationActive, isWindowKey else { return false }
        switch policy {
        case .local: return false
        case .stream: return true
        case .auto: return seatCompositesCursor || remoteCursorWantsPointer == false
        }
    }

    func applyLocalCursorPolicy() {
        let hides = Self.hidesLocalCursorOverVideo(
            policy: cursorPolicy,
            mode: mouseInputMode,
            isPointerLocked: isPointerLocked,
            remoteInputEnabled: remoteInputEnabled,
            localOverlayCapturesInput: localOverlayCapturesInput,
            seatCompositesCursor: seatCompositesCursor,
            remoteCursorWantsPointer: remoteCursorWantsPointer,
            isApplicationActive: NSApplication.shared.isActive,
            isWindowKey: window?.isKeyWindow == true
        )
        guard hides != hidesLocalCursorOverVideo else { return }
        hidesLocalCursorOverVideo = hides
        window?.invalidateCursorRects(for: self)
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard hidesLocalCursorOverVideo else { return }
        let content = videoContentFrame()
        guard content.width > 0, content.height > 0 else { return }
        addCursorRect(content, cursor: Self.invisibleCursor)
    }

    private func synchronizeSDLKeyboardFocus() {
        guard nvstCoreRenderer == nil else {
            nativeNVSTRendererWindow.keyboardFocusEnabled = false
            return
        }
        guard !nativeNVSTRendererPreparedForShutdown else {
            nativeNVSTRendererWindow.keyboardFocusEnabled = false
            return
        }
        let wantsProxyFocus = nativeNVSTRendererEnabled
            && !nativeNVSTRendererPreparedForShutdown
            && remoteInputEnabled
            && directMouseInputEnabled
            && mouseInputMode == .relative
        nativeNVSTRendererWindow.keyboardFocusEnabled = wantsProxyFocus
        guard window != nil else { return }
        if wantsProxyFocus {
            if !nativeNVSTRendererWindow.isKeyWindow {
                nativeNVSTRendererWindow.makeKeyAndOrderFront(nil)
            }
        } else {
            nativeNVSTRendererWindow.keyboardFocusEnabled = false
            if nativeNVSTRendererWindow.isKeyWindow {
                window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    public override func layout() {
        super.layout()
        videoSurface.frame = videoContentFrame()
        for subview in videoSurface.subviews {
            subview.frame = videoSurface.bounds
        }
        nvstCoreRenderer?.layoutVideoView()
        nativeNVSTMetalView?.frame = videoSurface.bounds
        if nativeNVSTRendererEnabled && nativeNVSTRendererWindow.parent != nil {
            updateNativeNVSTRendererWindowFrame()
            updateNativeNVSTPresentation()
            if !nativeNVSTRendererPreparedForShutdown { _ = embedNativeNVSTMetalViewIfAvailable() }
        }
    }

    private func updateNativeNVSTRendererWindowParent() {
        guard nativeNVSTRendererParentWindow !== window else { return }
        if let nativeNVSTRendererParentWindow {
            nativeNVSTRendererParentWindow.removeChildWindow(nativeNVSTRendererWindow)
        }
        nativeNVSTRendererParentWindow = window
        guard let window else {
            nativeNVSTRendererWindow.orderOut(nil)
            return
        }
        window.addChildWindow(nativeNVSTRendererWindow, ordered: .above)
        nativeNVSTRendererWindow.orderFront(nil)
        updateNativeNVSTRendererWindowFrame()
    }

    private func updateNativeNVSTRendererWindowFrame() {
        guard let window else { return }
        let rendererFrameInWindow = videoSurface.convert(videoSurface.bounds, to: nil)
        nativeNVSTRendererWindow.setFrame(window.convertToScreen(rendererFrameInWindow), display: true)
    }

    private func installNativeNVSTDisplayNotifications() {
        removeNativeNVSTDisplayNotifications()
        guard let window else { return }
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNativeNVSTDisplayState() }
        }
        for observedWindow in [window, nativeNVSTRendererWindow] {
            nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: observedWindow, queue: .main, using: refresh))
            nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: observedWindow, queue: .main, using: refresh))
            nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSWindow.didChangeScreenProfileNotification, object: observedWindow, queue: .main, using: refresh))
        }
        nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: NSApplication.shared, queue: .main, using: refresh))
    }

    private func removeNativeNVSTDisplayNotifications() {
        let center = NotificationCenter.default
        nativeNVSTDisplayNotificationTokens.forEach { center.removeObserver($0) }
        nativeNVSTDisplayNotificationTokens.removeAll()
    }

    private func refreshNativeNVSTDisplayState() {
        guard nativeNVSTRendererEnabled else { return }
        updateNativeNVSTRendererWindowFrame()
        if let nativeNVSTMetalView { updateNativeNVSTMetalDrawableSize(nativeNVSTMetalView) }
        updateNativeNVSTPresentation()
    }

    private func updateNativeNVSTPresentation() {
        let screenSupportsEDR = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let usesEDR = Self.nativeNVSTPresentationUsesEDR(
            requestedHDR: nativeNVSTRendererWindow.hdrPresentationRequested,
            codecSupportsHDR: nativeNVSTRendererWindow.codecSupportsHDR,
            screenSupportsEDR: screenSupportsEDR > 1
        )
        nativeNVSTRendererWindow.colorSpace = usesEDR ? nil : .sRGB
        nativeNVSTRendererWindow.contentView?.layer?.wantsExtendedDynamicRangeContent = usesEDR
        videoSurface.layer?.wantsExtendedDynamicRangeContent = usesEDR
        nativeNVSTMetalView?.layer?.wantsExtendedDynamicRangeContent = usesEDR
    }

    @discardableResult
    private func embedNativeNVSTMetalViewIfAvailable() -> Bool {
        if let nativeNVSTMetalView {
            nativeNVSTMetalView.frame = videoSurface.bounds
            nativeNVSTMetalView.isHidden = !nativeNVSTVideoVisible
            updateNativeNVSTMetalDrawableSize(nativeNVSTMetalView)
            updateNativeNVSTPresentation()
            return true
        }
        guard nativeNVSTVideoVisible,
              let metalView = nativeNVSTRendererWindow.contentView?.subviews.first(where: { $0.layer is CAMetalLayer }) else { return false }
        metalView.removeFromSuperview()
        metalView.frame = videoSurface.bounds
        metalView.autoresizingMask = [.width, .height]
        metalView.isHidden = !nativeNVSTVideoVisible
        videoSurface.addSubview(metalView)
        nativeNVSTMetalView = metalView
        updateNativeNVSTMetalDrawableSize(metalView)
        updateNativeNVSTPresentation()
        return true
    }

    private func updateNativeNVSTMetalDrawableSize(_ metalView: NSView) {
        guard let metalLayer = metalView.layer as? CAMetalLayer else { return }
        let scale = max(1, metalView.window?.backingScaleFactor ?? window?.backingScaleFactor ?? 1)
        guard let drawableSize = Self.nativeNVSTDrawableSize(boundsSize: metalView.bounds.size, backingScaleFactor: scale) else { return }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = drawableSize
    }

    static func nativeNVSTDrawableSize(boundsSize: CGSize, backingScaleFactor: CGFloat) -> CGSize? {
        guard boundsSize.width.isFinite, boundsSize.height.isFinite, backingScaleFactor.isFinite,
              boundsSize.width >= 1, boundsSize.height >= 1, backingScaleFactor > 0 else { return nil }
        return CGSize(width: floor(boundsSize.width * backingScaleFactor), height: floor(boundsSize.height * backingScaleFactor))
    }

    public func setPointerLocked(_ locked: Bool) {
        if locked {
            guard !isPointerLocked else { return }
            enablePointerLock()
        } else {
            releasePressedMouseButtons()
            disablePointerLock()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        trackingArea = area
        addTrackingArea(area)
    }

    public override func mouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(.left, isPressed: true)
    }

    public override func mouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(.left, isPressed: false)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(.right, isPressed: true)
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(.right, isPressed: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        guard let button = mouseButton(event.buttonNumber) else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(button, isPressed: true)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        guard let button = mouseButton(event.buttonNumber) else { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(button, isPressed: false)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitMouseMove(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitMouseMove(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitMouseMove(event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitMouseMove(event)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitScrollWheel(event)
    }

    public override func keyDown(with event: NSEvent) {
        guard remoteInputEnabled else {
            if handleCommand(event) { return }
            super.keyDown(with: event)
            return
        }
        if handlePushToTalk(event, isPressed: true) { return }
        if handlePasteShortcut(event) { return }
        if handleCommand(event) { return }
        if forwardCommandShortcut(event) { return }
        if handleTextInput(event) { return }
        emitKey(event, isPressed: true)
    }

    public override func keyUp(with event: NSEvent) {
        guard remoteInputEnabled else {
            if handleCommand(event) { return }
            super.keyUp(with: event)
            return
        }
        if handlePushToTalk(event, isPressed: false) { return }
        if handlePasteShortcut(event) { return }
        if handleCommand(event) { return }
        if textInputKeyCodes.remove(UInt16(event.keyCode)) != nil { return }
        emitKey(event, isPressed: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard remoteInputEnabled else {
            super.flagsChanged(with: event)
            return
        }
        let pressed: Bool
        switch event.keyCode {
        case 54, 55:
            pressed = event.modifierFlags.contains(.command)
        case 56, 60:
            pressed = event.modifierFlags.contains(.shift)
        case 57:
            pressed = event.modifierFlags.contains(.capsLock)
        case 58, 61:
            pressed = event.modifierFlags.contains(.option)
        case 59, 62:
            pressed = event.modifierFlags.contains(.control)
        default:
            return
        }
        emitKey(event, isPressed: pressed)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard remoteInputEnabled else { return handleCommand(event) || super.performKeyEquivalent(with: event) }
        return handlePasteShortcut(event) || handleCommand(event) || forwardCommandShortcut(event) || super.performKeyEquivalent(with: event)
    }

    private func emitMouseMove(_ event: NSEvent) {
        if mouseInputMode == .relative, directMouseInputEnabled, !isPointerLocked {
            synchronizeRelativePointerCapture()
        }
        if !isPointerLocked, mouseInputMode == .absolute {
            emitAbsoluteMousePosition(event)
            return
        }
        emitMouseMove(deltaX: Self.truncatedMouseDelta(event.deltaX), deltaY: Self.truncatedMouseDelta(event.deltaY))
    }

    private func emitMouseMove(deltaX: Int16, deltaY: Int16) {
        guard deltaX != 0 || deltaY != 0 else { return }
        onInputEvent?(.mouse(.moved(
            deviceID: "mouse",
            deltaX: deltaX,
            deltaY: deltaY,
            timestamp: Self.timestamp()
        )))
    }

    private func emitScrollWheel(_ event: NSEvent) {
        let delta = Self.accumulatedWheelDelta(
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            remainder: &preciseScrollRemainder
        )
        guard delta != 0 else { return }
        onInputEvent?(.mouse(.wheel(deviceID: "mouse", delta: delta, timestamp: Self.timestamp())))
    }

    private func enablePointerLock() {
        guard window != nil else { return }
        let restoreLocation = cursorLocationProvider()
        guard cursorAssociationHandler(false) == .success else {
            NativeNVSTMediaTelemetry.capture("webrtc.input.pointer_lock.failed", level: .error, message: "macOS rejected relative pointer capture.", attributes: ["locked": "false"])
            return
        }
        cursorAssociationGeneration &+= 1
        isPointerLocked = true
        pointerLockRestoreLocation = restoreLocation
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        updatePointerLockCursorVisibility()
        installPointerLockMonitor()
        installPointerLockNotifications()
        applyLocalCursorPolicy()
        notifyPointerLockChanged(true)
    }

    private func disablePointerLock() {
        guard isPointerLocked else { return }
        let associationResult = cursorAssociationHandler(true)
        cursorAssociationGeneration &+= 1
        let releaseGeneration = cursorAssociationGeneration
        if associationResult != .success {
            NativeNVSTMediaTelemetry.capture("webrtc.input.pointer_unlock.failed", level: .error, message: "macOS rejected relative pointer release.", attributes: ["locked": "true"])
            retryCursorAssociation(generation: releaseGeneration)
        }
        isPointerLocked = false
        removePointerLockMonitor()
        if let restoreLocation = pointerLockRestoreLocation {
            moveCursor(toScreenPoint: restoreLocation)
        }
        pointerLockRestoreLocation = nil
        if pointerLockCursorHidden {
            NSCursor.unhide()
            pointerLockCursorHidden = false
        }
        manualPointerCaptureOverride = false
        if remoteCursorWantsPointer == true, mouseInputMode != .absolute { mouseInputMode = .absolute }
        applyLocalCursorPolicy()
        notifyPointerLockChanged(false)
    }

    private func retryCursorAssociation(generation: UInt, delay: TimeInterval = 0.01) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard cursorAssociationGeneration == generation, !isCursorCaptured else { return }
            if cursorAssociationHandler(true) != .success {
                retryCursorAssociation(generation: generation, delay: min(delay * 2, 1))
            }
        }
    }

    private func notifyPointerLockChanged(_ locked: Bool) {
        onPointerLockChanged?(locked)
        NativeNVSTMediaTelemetry.capture("webrtc.input.pointer_lock", level: .info, message: locked ? "Pointer lock enabled." : "Pointer lock disabled.", attributes: ["locked": String(locked)])
    }

    private func updatePointerLockCursorVisibility() {
        if hidesCursorWhilePointerLocked {
            if !pointerLockCursorHidden {
                NSCursor.hide()
                pointerLockCursorHidden = true
            }
        } else if pointerLockCursorHidden {
            NSCursor.unhide()
            pointerLockCursorHidden = false
        }
    }

    private func installPointerLockMonitor() {
        guard pointerLockMonitor == nil else { return }
        pointerLockMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
            guard let self, self.isCursorCaptured else { return event }
            guard NSApplication.shared.isActive, self.streamWindowHasInputFocus else {
                self.handleFocusLoss()
                return event
            }
            switch event.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                self.emitMouseMove(event)
                return nil
            case .scrollWheel:
                self.emitScrollWheel(event)
                return nil
            default:
                return event
            }
        }
    }

    private func removePointerLockMonitor() {
        guard let pointerLockMonitor else { return }
        NSEvent.removeMonitor(pointerLockMonitor)
        self.pointerLockMonitor = nil
    }

    private func installPointerLockNotifications() {
        guard pointerLockNotificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let appToken = center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApplication.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFocusLoss() }
        }
        let windowToken = center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFocusLoss() }
        }
        let appActiveToken = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApplication.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFocusGain() }
        }
        let becameKeyToken = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFocusGain() }
        }
        pointerLockNotificationTokens = [appToken, windowToken, appActiveToken, becameKeyToken]
    }

    func handleFocusGain() {
        restoreInputFocus()
        applyLocalCursorPolicy()
    }

    private func removePointerLockNotifications() {
        let center = NotificationCenter.default
        pointerLockNotificationTokens.forEach { center.removeObserver($0) }
        pointerLockNotificationTokens.removeAll()
    }

    private func moveCursor(toScreenPoint point: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? window?.screen
        guard let screen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            CGWarpMouseCursorPosition(point)
            return
        }
        let displayPoint = CGPoint(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y)
        CGDisplayMoveCursorToPoint(CGDirectDisplayID(screenNumber.uint32Value), displayPoint)
    }

    private func capturePointerForMouseDown() -> Bool {
        guard remoteInputEnabled, directMouseInputEnabled, mouseInputMode == .relative, !isPointerLocked else { return false }
        synchronizeSDLKeyboardFocus()
        setPointerLocked(true)
        return isPointerLocked
    }

    static func accumulatedWheelDelta(scrollingDeltaY: Double,
                                      hasPreciseScrollingDeltas: Bool,
                                      remainder: inout Double) -> Int16 {
        guard scrollingDeltaY.isFinite else { return 0 }
        if !hasPreciseScrollingDeltas {
            remainder = 0
            let scaled = min(max((scrollingDeltaY * 120).rounded(), Double(Int16.min)), Double(Int16.max))
            return Int16(scaled)
        }
        remainder += scrollingDeltaY
        let completeDetents = remainder.rounded(.towardZero)
        guard completeDetents != 0 else { return 0 }
        let packetLimit = Double(Int16.max / 120)
        let packetDetents = min(max(completeDetents, -packetLimit), packetLimit)
        remainder -= packetDetents
        return Int16(packetDetents * 120)
    }

    private static func isSamePointerPosition(_ lhs: NativeNVSTAbsoluteMouseEvent?, _ rhs: NativeNVSTAbsoluteMouseEvent?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.x == rhs.x && lhs.y == rhs.y && lhs.viewportWidth == rhs.viewportWidth && lhs.viewportHeight == rhs.viewportHeight
    }

    private func emitAbsoluteMousePosition(_ event: NSEvent) {
        guard !isPointerLocked, mouseInputMode == .absolute else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let absoluteEvent = absoluteMouseEvent(at: point, timestamp: Self.timestamp()) else { return }
        guard !Self.isSamePointerPosition(lastEmittedAbsoluteMouseEvent, absoluteEvent) else { return }
        lastEmittedAbsoluteMouseEvent = absoluteEvent
        onAbsoluteMouseMove?(absoluteEvent)
    }

    func absoluteMouseEvent(at point: CGPoint, timestamp: MediaTimestamp) -> NativeNVSTAbsoluteMouseEvent? {
        let contentFrame = videoContentFrame()
        guard contentFrame.width > 0, contentFrame.height > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let backingScale = max(1, window?.backingScaleFactor ?? 1)
        let viewportWidth = max(1, (contentFrame.width * backingScale).rounded())
        let viewportHeight = max(1, (contentFrame.height * backingScale).rounded())
        let clampedX = min(max(0, point.x - contentFrame.minX), contentFrame.width)
        let clampedY = min(max(0, contentFrame.maxY - point.y), contentFrame.height)
        let pixelX = min(max(0, floor(clampedX * backingScale)), viewportWidth - 1)
        let pixelY = min(max(0, floor(clampedY * backingScale)), viewportHeight - 1)
        return NativeNVSTAbsoluteMouseEvent(
            x: Int32(clamping: Int(pixelX)),
            y: Int32(clamping: Int(pixelY)),
            viewportWidth: Int32(clamping: Int(viewportWidth)),
            viewportHeight: Int32(clamping: Int(viewportHeight)),
            timestamp: timestamp
        )
    }

    private func videoContentFrame() -> CGRect {
        guard bounds.width > 0, bounds.height > 0, streamContentSize.width > 0, streamContentSize.height > 0 else { return bounds }
        let viewAspect = bounds.width / bounds.height
        let contentAspect = streamContentSize.width / streamContentSize.height
        if contentAspect > viewAspect {
            let height = bounds.width / contentAspect
            return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height).integral
        }
        let width = bounds.height * contentAspect
        return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height).integral
    }

    private func emitMouseButton(_ button: MouseButton, isPressed: Bool) {
        if isPressed {
            guard pressedMouseButtons.insert(button).inserted else { return }
        } else {
            guard pressedMouseButtons.remove(button) != nil else { return }
        }
        onInputEvent?(.mouse(.button(deviceID: "mouse", button: button, isPressed: isPressed, timestamp: Self.timestamp())))
    }

    private func releasePressedInputs() {
        let timestamp = Self.timestamp()
        let keyboardEvents = pressedKeyboardEvents.values
        let mouseButtons = pressedMouseButtons
        let gamepadStates = activeGamepadStates.values
        pressedKeyboardEvents.removeAll()
        textInputKeyCodes.removeAll()
        pushToTalkState?.release()
        textInputState.cancel()
        activeGamepadStates.removeAll()
        preciseScrollRemainder = 0
        lastEmittedAbsoluteMouseEvent = nil
        for event in keyboardEvents {
            onInputEvent?(.keyboard(KeyboardEvent(
                deviceID: event.deviceID,
                keyCode: event.keyCode,
                scanCode: event.scanCode,
                modifiers: [],
                isPressed: false,
                timestamp: timestamp
            )))
        }
        releasePressedMouseButtons(mouseButtons, timestamp: timestamp)
        for state in gamepadStates {
            onInputEvent?(.gamepad(GamepadState(deviceID: state.deviceID, playerIndex: state.playerIndex, timestamp: timestamp)))
        }
    }

    private func emitCurrentAbsoluteMousePosition(timestamp: MediaTimestamp) {
        guard let window else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = convert(windowPoint, from: nil)
        guard let event = absoluteMouseEvent(at: viewPoint, timestamp: timestamp) else { return }
        lastEmittedAbsoluteMouseEvent = event
        isEmittingNeutralizingAbsolutePosition = true
        defer { isEmittingNeutralizingAbsolutePosition = false }
        onAbsoluteMouseMove?(event)
    }

    func handleFocusLoss() {
        releasePressedInputs()
        setPointerLocked(false)
    }

    func receiveGamepadState(_ state: GamepadState) {
        activeGamepadStates[state.playerIndex] = state
        onInputEvent?(.gamepad(state))
    }

    private func releasePressedMouseButtons() {
        releasePressedMouseButtons(pressedMouseButtons, timestamp: Self.timestamp())
    }

    private func releasePressedMouseButtons(_ buttons: Set<MouseButton>, timestamp: MediaTimestamp) {
        pressedMouseButtons.subtract(buttons)
        for button in buttons.sorted(by: { Self.mouseButtonOrder($0) < Self.mouseButtonOrder($1) }) {
            if mouseInputMode == .absolute {
                lastEmittedAbsoluteMouseEvent = nil
                emitCurrentAbsoluteMousePosition(timestamp: timestamp)
            }
            onInputEvent?(.mouse(.button(deviceID: "mouse", button: button, isPressed: false, timestamp: timestamp)))
        }
    }

    private static func mouseButtonOrder(_ button: MouseButton) -> Int {
        switch button {
        case .left: 0
        case .middle: 1
        case .right: 2
        case .back: 3
        case .forward: 4
        }
    }

    private func handleCommand(_ event: NSEvent) -> Bool {
        guard let command = streamCommand(for: event) else { return false }
        guard shouldHandleCommand?(command) == true else { return false }
        if event.type == .keyDown { onCommand?(command) }
        return true
    }

    private func handlePasteShortcut(_ event: NSEvent) -> Bool {
        guard Self.isPasteShortcut(event), NSPasteboard.general.string(forType: .string) != nil else { return false }
        if event.type == .keyDown, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            onInputEvent?(.text(deviceID: "keyboard", value: text, timestamp: Self.timestamp()))
        }
        return true
    }

    private static func isPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == 9 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        return modifiers == .command
    }

    private func streamCommand(for event: NSEvent) -> NativeNVSTMediaStreamCommand? {
        NativeNVSTMediaStreamCommand.shortcutCommand(keyCode: UInt16(event.keyCode), modifierFlags: event.modifierFlags)
    }

    private func installKeyEquivalentMonitor() {
        guard keyEquivalentMonitor == nil else { return }
        keyEquivalentMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            guard self.streamWindowHasInputFocus,
                  Self.isStreamWindowKeyEvent(event.window, streamWindow: self.window) else {
                self.releaseRemotelyPressedKeyIfNeeded(event)
                return event
            }
            guard NSApplication.shared.isActive else {
                self.releaseRemotelyPressedKeyIfNeeded(event)
                return event
            }
            guard self.remoteInputEnabled else { return self.handleCommand(event) ? nil : event }
            if self.handlePushToTalk(event, isPressed: event.type == .keyDown) { return nil }
            let routesToApplication = Self.reservesApplicationMenuKeyEquivalent(event.modifierFlags)
            if routesToApplication { self.releaseRemotelyPressedKeyIfNeeded(event) }
            if self.handlePasteShortcut(event) { return nil }
            if self.handleCommand(event) { return nil }
            if self.forwardCommandShortcut(event) { return nil }
            if routesToApplication { return event }
            if event.type == .keyDown {
                if !self.handleTextInput(event) { self.emitKey(event, isPressed: true) }
            } else if self.textInputKeyCodes.remove(UInt16(event.keyCode)) == nil {
                self.emitKey(event, isPressed: false)
            }
            return nil
        }
    }

    private func forwardCommandShortcut(_ event: NSEvent) -> Bool {
        guard remoteInputEnabled, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }

        switch event.keyCode {
        case 12, 4, 46, 43: // Q, H, M, Comma (system app menu shortcuts)
            return false
        case 0, 1, 3, 6, 7, 8, 9, 11, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 45:
            // A, S, F, Z, X, C, V, B, W, E, R, Y, T, O, U, I, P, L, J, N
            let timestamp = Self.timestamp()
            let ctrlModifier: KeyboardModifiers = modifiers.contains(.shift) ? [.control, .shift] : [.control]

            onInputEvent?(.keyboard(KeyboardEvent(
                deviceID: "keyboard",
                keyCode: 59,
                scanCode: 59,
                modifiers: ctrlModifier,
                isPressed: true,
                timestamp: timestamp
            )))
            onInputEvent?(.keyboard(KeyboardEvent(
                deviceID: "keyboard",
                keyCode: UInt16(event.keyCode),
                scanCode: UInt16(event.keyCode),
                modifiers: ctrlModifier,
                isPressed: true,
                timestamp: timestamp
            )))
            onInputEvent?(.keyboard(KeyboardEvent(
                deviceID: "keyboard",
                keyCode: UInt16(event.keyCode),
                scanCode: UInt16(event.keyCode),
                modifiers: ctrlModifier,
                isPressed: false,
                timestamp: timestamp
            )))
            onInputEvent?(.keyboard(KeyboardEvent(
                deviceID: "keyboard",
                keyCode: 59,
                scanCode: 59,
                modifiers: [],
                isPressed: false,
                timestamp: timestamp
            )))
            return true
        default:
            return false
        }
    }

    static func reservesApplicationMenuKeyEquivalent(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    static func isStreamWindowKeyEvent(_ eventWindow: NSWindow?, streamWindow: NSWindow?) -> Bool {
        guard let eventWindow, let streamWindow else { return false }
        if eventWindow === streamWindow { return true }
        return streamWindow.childWindows?.contains(where: { $0 === eventWindow }) == true
    }

    private func removeKeyEquivalentMonitor() {
        guard let keyEquivalentMonitor else { return }
        NSEvent.removeMonitor(keyEquivalentMonitor)
        self.keyEquivalentMonitor = nil
    }

    private func emitKey(_ event: NSEvent, isPressed: Bool) {
        let keyboardEvent = Self.keyboardEvent(from: event, isPressed: isPressed)
        if pushToTalkState?.handle(keyboardEvent) == true { return }
        if keyboardEvent.keyCode == 57 {
            pressedKeyboardEvents.removeValue(forKey: keyboardEvent.keyCode)
        } else if isPressed {
            pressedKeyboardEvents[keyboardEvent.keyCode] = keyboardEvent
        } else {
            pressedKeyboardEvents.removeValue(forKey: keyboardEvent.keyCode)
        }
        onInputEvent?(.keyboard(keyboardEvent))
    }

    private func handleTextInput(_ event: NSEvent) -> Bool {
        guard Self.shouldInterpretAsText(event, hasMarkedText: hasMarkedText(), inputSourceID: inputContext?.selectedKeyboardInputSource) else { return false }
        textInputKeyCodes.insert(UInt16(event.keyCode))
        interpretKeyEvents([event])
        return true
    }

    static func shouldInterpretAsText(_ event: NSEvent, hasMarkedText: Bool, inputSourceID: String?) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        if hasMarkedText || modifiers.contains(.option) { return true }
        if inputSourceID?.localizedCaseInsensitiveContains("inputmethod") == true { return true }
        guard let characters = event.characters, !characters.isEmpty else { return true }
        if characters.unicodeScalars.contains(where: { $0.value >= 0xF700 && $0.value <= 0xF8FF }) { return false }
        return !characters.unicodeScalars.allSatisfy(\.isASCII)
    }

    private func handlePushToTalk(_ event: NSEvent, isPressed: Bool) -> Bool {
        pushToTalkState?.handle(Self.keyboardEvent(from: event, isPressed: isPressed)) == true
    }

    private static func keyboardEvent(from event: NSEvent, isPressed: Bool) -> KeyboardEvent {
        KeyboardEvent(
            deviceID: "keyboard",
            keyCode: UInt16(event.keyCode),
            scanCode: UInt16(event.keyCode),
            modifiers: modifiers(event.modifierFlags),
            isPressed: isPressed,
            timestamp: timestamp()
        )
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let value = Self.string(from: string)
        guard let committed = textInputState.commit(value) else { return }
        onInputEvent?(.text(deviceID: "keyboard", value: committed, timestamp: Self.timestamp()))
    }

    public override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) { cancelOperation(nil) }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        textInputState.setMarkedText(Self.attributedString(from: string), selectedRange: selectedRange, replacementRange: replacementRange)
    }

    public func unmarkText() {
        guard let committed = textInputState.unmark() else { return }
        onInputEvent?(.text(deviceID: "keyboard", value: committed, timestamp: Self.timestamp()))
    }

    public func selectedRange() -> NSRange { textInputState.selection }
    public func markedRange() -> NSRange { textInputState.markedRange }
    public func hasMarkedText() -> Bool { textInputState.hasMarkedText }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let (substring, resolvedRange) = textInputState.attributedSubstring(for: range) else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        actualRange?.pointee = resolvedRange
        return substring
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.markedClauseSegment, .replacementIndex, .underlineStyle, .underlineColor, .foregroundColor, .backgroundColor]
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let length = textInputState.markedText.length
        let location = range.location == NSNotFound ? textInputState.selection.location : min(range.location, length)
        actualRange?.pointee = NSRange(location: location, length: min(range.length, length - location))
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let prefixRange = NSRange(location: 0, length: location)
        let prefix = textInputState.markedText.attributedSubstring(from: prefixRange).string as NSString
        let offset = prefix.size(withAttributes: [.font: font]).width
        let localRect = NSRect(x: min(bounds.maxX, bounds.minX + offset), y: bounds.minY, width: 1, height: font.ascender - font.descender)
        guard let window else { return localRect }
        return window.convertToScreen(convert(localRect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return 0 }
        let localPoint = convert(window.convertPoint(fromScreen: point), from: nil)
        let text = textInputState.markedText.string as NSString
        guard text.length > 0 else { return 0 }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var width: CGFloat = 0
        for index in 0..<text.length {
            let characterWidth = text.substring(with: NSRange(location: index, length: 1)).size(withAttributes: [.font: font]).width
            if localPoint.x < bounds.minX + width + characterWidth / 2 { return index }
            width += characterWidth
        }
        return text.length
    }

    public override func cancelOperation(_ sender: Any?) {
        textInputState.cancel()
    }

    private static func string(from value: Any) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String ?? ""
    }

    private static func attributedString(from value: Any) -> NSAttributedString {
        if let attributed = value as? NSAttributedString { return attributed }
        return NSAttributedString(string: value as? String ?? "")
    }

    private func releaseRemotelyPressedKeyIfNeeded(_ event: NSEvent) {
        guard event.type == .keyUp, pressedKeyboardEvents[UInt16(event.keyCode)] != nil else { return }
        emitKey(event, isPressed: false)
    }

    private func mouseButton(_ buttonNumber: Int) -> MouseButton? {
        switch buttonNumber {
        case 2:
            .middle
        case 3:
            .back
        case 4:
            .forward
        default:
            nil
        }
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyboardModifiers {
        var modifiers: KeyboardModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if flags.contains(.numericPad) { modifiers.insert(.numericPad) }
        return modifiers
    }

    static func truncatedMouseDelta(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let truncated = value.rounded(.towardZero)
        if truncated <= Double(Int16.min) { return Int16.min }
        if truncated >= Double(Int16.max) { return Int16.max }
        return Int16(truncated)
    }

    private static func timestamp() -> MediaTimestamp {
        MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}
