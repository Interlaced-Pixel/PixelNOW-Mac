import CoreGraphics
import CoreVideo
import Foundation
import Vision

public struct DetectedTextElement: Sendable, Equatable {
    public let text: String
    public let bounds: CGRect
    public let confidence: Float

    public init(text: String, bounds: CGRect, confidence: Float) {
        self.text = text
        self.bounds = bounds
        self.confidence = confidence
    }

    public func remotePoint(viewportWidth: Int32, viewportHeight: Int32) -> (x: Int32, y: Int32) {
        let normalizedX = Double(bounds.midX)
        let normalizedY = Double(1.0 - bounds.midY)
        let clampedX = Int32(clamping: Int(normalizedX * Double(viewportWidth)))
        let clampedY = Int32(clamping: Int(normalizedY * Double(viewportHeight)))
        return (clampedX, clampedY)
    }
}

public final class DesktopMacroVisionScanner: @unchecked Sendable {
    public static let shared = DesktopMacroVisionScanner()

    public init() {}

    public func recognizeText(in pixelBuffer: CVPixelBuffer) -> [DetectedTextElement] {
        var results: [DetectedTextElement] = []
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                results.append(DetectedTextElement(
                    text: candidate.string,
                    bounds: observation.boundingBox,
                    confidence: candidate.confidence
                ))
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
        return results
    }

    // MARK: - Screen Context Classifiers

    /// Detects if the Steam "Friends & Chat" window is visible.
    /// Returns the location of the close ("X") button to dismiss it.
    public func detectFriendsWindow(in elements: [DetectedTextElement], viewportWidth: Int32, viewportHeight: Int32) -> (closePoint: (x: Int32, y: Int32), label: String)? {
        let friendsIndicators = ["FRIENDS & CHAT", "FRIENDS AND CHAT", "FRIENDS LIST", "SIGN IN TO CHAT"]
        for element in elements {
            let u = element.text.uppercased()
            for indicator in friendsIndicators {
                if u.contains(indicator) {
                    let headerPt = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
                    // If an 'X' close button element exists near this header, click it directly
                    if let closeElement = elements.first(where: {
                        let pt = $0.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
                        return abs(pt.y - headerPt.y) < 35 && pt.x > headerPt.x && ($0.text.uppercased() == "X" || $0.text == "×" || $0.text == "✕")
                    }) {
                        let pt = closeElement.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
                        return (closePoint: pt, label: closeElement.text)
                    }
                    // Otherwise, the close button in Steam Friends is located at the top-right of the friends window titlebar (~280px right or window edge)
                    let estimatedCloseX = min(viewportWidth - 15, headerPt.x + 280)
                    return (closePoint: (x: estimatedCloseX, y: max(20, headerPt.y)), label: "Close Friends")
                }
            }
        }
        return nil
    }

    /// Detects if an "Install - [Game]" wizard dialog is open and returns the button to advance/install (Next, Install, I Agree, Finish).
    public func detectInstallPrompt(in elements: [DetectedTextElement], viewportWidth: Int32, viewportHeight: Int32) -> (buttonPoint: (x: Int32, y: Int32), label: String)? {
        let hasInstallIndicators = elements.contains {
            let u = $0.text.uppercased()
            return u.contains("INSTALL -") || u.contains("CHOOSE LOCATION") || u.contains("DISK SPACE REQUIRED") || u.contains("READY TO LAUNCH") || u.contains("CREATE DESKTOP SHORTCUT")
        }
        guard hasInstallIndicators else { return nil }

        // Action buttons to advance the installation
        let advanceLabels = ["NEXT >", "NEXT", "INSTALL", "I AGREE", "FINISH"]
        for label in advanceLabels {
            if let buttonElement = elements.first(where: {
                let trimmed = $0.text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed == label || trimmed.contains(label)
            }) {
                let pt = buttonElement.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
                return (buttonPoint: pt, label: buttonElement.text)
            }
        }
        return nil
    }

    /// Finds the top navigation header "STORE" button in Steam (y < 120px) for LEFT-CLICKING to navigate to the store.
    public func findSteamTopStoreButton(in elements: [DetectedTextElement], viewportWidth: Int32, viewportHeight: Int32) -> (point: (x: Int32, y: Int32), label: String)? {
        for element in elements {
            let pt = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            // Top navigation is in the upper ~120px of the screen
            guard pt.y < 120 else { continue }
            let trimmed = element.text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "STORE" {
                return (pt, element.text)
            }
        }
        return nil
    }

