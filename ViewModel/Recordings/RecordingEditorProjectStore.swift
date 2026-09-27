import Foundation

struct RecordingEditorProject: Codable, Identifiable {
    struct Segment: Codable {
        var id: UUID
        var recordingID: UUID
        var startSeconds: Double
        var endSeconds: Double
        var audioGain: Double
        var isAudioMuted: Bool
        var fadeInSeconds: Double
        var fadeOutSeconds: Double
        var transitionBefore: String?
        var transitionDurationSeconds: Double?
    }

    struct TimelineSettings: Codable {
        var zoomScale: Double
        var snappingEnabled: Bool
        var visibleStartSeconds: Double?
    }

    var schemaVersion: Int
    var id: UUID
    var primaryRecordingID: UUID
    var title: String
    var segments: [Segment]
    var selectedSegmentID: UUID?
    var markers: [RecordingEditorMarker]
    var timelineSettings: TimelineSettings
    var cropX: Double
    var cropY: Double
    var cropWidth: Double
    var cropHeight: Double
    var cropEnabled: Bool
    var cropAspectPreset: String?
    var rotationRawValue: Int
    var isFlippedHorizontally: Bool
    var isFlippedVertically: Bool
    var playbackRate: Double
    var isMuted: Bool
    var volume: Double
    var fadeInSeconds: Double
    var fadeOutSeconds: Double
    var exportQuality: String
    var outputResolution: String
    var colorExposure: Double
    var colorContrast: Double
    var colorSaturation: Double
    var colorTemperature: Double
    var colorTint: Double
    var colorVignette: Double
    var transcript: RecordingEditorTranscript?
    var captions: [RecordingEditorCaption]
    var burnInCaptions: Bool
    var overlays: [RecordingEditorOverlay]?
    var zoomKeyframes: [RecordingEditorZoomKeyframe]?
}

enum RecordingEditorProjectStore {
    private static let currentSchemaVersion = 5

    static func load(primaryRecordingID: UUID) throws -> RecordingEditorProject? {
        guard FileManager.default.fileExists(atPath: projectDirectory.path) else { return nil }
        let projects = try FileManager.default.contentsOfDirectory(at: projectDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (RecordingEditorProject, Date)? in
                guard let data = try? Data(contentsOf: url), var project = try? JSONDecoder().decode(RecordingEditorProject.self, from: data),
                      (2...currentSchemaVersion).contains(project.schemaVersion), project.primaryRecordingID == primaryRecordingID else { return nil }
                if project.schemaVersion < currentSchemaVersion {
                    let playbackRate = max(0.25, project.playbackRate)
                    project.markers = project.markers.map { marker in
                        var migrated = marker
                        migrated.timeSeconds /= playbackRate
                        return migrated
                    }
                    project.timelineSettings.visibleStartSeconds = (project.timelineSettings.visibleStartSeconds ?? 0) / playbackRate
                }
                project.schemaVersion = currentSchemaVersion
                if project.overlays == nil { project.overlays = [] }
                if project.zoomKeyframes == nil { project.zoomKeyframes = [] }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (project, date)
            }
        return projects.max(by: { $0.1 < $1.1 })?.0
    }

    static func save(_ project: RecordingEditorProject) throws {
        let directory = projectDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(project)
        try data.write(to: projectURL(for: project.id), options: .atomic)
    }

    static func discard(projectID: UUID) throws {
        let url = projectURL(for: projectID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static var projectDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("PixelNOW/RecordingEditorProjects", isDirectory: true)
    }

    private static func projectURL(for projectID: UUID) -> URL {
        projectDirectory.appendingPathComponent(projectID.uuidString).appendingPathExtension("json")
    }
}
