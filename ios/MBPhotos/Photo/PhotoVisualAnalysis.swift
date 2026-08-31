import CoreGraphics
import Foundation
import Vision

enum VisualAnalysisAlgorithm {
    /// Bump this value whenever rendition sizing, request configuration, or any
    /// persisted derived metric changes. Vision's own revisions are recorded
    /// separately so cache compatibility never depends on an SDK default.
    static let currentVersion = "bounded-vision-v1"
    static let maximumRenditionDimension = 1_024
}

enum VisualAnalysisStage: String, Codable, Sendable {
    case fetchingAsset
    case requestingRendition
    case analyzingVision
    case revalidatingAsset
    case complete
}

struct VisualAnalysisProgress: Equatable, Sendable {
    let stage: VisualAnalysisStage
    let fractionCompleted: Double

    init(stage: VisualAnalysisStage, fractionCompleted: Double) {
        self.stage = stage
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
    }
}

struct VisualAnalysisKey: Codable, Hashable, Sendable {
    let assetID: String
    let sourceRevision: String
    let algorithmVersion: String
}

struct VisualAnalysisVisionRevisions: Codable, Hashable, Sendable {
    let featurePrint: Int
    let aesthetics: Int
    let faceCaptureQuality: Int
    let textRecognition: Int
    let barcodeDetection: Int
    let objectnessSaliency: Int
    /// The revision attempted on supported iOS 26 hardware. A nil result in the
    /// record still means the request was unavailable or unsupported.
    let lensSmudge: Int?

    static let pinnedV1 = VisualAnalysisVisionRevisions(
        featurePrint: VNGenerateImageFeaturePrintRequestRevision2,
        aesthetics: VNCalculateImageAestheticsScoresRequestRevision1,
        faceCaptureQuality: VNDetectFaceCaptureQualityRequestRevision3,
        textRecognition: VNRecognizeTextRequestRevision3,
        barcodeDetection: VNDetectBarcodesRequestRevision4,
        objectnessSaliency: VNGenerateObjectnessBasedSaliencyImageRequestRevision2,
        lensSmudge: 1
    )

    var isStructurallyValid: Bool {
        featurePrint > 0
            && aesthetics > 0
            && faceCaptureQuality > 0
            && textRecognition > 0
            && barcodeDetection > 0
            && objectnessSaliency > 0
            && lensSmudge.map { $0 > 0 } != false
    }
}

struct ArchivedVisualFeaturePrint: Codable, Hashable, Sendable {
    let requestRevision: Int
    let elementCount: Int
    let elementTypeRawValue: UInt
    let archive: Data

    init(
        requestRevision: Int,
        elementCount: Int,
        elementTypeRawValue: UInt,
        archive: Data
    ) {
        self.requestRevision = requestRevision
        self.elementCount = elementCount
        self.elementTypeRawValue = elementTypeRawValue
        self.archive = archive
    }

    init(observation: VNFeaturePrintObservation) throws {
        requestRevision = Int(observation.requestRevision)
        elementCount = observation.elementCount
        elementTypeRawValue = observation.elementType.rawValue
        archive = try NSKeyedArchiver.archivedData(
            withRootObject: observation,
            requiringSecureCoding: true
        )
    }

    var isStructurallyValid: Bool {
        requestRevision > 0
            && elementCount > 0
            && [VNElementType.float.rawValue, VNElementType.double.rawValue]
                .contains(elementTypeRawValue)
            && !archive.isEmpty
    }

    /// Returns nil for corrupt, non-finite, or non-comparable feature prints.
    /// Metadata is checked before unarchiving so differently-versioned vectors
    /// never reach Vision's distance API.
    func distance(to other: ArchivedVisualFeaturePrint) -> Float? {
        guard isStructurallyValid,
              other.isStructurallyValid,
              requestRevision == other.requestRevision,
              elementCount == other.elementCount,
              elementTypeRawValue == other.elementTypeRawValue,
              let first = try? observation(),
              let second = try? other.observation() else {
            return nil
        }

        var distance: Float = 0
        guard (try? first.computeDistance(&distance, to: second)) != nil,
              distance.isFinite,
              distance >= 0 else {
            return nil
        }
        return distance
    }

    func observation() throws -> VNFeaturePrintObservation {
        guard isStructurallyValid,
              let observation = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self,
                from: archive
              ),
              Int(observation.requestRevision) == requestRevision,
              observation.elementCount == elementCount,
              observation.elementType.rawValue == elementTypeRawValue else {
            throw VisualAnalysisError.invalidFeaturePrintArchive
        }
        return observation
    }
}

struct VisualAestheticsResult: Codable, Hashable, Sendable {
    let overallScore: Float
    let isUtility: Bool

