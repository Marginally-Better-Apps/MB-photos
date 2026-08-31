@preconcurrency import AVFoundation
@preconcurrency import Photos
import CryptoKit
import Foundation
import UIKit

enum OrganizePhotoServiceError: LocalizedError, Sendable {
    case assetUnavailable(String)
    case assetChanged(String)
    case resourceUnavailable(String)
    case networkAccessRequired(String)
    case requestFailed(String)
    case cancelled
    case missingAssets([String])
    case thumbnailEncodingFailed
    case invalidThumbnailReference

    var errorDescription: String? {
        switch self {
        case let .assetUnavailable(assetID):
            "The photo or video is no longer accessible (\(assetID))."
        case let .assetChanged(assetID):
            "The photo or video changed while it was being analyzed (\(assetID))."
        case let .resourceUnavailable(filename):
            "A required photo resource is no longer available (\(filename))."
        case let .networkAccessRequired(filename):
            "\(filename) is stored in iCloud. Include iCloud items to analyze it."
        case let .requestFailed(message):
            message
        case .cancelled:
            "The Photo Library request was cancelled."
        case let .missingAssets(assetIDs):
            "Some queued items are no longer accessible: \(assetIDs.joined(separator: ", "))."
        case .thumbnailEncodingFailed:
            "The audit thumbnail could not be encoded."
        case .invalidThumbnailReference:
            "The audit thumbnail reference is invalid."
        }
    }
}

// MARK: - Screen-sized previews

