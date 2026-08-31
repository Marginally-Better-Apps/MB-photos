@preconcurrency import Photos
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UIKit
import Vision

protocol VisualAssetAnalyzing: Sendable {
    func analyze(
        assetID: String,
        sourceRevision: String,
        includeNetwork: Bool,
        progress: @escaping @Sendable (VisualAnalysisProgress) -> Void
    ) async throws -> VisualAnalysisRecord
}

extension VisualAssetAnalyzing {
    func analyze(
        assetID: String,
        sourceRevision: String,
        includeNetwork: Bool
    ) async throws -> VisualAnalysisRecord {
        try await analyze(
            assetID: assetID,
            sourceRevision: sourceRevision,
            includeNetwork: includeNetwork,
            progress: { _ in }
        )
    }
}

/// Produces privacy-preserving, bounded-cost visual evidence from PhotoKit's
/// current rendition. Image bytes and recognized text/barcode payloads remain
/// in memory and are never included in the returned record.
final class PhotoKitVisualAnalysisService: VisualAssetAnalyzing, @unchecked Sendable {
    private let imageManager: PHImageManager
    private let algorithmVersion: String
    private let revisions: VisualAnalysisVisionRevisions
    private let maximumRenditionDimension: Int
    private let now: @Sendable () -> Date

    init(
        imageManager: PHImageManager = .default(),
        algorithmVersion: String = VisualAnalysisAlgorithm.currentVersion,
        revisions: VisualAnalysisVisionRevisions = .pinnedV1,
        maximumRenditionDimension: Int = VisualAnalysisAlgorithm.maximumRenditionDimension,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.imageManager = imageManager
        self.algorithmVersion = algorithmVersion
        self.revisions = revisions
        self.maximumRenditionDimension = maximumRenditionDimension
        self.now = now
    }

    func analyze(
        assetID: String,
        sourceRevision: String,
        includeNetwork: Bool,
        progress: @escaping @Sendable (VisualAnalysisProgress) -> Void = { _ in }
    ) async throws -> VisualAnalysisRecord {
        try Task.checkCancellation()
        guard revisions.isStructurallyValid,
              !algorithmVersion.isEmpty,
              maximumRenditionDimension > 0 else {
            throw VisualAnalysisError.imageRequestFailed("The visual-analysis configuration is invalid.")
        }

        progress(VisualAnalysisProgress(stage: .fetchingAsset, fractionCompleted: 0))
        let initial = try Self.fetchImageAsset(assetID: assetID)
        guard initial.model.analysisRevision == sourceRevision else {
            throw VisualAnalysisError.assetChanged(assetID)
        }

        let targetSize = VisualAnalysisGeometry.boundedRenditionSize(
            pixelWidth: initial.model.pixelWidth,
            pixelHeight: initial.model.pixelHeight,
            maximumDimension: maximumRenditionDimension
        )
        guard targetSize.width > 0, targetSize.height > 0 else {
            throw VisualAnalysisError.invalidImage(assetID)
        }

        progress(VisualAnalysisProgress(stage: .requestingRendition, fractionCompleted: 0.05))
        let imageBox = try await requestCurrentRendition(
            for: initial.photoKitAsset,
            assetID: assetID,
            targetSize: targetSize,
            includeNetwork: includeNetwork
        ) { value in
            progress(
                VisualAnalysisProgress(
                    stage: .requestingRendition,
                    fractionCompleted: 0.05 + (0.30 * min(max(value, 0), 1))
                )
            )
        }

        try Task.checkCancellation()
        progress(VisualAnalysisProgress(stage: .analyzingVision, fractionCompleted: 0.40))
        let evidence = try await Self.performVisionAnalysis(
            image: imageBox.image,
            assetID: assetID,
            revisions: revisions
        )
        try Task.checkCancellation()

        progress(VisualAnalysisProgress(stage: .revalidatingAsset, fractionCompleted: 0.95))
        let final = try Self.fetchImageAsset(assetID: assetID)
        guard final.model.analysisRevision == sourceRevision else {
            throw VisualAnalysisError.assetChanged(assetID)
        }

        let result = VisualAnalysisRecord(
            assetID: assetID,
            sourceRevision: sourceRevision,
            algorithmVersion: algorithmVersion,
            visionRevisions: revisions,
            featurePrint: evidence.featurePrint,
            aesthetics: evidence.aesthetics,
            faces: evidence.faces,
            text: evidence.text,
            containsBarcode: evidence.containsBarcode,
            saliency: evidence.saliency,
            lensSmudge: evidence.lensSmudge,
            analyzedAt: now()
        )
        guard result.isStructurallyValid else {
            throw VisualAnalysisError.imageRequestFailed("Vision returned an invalid visual-analysis record.")
        }
        progress(VisualAnalysisProgress(stage: .complete, fractionCompleted: 1))
        return result
    }

