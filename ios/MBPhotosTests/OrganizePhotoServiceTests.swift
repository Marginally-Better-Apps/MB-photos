@testable import MBPhotos
import AVFoundation
@preconcurrency import Photos
import UIKit
import XCTest

final class OrganizePhotoServiceTests: XCTestCase {
    func testPhotoKitMapperIncludesScreenRecordingAndSpatialMediaSubtypes() {
        let mapped = PhotoKitAssetMapper.mapSubtypes([.videoScreenRecording, .spatialMedia])

        XCTAssertTrue(mapped.contains(.screenRecording))
        XCTAssertTrue(mapped.contains(.spatialMedia))
    }

    @MainActor
    func testAuditThumbnailPreparationCancelsWithPhotoRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "audit-thumbnail-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let previews = CancellablePreviewProvider()
        let store = PhotoKitAuditThumbnailStore(previews: previews, cacheRootURL: root)
        let preparation = Task {
            try await store.prepareThumbnail(
                assetID: "asset",
                batchID: UUID(),
                includeNetwork: false,
                now: Date()
            )
        }
        await previews.waitUntilStarted()
        preparation.cancel()

        do {
            _ = try await preparation.value
            XCTFail("Cancelled thumbnail preparation unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
    }

    @MainActor
    func testCancellingOneSharedAuditThumbnailWaiterDoesNotCancelTheOther() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "shared-audit-thumbnail-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let previews = SharedCancellablePreviewProvider()
        let store = PhotoKitAuditThumbnailStore(previews: previews, cacheRootURL: root)
        let batchID = UUID()
        let first = Task {
            try await store.prepareThumbnail(
                assetID: "shared-asset",
                batchID: batchID,
                includeNetwork: false,
                now: Date()
            )
        }
        await previews.waitUntilStarted()
        let second = Task {
            try await store.prepareThumbnail(
                assetID: "shared-asset",
                batchID: batchID,
                includeNetwork: false,
                now: Date()
            )
        }
        // Let the actor register the second waiter before cancelling the first.
        try await Task.sleep(for: .milliseconds(25))
        first.cancel()
        try await Task.sleep(for: .milliseconds(25))
        previews.releasePreview()

        do {
            _ = try await first.value
            XCTFail("A cancelled shared waiter unexpectedly received the thumbnail")
        } catch is CancellationError {
            // Expected: cancellation is per waiter.
        }
        let reference = try await second.value
        XCTAssertTrue(reference.relativePath.hasPrefix("OrganizeAuditThumbnails/"))
        XCTAssertEqual(previews.requestCount, 1)
    }

