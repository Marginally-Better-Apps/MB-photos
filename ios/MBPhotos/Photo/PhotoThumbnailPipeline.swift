@preconcurrency import Photos
import Foundation
import ImageIO
import UIKit

struct PhotoThumbnailKey: Hashable, Sendable {
    let assetID: String
    let revision: UInt64
    let pixelWidth: Int
    let pixelHeight: Int
    /// Network permission is part of request and cache identity so a local-only
    /// miss can never poison an explicitly requested iCloud thumbnail.
    let allowsNetworkAccess: Bool

    init(
        assetID: String,
        revision: UInt64,
        pixelWidth: Int,
        pixelHeight: Int,
        allowsNetworkAccess: Bool = false
    ) {
        self.assetID = assetID
        self.revision = revision
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.allowsNetworkAccess = allowsNetworkAccess
    }
}

protocol PhotoThumbnailRequesting: Sendable {
    func thumbnailData(for key: PhotoThumbnailKey) async -> Data?
}

protocol PhotoThumbnailDecoding: Sendable {
    func decode(
        data: Data,
        key: PhotoThumbnailKey,
        scale: Double
    ) async -> DecodedThumbnailImage?
}

/// UIKit images are immutable after construction but are not formally
/// `Sendable`. This box lets the thumbnail worker finish decoding and eagerly
/// materializing pixels off-main before handing the final presentation value to
/// the main actor.
final class DecodedThumbnailImage: @unchecked Sendable {
    let image: UIImage
    let estimatedByteCount: Int

    init(_ image: UIImage, estimatedByteCount: Int? = nil) {
        self.image = image
        self.estimatedByteCount = max(
            estimatedByteCount ?? image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0,
            1
        )
    }
}

struct CGImagePhotoThumbnailDecoder: PhotoThumbnailDecoding {
    func decode(
        data: Data,
        key: PhotoThumbnailKey,
        scale: Double
    ) async -> DecodedThumbnailImage? {
        let maximumPixelSize = max(key.pixelWidth, key.pixelHeight)
        let decoding = Task.detached(priority: .utility) { () -> DecodedThumbnailImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
            ]
            guard !Task.isCancelled,
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  !Task.isCancelled else { return nil }
            return DecodedThumbnailImage(
                UIImage(cgImage: decoded, scale: CGFloat(scale), orientation: .up),
                estimatedByteCount: decoded.bytesPerRow * decoded.height
            )
        }
        return await withTaskCancellationHandler {
            await decoding.value
        } onCancel: {
            decoding.cancel()
        }
    }
}