    private func requestCurrentRendition(
        for asset: PHAsset,
        assetID: String,
        targetSize: CGSize,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VisualAnalysisImageBox {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = includeNetwork
        options.progressHandler = { value, _, _, _ in progress(value) }
        let cancellation = VisualImageRequestCancellation(manager: imageManager)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = VisualAnalysisContinuation(continuation)
                cancellation.setCancellationHandler {
                    box.resume(throwing: CancellationError())
                }
                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if cancellation.isCancelled
                        || (info?[PHImageCancelledKey] as? Bool) == true {
                        box.resume(throwing: CancellationError())
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        box.resume(
                            throwing: Self.mapPhotoError(
                                error,
                                assetID: assetID,
                                includeNetwork: includeNetwork
                            )
                        )
                    } else if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        return
                    } else if let image {
                        progress(1)
                        box.resume(returning: VisualAnalysisImageBox(image))
                    } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true,
                              !includeNetwork {
                        box.resume(throwing: VisualAnalysisError.networkAccessRequired(assetID))
                    } else {
                        box.resume(throwing: VisualAnalysisError.assetUnavailable(assetID))
                    }
                }
                cancellation.setRequestID(requestID)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func fetchImageAsset(
        assetID: String
    ) throws -> (photoKitAsset: PHAsset, model: PhotoAsset) {
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        guard let asset = result.firstObject,
              let model = PhotoKitAssetMapper.model(from: asset) else {
            throw VisualAnalysisError.assetUnavailable(assetID)
        }
        guard asset.mediaType == .image else {
            throw VisualAnalysisError.unsupportedMedia(assetID)
        }
        return (asset, model)
    }

    private static func mapPhotoError(
        _ error: Error,
        assetID: String,
        includeNetwork: Bool
    ) -> Error {
        let nsError = error as NSError
        if nsError.domain == PHPhotosErrorDomain,
           nsError.code == PHPhotosError.userCancelled.rawValue {
            return CancellationError()
        }
        if nsError.domain == PHPhotosErrorDomain,
           nsError.code == PHPhotosError.networkAccessRequired.rawValue {
            return VisualAnalysisError.networkAccessRequired(assetID)
        }
        if !includeNetwork,
           nsError.domain == PHPhotosErrorDomain,
           nsError.code == PHPhotosError.networkError.rawValue {
            return VisualAnalysisError.networkAccessRequired(assetID)
        }
        return VisualAnalysisError.imageRequestFailed(error.localizedDescription)
    }

