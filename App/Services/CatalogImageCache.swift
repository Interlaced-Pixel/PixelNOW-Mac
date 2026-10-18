//
//  CatalogImageCache.swift
//  PixelNOW
//

import AppKit
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import SwiftData

struct CatalogCachedImageData: @unchecked Sendable {
    let data: Data
    let image: NSImage
}

struct CatalogImageCacheStatistics: Sendable {
    let entryCount: Int
    let totalBytes: Int
}

struct CatalogImageLoadProgress: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case queued
        case downloading
        case loaded
        case failed
    }

    let status: Status
    let receivedBytes: Int64
    let expectedBytes: Int64?

    var fractionCompleted: Double? {
        switch status {
        case .queued:
            return 0
        case .downloading, .failed:
            guard let expectedBytes, expectedBytes > 0 else { return nil }
            return min(1, Double(receivedBytes) / Double(expectedBytes))
        case .loaded:
            return 1
        }
    }

    var accessibilityDescription: String {
        switch status {
        case .queued:
            return "Artwork queued"
        case .downloading:
            if let expectedBytes, expectedBytes > 0 {
                return "Downloading artwork, \(receivedBytes) of \(expectedBytes) bytes"
            }
            return "Downloading artwork, \(receivedBytes) bytes received"
        case .loaded:
            return "Artwork ready, \(receivedBytes) bytes"
        case .failed:
            return "Artwork unavailable, \(receivedBytes) bytes received"
        }
    }

    static var queued: Self {
        Self(status: .queued, receivedBytes: 0, expectedBytes: nil)
    }
}

typealias CatalogImageProgressHandler = @MainActor @Sendable (CatalogImageLoadProgress) -> Void
typealias CatalogImagePrefetchProgressHandler = @MainActor @Sendable (URL, CatalogImageLoadProgress) -> Void