    var isStructurallyValid: Bool {
        overallScore.isFinite && (-1 ... 1).contains(overallScore)
    }
}

struct VisualFaceResult: Codable, Hashable, Sendable {
    let count: Int
    let bestCaptureQuality: Float?

    var isStructurallyValid: Bool {
        count >= 0
            && bestCaptureQuality.map { $0.isFinite && (0 ... 1).contains($0) } != false
            && (count > 0 || bestCaptureQuality == nil)
    }
}

struct VisualTextStatistics: Codable, Hashable, Sendable {
    let observationCount: Int
    /// Union area of Vision's normalized text boxes. Overlap is counted once.
    let normalizedCoverage: Double

    var isStructurallyValid: Bool {
        observationCount >= 0
            && normalizedCoverage.isFinite
            && (0 ... 1).contains(normalizedCoverage)
            && (observationCount > 0 || normalizedCoverage == 0)
    }
}

struct VisualSaliencyResult: Codable, Hashable, Sendable {
    let salientObjectCount: Int
    let maximumValue: Float?
    /// Vision produced no objectness-based salient-object regions.
    let noClearSubject: Bool

    var isStructurallyValid: Bool {
        salientObjectCount >= 0
            && maximumValue.map { $0.isFinite && (0 ... 1).contains($0) } != false
            && noClearSubject == (salientObjectCount == 0)
    }
}

struct VisualLensSmudgeResult: Codable, Hashable, Sendable {
    let confidence: Float

    var isStructurallyValid: Bool {
        confidence.isFinite && (0 ... 1).contains(confidence)
    }
}

struct VisualAnalysisRecord: Codable, Hashable, Identifiable, Sendable {
    let assetID: String
    /// This is `PhotoAsset.analysisRevision`, not its export-renderer revision.
    let sourceRevision: String
    let algorithmVersion: String
    let visionRevisions: VisualAnalysisVisionRevisions
    let featurePrint: ArchivedVisualFeaturePrint?
    let aesthetics: VisualAestheticsResult?
    let faces: VisualFaceResult
    /// Derived counts and coverage only. Recognized strings are never persisted.
    let text: VisualTextStatistics
    /// Presence only. Barcode payloads and symbologies are never persisted.
    let containsBarcode: Bool
    let saliency: VisualSaliencyResult?
    let lensSmudge: VisualLensSmudgeResult?
    let analyzedAt: Date

    var id: VisualAnalysisKey {
        VisualAnalysisKey(
            assetID: assetID,
            sourceRevision: sourceRevision,
            algorithmVersion: algorithmVersion
        )
    }

    var isStructurallyValid: Bool {
        !assetID.isEmpty
            && !sourceRevision.isEmpty
            && !algorithmVersion.isEmpty
            && visionRevisions.isStructurallyValid
            && featurePrint.map {
                $0.isStructurallyValid && $0.requestRevision == visionRevisions.featurePrint
            } != false
            && aesthetics.map(\.isStructurallyValid) != false
            && faces.isStructurallyValid
            && text.isStructurallyValid
            && saliency.map(\.isStructurallyValid) != false
            && lensSmudge.map(\.isStructurallyValid) != false
            && analyzedAt.timeIntervalSinceReferenceDate.isFinite
    }

    func isValid(
        assetID: String,
        sourceRevision: String,
        algorithmVersion: String = VisualAnalysisAlgorithm.currentVersion,
        visionRevisions: VisualAnalysisVisionRevisions = .pinnedV1
    ) -> Bool {
        isStructurallyValid
            && self.assetID == assetID
            && self.sourceRevision == sourceRevision
            && self.algorithmVersion == algorithmVersion
            && self.visionRevisions == visionRevisions
    }

    func isValid(
        for asset: PhotoAsset,
        algorithmVersion: String = VisualAnalysisAlgorithm.currentVersion,
        visionRevisions: VisualAnalysisVisionRevisions = .pinnedV1
    ) -> Bool {
        isValid(
            assetID: asset.id,
            sourceRevision: asset.analysisRevision,
            algorithmVersion: algorithmVersion,
            visionRevisions: visionRevisions
        )
    }
}

enum VisualAnalysisAttemptStatus: String, Codable, Hashable, Sendable {
    /// The bounded current rendition is only available through an iCloud fetch.
    case unavailableLocally
    /// Vision or PhotoKit could not analyze the current revision. Explicit user
    /// analysis may retry it, while automatic maintenance leaves it alone.
    case failed
}