    private static func performVisionAnalysis(
        image: UIImage,
        assetID: String,
        revisions: VisualAnalysisVisionRevisions
    ) async throws -> VisualAnalysisEvidence {
        guard let cgImage = makeCGImage(from: image) else {
            throw VisualAnalysisError.invalidImage(assetID)
        }
        let orientation = cgImageOrientation(for: image.imageOrientation)

        let featureRequest = VNGenerateImageFeaturePrintRequest()
        featureRequest.revision = revisions.featurePrint
        featureRequest.imageCropAndScaleOption = .scaleFit

        let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
        aestheticsRequest.revision = revisions.aesthetics

        let faceRequest = VNDetectFaceCaptureQualityRequest()
        faceRequest.revision = revisions.faceCaptureQuality

        let textRequest = VNRecognizeTextRequest()
        textRequest.revision = revisions.textRecognition
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        textRequest.automaticallyDetectsLanguage = false

        let barcodeRequest = VNDetectBarcodesRequest()
        barcodeRequest.revision = revisions.barcodeDetection

        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        saliencyRequest.revision = revisions.objectnessSaliency

        let requests: [VNRequest] = [
            featureRequest,
            aestheticsRequest,
            faceRequest,
            textRequest,
            barcodeRequest,
            saliencyRequest,
        ]
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation,
            options: [:]
        )
        let cancellation = VisualVisionRequestCancellation(requests: requests)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try handler.perform(requests)
                try Task.checkCancellation()
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }

        guard let featureObservation = featureRequest.results?.first else {
            throw VisualAnalysisError.missingVisionResult("feature-print")
        }
        let featurePrint = try ArchivedVisualFeaturePrint(observation: featureObservation)

        let aesthetics = aestheticsRequest.results?.first.map {
            VisualAestheticsResult(overallScore: $0.overallScore, isUtility: $0.isUtility)
        }
        let faceObservations = faceRequest.results ?? []
        let bestFaceQuality = faceObservations
            .compactMap(\.faceCaptureQuality)
            .filter { $0.isFinite }
            .max()
        let faces = VisualFaceResult(
            count: faceObservations.count,
            bestCaptureQuality: bestFaceQuality
        )

        let textObservations = textRequest.results ?? []
        let text = VisualTextStatistics(
            observationCount: textObservations.count,
            normalizedCoverage: VisualAnalysisGeometry.normalizedCoverage(
                of: textObservations.map(\.boundingBox)
            )
        )

        let saliency: VisualSaliencyResult?
        if let observation = saliencyRequest.results?.first {
            let objectCount = observation.salientObjects?.count ?? 0
            saliency = VisualSaliencyResult(
                salientObjectCount: objectCount,
                maximumValue: maximumSaliencyValue(in: observation.pixelBuffer),
                noClearSubject: objectCount == 0
            )
        } else {
            saliency = nil
        }

        let lensSmudge = try await detectLensSmudgeIfSupported(
            in: cgImage,
            orientation: orientation,
            pinnedRevision: revisions.lensSmudge
        )
        return VisualAnalysisEvidence(
            featurePrint: featurePrint,
            aesthetics: aesthetics,
            faces: faces,
            text: text,
            containsBarcode: !(barcodeRequest.results ?? []).isEmpty,
            saliency: saliency,
            lensSmudge: lensSmudge
        )
    }

    private static func makeCGImage(from image: UIImage) -> CGImage? {
        if let cgImage = image.cgImage { return cgImage }
        guard let ciImage = image.ciImage else { return nil }
        return CIContext(options: nil).createCGImage(ciImage, from: ciImage.extent)
    }

    private static func cgImageOrientation(
        for orientation: UIImage.Orientation
    ) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }

    private static func maximumSaliencyValue(in pixelBuffer: CVPixelBuffer) -> Float? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_OneComponent32Float
                || format == kCVPixelFormatType_OneComponent8 else {
            return nil
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var maximum: Float = 0
        var foundFiniteValue = false
        if format == kCVPixelFormatType_OneComponent32Float {
            for row in 0 ..< height {
                let values = baseAddress
                    .advanced(by: row * bytesPerRow)
                    .assumingMemoryBound(to: Float.self)
                for column in 0 ..< width where values[column].isFinite {
                    foundFiniteValue = true
                    maximum = max(maximum, values[column])
                }
            }
        } else {
            foundFiniteValue = width > 0 && height > 0
            for row in 0 ..< height {
                let values = baseAddress
                    .advanced(by: row * bytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                for column in 0 ..< width {
                    maximum = max(maximum, Float(values[column]) / 255)
                }
            }
        }
        guard foundFiniteValue else { return nil }
        return min(max(maximum, 0), 1)
    }

    private static func detectLensSmudgeIfSupported(
        in image: CGImage,
        orientation: CGImagePropertyOrientation,
        pinnedRevision: Int?
    ) async throws -> VisualLensSmudgeResult? {
        guard pinnedRevision == 1 else { return nil }
        if #available(iOS 26.0, *) {
            guard DetectLensSmudgeRequest.supportedRevisions.contains(.revision1) else {
                return nil
            }
            do {
                let observation = try await DetectLensSmudgeRequest(.revision1).perform(
                    on: image,
                    orientation: orientation
                )
                return VisualLensSmudgeResult(confidence: observation.confidence)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The request is limited to newer Neural Engine hardware. An
                // unsupported compute device is evidence absence, not failure of
                // the other Vision analysis.
                return nil
            }
        }
        return nil
    }
}

private struct VisualAnalysisEvidence: Sendable {
    let featurePrint: ArchivedVisualFeaturePrint
    let aesthetics: VisualAestheticsResult?
    let faces: VisualFaceResult
    let text: VisualTextStatistics
    let containsBarcode: Bool
    let saliency: VisualSaliencyResult?
    let lensSmudge: VisualLensSmudgeResult?
}

private final class VisualAnalysisImageBox: @unchecked Sendable {
    let image: UIImage

    init(_ image: UIImage) {
        self.image = image
    }
}

private final class VisualAnalysisContinuation<Value: Sendable>: @unchecked Sendable {
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
        let value = continuation
        continuation = nil
        lock.unlock()
        return value
    }
}

private final class VisualImageRequestCancellation: @unchecked Sendable {
    private let manager: PHImageManager
    private let lock = NSLock()
    private var requestID: PHImageRequestID?
    private var cancellationHandler: (@Sendable () -> Void)?
    private var cancelled = false

    init(manager: PHImageManager) {
        self.manager = manager
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func setCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        cancellationHandler = handler
        let shouldCallImmediately = cancelled
        lock.unlock()
        if shouldCallImmediately { handler() }
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
        let cancellationHandler = cancellationHandler
        lock.unlock()
        if let requestID { manager.cancelImageRequest(requestID) }
        cancellationHandler?()
    }
}

private final class VisualVisionRequestCancellation: @unchecked Sendable {
    private let requests: [VNRequest]

    init(requests: [VNRequest]) {
        self.requests = requests
    }

    func cancel() {
        for request in requests {
            request.cancel()
        }
    }
}