    /// Checks if the Steam Store page has finished loading inside the client webview.
    public func isSteamStorePageLoaded(in elements: [DetectedTextElement]) -> Bool {
        let storeContentMarkers = [
            "FEATURED", "SPECIAL OFFERS", "TOP SELLERS", "NEW & TRENDING",
            "BROWSE", "CATEGORIES", "POINTS SHOP", "NEWS", "GREAT ON DECK",
            "FREE TO PLAY", "DISCOVERY QUEUE", "WISHLIST", "CART", "SEARCH"
        ]
        var matches = 0
        for element in elements {
            let u = element.text.uppercased()
            for marker in storeContentMarkers {
                if u.contains(marker) {
                    matches += 1
                    if matches >= 2 { return true }
                }
            }
        }
        return false
    }

    /// Finds an actual hyperlink inside the Steam Store webview body (remoteY between 140px and 850px).
    /// This is what we RIGHT-CLICK to get the "Open link in new tab" context menu.
    public func findStoreWebHyperlink(in elements: [DetectedTextElement], viewportWidth: Int32, viewportHeight: Int32) -> (point: (x: Int32, y: Int32), label: String)? {
        let preferredLinkPhrases = [
            "COMMUNITY HUB", "VISIT THE WEBSITE", "VIEW STATS", "DISCUSSIONS",
            "SPECIAL OFFERS", "TOP SELLERS", "FREE TO PLAY", "ACTION", "STRATEGY",
            "RPG", "ADVENTURE", "SIMULATION", "CASUAL", "INDIE", "NEW RELEASES"
        ]

        // First pass: look for known store link phrases in the webview area
        for element in elements {
            let pt = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            guard pt.y >= 140 && pt.y <= 850 && pt.x >= 50 && pt.x <= (viewportWidth - 50) else { continue }
            let u = element.text.uppercased()
            for phrase in preferredLinkPhrases {
                if u.contains(phrase) {
                    return (pt, element.text)
                }
            }
        }

        // Second pass: any prominent text element in the main store view
        for element in elements {
            let pt = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            guard pt.y >= 160 && pt.y <= 750 && pt.x >= 100 && pt.x <= (viewportWidth - 100) else { continue }
            let trimmed = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 4 && !trimmed.allSatisfy(\.isNumber) {
                let u = trimmed.uppercased()
                if !u.contains("STEAM") && !u.contains("VALVE") && !u.contains("STORE") && !u.contains("LIBRARY") {
                    return (pt, element.text)
                }
            }
        }

        return nil
    }

    /// Locates "Open link in new tab" or "Open link in new window" in the Chromium context menu.
    public func findContextMenuOption(in elements: [DetectedTextElement], viewportWidth: Int32, viewportHeight: Int32) -> (point: (x: Int32, y: Int32), label: String)? {
        let targetPhrases = [
            "OPEN LINK IN NEW TAB",
            "OPEN LINK IN NEW WINDOW",
            "OPEN IN NEW TAB",
            "OPEN IN NEW WINDOW",
            "NEW TAB",
            "NEW WINDOW",
            "COPY LINK ADDRESS"
        ]

        for phrase in targetPhrases {
            if let element = elements.first(where: {
                $0.text.uppercased().contains(phrase)
            }) {
                let point = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
                return (point, element.text)
            }
        }

        return nil
    }

    /// Locates the address bar in the Steam browser window / tab.
    public func findAddressBar(in elements: [DetectedTextElement], viewportWidth: Int32, viewportHeight: Int32) -> (point: (x: Int32, y: Int32), label: String)? {
        let urlIndicators = [
            "HTTP:", "HTTPS:", "HTTP//", "HTTPS//", "HTTP://", "HTTPS://", "://",
            "STORE.STEAM", "STEAMPOWERED", "STEAMCOMMUNITY",
            ".COM/APP", "/APP/", "/STORE/", "/GENRE/",
            "ENTER A URL", "SEARCH OR ENTER", "WWW.",
            "HTTPS://STORE", "HTTP://STORE", "STORE.STEAMPOWERED.COM"
        ]
        // Primary pass: Elements with URL indicators in the navigation region (y between 20 and 240)
        for element in elements {
            let pt = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            guard pt.y >= 20 && pt.y <= 240 && pt.x >= 40 && pt.x <= (viewportWidth - 40) else { continue }
            let u = element.text.uppercased()
            for indicator in urlIndicators {
                if u.contains(indicator) {
                    return (pt, element.text)
                }
            }
        }
        // Secondary pass: Any element containing ".COM" or "/APP" in navigation region
        for element in elements {
            let pt = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            guard pt.y >= 20 && pt.y <= 240 && pt.x >= 40 && pt.x <= (viewportWidth - 40) else { continue }
            let u = element.text.uppercased()
            if u.contains(".COM") || u.contains("/APP") {
                return (pt, element.text)
            }
        }
        return nil
    }

    /// Verifies whether the address bar was overwritten with the SalsaNOW updater URL.
    public func isAddressBarOverwritten(in elements: [DetectedTextElement]) -> Bool {
        let salsaIndicators = [
            "SALSANOW", "UPDATER", "FILES.WORK", "SALSANOWFILES", "SALSA"
        ]
        for element in elements {
            let upper = element.text.uppercased()
            for indicator in salsaIndicators {
                if upper.contains(indicator) {
                    return true
                }
            }
        }
        return false
    }