actor CatalogImageCache {
    static let shared = CatalogImageCache()

    private struct InFlightImageLoad {
        let id: UUID
        let task: Task<CatalogCachedImageData?, Never>
        var observers: [UUID: CatalogImageProgressHandler]
        var latestProgress: CatalogImageLoadProgress
    }

    private let memoryCache = NSCache<NSURL, CatalogCachedImageBox>()
    private let loadingArtworkCache = NSCache<NSString, CatalogCachedImageBox>()
    private let cacheDirectory: URL
    private var inFlightLoads: [URL: InFlightImageLoad] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchQueue: [URL] = []
    private var prefetchQueueHead = 0
    private var queuedPrefetchURLs: Set<URL> = []
    private var metadataIndex: [String: StoredImageMetadata]?
    private var storedByteCount = 0

    private let maximumCacheAge: TimeInterval = 14 * 24 * 60 * 60
    private let maximumStoredBytes = 512 * 1024 * 1024
    private let maximumStoredEntries = 2_000

    private init() {
        cacheDirectory = Self.defaultCacheDirectory()
        memoryCache.countLimit = 512
        memoryCache.totalCostLimit = 128 * 1024 * 1024
        loadingArtworkCache.countLimit = 48
        loadingArtworkCache.totalCostLimit = 192 * 1024 * 1024
        Self.ensureCacheDirectory(at: cacheDirectory)
    }

    nonisolated func configure(container _: ModelContainer) {}

    nonisolated func prefetch(_ urls: [URL]) {
        Task(priority: .background) { [weak self] in
            await self?.startPrefetch(urls)
        }
    }

    func image(for url: URL, onProgress: CatalogImageProgressHandler? = nil) async -> CatalogCachedImageData? {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            if let onProgress {
                let byteCount = Int64(cached.value.data.count)
                await onProgress(CatalogImageLoadProgress(status: .loaded, receivedBytes: byteCount, expectedBytes: byteCount))
            }
            return cached.value
        }

        let loadID: UUID
        let loadTask: Task<CatalogCachedImageData?, Never>
        let observerID: UUID?

        if var existingLoad = inFlightLoads[url] {
            loadID = existingLoad.id
            loadTask = existingLoad.task
            if let onProgress {
                let id = UUID()
                observerID = id
                existingLoad.observers[id] = onProgress
                inFlightLoads[url] = existingLoad
                await onProgress(existingLoad.latestProgress)
            } else {
                observerID = nil
            }
        } else {
            loadID = UUID()
            observerID = onProgress == nil ? nil : UUID()
            let task = Task<CatalogCachedImageData?, Never> { [weak self] in
                guard let self else { return nil }
                return await self.loadImage(for: url, loadID: loadID)
            }
            loadTask = task
            var observers: [UUID: CatalogImageProgressHandler] = [:]
            if let onProgress, let observerID {
                observers[observerID] = onProgress
            }
            inFlightLoads[url] = InFlightImageLoad(
                id: loadID,
                task: task,
                observers: observers,
                latestProgress: .queued
            )
        }

        let result = await loadTask.value
        if let load = inFlightLoads[url], load.id == loadID {
            let finalProgress: CatalogImageLoadProgress
            if let result {
                let byteCount = Int64(result.data.count)
                finalProgress = CatalogImageLoadProgress(status: .loaded, receivedBytes: byteCount, expectedBytes: byteCount)
            } else {
                finalProgress = CatalogImageLoadProgress(
                    status: .failed,
                    receivedBytes: load.latestProgress.receivedBytes,
                    expectedBytes: load.latestProgress.expectedBytes
                )
            }
            await publish(finalProgress, for: url, loadID: loadID)
            inFlightLoads[url] = nil
        }
        return result
    }

    func prefetch(
        _ urls: [URL],
        concurrencyLimit: Int = 4,
        onProgress: @escaping CatalogImagePrefetchProgressHandler
    ) async {
        var seenURLs = Set<URL>()
        let uniqueURLs = urls.filter { seenURLs.insert($0).inserted }
        let limit = max(1, concurrencyLimit)
        guard !uniqueURLs.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            for _ in 0..<min(limit, uniqueURLs.count) {
                let url = uniqueURLs[nextIndex]
                nextIndex += 1
                group.addTask { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    _ = await self.image(for: url, onProgress: { progress in
                        onProgress(url, progress)
                    })
                }
            }

            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                guard nextIndex < uniqueURLs.count else { continue }
                let url = uniqueURLs[nextIndex]
                nextIndex += 1
                group.addTask { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    _ = await self.image(for: url, onProgress: { progress in
                        onProgress(url, progress)
                    })
                }
            }
        }
    }

    func loadingArtwork(for url: URL, targetPixelSize: CGSize, focalPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)) async -> CatalogCachedImageData? {
        let width = max(1, Int(targetPixelSize.width.rounded()))
        let height = max(1, Int(targetPixelSize.height.rounded()))
        let focalX = min(max(focalPoint.x, 0), 1)
        let focalY = min(max(focalPoint.y, 0), 1)
        let key = "\(cacheKey(for: url))|\(width)x\(height)|\(Int(focalX * 1000))x\(Int(focalY * 1000))" as NSString
        if let cached = loadingArtworkCache.object(forKey: key) { return cached.value }
        guard let source = await image(for: url), !Task.isCancelled else { return nil }
        guard let processed = await Self.processLoadingArtwork(
            source.data,
            targetWidth: width,
            targetHeight: height,
            focalX: focalX,
            focalY: focalY
        ), !Task.isCancelled else { return nil }
        loadingArtworkCache.setObject(CatalogCachedImageBox(value: processed), forKey: key, cost: memoryCost(for: processed))
        return processed
    }

    func statistics() -> CatalogImageCacheStatistics {
        ensureMetadataIndex()
        return CatalogImageCacheStatistics(entryCount: metadataIndex?.count ?? 0, totalBytes: storedByteCount)
    }

    func clear() -> Bool {
        do {
            try FileManager.default.removeItem(at: cacheDirectory)
            ensureCacheDirectory()
            memoryCache.removeAllObjects()
            loadingArtworkCache.removeAllObjects()
            prefetchQueue.removeAll()
            prefetchQueueHead = 0
            queuedPrefetchURLs.removeAll()
            prefetchTask?.cancel()
            prefetchTask = nil
            metadataIndex = [:]
            storedByteCount = 0
            return true
        } catch {
            return false
        }
    }

    private func startPrefetch(_ urls: [URL]) {
        let uniqueUrls = Array(Dictionary(grouping: urls, by: { $0 }).keys)
        guard !uniqueUrls.isEmpty else { return }
        for url in uniqueUrls where !queuedPrefetchURLs.contains(url) {
            queuedPrefetchURLs.insert(url)
            prefetchQueue.append(url)
        }
        startPrefetchTaskIfNeeded()
    }

    private func startPrefetchTaskIfNeeded() {
        guard prefetchTask == nil, !prefetchQueue.isEmpty else { return }
        prefetchTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            while let url = await self.nextPrefetchURL() {
                guard !Task.isCancelled else { return }
                if await self.hasCachedImage(for: url) { continue }
                _ = await self.image(for: url)
                try? await Task.sleep(nanoseconds: 35_000_000)
            }
            await self.prefetchDidFinish()
        }
    }

    private func nextPrefetchURL() -> URL? {
        guard prefetchQueueHead < prefetchQueue.count else {
            prefetchQueue.removeAll(keepingCapacity: true)
            prefetchQueueHead = 0
            return nil
        }
        let url = prefetchQueue[prefetchQueueHead]
        prefetchQueueHead += 1
        queuedPrefetchURLs.remove(url)
        if prefetchQueueHead >= prefetchQueue.count {
            prefetchQueue.removeAll(keepingCapacity: true)
            prefetchQueueHead = 0
        } else if prefetchQueueHead >= 256 && prefetchQueueHead >= prefetchQueue.count / 2 {
            prefetchQueue.removeFirst(prefetchQueueHead)
            prefetchQueueHead = 0
        }
        return url
    }

    private func prefetchDidFinish() {
        prefetchTask = nil
        startPrefetchTaskIfNeeded()
    }

    private func loadImage(for url: URL, loadID: UUID) async -> CatalogCachedImageData? {
        if let stored = loadStoredImage(for: url) {
            if stored.isFresh {
                return stored.imageData
            }
            refreshStoredImage(for: url, eTag: stored.eTag, lastModified: stored.lastModified)
            return stored.imageData
        }
        return await downloadAndStoreImage(for: url, eTag: "", lastModified: "", loadID: loadID)
    }

    private func publish(_ progress: CatalogImageLoadProgress, for url: URL, loadID: UUID) async {
        guard var load = inFlightLoads[url], load.id == loadID else { return }
        load.latestProgress = progress
        inFlightLoads[url] = load
        for observer in load.observers.values {
            await observer(progress)
        }
    }

    private nonisolated static func processLoadingArtwork(
        _ data: Data,
        targetWidth: Int,
        targetHeight: Int,
        focalX: CGFloat,
        focalY: CGFloat
    ) async -> CatalogCachedImageData? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                return nil
            }

            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
            var image = CIImage(cgImage: cgImage).oriented(forExifOrientation: orientation)
            let orientedExtent = image.extent.integral
            guard orientedExtent.width > 0, orientedExtent.height > 0 else { return nil }
            image = image.transformed(by: CGAffineTransform(translationX: -orientedExtent.minX, y: -orientedExtent.minY))

            let targetAspect = CGFloat(targetWidth) / CGFloat(targetHeight)
            let sourceAspect = image.extent.width / image.extent.height
            let cropWidth = sourceAspect > targetAspect ? image.extent.height * targetAspect : image.extent.width
            let cropHeight = sourceAspect > targetAspect ? image.extent.height : image.extent.width / targetAspect
            let originX = min(max(image.extent.width * focalX - cropWidth * 0.5, 0), image.extent.width - cropWidth)
            let originY = min(max(image.extent.height * focalY - cropHeight * 0.5, 0), image.extent.height - cropHeight)
            let crop = CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight)
            image = image
                .cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -originX, y: -originY))

            let scale = CGFloat(targetWidth) / cropWidth
            guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return nil }
            lanczos.setValue(image, forKey: kCIInputImageKey)
            lanczos.setValue(scale, forKey: kCIInputScaleKey)
            lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
            guard var scaled = lanczos.outputImage else { return nil }
            let expectedExtent = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            scaled = scaled.cropped(to: expectedExtent)

            if let sharpen = CIFilter(name: "CISharpenLuminance") {
                sharpen.setValue(scaled, forKey: kCIInputImageKey)
                sharpen.setValue(0.28, forKey: kCIInputSharpnessKey)
                sharpen.setValue(0.6, forKey: kCIInputRadiusKey)
                if let sharpened = sharpen.outputImage { scaled = sharpened.cropped(to: expectedExtent) }
            }

            let context = CIContext(options: [.useSoftwareRenderer: false])
            guard let output = context.createCGImage(scaled, from: expectedExtent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
                return nil
            }
            let processedImage = NSImage(cgImage: output, size: NSSize(width: targetWidth, height: targetHeight))
            return CatalogCachedImageData(data: data, image: processedImage)
        }.value
    }

    private func loadStoredImage(for url: URL) -> StoredImage? {
        let key = cacheKey(for: url)
        let dataURL = imageFileURL(for: key)
        let metadataURL = metadataFileURL(for: key)
        guard let data = try? Data(contentsOf: dataURL),
              var metadata = readMetadata(at: metadataURL),
              metadata.url == url.absoluteString,
              let image = NSImage(data: data) else {
            removeStoredImage(for: key)
            return nil
        }
        metadata.lastAccessedAt = Date()
        metadata.hitCount += 1
        metadata.byteCount = data.count
        writeMetadata(metadata, to: metadataURL)
        updateIndexedMetadata(metadata, for: key)
        let imageData = CatalogCachedImageData(data: data, image: image)
        memoryCache.setObject(CatalogCachedImageBox(value: imageData), forKey: url as NSURL, cost: memoryCost(for: imageData))
        return StoredImage(imageData: imageData, isFresh: Date().timeIntervalSince(metadata.updatedAt) < maximumCacheAge, eTag: metadata.eTag, lastModified: metadata.lastModified)
    }

    private func refreshStoredImage(for url: URL, eTag: String, lastModified: String) {
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            _ = await self.downloadAndStoreImage(for: url, eTag: eTag, lastModified: lastModified)
        }
    }

    private func downloadAndStoreImage(
        for url: URL,
        eTag: String,
        lastModified: String,
        loadID: UUID? = nil
    ) async -> CatalogCachedImageData? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        if !eTag.isEmpty { request.setValue(eTag, forHTTPHeaderField: "If-None-Match") }
        if !lastModified.isEmpty { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let networkStart = NetworkLog.start(request, operation: "catalog.image")
        var expectedBytes: Int64?
        var receivedBytes: Int64 = 0
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            expectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            if let loadID {
                await publish(
                    CatalogImageLoadProgress(status: .downloading, receivedBytes: 0, expectedBytes: expectedBytes),
                    for: url,
                    loadID: loadID
                )
            }

            var data = Data()
            if let expectedBytes, expectedBytes <= 64 * 1024 * 1024 {
                data.reserveCapacity(Int(expectedBytes))
            }
            let progressUpdateStride = 16 * 1024
            var pendingBytes: [UInt8] = []
            pendingBytes.reserveCapacity(progressUpdateStride)

            for try await byte in bytes {
                pendingBytes.append(byte)
                receivedBytes += 1
                guard pendingBytes.count >= progressUpdateStride else { continue }
                data.append(contentsOf: pendingBytes)
                pendingBytes.removeAll(keepingCapacity: true)
                if let loadID {
                    await publish(
                        CatalogImageLoadProgress(status: .downloading, receivedBytes: receivedBytes, expectedBytes: expectedBytes),
                        for: url,
                        loadID: loadID
                    )
                }
            }
            if !pendingBytes.isEmpty {
                data.append(contentsOf: pendingBytes)
                if let loadID {
                    await publish(
                        CatalogImageLoadProgress(status: .downloading, receivedBytes: receivedBytes, expectedBytes: expectedBytes),
                        for: url,
                        loadID: loadID
                    )
                }
            }
            NetworkLog.finish(operation: "catalog.image", startedAt: networkStart, data: data, response: response, error: nil)
            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run { Log.warning(.cache, "Catalog image response was not HTTP url=\(url.absoluteString)") }
                return nil
            }
            if httpResponse.statusCode == 304 {
                markStoredImageFresh(for: url)
                await MainActor.run { Log.debug(.cache, "Catalog image cache validated url=\(url.absoluteString)") }
                return loadStoredImage(for: url)?.imageData
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                await MainActor.run { Log.warning(.cache, "Catalog image download failed status=\(httpResponse.statusCode) url=\(url.absoluteString)") }
                return nil
            }
            guard let image = NSImage(data: data) else {
                await MainActor.run { Log.warning(.cache, "Catalog image data could not be decoded url=\(url.absoluteString) bytes=\(data.count)") }
                return nil
            }
            let imageData = CatalogCachedImageData(data: data, image: image)
            store(imageData: imageData, response: httpResponse, for: url)
            await MainActor.run { Log.debug(.cache, "Catalog image cached url=\(url.absoluteString) bytes=\(data.count)") }
            return imageData
        } catch {
            if let loadID {
                await publish(
                    CatalogImageLoadProgress(status: .downloading, receivedBytes: receivedBytes, expectedBytes: expectedBytes),
                    for: url,
                    loadID: loadID
                )
            }
            NetworkLog.finish(operation: "catalog.image", startedAt: networkStart, data: nil, response: nil, error: error)
            await MainActor.run { Log.warning(.cache, "Catalog image download threw url=\(url.absoluteString) error=\(error.localizedDescription)") }
            return nil
        }
    }

    private func hasCachedImage(for url: URL) -> Bool {
        memoryCache.object(forKey: url as NSURL) != nil
    }

    private func markStoredImageFresh(for url: URL) {
        let key = cacheKey(for: url)
        let metadataURL = metadataFileURL(for: key)
        guard var metadata = readMetadata(at: metadataURL) else { return }
        let now = Date()
        metadata.updatedAt = now
        metadata.lastAccessedAt = now
        writeMetadata(metadata, to: metadataURL)
        updateIndexedMetadata(metadata, for: key)
    }

    private func store(imageData: CatalogCachedImageData, response: HTTPURLResponse, for url: URL) {
        ensureCacheDirectory()
        let key = cacheKey(for: url)
        let dataURL = imageFileURL(for: key)
        let metadataURL = metadataFileURL(for: key)
        let now = Date()
        ensureMetadataIndex()
        let previous = metadataIndex?[key] ?? readMetadata(at: metadataURL)
        let metadata = StoredImageMetadata(
            url: url.absoluteString,
            mimeType: response.mimeType ?? "",
            eTag: response.value(forHTTPHeaderField: "ETag") ?? "",
            lastModified: response.value(forHTTPHeaderField: "Last-Modified") ?? "",
            byteCount: imageData.data.count,
            createdAt: previous?.createdAt ?? now,
            updatedAt: now,
            lastAccessedAt: now,
            hitCount: previous?.hitCount ?? 0
        )
        do {
            try imageData.data.write(to: dataURL, options: .atomic)
            writeMetadata(metadata, to: metadataURL)
        } catch {
            removeStoredImage(for: key)
            return
        }
        updateIndexedMetadata(metadata, for: key)
        memoryCache.setObject(CatalogCachedImageBox(value: imageData), forKey: url as NSURL, cost: memoryCost(for: imageData))
        if (metadataIndex?.count ?? 0) > maximumStoredEntries || storedByteCount > maximumStoredBytes { pruneIfNeeded() }
    }

    private func pruneIfNeeded() {
        ensureMetadataIndex()
        let oldestFirst = (metadataIndex ?? [:]).sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        for (key, _) in oldestFirst {
            guard (metadataIndex?.count ?? 0) > maximumStoredEntries || storedByteCount > maximumStoredBytes else { break }
            removeStoredImage(for: key)
        }
    }

    private func ensureMetadataIndex() {
        guard metadataIndex == nil else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            metadataIndex = [:]
            storedByteCount = 0
            return
        }
        let entries = urls.filter { $0.pathExtension == "json" }.compactMap { url -> (String, StoredImageMetadata)? in
            guard let metadata = readMetadata(at: url) else { return nil }
            return (url.deletingPathExtension().lastPathComponent, metadata)
        }
        metadataIndex = Dictionary(entries, uniquingKeysWith: { _, newest in newest })
        storedByteCount = entries.reduce(0) { $0 + max(0, $1.1.byteCount) }
    }

    private func updateIndexedMetadata(_ metadata: StoredImageMetadata, for key: String) {
        guard metadataIndex != nil else { return }
        let previous = metadataIndex?.updateValue(metadata, forKey: key)
        storedByteCount += metadata.byteCount - (previous?.byteCount ?? 0)
    }

    private func memoryCost(for imageData: CatalogCachedImageData) -> Int {
        let decodedCost = imageData.image.representations.reduce(into: 0) { total, representation in
            guard total < Int.max, representation.pixelsWide > 0, representation.pixelsHigh > 0 else { return }
            let (pixelCount, pixelCountOverflow) = representation.pixelsWide.multipliedReportingOverflow(by: representation.pixelsHigh)
            guard !pixelCountOverflow else { total = Int.max; return }
            let (representationCost, representationCostOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
            guard !representationCostOverflow else { total = Int.max; return }
            let (combinedCost, combinedCostOverflow) = total.addingReportingOverflow(representationCost)
            total = combinedCostOverflow ? Int.max : combinedCost
        }
        let (estimatedCost, estimatedCostOverflow) = imageData.data.count.addingReportingOverflow(decodedCost)
        return estimatedCostOverflow ? Int.max : estimatedCost
    }

    private func readMetadata(at url: URL) -> StoredImageMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredImageMetadata.self, from: data)
    }

    private func writeMetadata(_ metadata: StoredImageMetadata, to url: URL) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func removeStoredImage(for key: String) {
        ensureMetadataIndex()
        if let removed = metadataIndex?.removeValue(forKey: key) {
            storedByteCount = max(0, storedByteCount - removed.byteCount)
        }
        try? FileManager.default.removeItem(at: imageFileURL(for: key))
        try? FileManager.default.removeItem(at: metadataFileURL(for: key))
    }

    private func imageFileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key, isDirectory: false).appendingPathExtension("img")
    }

    private func metadataFileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key, isDirectory: false).appendingPathExtension("json")
    }

    private func cacheKey(for url: URL) -> String {
        cacheKey(for: url.absoluteString)
    }

    private func cacheKey(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func ensureCacheDirectory() {
        Self.ensureCacheDirectory(at: cacheDirectory)
    }

    private static func ensureCacheDirectory(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PixelNOW", isDirectory: true).appendingPathComponent("CatalogImageCache", isDirectory: true)
    }

    private struct StoredImage {
        let imageData: CatalogCachedImageData
        let isFresh: Bool
        let eTag: String
        let lastModified: String
    }

    private struct StoredImageMetadata: Codable, Sendable {
        let url: String
        let mimeType: String
        let eTag: String
        let lastModified: String
        var byteCount: Int
        let createdAt: Date
        var updatedAt: Date
        var lastAccessedAt: Date
        var hitCount: Int
    }
}

nonisolated private final class CatalogCachedImageBox {
    let value: CatalogCachedImageData

    init(value: CatalogCachedImageData) {
        self.value = value
    }
}