/// Durable negative-result cache for bounded visual analysis. Keeping this
/// separate from `VisualAnalysisRecord` prevents an unavailable or failed
/// attempt from masquerading as usable visual evidence.
struct VisualAnalysisAttemptRecord: Codable, Hashable, Sendable {
    let assetID: String
    let sourceRevision: String
    let algorithmVersion: String
    let visionRevisions: VisualAnalysisVisionRevisions
    let status: VisualAnalysisAttemptStatus
    let attemptedAt: Date

    var isStructurallyValid: Bool {
        !assetID.isEmpty
            && !sourceRevision.isEmpty
            && !algorithmVersion.isEmpty
            && visionRevisions.isStructurallyValid
            && attemptedAt.timeIntervalSinceReferenceDate.isFinite
    }

    func isValid(
        for asset: PhotoAsset,
        algorithmVersion: String = VisualAnalysisAlgorithm.currentVersion,
        visionRevisions: VisualAnalysisVisionRevisions = .pinnedV1
    ) -> Bool {
        isStructurallyValid
            && assetID == asset.id
            && sourceRevision == asset.analysisRevision
            && self.algorithmVersion == algorithmVersion
            && self.visionRevisions == visionRevisions
    }
}

enum VisualAnalysisError: LocalizedError, Sendable {
    case assetUnavailable(String)
    case assetChanged(String)
    case unsupportedMedia(String)
    case networkAccessRequired(String)
    case imageRequestFailed(String)
    case invalidImage(String)
    case missingVisionResult(String)
    case invalidFeaturePrintArchive

    var errorDescription: String? {
        switch self {
        case let .assetUnavailable(assetID):
            "The photo is no longer accessible (\(assetID))."
        case let .assetChanged(assetID):
            "The photo changed while visual analysis was running (\(assetID))."
        case let .unsupportedMedia(assetID):
            "Visual analysis currently supports still-photo assets only (\(assetID))."
        case let .networkAccessRequired(assetID):
            "The current photo rendition is in iCloud (\(assetID))."
        case let .imageRequestFailed(message):
            message
        case let .invalidImage(assetID):
            "PhotoKit did not provide a readable image rendition (\(assetID))."
        case let .missingVisionResult(request):
            "Vision did not return a required \(request) result."
        case .invalidFeaturePrintArchive:
            "The archived Vision feature print is invalid or incompatible."
        }
    }
}

enum VisualAnalysisGeometry {
    static func boundedRenditionSize(
        pixelWidth: Int,
        pixelHeight: Int,
        maximumDimension: Int = VisualAnalysisAlgorithm.maximumRenditionDimension
    ) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0, maximumDimension > 0 else { return .zero }
        let longestSide = max(pixelWidth, pixelHeight)
        let scale = min(1, Double(maximumDimension) / Double(longestSide))
        return CGSize(
            width: max((Double(pixelWidth) * scale).rounded(), 1),
            height: max((Double(pixelHeight) * scale).rounded(), 1)
        )
    }

    /// Calculates the exact union area of normalized rectangles and clamps
    /// boxes that extend beyond the image. This avoids inflating OCR coverage
    /// when Vision's line boxes overlap.
    static func normalizedCoverage(of boundingBoxes: [CGRect]) -> Double {
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rectangles = boundingBoxes.compactMap { box -> CGRect? in
            guard box.origin.x.isFinite,
                  box.origin.y.isFinite,
                  box.width.isFinite,
                  box.height.isFinite else {
                return nil
            }
            let clipped = box.standardized.intersection(unitRect)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
        guard !rectangles.isEmpty else { return 0 }

        let xCoordinates = Set(rectangles.flatMap { [$0.minX, $0.maxX] }).sorted()
        var area: CGFloat = 0
        for index in 0 ..< max(xCoordinates.count - 1, 0) {
            let xStart = xCoordinates[index]
            let xEnd = xCoordinates[index + 1]
            guard xEnd > xStart else { continue }

            var intervals: [(minimum: CGFloat, maximum: CGFloat)] = []
            intervals.reserveCapacity(rectangles.count)
            for rectangle in rectangles where rectangle.minX < xEnd && rectangle.maxX > xStart {
                intervals.append((rectangle.minY, rectangle.maxY))
            }
            intervals.sort { lhs, rhs in
                lhs.minimum == rhs.minimum
                    ? lhs.maximum < rhs.maximum
                    : lhs.minimum < rhs.minimum
            }
            guard var current = intervals.first else { continue }
            var coveredHeight: CGFloat = 0
            for interval in intervals.dropFirst() {
                if interval.minimum <= current.maximum {
                    current.maximum = max(current.maximum, interval.maximum)
                } else {
                    coveredHeight += current.maximum - current.minimum
                    current = interval
                }
            }
            coveredHeight += current.maximum - current.minimum
            area += (xEnd - xStart) * coveredHeight
        }
        return min(max(Double(area), 0), 1)
    }
}