    /// Locates the newly opened tab header in the Steam tab strip to ensure it is focused.
    public func findNewTabHeader(in elements: [DetectedTextElement], hint: String?, viewportWidth: Int32, viewportHeight: Int32) -> (point: (x: Int32, y: Int32), label: String)? {
        let tabKeywords = ["TAB", "NEW TAB", "WESNOTH", "BATTLE", "DCS"]
        for element in elements {
            let pt = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            guard pt.y >= 20 && pt.y <= 120 && pt.x >= 120 && pt.x <= (viewportWidth - 150) else { continue }
            let u = element.text.uppercased()
            if let hint = hint?.uppercased(), !hint.isEmpty && u.contains(hint) {
                return (pt, element.text)
            }
            for kw in tabKeywords {
                if u.contains(kw) {
                    return (pt, element.text)
                }
            }
        }
        return nil
    }

    /// Detects if a browser tab or separate browser window is active.
    public func detectBrowserWindow(in elements: [DetectedTextElement]) -> Bool {
        let browserIndicators = [
            "HTTP", "HTTPS", "://", "ENTER A URL", "SEARCH OR ENTER",
            "STEAM BROWSER", "WEB BROWSER", "NEW TAB", "STORE.STEAM", "STEAMPOWERED"
        ]
        for element in elements {
            let upper = element.text.uppercased()
            for indicator in browserIndicators {
                if upper.contains(indicator) {
                    return true
                }
            }
        }
        return false
    }

    /// Detects Windows "Save As" file dialog.
    public func detectSaveAsDialog(in elements: [DetectedTextElement]) -> Bool {
        let dialogIndicators = [
            "SAVE AS", "SAVE IN:", "FILE NAME:", "SAVE AS TYPE:",
            "HIDE FOLDERS", "BROWSE FOLDERS", "THIS PC", "QUICK ACCESS"
        ]
        for element in elements {
            let upper = element.text.uppercased()
            for indicator in dialogIndicators {
                if upper.contains(indicator) {
                    return true
                }
            }
        }
        return false
    }

    /// Locates the game folder or executable in the Save As dialog.
    public func findExecutableInDialog(in elements: [DetectedTextElement], hint: String? = nil, viewportWidth: Int32, viewportHeight: Int32) -> (point: (x: Int32, y: Int32), label: String)? {
        if let hint, !hint.isEmpty {
            let upperHint = hint.uppercased()
            if let element = elements.first(where: {
                let u = $0.text.uppercased()
                return u.contains(upperHint) && u.contains(".EXE")
            }) {
                let point = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
                return (point, element.text)
            }
        }

        let targetHints = ["WESNOTH", "BATTLE FOR WESNOTH", "DCS"]
        for target in targetHints {
            if let element = elements.first(where: {
                $0.text.uppercased().contains(target)
            }) {
                let point = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
                return (point, element.text)
            }
        }

        if let element = elements.first(where: {
            $0.text.uppercased().contains(".EXE")
        }) {
            let point = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            return (point, element.text)
        }

        let folderHints = ["WESNOTH", "BATTLE FOR WESNOTH", "DCS", "COMMON", "STEAMAPPS", "STEAM"]
        for folder in folderHints {
            if let element = elements.first(where: {
                $0.text.uppercased().contains(folder)
            }) {
                let point = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
                return (point, element.text)
            }
        }

        return nil
    }

    /// Finds the "Save" button in the Save As dialog.
    public func findSaveButton(in elements: [DetectedTextElement], viewportWidth: Int32, viewportHeight: Int32) -> (point: (x: Int32, y: Int32), label: String)? {
        if let element = elements.first(where: {
            let trimmed = $0.text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "SAVE" || trimmed == "&SAVE"
        }) {
            let point = element.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            return (point, element.text)
        }
        return nil
    }

    /// Detects if an overwrite confirmation ("Confirm Save As" / "Do you want to replace it?") is showing.
    public func detectOverwriteConfirmation(in elements: [DetectedTextElement], viewportWidth: Int32, viewportHeight: Int32) -> (point: (x: Int32, y: Int32), label: String)? {
        let hasWarning = elements.contains {
            let u = $0.text.uppercased()
            return u.contains("ALREADY EXISTS") || u.contains("REPLACE IT") || u.contains("CONFIRM SAVE AS")
        }
        guard hasWarning else { return nil }

        if let yesElement = elements.first(where: {
            let trimmed = $0.text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "YES" || trimmed == "&YES"
        }) {
            let point = yesElement.remotePoint(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            return (point, yesElement.text)
        }
        return nil
    }
}