/// A bounded, actor-owned thumbnail cache. Concurrent requests for an identical
/// asset/size/revision share one PhotoKit operation. When every waiter disappears,
/// cancellation propagates to `PHImageManager.cancelImageRequest`.
actor PhotoThumbnailPipeline {
    private struct DecodedThumbnailKey: Hashable, Sendable {
        let source: PhotoThumbnailKey
        let scale: Double

        init(source: PhotoThumbnailKey, scale: CGFloat) {
            let requestedScale = Double(scale)
            self.source = source
            self.scale = requestedScale.isFinite && requestedScale > 0 ? requestedScale : 1
        }
    }

    private struct DataWorkID: Hashable, Sendable {
        let key: PhotoThumbnailKey
        let requestID: UUID
    }

    private struct DecodedWorkID: Hashable, Sendable {
        let key: DecodedThumbnailKey
        let requestID: UUID
    }

    private struct CacheEntry: Sendable {
        let data: Data
        var lastAccess: UInt64
    }

    private struct InFlight {
        let requestID: UUID
        var waiters: [UUID: CheckedContinuation<Data?, Never>]
    }

    private struct DecodedCacheEntry: Sendable {
        let image: DecodedThumbnailImage
        var lastAccess: UInt64
    }

    private struct DecodedInFlight {
        let requestID: UUID
        var waiters: [UUID: CheckedContinuation<DecodedThumbnailImage?, Never>]
    }

    private let client: any PhotoThumbnailRequesting
    private let decoder: any PhotoThumbnailDecoding
    private let permits: ThumbnailPermitPool
    private let maximumConcurrentRequests: Int
    private let maximumPendingRequests: Int
    private let maximumEntryCount: Int
    private let maximumByteCount: Int
    private var cache: [PhotoThumbnailKey: CacheEntry] = [:]
    private var inFlight: [PhotoThumbnailKey: InFlight] = [:]
    private var decodedCache: [DecodedThumbnailKey: DecodedCacheEntry] = [:]
    private var decodedInFlight: [DecodedThumbnailKey: DecodedInFlight] = [:]
    private var activeDataTasks: [DataWorkID: Task<Void, Never>] = [:]
    private var pendingDataWork: [DataWorkID] = []
    private var activeDecodedTasks: [DecodedWorkID: Task<Void, Never>] = [:]
    private var pendingDecodedWork: [DecodedWorkID] = []
    private var admittedDataRequestCount = 0
    private var admittedDecodedRequestCount = 0
    private var accessCounter: UInt64 = 0
    private var cachedByteCount = 0

    init(
        client: any PhotoThumbnailRequesting,
        decoder: any PhotoThumbnailDecoding = CGImagePhotoThumbnailDecoder(),
        maximumConcurrentRequests: Int = 4,
        maximumPendingRequests: Int = 96,
        maximumEntryCount: Int = 256,
        maximumByteCount: Int = 32 * 1_024 * 1_024
    ) {
        self.client = client
        self.decoder = decoder
        self.maximumConcurrentRequests = max(maximumConcurrentRequests, 1)
        self.maximumPendingRequests = max(maximumPendingRequests, 1)
        permits = ThumbnailPermitPool(
            limit: maximumConcurrentRequests,
            maximumPendingRequests: maximumPendingRequests
        )
        self.maximumEntryCount = maximumEntryCount
        self.maximumByteCount = maximumByteCount
    }

    func thumbnailData(for key: PhotoThumbnailKey) async -> Data? {
        accessCounter &+= 1
        if var entry = cache[key] {
            entry.lastAccess = accessCounter
            cache[key] = entry
            return entry.data
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }

                if var existing = inFlight[key] {
                    existing.waiters[waiterID] = continuation
                    inFlight[key] = existing
                    return
                }

                let requestID = UUID()
                admittedDataRequestCount += 1
                inFlight[key] = InFlight(
                    requestID: requestID,
                    waiters: [waiterID: continuation]
                )
                enqueueDataWork(DataWorkID(key: key, requestID: requestID))
            }
        } onCancel: {
            Task { [weak self] in
                await self?.waiterCancelled(key: key, id: waiterID)
            }
        }
    }

    func decodedThumbnail(for key: PhotoThumbnailKey, scale: CGFloat) async -> DecodedThumbnailImage? {
        let decodedKey = DecodedThumbnailKey(source: key, scale: scale)
        accessCounter &+= 1
        if var entry = decodedCache[decodedKey] {
            entry.lastAccess = accessCounter
            decodedCache[decodedKey] = entry
            return entry.image
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<DecodedThumbnailImage?, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }

                if var existing = decodedInFlight[decodedKey] {
                    existing.waiters[waiterID] = continuation
                    decodedInFlight[decodedKey] = existing
                    return
                }

                let requestID = UUID()
                admittedDecodedRequestCount += 1
                decodedInFlight[decodedKey] = DecodedInFlight(
                    requestID: requestID,
                    waiters: [waiterID: continuation]
                )
                enqueueDecodedWork(DecodedWorkID(key: decodedKey, requestID: requestID))
            }
        } onCancel: {
            Task { [weak self] in
                await self?.decodedWaiterCancelled(key: decodedKey, id: waiterID)
            }
        }
    }

    func removeAll() {
        for task in activeDecodedTasks.values { task.cancel() }
        for task in activeDataTasks.values { task.cancel() }
        pendingDecodedWork.removeAll(keepingCapacity: false)
        pendingDataWork.removeAll(keepingCapacity: false)
        for request in decodedInFlight.values {
            for continuation in request.waiters.values {
                continuation.resume(returning: nil)
            }
        }
        decodedInFlight.removeAll()
        for request in inFlight.values {
            for continuation in request.waiters.values {
                continuation.resume(returning: nil)
            }
        }
        inFlight.removeAll()
        cache.removeAll()
        decodedCache.removeAll()
        cachedByteCount = 0
    }

    func workState() -> PhotoThumbnailPipelineWorkState {
        PhotoThumbnailPipelineWorkState(
            activeDataTaskCount: activeDataTasks.count,
            pendingDataWorkCount: pendingDataWork.count,
            residentDataRequestCount: inFlight.count,
            activeDecodedTaskCount: activeDecodedTasks.count,
            pendingDecodedWorkCount: pendingDecodedWork.count,
            residentDecodedRequestCount: decodedInFlight.count,
            admittedDataRequestCount: admittedDataRequestCount,
            admittedDecodedRequestCount: admittedDecodedRequestCount
        )
    }

    private func enqueueDataWork(_ workID: DataWorkID) {
        if activeDataTasks.count < maximumConcurrentRequests {
            startDataWork(workID)
            return
        }
        if pendingDataWork.count >= maximumPendingRequests {
            rejectDataWork(pendingDataWork.removeFirst())
        }
        pendingDataWork.append(workID)
    }

    private func startDataWork(_ workID: DataWorkID) {
        guard inFlight[workID.key]?.requestID == workID.requestID else { return }
        let client = self.client
        let permits = self.permits
        let task = Task<Void, Never>(priority: .utility) { [weak self] in
            guard await permits.acquire() else {
                await self?.dataWorkFinished(workID, data: nil)
                return
            }
            let data: Data?
            if Task.isCancelled {
                data = nil
            } else {
                let loaded = await client.thumbnailData(for: workID.key)
                data = Task.isCancelled ? nil : loaded
            }
            await permits.release()
            await self?.dataWorkFinished(workID, data: data)
        }
        activeDataTasks[workID] = task
    }

    private func dataWorkFinished(_ workID: DataWorkID, data: Data?) {
        activeDataTasks.removeValue(forKey: workID)
        requestFinished(key: workID.key, requestID: workID.requestID, data: data)
        startPendingDataWorkIfPossible()
    }

    private func startPendingDataWorkIfPossible() {
        while activeDataTasks.count < maximumConcurrentRequests, !pendingDataWork.isEmpty {
            let next = pendingDataWork.removeFirst()
            guard inFlight[next.key]?.requestID == next.requestID else { continue }
            startDataWork(next)
        }
    }

    private func rejectDataWork(_ workID: DataWorkID) {
        guard let request = inFlight[workID.key], request.requestID == workID.requestID else { return }
        inFlight.removeValue(forKey: workID.key)
        for continuation in request.waiters.values {
            continuation.resume(returning: nil)
        }
    }

    private func requestFinished(key: PhotoThumbnailKey, requestID: UUID, data: Data?) {
        guard let request = inFlight[key], request.requestID == requestID else { return }
        inFlight.removeValue(forKey: key)
        if let data, !data.isEmpty {
            accessCounter &+= 1
            if let previous = cache.updateValue(
                CacheEntry(data: data, lastAccess: accessCounter),
                forKey: key
            ) {
                cachedByteCount -= previous.data.count
            }
            cachedByteCount += data.count
            evictIfNeeded()
        }
        for continuation in request.waiters.values {
            continuation.resume(returning: data)
        }
    }

    private func waiterCancelled(key: PhotoThumbnailKey, id: UUID) {
        guard var request = inFlight[key],
              let continuation = request.waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        if request.waiters.isEmpty {
            let workID = DataWorkID(key: key, requestID: request.requestID)
            activeDataTasks[workID]?.cancel()
            pendingDataWork.removeAll { $0 == workID }
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = request
        }
    }

    private func decodedRequestFinished(
        key: DecodedThumbnailKey,
        requestID: UUID,
        image: DecodedThumbnailImage?
    ) {
        guard let request = decodedInFlight[key], request.requestID == requestID else { return }
        decodedInFlight.removeValue(forKey: key)
        if let image {
            accessCounter &+= 1
            if let raw = cache.removeValue(forKey: key.source) {
                cachedByteCount -= raw.data.count
            }
            if let previous = decodedCache.updateValue(
                DecodedCacheEntry(image: image, lastAccess: accessCounter),
                forKey: key
            ) {
                cachedByteCount -= previous.image.estimatedByteCount
            }
            cachedByteCount += image.estimatedByteCount
            evictIfNeeded()
        }
        for continuation in request.waiters.values {
            continuation.resume(returning: image)
        }
    }

    private func enqueueDecodedWork(_ workID: DecodedWorkID) {
        if activeDecodedTasks.count < maximumConcurrentRequests {
            startDecodedWork(workID)
            return
        }
        if pendingDecodedWork.count >= maximumPendingRequests {
            rejectDecodedWork(pendingDecodedWork.removeFirst())
        }
        pendingDecodedWork.append(workID)
    }

    private func startDecodedWork(_ workID: DecodedWorkID) {
        guard decodedInFlight[workID.key]?.requestID == workID.requestID else { return }
        let decoder = self.decoder
        let permits = self.permits
        let task = Task<Void, Never>(priority: .utility) { [weak self] in
            guard let self,
                  let data = await self.thumbnailData(for: workID.key.source),
                  !Task.isCancelled,
                  await permits.acquire() else {
                await self?.decodedWorkFinished(workID, image: nil)
                return
            }
            let image: DecodedThumbnailImage?
            if Task.isCancelled {
                image = nil
            } else {
                let decoded = await decoder.decode(
                    data: data,
                    key: workID.key.source,
                    scale: workID.key.scale
                )
                image = Task.isCancelled ? nil : decoded
            }
            await permits.release()
            await self.decodedWorkFinished(workID, image: image)
        }
        activeDecodedTasks[workID] = task
    }

    private func decodedWorkFinished(
        _ workID: DecodedWorkID,
        image: DecodedThumbnailImage?
    ) {
        activeDecodedTasks.removeValue(forKey: workID)
        decodedRequestFinished(
            key: workID.key,
            requestID: workID.requestID,
            image: image
        )
        startPendingDecodedWorkIfPossible()
    }

    private func startPendingDecodedWorkIfPossible() {
        while activeDecodedTasks.count < maximumConcurrentRequests, !pendingDecodedWork.isEmpty {
            let next = pendingDecodedWork.removeFirst()
            guard decodedInFlight[next.key]?.requestID == next.requestID else { continue }
            startDecodedWork(next)
        }
    }

    private func rejectDecodedWork(_ workID: DecodedWorkID) {
        guard let request = decodedInFlight[workID.key],
              request.requestID == workID.requestID else { return }
        decodedInFlight.removeValue(forKey: workID.key)
        for continuation in request.waiters.values {
            continuation.resume(returning: nil)
        }
    }

    private func decodedWaiterCancelled(key: DecodedThumbnailKey, id: UUID) {
        guard var request = decodedInFlight[key],
              let continuation = request.waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
        if request.waiters.isEmpty {
            let workID = DecodedWorkID(key: key, requestID: request.requestID)
            activeDecodedTasks[workID]?.cancel()
            pendingDecodedWork.removeAll { $0 == workID }
            decodedInFlight.removeValue(forKey: key)
        } else {
            decodedInFlight[key] = request
        }
    }

    private func evictIfNeeded() {
        while cache.count + decodedCache.count > maximumEntryCount
                || cachedByteCount > maximumByteCount {
            let oldestData = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })
            let oldestImage = decodedCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })
            if let oldestImage,
               oldestData == nil || oldestImage.value.lastAccess < oldestData!.value.lastAccess {
                cachedByteCount -= oldestImage.value.image.estimatedByteCount
                decodedCache.removeValue(forKey: oldestImage.key)
            } else if let oldestData {
                cachedByteCount -= oldestData.value.data.count
                cache.removeValue(forKey: oldestData.key)
            } else {
                return
            }
        }
    }
}

