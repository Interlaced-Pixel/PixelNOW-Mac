import Foundation

public enum RecordingEditorOverlayKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case callout
    case redaction
    case blur

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .callout: "Callout"
        case .redaction: "Redaction"
        case .blur: "Blur"
        }
    }
}

public struct RecordingEditorOverlay: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: RecordingEditorOverlayKind
    public var startSeconds: Double
    public var endSeconds: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var text: String

    public init(id: UUID = UUID(), kind: RecordingEditorOverlayKind, startSeconds: Double, endSeconds: Double, x: Double = 0.1, y: Double = 0.1, width: Double = 0.35, height: Double = 0.18, text: String = "Callout") {
        self.id = id
        self.kind = kind
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
    }
}