    @MainActor
    func testCancelledThumbnailObserverCannotFinishNewRequestWithReusedKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "aba-audit-thumbnail-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let previews = GenerationControlledPreviewProvider()
        let observerProbe = ThumbnailObserverProbe()
        let store = PhotoKitAuditThumbnailStore(
            previews: previews,
            cacheRootURL: root,
            requestObserverDidFinish: { _, _ in
                await observerProbe.recordCompletion()
            }
        )
        let batchID = UUID()
        let first = Task {
            try await store.prepareThumbnail(
                assetID: "reused-key-asset",
                batchID: batchID,
                includeNetwork: false,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        await previews.waitUntilRequestCount(1)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Cancelled first generation unexpectedly completed")
        } catch is CancellationError {
            // Expected. Its underlying preview deliberately remains suspended.
        }

        let second = Task {
            try await store.prepareThumbnail(
                assetID: "reused-key-asset",
                batchID: batchID,
                includeNetwork: false,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        await previews.waitUntilRequestCount(2)

        // Complete the cancelled generation only after the same key has been reused.
        // Waiting for its observer makes the ABA ordering deterministic.
        previews.releaseRequest(1)
        await observerProbe.waitUntilCompletionCount(1)

        previews.releaseRequest(2)
        let reference = try await second.value
        XCTAssertTrue(reference.relativePath.hasPrefix("OrganizeAuditThumbnails/"))
        XCTAssertEqual(previews.requestCount, 2)
    }

    func testExactDuplicateKeyUsesSortedCompleteResourceManifest() {
        let photo = ResourceFingerprint(kind: .photo, byteCount: 12, sha256: String(repeating: "a", count: 64))
        let liveComponent = ResourceFingerprint(
            kind: .pairedVideo,
            byteCount: 34,
            sha256: String(repeating: "b", count: 64)
        )
        let analyzedAt = Date(timeIntervalSince1970: 100)

        let first = AssetFingerprint(
            assetID: "first",
            sourceRevision: "revision-one",
            resources: [photo, liveComponent],
            analyzedAt: analyzedAt
        )
        let second = AssetFingerprint(
            assetID: "second",
            sourceRevision: "revision-two",
            resources: [liveComponent, photo],
            analyzedAt: analyzedAt.addingTimeInterval(10)
        )

        XCTAssertEqual(first.exactDuplicateKey, second.exactDuplicateKey)
        XCTAssertEqual(first.knownByteCount, 46)
    }

    func testExactDuplicateKeyChangesForAnyCompanionResourceDifference() {
        let photo = ResourceFingerprint(kind: .photo, byteCount: 12, sha256: String(repeating: "a", count: 64))
        let pairedVideo = ResourceFingerprint(
            kind: .pairedVideo,
            byteCount: 34,
            sha256: String(repeating: "b", count: 64)
        )
        let changedPair = ResourceFingerprint(
            kind: .pairedVideo,
            byteCount: 34,
            sha256: String(repeating: "c", count: 64)
        )

        let complete = fingerprint(resources: [photo, pairedVideo])
        XCTAssertNotEqual(complete.exactDuplicateKey, fingerprint(resources: [photo]).exactDuplicateKey)
        XCTAssertNotEqual(
            complete.exactDuplicateKey,
            fingerprint(resources: [photo, changedPair]).exactDuplicateKey
        )
        XCTAssertNotEqual(
            complete.exactDuplicateKey,
            fingerprint(resources: [photo, pairedVideo, pairedVideo]).exactDuplicateKey
        )
    }

    func testPhotoAssetDecodesPreOrganizeMetadataWithSafeDefaults() throws {
        let asset = PhotoAsset(
            id: "legacy",
            mediaKind: .photo,
            mediaSubtypes: [],
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: nil,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            durationMilliseconds: nil,
            location: nil,
            isFavorite: false,
            isEdited: false,
            resources: [
                PhotoResourceDescriptor(
                    id: "legacy-resource",
                    kind: .photo,
                    originalFilename: "IMG_0001.HEIC",
                    uniformTypeIdentifier: "public.heic"
                )
            ]
        )
        let encoded = try WireCoders.encoder().encode(asset)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isHidden")
        object.removeValue(forKey: "addedDate")
        object.removeValue(forKey: "burstIdentifier")
        object.removeValue(forKey: "representsBurst")
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try WireCoders.decoder().decode(PhotoAsset.self, from: legacyData)

        XCTAssertFalse(decoded.isHidden)
        XCTAssertNil(decoded.addedDate)
        XCTAssertNil(decoded.burstIdentifier)
        XCTAssertFalse(decoded.representsBurst)
    }

    private func fingerprint(resources: [ResourceFingerprint]) -> AssetFingerprint {
        AssetFingerprint(
            assetID: UUID().uuidString,
            sourceRevision: UUID().uuidString,
            resources: resources,
            analyzedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@MainActor
private final class CancellablePreviewProvider: PhotoPreviewProviding {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func imagePreview(
        assetID: String,
        targetSize: CGSize,
        scale: CGFloat,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UIImage {
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        try await Task.sleep(for: .seconds(30))
        return UIImage()
    }

    func videoPlayerItem(
        assetID: String,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AVPlayerItem {
        throw CancellationError()
    }
}

@MainActor
private final class SharedCancellablePreviewProvider: PhotoPreviewProviding {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private(set) var requestCount = 0

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func releasePreview() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func imagePreview(
        assetID: String,
        targetSize: CGSize,
        scale: CGFloat,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UIImage {
        requestCount += 1
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
        try Task.checkCancellation()
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    func videoPlayerItem(
        assetID: String,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AVPlayerItem {
        throw CancellationError()
    }
}

private actor ThumbnailObserverProbe {
    private var completionCount = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordCompletion() {
        completionCount += 1
        let ready = waiters.filter { completionCount >= $0.count }
        waiters.removeAll { completionCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitUntilCompletionCount(_ count: Int) async {
        if completionCount >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

@MainActor
private final class GenerationControlledPreviewProvider: PhotoPreviewProviding {
    private var requestCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedRequests: Set<Int> = []
    private(set) var requestCount = 0

    func waitUntilRequestCount(_ count: Int) async {
        if requestCount >= count { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append((count, continuation))
        }
    }

    func releaseRequest(_ request: Int) {
        if let continuation = releaseContinuations.removeValue(forKey: request) {
            continuation.resume()
        } else {
            releasedRequests.insert(request)
        }
    }

    func imagePreview(
        assetID: String,
        targetSize: CGSize,
        scale: CGFloat,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UIImage {
        requestCount += 1
        let request = requestCount
        let ready = requestCountWaiters.filter { requestCount >= $0.count }
        requestCountWaiters.removeAll { requestCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
        if releasedRequests.remove(request) == nil {
            await withCheckedContinuation { continuation in
                releaseContinuations[request] = continuation
            }
        }
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    func videoPlayerItem(
        assetID: String,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AVPlayerItem {
        throw CancellationError()
    }
}