struct PhotoThumbnailPipelineWorkState: Equatable, Sendable {
    let activeDataTaskCount: Int
    let pendingDataWorkCount: Int
    let residentDataRequestCount: Int
    let activeDecodedTaskCount: Int
    let pendingDecodedWorkCount: Int
    let residentDecodedRequestCount: Int
    let admittedDataRequestCount: Int
    let admittedDecodedRequestCount: Int
}

actor ThumbnailPermitPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var available: Int
    private let maximumPendingRequests: Int
    private var waiters: [Waiter] = []

    init(limit: Int, maximumPendingRequests: Int) {
        available = max(limit, 1)
        self.maximumPendingRequests = max(maximumPendingRequests, 1)
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard available == 0 else {
            available -= 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                // Keep the queue bounded while favoring the newest visible
                // cells. A request displaced here is normally already scrolling
                // away; returning false also releases its pipeline entry.
                if waiters.count >= maximumPendingRequests {
                    waiters.removeFirst().continuation.resume(returning: false)
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { [weak self] in await self?.cancel(waiterID) }
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

final class PhotoKitThumbnailRequestClient: PhotoThumbnailRequesting, @unchecked Sendable {
    private let imageManager: PHCachingImageManager

    init(imageManager: PHCachingImageManager = PHCachingImageManager()) {
        self.imageManager = imageManager
    }

    func thumbnailData(for key: PhotoThumbnailKey) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: [key.assetID],
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        guard let asset = result.firstObject else { return nil }

        let options = PHImageRequestOptions()
        // These images are reused in large review surfaces as well as grid cells.
        // Fast-format requests may legally return a rendition smaller than the
        // requested pixel size, which becomes visibly soft when the image is
        // promoted into the review deck or photo stack.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = key.allowsNetworkAccess
        let cancellation = ThumbnailImageRequestCancellation(manager: imageManager)

        let box: ThumbnailImageBox? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let continuationBox = ThumbnailContinuationBox(continuation)
                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: key.pixelWidth, height: key.pixelHeight),
                    contentMode: .aspectFill,
                    options: options
                ) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                        continuationBox.resume(nil)
                        return
                    }
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                    // Never cache PhotoKit's low-resolution placeholder. Once
                    // cached, that degraded result would remain blurry in every
                    // larger surface for the lifetime of the catalog revision.
                    if let image, !degraded {
                        continuationBox.resume(ThumbnailImageBox(image))
                    } else if !degraded {
                        continuationBox.resume(nil)
                    }
                }
                cancellation.setRequestID(requestID)
            }
        } onCancel: {
            cancellation.cancel()
        }
        guard let box, !Task.isCancelled else { return nil }

        // UIImage is immutable here but not formally Sendable. The unchecked box
        // confines it to this one detached encoding operation; only Data crosses
        // back into the cache actor.
        return await Task.detached(priority: .utility) {
            box.image.jpegData(compressionQuality: 0.84)
        }.value
    }
}

private final class ThumbnailImageBox: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

private final class ThumbnailContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ThumbnailImageBox?, Never>?

    init(_ continuation: CheckedContinuation<ThumbnailImageBox?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: ThumbnailImageBox?) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(returning: value)
    }
}

private final class ThumbnailImageRequestCancellation: @unchecked Sendable {
    private let manager: PHImageManager
    private let lock = NSLock()
    private var requestID: PHImageRequestID?
    private var cancelled = false

    init(manager: PHImageManager) {
        self.manager = manager
    }

    func setRequestID(_ requestID: PHImageRequestID) {
        lock.lock()
        self.requestID = requestID
        let cancelImmediately = cancelled
        lock.unlock()
        if cancelImmediately { manager.cancelImageRequest(requestID) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let requestID = requestID
        lock.unlock()
        if let requestID { manager.cancelImageRequest(requestID) }
    }
}