@MainActor
protocol PhotoPreviewProviding: AnyObject, Sendable {
    func imagePreview(
        assetID: String,
        targetSize: CGSize,
        scale: CGFloat,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UIImage

    func videoPlayerItem(
        assetID: String,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AVPlayerItem

    func livePhoto(
        assetID: String,
        targetSize: CGSize,
        scale: CGFloat,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PHLivePhoto
}

extension PhotoPreviewProviding {
    func livePhoto(
        assetID: String,
        targetSize: CGSize,
        scale: CGFloat,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PHLivePhoto {
        throw OrganizePhotoServiceError.assetUnavailable(assetID)
    }
}

@MainActor
final class PhotoKitPreviewProvider: PhotoPreviewProviding {
    private let imageManager: PHImageManager

    init(imageManager: PHImageManager = .default()) {
        self.imageManager = imageManager
    }

    func imagePreview(
        assetID: String,
        targetSize: CGSize,
        scale: CGFloat,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> UIImage {
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        guard let asset = result.firstObject else {
            throw OrganizePhotoServiceError.assetUnavailable(assetID)
        }

        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = includeNetwork
        options.progressHandler = { value, _, _, _ in progress(value) }
        let pixels = CGSize(
            width: max(targetSize.width * scale, 1),
            height: max(targetSize.height * scale, 1)
        )
        let cancellation = PhotoImageRequestCancellation(manager: imageManager)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = LockedThrowingContinuation(continuation)
                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: pixels,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        box.resume(throwing: OrganizePhotoServiceError.cancelled)
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        box.resume(throwing: Self.mapPhotoError(error, fallbackName: assetID))
                    } else if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        return
                    } else if let image {
                        progress(1)
                        box.resume(returning: image)
                    } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true, !includeNetwork {
                        box.resume(throwing: OrganizePhotoServiceError.networkAccessRequired(assetID))
                    } else {
                        box.resume(throwing: OrganizePhotoServiceError.assetUnavailable(assetID))
                    }
                }
                cancellation.setRequestID(requestID)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func videoPlayerItem(
        assetID: String,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> AVPlayerItem {
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        guard let asset = result.firstObject, asset.mediaType == .video else {
            throw OrganizePhotoServiceError.assetUnavailable(assetID)
        }

        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = includeNetwork
        options.progressHandler = { value, _, _, _ in progress(value) }
        let cancellation = PhotoImageRequestCancellation(manager: imageManager)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = LockedThrowingContinuation(continuation)
                let requestID = imageManager.requestPlayerItem(forVideo: asset, options: options) { item, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        box.resume(throwing: OrganizePhotoServiceError.cancelled)
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        box.resume(throwing: Self.mapPhotoError(error, fallbackName: assetID))
                    } else if let item {
                        progress(1)
                        box.resume(returning: item)
                    } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true, !includeNetwork {
                        box.resume(throwing: OrganizePhotoServiceError.networkAccessRequired(assetID))
                    } else {
                        box.resume(throwing: OrganizePhotoServiceError.assetUnavailable(assetID))
                    }
                }
                cancellation.setRequestID(requestID)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func livePhoto(
        assetID: String,
        targetSize: CGSize,
        scale: CGFloat,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> PHLivePhoto {
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        guard let asset = result.firstObject, asset.mediaSubtypes.contains(.photoLive) else {
            throw OrganizePhotoServiceError.assetUnavailable(assetID)
        }

        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = includeNetwork
        options.progressHandler = { value, _, _, _ in progress(value) }
        let pixels = CGSize(
            width: max(targetSize.width * scale, 1),
            height: max(targetSize.height * scale, 1)
        )
        let cancellation = PhotoImageRequestCancellation(manager: imageManager)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = LockedThrowingContinuation(continuation)
                let requestID = imageManager.requestLivePhoto(
                    for: asset,
                    targetSize: pixels,
                    contentMode: .aspectFit,
                    options: options
                ) { livePhoto, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        box.resume(throwing: OrganizePhotoServiceError.cancelled)
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        box.resume(throwing: Self.mapPhotoError(error, fallbackName: assetID))
                    } else if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        return
                    } else if let livePhoto {
                        progress(1)
                        box.resume(returning: livePhoto)
                    } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true, !includeNetwork {
                        box.resume(throwing: OrganizePhotoServiceError.networkAccessRequired(assetID))
                    } else {
                        box.resume(throwing: OrganizePhotoServiceError.assetUnavailable(assetID))
                    }
                }
                cancellation.setRequestID(requestID)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    nonisolated private static func mapPhotoError(_ error: Error, fallbackName: String) -> Error {
        let nsError = error as NSError
        if nsError.domain == PHPhotosErrorDomain,
           nsError.code == PHPhotosError.networkAccessRequired.rawValue {
            return OrganizePhotoServiceError.networkAccessRequired(fallbackName)
        }
        if nsError.domain == PHPhotosErrorDomain,
           nsError.code == PHPhotosError.userCancelled.rawValue {
            return OrganizePhotoServiceError.cancelled
        }
        return error
    }
}

// MARK: - Streaming resource analysis

struct AssetAnalysisProgress: Equatable, Sendable {
    let assetID: String
    let completedResourceCount: Int
    let totalResourceCount: Int
    let currentResourceKind: PhotoResourceKind?
    let currentResourceProgress: Double

    var fractionCompleted: Double {
        guard totalResourceCount > 0 else { return 1 }
        let current = min(max(currentResourceProgress, 0), 1)
        return min((Double(completedResourceCount) + current) / Double(totalResourceCount), 1)
    }
}

protocol AssetResourceAnalyzing: Sendable {
    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint
}

actor PhotoKitAssetResourceAnalyzer: AssetResourceAnalyzing {
    private let resourceManager: PHAssetResourceManager
    private let now: @Sendable () -> Date

    init(
        resourceManager: PHAssetResourceManager = .default(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resourceManager = resourceManager
        self.now = now
    }

    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void = { _ in }
    ) async throws -> AssetFingerprint {
        try Task.checkCancellation()
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [asset.id],
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        guard let photoKitAsset = fetchResult.firstObject,
              let currentAsset = PhotoKitAssetMapper.model(from: photoKitAsset) else {
            throw OrganizePhotoServiceError.assetUnavailable(asset.id)
        }
        guard currentAsset.analysisRevision == asset.analysisRevision else {
            throw OrganizePhotoServiceError.assetChanged(asset.id)
        }

        let photoKitResources = PHAssetResource.assetResources(for: photoKitAsset)
        let descriptors = PhotoKitResourceCatalog.descriptors(
            assetID: asset.id,
            resources: photoKitResources
        )
        let total = descriptors.count
        var fingerprints: [ResourceFingerprint] = []
        fingerprints.reserveCapacity(total)

        progress(
            AssetAnalysisProgress(
                assetID: asset.id,
                completedResourceCount: 0,
                totalResourceCount: total,
                currentResourceKind: descriptors.first?.kind,
                currentResourceProgress: 0
            )
        )

        for (index, descriptor) in descriptors.enumerated() {
            try Task.checkCancellation()
            guard let resource = PhotoKitResourceCatalog.resource(
                descriptorID: descriptor.id,
                assetID: asset.id,
                resources: photoKitResources
            ) else {
                throw OrganizePhotoServiceError.resourceUnavailable(descriptor.originalFilename)
            }

            let fingerprint = try await fingerprint(
                resource: resource,
                descriptor: descriptor,
                includeNetwork: includeNetwork
            ) { resourceProgress in
                progress(
                    AssetAnalysisProgress(
                        assetID: asset.id,
                        completedResourceCount: index,
                        totalResourceCount: total,
                        currentResourceKind: descriptor.kind,
                        currentResourceProgress: resourceProgress
                    )
                )
            }
            fingerprints.append(fingerprint)
            progress(
                AssetAnalysisProgress(
                    assetID: asset.id,
                    completedResourceCount: index + 1,
                    totalResourceCount: total,
                    currentResourceKind: index + 1 < total ? descriptors[index + 1].kind : nil,
                    currentResourceProgress: 0
                )
            )
        }

        try Task.checkCancellation()
        let finalFetch = PHAsset.fetchAssets(
            withLocalIdentifiers: [asset.id],
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        guard let finalAsset = finalFetch.firstObject,
              let finalModel = PhotoKitAssetMapper.model(from: finalAsset) else {
            throw OrganizePhotoServiceError.assetUnavailable(asset.id)
        }
        guard finalModel.analysisRevision == asset.analysisRevision else {
            throw OrganizePhotoServiceError.assetChanged(asset.id)
        }

        let sortedFingerprints = fingerprints.sorted(by: Self.fingerprintSort)
        return AssetFingerprint(
            assetID: asset.id,
            sourceRevision: asset.analysisRevision,
            resources: sortedFingerprints,
            analyzedAt: now()
        )
    }

    private func fingerprint(
        resource: PHAssetResource,
        descriptor: PhotoResourceDescriptor,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ResourceFingerprint {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = includeNetwork
        options.progressHandler = { value in progress(value) }
        let digest = ResourceDigestAccumulator()
        let cancellation = PhotoResourceRequestCancellation(manager: resourceManager)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = LockedThrowingContinuation(continuation)
                let requestID = resourceManager.requestData(
                    for: resource,
                    options: options
                ) { data in
                    digest.update(data)
                } completionHandler: { error in
                    if cancellation.isCancelled {
                        box.resume(throwing: OrganizePhotoServiceError.cancelled)
                    } else if let error {
                        box.resume(
                            throwing: Self.mapResourceError(
                                error,
                                filename: descriptor.originalFilename,
                                includeNetwork: includeNetwork
                            )
                        )
                    } else {
                        let value = digest.finalize()
                        progress(1)
                        box.resume(
                            returning: ResourceFingerprint(
                                kind: descriptor.kind,
                                byteCount: value.byteCount,
                                sha256: value.sha256
                            )
                        )
                    }
                }
                cancellation.setRequestID(requestID)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    nonisolated private static func fingerprintSort(
        _ lhs: ResourceFingerprint,
        _ rhs: ResourceFingerprint
    ) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.byteCount != rhs.byteCount { return lhs.byteCount < rhs.byteCount }
        return lhs.sha256.localizedStandardCompare(rhs.sha256) == .orderedAscending
    }

    nonisolated private static func mapResourceError(
        _ error: Error,
        filename: String,
        includeNetwork: Bool
    ) -> Error {
        let nsError = error as NSError
        if nsError.domain == PHPhotosErrorDomain,
           nsError.code == PHPhotosError.networkAccessRequired.rawValue {
            return OrganizePhotoServiceError.networkAccessRequired(filename)
        }
        if !includeNetwork,
           nsError.domain == PHPhotosErrorDomain,
           nsError.code == PHPhotosError.networkError.rawValue {
            return OrganizePhotoServiceError.networkAccessRequired(filename)
        }
        if nsError.domain == PHPhotosErrorDomain,
           nsError.code == PHPhotosError.userCancelled.rawValue {
            return OrganizePhotoServiceError.cancelled
        }
        return error
    }
}

// MARK: - Revalidation and one-batch deletion

struct PhotoAssetRevalidationRequest: Equatable, Sendable {
    let assetID: String
    let expectedSourceRevision: String
}

enum PhotoAssetRevalidationStatus: String, Codable, Sendable {
    case unchanged
    case changed
    case missing
}

struct PhotoAssetRevalidationResult: Sendable {
    let request: PhotoAssetRevalidationRequest
    let status: PhotoAssetRevalidationStatus
    let currentAsset: PhotoAsset?
}

protocol PhotoAssetRevalidating: Sendable {
    func revalidate(_ requests: [PhotoAssetRevalidationRequest]) async -> [PhotoAssetRevalidationResult]
}

actor PhotoKitAssetRevalidator: PhotoAssetRevalidating {
    func revalidate(_ requests: [PhotoAssetRevalidationRequest]) async -> [PhotoAssetRevalidationResult] {
        guard !requests.isEmpty else { return [] }
        let identifiers = Array(Set(requests.map(\.assetID)))
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: identifiers,
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        var currentByID: [String: PhotoAsset] = [:]
        currentByID.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in
            if let model = PhotoKitAssetMapper.model(from: asset) {
                currentByID[model.id] = model
            }
        }

        return requests.map { request in
            guard let currentAsset = currentByID[request.assetID] else {
                return PhotoAssetRevalidationResult(
                    request: request,
                    status: .missing,
                    currentAsset: nil
                )
            }
            return PhotoAssetRevalidationResult(
                request: request,
                status: currentAsset.sourceRevision == request.expectedSourceRevision ? .unchanged : .changed,
                currentAsset: currentAsset
            )
        }
    }
}

struct PhotoLibraryDeletionResult: Equatable, Sendable {
    let assetIDs: [String]
    let completedAt: Date
}

typealias PhotoLibraryDeletionForegroundValidator = @MainActor @Sendable () -> Bool

protocol PhotoLibraryDeleting: Sendable {
    /// Performs exactly one PhotoKit change request. PhotoKit presents the system
    /// confirmation and moves the assets into Apple Photos' Recently Deleted album.
    /// The validator is deliberately invoked after all potentially proportional
    /// PhotoKit fetch/enumeration work and immediately before the destructive request.
    func moveToRecentlyDeleted(
        assetIDs: [String],
        foregroundValidator: @escaping PhotoLibraryDeletionForegroundValidator
    ) async throws -> PhotoLibraryDeletionResult
}

actor PhotoKitDeletionService: PhotoLibraryDeleting {
    private let photoLibrary: PHPhotoLibrary
    private let now: @Sendable () -> Date

    init(
        photoLibrary: PHPhotoLibrary = .shared(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.photoLibrary = photoLibrary
        self.now = now
    }

    func moveToRecentlyDeleted(
        assetIDs: [String],
        foregroundValidator: @escaping PhotoLibraryDeletionForegroundValidator
    ) async throws -> PhotoLibraryDeletionResult {
        var seen: Set<String> = []
        let uniqueIDs = assetIDs.filter { seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else {
            return PhotoLibraryDeletionResult(assetIDs: [], completedAt: now())
        }

        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: uniqueIDs,
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        var fetchedIDs: Set<String> = []
        fetchResult.enumerateObjects { asset, _, _ in fetchedIDs.insert(asset.localIdentifier) }
        let missing = uniqueIDs.filter { !fetchedIDs.contains($0) }
        guard missing.isEmpty else {
            throw OrganizePhotoServiceError.missingAssets(missing)
        }
        guard !Task.isCancelled, await foregroundValidator() else {
            throw OrganizePhotoServiceError.cancelled
        }

        do {
            try await photoLibrary.performChanges {
                PHAssetChangeRequest.deleteAssets(fetchResult)
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain,
               nsError.code == PHPhotosError.userCancelled.rawValue {
                throw OrganizePhotoServiceError.cancelled
            }
            throw error
        }
        return PhotoLibraryDeletionResult(assetIDs: uniqueIDs, completedAt: now())
    }
}

// MARK: - Expiring audit thumbnails

struct AuditThumbnailReference: Equatable, Sendable {
    let relativePath: String
    let expiresAt: Date
}

protocol AuditThumbnailStoring: Sendable {
    func prepareThumbnail(
        assetID: String,
        batchID: UUID,
        includeNetwork: Bool,
        now: Date
    ) async throws -> AuditThumbnailReference

    func loadThumbnail(relativePath: String) async throws -> UIImage?
    func removeExpired(now: Date) async throws
    func removeThumbnail(relativePath: String) async throws
}

actor PhotoKitAuditThumbnailStore: AuditThumbnailStoring {
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumMemoryImageCount = 48

    private struct InFlightRequest {
        let generation: UUID
        let task: Task<AuditThumbnailReference, Error>
        var waiters: [UUID: CheckedContinuation<AuditThumbnailReference, Error>]
    }

    private let previews: any PhotoPreviewProviding
    private let fileManager: FileManager
    private let cacheRootURL: URL
    private let requestObserverDidFinish: (@Sendable (_ requestKey: String, _ generation: UUID) async -> Void)?
    private let directoryName = "OrganizeAuditThumbnails"
    private var inFlight: [String: InFlightRequest] = [:]
    private var memoryImages: [String: UIImage] = [:]
    private var memoryOrder: [String] = []

    init(
        previews: any PhotoPreviewProviding,
        fileManager: FileManager = .default,
        cacheRootURL: URL? = nil,
        requestObserverDidFinish: (@Sendable (_ requestKey: String, _ generation: UUID) async -> Void)? = nil
    ) {
        self.previews = previews
        self.fileManager = fileManager
        self.requestObserverDidFinish = requestObserverDidFinish
        self.cacheRootURL = cacheRootURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    func prepareThumbnail(
        assetID: String,
        batchID: UUID,
        includeNetwork: Bool,
        now: Date = Date()
    ) async throws -> AuditThumbnailReference {
        let requestKey = "\(batchID.uuidString.lowercased())|\(assetID)"
        let waiterID = UUID()
        let waiterCancellation = ThumbnailWaiterCancellation()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let generation: UUID
                if var request = inFlight[requestKey] {
                    generation = request.generation
                    request.waiters[waiterID] = continuation
                    inFlight[requestKey] = request
                } else {
                    generation = UUID()
                    let task = Task { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.generateThumbnail(
                            assetID: assetID,
                            batchID: batchID,
                            includeNetwork: includeNetwork,
                            now: now
                        )
                    }
                    inFlight[requestKey] = InFlightRequest(
                        generation: generation,
                        task: task,
                        waiters: [waiterID: continuation]
                    )
                    Task { [weak self, requestObserverDidFinish] in
                        let result = await task.result
                        await self?.finishRequest(
                            requestKey: requestKey,
                            generation: generation,
                            result: result
                        )
                        await requestObserverDidFinish?(requestKey, generation)
                    }
                }

                if waiterCancellation.setGeneration(generation) {
                    cancelWaiter(
                        waiterID,
                        requestKey: requestKey,
                        generation: generation
                    )
                }
            }
        } onCancel: {
            if let generation = waiterCancellation.cancel() {
                Task {
                    await self.cancelWaiter(
                        waiterID,
                        requestKey: requestKey,
                        generation: generation
                    )
                }
            }
        }
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        requestKey: String,
        generation: UUID
    ) {
        guard var request = inFlight[requestKey],
              request.generation == generation,
              let continuation = request.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if request.waiters.isEmpty {
            request.task.cancel()
            inFlight.removeValue(forKey: requestKey)
        } else {
            inFlight[requestKey] = request
        }
    }

    private func finishRequest(
        requestKey: String,
        generation: UUID,
        result: Result<AuditThumbnailReference, Error>
    ) {
        guard let request = inFlight[requestKey],
              request.generation == generation else { return }
        inFlight.removeValue(forKey: requestKey)
        for continuation in request.waiters.values {
            switch result {
            case let .success(reference): continuation.resume(returning: reference)
            case let .failure(error): continuation.resume(throwing: error)
            }
        }
    }

    private func generateThumbnail(
        assetID: String,
        batchID: UUID,
        includeNetwork: Bool,
        now: Date
    ) async throws -> AuditThumbnailReference {
        try Task.checkCancellation()
        let directoryURL = try prepareDirectory()
        let expiresAt = now.addingTimeInterval(Self.retentionInterval)
        let expiry = Int64(expiresAt.timeIntervalSince1970.rounded(.down))
        let identity = "\(batchID.uuidString.lowercased())|\(assetID)|\(expiry)"
        let digest = SHA256.hash(data: Data(identity.utf8)).hexString
        let filename = "\(expiry)-\(digest).jpg"
        let fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)

        let image = try await previews.imagePreview(
            assetID: assetID,
            targetSize: CGSize(width: 480, height: 480),
            scale: 1,
            includeNetwork: includeNetwork,
            progress: { _ in }
        )
        try Task.checkCancellation()
        guard let jpeg = image.jpegData(compressionQuality: 0.78) else {
            throw OrganizePhotoServiceError.thumbnailEncodingFailed
        }
        try jpeg.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )
        try excludeFromBackup(fileURL)

        return AuditThumbnailReference(
            relativePath: "\(directoryName)/\(filename)",
            expiresAt: expiresAt
        )
    }

    func loadThumbnail(relativePath: String) throws -> UIImage? {
        if let cached = memoryImages[relativePath] {
            touchMemoryKey(relativePath)
            return cached
        }
        try Task.checkCancellation()
        let fileURL = try validatedThumbnailURL(relativePath: relativePath)
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        try Task.checkCancellation()
        guard let image = UIImage(data: data) else { return nil }
        memoryImages[relativePath] = image
        touchMemoryKey(relativePath)
        while memoryOrder.count > Self.maximumMemoryImageCount {
            memoryImages.removeValue(forKey: memoryOrder.removeFirst())
        }
        return image
    }

    private func validatedThumbnailURL(relativePath: String) throws -> URL {
        let expectedDirectory = cacheRootURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
        let candidate = cacheRootURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == expectedDirectory,
              candidate.pathExtension.lowercased() == "jpg" else {
            throw OrganizePhotoServiceError.invalidThumbnailReference
        }
        return candidate
    }

    func removeExpired(now: Date = Date()) throws {
        let directoryURL = cacheRootURL.appendingPathComponent(directoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for fileURL in files where fileURL.pathExtension.lowercased() == "jpg" {
            let expiryString = fileURL.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 1).first
            guard let expiryString,
                  let expiry = TimeInterval(expiryString),
                  expiry <= now.timeIntervalSince1970 else { continue }
            try fileManager.removeItem(at: fileURL)
            let key = "\(directoryName)/\(fileURL.lastPathComponent)"
            memoryImages.removeValue(forKey: key)
            memoryOrder.removeAll { $0 == key }
        }
    }

    func removeThumbnail(relativePath: String) throws {
        let fileURL = try validatedThumbnailURL(relativePath: relativePath)
        memoryImages.removeValue(forKey: relativePath)
        memoryOrder.removeAll { $0 == relativePath }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func prepareDirectory() throws -> URL {
        let directoryURL = cacheRootURL.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directoryURL.path
        )
        try excludeFromBackup(directoryURL)
        return directoryURL
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private func touchMemoryKey(_ key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

}

// MARK: - Callback synchronization

private final class LockedThrowingContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: sending Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        return current
    }
}

private final class ThumbnailWaiterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UUID?
    private var cancelled = false

    /// Returns true when cancellation arrived before the generation was assigned.
    func setGeneration(_ generation: UUID) -> Bool {
        lock.lock()
        self.generation = generation
        let shouldCancel = cancelled
        lock.unlock()
        return shouldCancel
    }

    /// Returns the assigned generation when cancellation can be delivered immediately.
    func cancel() -> UUID? {
        lock.lock()
        cancelled = true
        let generation = generation
        lock.unlock()
        return generation
    }
}

private final class PhotoImageRequestCancellation: @unchecked Sendable {
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
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { manager.cancelImageRequest(requestID) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let requestID = requestID
        lock.unlock()
        if let requestID { manager.cancelImageRequest(requestID) }
    }
}

private final class PhotoResourceRequestCancellation: @unchecked Sendable {
    private let manager: PHAssetResourceManager
    private let lock = NSLock()
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelled = false

    init(manager: PHAssetResourceManager) {
        self.manager = manager
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func setRequestID(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { manager.cancelDataRequest(requestID) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let requestID = requestID
        lock.unlock()
        if let requestID { manager.cancelDataRequest(requestID) }
    }
}

private final class ResourceDigestAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var hash = SHA256()
    private var byteCount: Int64 = 0

    func update(_ data: Data) {
        lock.lock()
        hash.update(data: data)
        byteCount += Int64(data.count)
        lock.unlock()
    }

    func finalize() -> FileDigest {
        lock.lock()
        let digest = hash.finalize().hexString
        let count = byteCount
        lock.unlock()
        return FileDigest(byteCount: count, sha256: digest)
    }
}
