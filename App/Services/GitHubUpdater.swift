import Foundation

struct GitHubRelease: Sendable {
    let version: String
    let tagName: String
    let releaseNotes: String
    let releaseURL: String
    let assetName: String
    let assetDownloadURL: String
}

public enum UpdateStage: Sendable, Equatable {
    case initialStart
    case downloading(fractionCompleted: Double, bytesWritten: Int64, totalBytesExpected: Int64)
    case extracting
    case relaunching

    public var stageIndex: Int {
        switch self {
        case .initialStart: 0
        case .downloading: 1
        case .extracting: 2
        case .relaunching: 3
        }
    }
}

public struct UpdateProgressState: Sendable, Equatable {
    public let stage: UpdateStage
    public let overallFraction: Double
    public let title: String
    public let detail: String

    public init(stage: UpdateStage, overallFraction: Double, title: String, detail: String) {
        self.stage = stage
        self.overallFraction = overallFraction
        self.title = title
        self.detail = detail
    }

    public static let initial = UpdateProgressState(
        stage: .initialStart,
        overallFraction: 0.05,
        title: "Starting update...",
        detail: "Connecting to GitHub..."
    )
}

actor GitHubUpdater {
    fileprivate enum UpdateError: LocalizedError {
        case invalidResponse(String)
        case noReleaseAsset
        case notBundledApp
        case downloadFailed(String)
        case extractionFailed
        case validationFailed(String)
        case installerLaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let message), .downloadFailed(let message), .validationFailed(let message), .installerLaunchFailed(let message):
                message
            case .noReleaseAsset:
                "The latest GitHub release does not include an PixelNOW macOS zip asset."
            case .notBundledApp:
                "Updates can only be installed from the packaged PixelNOW.app bundle."
            case .extractionFailed:
                "The update archive could not be extracted."
            }
        }
    }

    let currentVersion: String

    private let owner: String
    private let repository: String
    private let session: URLSession

    init(owner: String, repository: String) {
        self.owner = owner
        self.repository = repository
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func checkForUpdate() async throws -> GitHubRelease? {
        guard let release = try await fetchLatestRelease(repository: repository) else { return nil }
        return compareVersion(release.version, to: currentVersion) > 0 ? release : nil
    }

    private func fetchLatestRelease(repository: String) async throws -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest") else {
            throw UpdateError.invalidResponse("The GitHub release URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PixelNOW-Updater", forHTTPHeaderField: "User-Agent")

        logInfo("Checking GitHub release metadata repository=\(owner)/\(repository) currentVersion=\(currentVersion)")
        let networkStart = NetworkLog.start(&request, operation: "updater.releaseMetadata")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            NetworkLog.finish(request, operation: "updater.releaseMetadata", startedAt: networkStart, data: data, response: response, error: nil)
        } catch {
            NetworkLog.finish(request, operation: "updater.releaseMetadata", startedAt: networkStart, data: nil, response: nil, error: error)
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode), !data.isEmpty else {
            throw UpdateError.invalidResponse("GitHub did not return a valid release response.")
        }

        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let json = decoded as? [String: Any] else {
            throw UpdateError.invalidResponse("GitHub release metadata was not valid JSON.")
        }

        let release = try release(from: json)
        logInfo("GitHub release metadata received latestVersion=\(release.version) currentVersion=\(currentVersion)")
        return release
    }

    func installRelease(
        _ release: GitHubRelease,
        onProgress: (@Sendable (UpdateProgressState) -> Void)? = nil
    ) async throws -> Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            throw UpdateError.notBundledApp
        }
        guard let downloadURL = URL(string: release.assetDownloadURL) else {
            throw UpdateError.invalidResponse("The release asset download URL is invalid.")
        }

        onProgress?(UpdateProgressState(
            stage: .initialStart,
            overallFraction: 0.05,
            title: "Starting update...",
            detail: "Connecting to GitHub..."
        ))

        var request = URLRequest(url: downloadURL)
        logInfo("Downloading update archive version=\(release.version) asset=\(release.assetName)")
        let networkStart = NetworkLog.start(&request, operation: "updater.archiveDownload")
        let archiveURL: URL
        do {
            archiveURL = try await downloadArchiveWithProgress(request: request) { bytesWritten, totalBytesExpected in
                let fraction: Double
                let detail: String
                if totalBytesExpected > 0 {
                    fraction = min(max(Double(bytesWritten) / Double(totalBytesExpected), 0.0), 1.0)
                    let writtenStr = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
                    let totalStr = ByteCountFormatter.string(fromByteCount: totalBytesExpected, countStyle: .file)
                    let percentage = Int(fraction * 100)
                    detail = "\(writtenStr) of \(totalStr) (\(percentage)%)"
                } else {
                    fraction = 0.0
                    let writtenStr = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
                    detail = "\(writtenStr) downloaded"
                }
                let overall = 0.05 + (0.75 * fraction)
                onProgress?(UpdateProgressState(
                    stage: .downloading(fractionCompleted: fraction, bytesWritten: bytesWritten, totalBytesExpected: totalBytesExpected),
                    overallFraction: overall,
                    title: "Downloading update...",
                    detail: detail
                ))
            }
            NetworkLog.finish(request, operation: "updater.archiveDownload", startedAt: networkStart, data: nil, response: responseArchivePlaceholder(url: archiveURL), error: nil)
        } catch {
            NetworkLog.finish(request, operation: "updater.archiveDownload", startedAt: networkStart, data: nil, response: nil, error: error)
            throw error
        }

        return try stageAndLaunchInstaller(
            downloadedArchiveURL: archiveURL,
            release: release,
            currentBundleURL: bundleURL,
            onProgress: onProgress
        )
    }

    private func responseArchivePlaceholder(url: URL) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) ?? URLResponse()
    }

    private func downloadArchiveWithProgress(
        request: URLRequest,
        onProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let holder = DownloadTaskHolder()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = UpdateDownloadDelegate(onProgress: onProgress, continuation: continuation)
                let downloadSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
                let task = downloadSession.downloadTask(with: request)
                holder.set(task: task, session: downloadSession)
                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private func stageAndLaunchInstaller(
        downloadedArchiveURL: URL,
        release: GitHubRelease,
        currentBundleURL: URL,
        onProgress: (@Sendable (UpdateProgressState) -> Void)? = nil
    ) throws -> Bool {
        let fileManager = FileManager.default
        let stagingURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveCopyURL = stagingURL.appendingPathComponent(release.assetName, isDirectory: false)
        let extractURL = stagingURL.appendingPathComponent("extracted", isDirectory: true)

        try fileManager.createDirectory(at: extractURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: downloadedArchiveURL, to: archiveCopyURL)
        try? fileManager.removeItem(at: downloadedArchiveURL.deletingLastPathComponent())
        logInfo("Staging update archive version=\(release.version) asset=\(release.assetName)")

        onProgress?(UpdateProgressState(
            stage: .extracting,
            overallFraction: 0.82,
            title: "Extracting update...",
            detail: "Unpacking update archive..."
        ))

        let extractProcess = Process()
        extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extractProcess.arguments = ["-x", "-k", archiveCopyURL.path, extractURL.path]
        try extractProcess.run()
        extractProcess.waitUntilExit()
        guard extractProcess.terminationStatus == 0 else {
            throw UpdateError.extractionFailed
        }

        onProgress?(UpdateProgressState(
            stage: .extracting,
            overallFraction: 0.90,
            title: "Validating update...",
            detail: "Verifying code signature and bundle integrity..."
        ))

        guard let newBundleURL = findAppBundle(in: extractURL) else {
            throw UpdateError.validationFailed("The update archive did not contain an app bundle.")
        }
        clearQuarantine(for: newBundleURL)
        try validateCandidateBundle(newBundleURL, expectedVersion: release.version, currentBundleURL: currentBundleURL)

        let installTargetURL = try writableInstallTarget(for: currentBundleURL)
        let scriptURL = stagingURL.appendingPathComponent("install-pixelnow-update.sh", isDirectory: false)
        let backupPath = installTargetURL.deletingLastPathComponent().appendingPathComponent(".\(installTargetURL.lastPathComponent).previous").path
        logInfo("Resolved update install target currentBundle=\(currentBundleURL.path) installTarget=\(installTargetURL.path)")
        let script = """
        #!/bin/sh
        set -eu
        parent_pid='\(ProcessInfo.processInfo.processIdentifier)'
        target=\(shellQuoted(installTargetURL.path))
        source=\(shellQuoted(newBundleURL.path))
        backup=\(shellQuoted(backupPath))
        staging=\(shellQuoted(stagingURL.path))
        while kill -0 "$parent_pid" >/dev/null 2>&1; do sleep 0.2; done
        rm -rf "$backup"
        if [ -d "$target" ]; then mv "$target" "$backup"; fi
        if mv "$source" "$target"; then
          /usr/bin/xattr -dr com.apple.quarantine "$target" >/dev/null 2>&1 || true
          /usr/bin/open "$target"
          rm -rf "$backup" "$staging"
        else
          if [ -d "$backup" ] && [ ! -d "$target" ]; then mv "$backup" "$target"; fi
          /usr/bin/open "$target" >/dev/null 2>&1 || true
          exit 1
        fi
        """
        try script.write(to: scriptURL, atomically: true, encoding: String.Encoding.utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        onProgress?(UpdateProgressState(
            stage: .relaunching,
            overallFraction: 1.0,
            title: "Relaunching PixelNOW...",
            detail: "Starting updated version..."
        ))

        let installerProcess = Process()
        installerProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        installerProcess.arguments = [scriptURL.path]
        do {
            try installerProcess.run()
            logInfo("Update installer launched version=\(release.version)")
            return true
        } catch {
            logError("Update installer launch failed version=\(release.version) error=\(error.localizedDescription)")
            throw UpdateError.installerLaunchFailed(error.localizedDescription)
        }
    }

    private func logInfo(_ message: String) {
        Sentry.logInfoMessage(Sentry.formattedLogMessage(level: "info", area: "Update", message: message))
    }

    private func logError(_ message: String) {
        Sentry.logErrorMessage(Sentry.formattedLogMessage(level: "error", area: "Update", message: message))
    }

    private func release(from json: [String: Any]) throws -> GitHubRelease {
        let tagName = json["tag_name"] as? String ?? ""
        let version = normalizedVersion(tagName)
        let releaseNotes = json["body"] as? String ?? ""
        let releaseURL = json["html_url"] as? String ?? ""
        let assets = json["assets"] as? [[String: Any]] ?? []
        let selectedAsset = assets.first { asset in
            let name = asset["name"] as? String ?? ""
            return name.hasPrefix("PixelNOW-") && name.hasSuffix("-macOS.zip")
        } ?? assets.first { asset in
            let name = (asset["name"] as? String ?? "").lowercased()
            return name.hasSuffix(".zip") && name.contains("macos")
        }

        guard let selectedAsset else {
            throw UpdateError.noReleaseAsset
        }
        let assetName = selectedAsset["name"] as? String ?? ""
        let assetDownloadURL = selectedAsset["browser_download_url"] as? String ?? ""
        guard !version.isEmpty, !assetDownloadURL.isEmpty else {
            throw UpdateError.noReleaseAsset
        }

        return GitHubRelease(
            version: version,
            tagName: tagName,
            releaseNotes: releaseNotes,
            releaseURL: releaseURL,
            assetName: assetName,
            assetDownloadURL: assetDownloadURL
        )
    }

    private func findAppBundle(in directoryURL: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "app" {
                return url
            }
        }
        return nil
    }

    private func validateCandidateBundle(_ candidateURL: URL?, expectedVersion: String, currentBundleURL: URL) throws {
        guard let candidateURL else {
            throw UpdateError.validationFailed("The update archive did not contain an app bundle.")
        }
        let candidateBundle = Bundle(url: candidateURL)
        let candidateIdentifier = candidateBundle?.bundleIdentifier
        let currentBundle = Bundle(url: currentBundleURL)
        let currentIdentifier = Bundle.main.bundleIdentifier ?? currentBundle?.bundleIdentifier
        let candidateVersion = candidateBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let installedVersion = currentBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? currentVersion
        let candidateExecutable = candidateBundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
        let executablePath = candidateExecutable.isEmpty ? "" : candidateURL.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(candidateExecutable).path
        var executableIsDirectory = ObjCBool(false)
        let executableExists = !executablePath.isEmpty && FileManager.default.fileExists(atPath: executablePath, isDirectory: &executableIsDirectory) && !executableIsDirectory.boolValue

        logInfo("Validating update bundle expectedVersion=\(expectedVersion) runningVersion=\(currentVersion) installedVersion=\(installedVersion) candidateVersion=\(candidateVersion ?? "missing") currentIdentifier=\(currentIdentifier ?? "missing") candidateIdentifier=\(candidateIdentifier ?? "missing") executableExists=\(executableExists ? "true" : "false")")

        guard candidateIdentifier == currentIdentifier else {
            throw UpdateError.validationFailed("The downloaded app bundle identifier was \(candidateIdentifier ?? "missing"), but PixelNOW expected \(currentIdentifier ?? "missing").")
        }
        guard executableExists else {
            throw UpdateError.validationFailed("The downloaded app bundle did not contain an executable PixelNOW app binary.")
        }
        guard let candidateVersion, compareVersion(candidateVersion, to: expectedVersion) == 0 else {
            throw UpdateError.validationFailed("The downloaded app bundle version was \(candidateVersion ?? "missing"), but the GitHub release expected \(expectedVersion).")
        }
        let effectiveCurrentVersion = compareVersion(installedVersion, to: currentVersion) > 0 ? installedVersion : currentVersion
        guard compareVersion(candidateVersion, to: effectiveCurrentVersion) > 0 else {
            throw UpdateError.validationFailed("PixelNOW is already on version \(effectiveCurrentVersion). Relaunch PixelNOW and check for updates again if the app still shows an older version.")
        }
        guard verifyCodeSignature(for: candidateURL) else {
            throw UpdateError.validationFailed("The downloaded app bundle did not pass macOS code-signature verification.")
        }
    }

    private func writableInstallTarget(for currentBundleURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let currentParentURL = currentBundleURL.deletingLastPathComponent()
        if isWritableDirectory(currentParentURL) {
            return currentBundleURL
        }

        let systemApplicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if isWritableDirectory(systemApplicationsURL) {
            return systemApplicationsURL.appendingPathComponent(currentBundleURL.lastPathComponent, isDirectory: true)
        }

        let userApplicationsURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try fileManager.createDirectory(at: userApplicationsURL, withIntermediateDirectories: true)
        if isWritableDirectory(userApplicationsURL) {
            return userApplicationsURL.appendingPathComponent(currentBundleURL.lastPathComponent, isDirectory: true)
        }

        throw UpdateError.validationFailed("PixelNOW could not find a writable Applications folder for installing the update.")
    }

    private func isWritableDirectory(_ directoryURL: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) && isDirectory.boolValue && FileManager.default.isWritableFile(atPath: directoryURL.path)
    }

    private func verifyCodeSignature(for bundleURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundleURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func clearQuarantine(for bundleURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", bundleURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                logInfo("Update quarantine attribute was not present or could not be cleared.")
            }
        } catch {
            logInfo("Update quarantine attribute could not be cleared error=\(error.localizedDescription)")
        }
    }

    private func normalizedVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }

    private func compareVersion(_ left: String, to right: String) -> Int {
        let separators = CharacterSet(charactersIn: ".-_")
        let leftParts = normalizedVersion(left).components(separatedBy: separators)
        let rightParts = normalizedVersion(right).components(separatedBy: separators)
        let count = max(leftParts.count, rightParts.count)

        for index in 0..<count {
            let leftPart = index < leftParts.count ? leftParts[index] : "0"
            let rightPart = index < rightParts.count ? rightParts[index] : "0"
            if let leftNumber = Int(leftPart), let rightNumber = Int(rightPart) {
                if leftNumber < rightNumber { return -1 }
                if leftNumber > rightNumber { return 1 }
            } else {
                let result = leftPart.compare(rightPart, options: [.caseInsensitive, .numeric])
                if result == .orderedAscending { return -1 }
                if result == .orderedDescending { return 1 }
            }
        }
        return 0
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private final class DownloadTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?

    func set(task: URLSessionDownloadTask, session: URLSession) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        self.session = session
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        session?.invalidateAndCancel()
    }
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()
    private var hasResumed = false

    init(
        onProgress: @Sendable @escaping (Int64, Int64) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        session.finishTasksAndInvalidate()
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true

        if let httpResponse = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            continuation?.resume(throwing: GitHubUpdater.UpdateError.downloadFailed("GitHub did not return the update archive."))
            continuation = nil
            return
        }

        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let destinationURL = tempDir.appendingPathComponent("update-\(UUID().uuidString).zip")
            try FileManager.default.moveItem(at: location, to: destinationURL)
            continuation?.resume(returning: destinationURL)
            continuation = nil
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        session.finishTasksAndInvalidate()
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        if (error as? URLError)?.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}

