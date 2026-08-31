@testable import MBPhotos
import CoreGraphics
import Foundation
import XCTest

final class PhotoVisualAnalysisTests: XCTestCase {
    func testRecordRoundTripsAndRetainsCacheIdentity() throws {
        let record = makeRecord()

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(VisualAnalysisRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(
            decoded.id,
            VisualAnalysisKey(
                assetID: "asset-1",
                sourceRevision: "analysis-revision-1",
                algorithmVersion: VisualAnalysisAlgorithm.currentVersion
            )
        )
        XCTAssertTrue(
            decoded.isValid(
                assetID: "asset-1",
                sourceRevision: "analysis-revision-1"
            )
        )
    }

    func testRecordValidityRejectsStaleOrDifferentlyVersionedEvidence() {
        let record = makeRecord()

        XCTAssertFalse(
            record.isValid(assetID: "asset-2", sourceRevision: "analysis-revision-1")
        )
        XCTAssertFalse(
            record.isValid(assetID: "asset-1", sourceRevision: "analysis-revision-2")
        )
        XCTAssertFalse(
            record.isValid(
                assetID: "asset-1",
                sourceRevision: "analysis-revision-1",
                algorithmVersion: "bounded-vision-v2"
            )
        )
        XCTAssertFalse(
            record.isValid(
                assetID: "asset-1",
                sourceRevision: "analysis-revision-1",
                visionRevisions: VisualAnalysisVisionRevisions(
                    featurePrint: 1,
                    aesthetics: 1,
                    faceCaptureQuality: 3,
                    textRecognition: 3,
                    barcodeDetection: 4,
                    objectnessSaliency: 2,
                    lensSmudge: 1
                )
            )
        )
    }

    func testPinnedVisionRevisionsAreExplicitAndStructurallyValid() {
        XCTAssertEqual(
            VisualAnalysisVisionRevisions.pinnedV1,
            VisualAnalysisVisionRevisions(
                featurePrint: 2,
                aesthetics: 1,
                faceCaptureQuality: 3,
                textRecognition: 3,
                barcodeDetection: 4,
                objectnessSaliency: 2,
                lensSmudge: 1
            )
        )
        XCTAssertTrue(VisualAnalysisVisionRevisions.pinnedV1.isStructurallyValid)
    }

    func testInvalidDerivedRangesInvalidateRecord() {
        let record = VisualAnalysisRecord(
            assetID: "asset-1",
            sourceRevision: "analysis-revision-1",
            algorithmVersion: VisualAnalysisAlgorithm.currentVersion,
            visionRevisions: .pinnedV1,
            featurePrint: nil,
            aesthetics: VisualAestheticsResult(overallScore: 1.1, isUtility: false),
            faces: VisualFaceResult(count: 0, bestCaptureQuality: 0.5),
            text: VisualTextStatistics(observationCount: 0, normalizedCoverage: 0.1),
            containsBarcode: false,
            saliency: VisualSaliencyResult(
                salientObjectCount: 0,
                maximumValue: 0.5,
                noClearSubject: false
            ),
            lensSmudge: VisualLensSmudgeResult(confidence: -0.1),
            analyzedAt: Date()
        )

        XCTAssertFalse(record.isStructurallyValid)
    }

    func testFeatureDistanceRejectsMetadataMismatchAndCorruptArchives() {
        let first = ArchivedVisualFeaturePrint(
            requestRevision: 2,
            elementCount: 768,
            elementTypeRawValue: 1,
            archive: Data([0x01])
        )
        let differentRevision = ArchivedVisualFeaturePrint(
            requestRevision: 1,
            elementCount: 768,
            elementTypeRawValue: 1,
            archive: Data([0x01])
        )
        let corruptMatch = ArchivedVisualFeaturePrint(
            requestRevision: 2,
            elementCount: 768,
            elementTypeRawValue: 1,
            archive: Data([0x02])
        )

        XCTAssertNil(first.distance(to: differentRevision))
        XCTAssertNil(first.distance(to: corruptMatch))
    }

    func testBoundedRenditionSizePreservesAspectRatioAndDoesNotUpscale() {
        XCTAssertEqual(
            VisualAnalysisGeometry.boundedRenditionSize(
                pixelWidth: 4_032,
                pixelHeight: 3_024
            ),
            CGSize(width: 1_024, height: 768)
        )
        XCTAssertEqual(
            VisualAnalysisGeometry.boundedRenditionSize(
                pixelWidth: 640,
                pixelHeight: 480
            ),
            CGSize(width: 640, height: 480)
        )
        XCTAssertEqual(
            VisualAnalysisGeometry.boundedRenditionSize(
                pixelWidth: 0,
                pixelHeight: 480
            ),
            .zero
        )
    }

    func testNormalizedTextCoverageUnionsOverlapAndClipsToImage() {
        let coverage = VisualAnalysisGeometry.normalizedCoverage(
            of: [
                CGRect(x: 0, y: 0, width: 0.75, height: 1),
                CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            ]
        )
        let clipped = VisualAnalysisGeometry.normalizedCoverage(
            of: [CGRect(x: -0.5, y: -0.5, width: 1, height: 1)]
        )

        XCTAssertEqual(coverage, 0.875, accuracy: 0.000_001)
        XCTAssertEqual(clipped, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(VisualAnalysisGeometry.normalizedCoverage(of: []), 0)
    }

    func testProgressClampsFractions() {
        XCTAssertEqual(
            VisualAnalysisProgress(stage: .fetchingAsset, fractionCompleted: -1)
                .fractionCompleted,
            0
        )
        XCTAssertEqual(
            VisualAnalysisProgress(stage: .complete, fractionCompleted: 2)
                .fractionCompleted,
            1
        )
    }

    private func makeRecord() -> VisualAnalysisRecord {
        VisualAnalysisRecord(
            assetID: "asset-1",
            sourceRevision: "analysis-revision-1",
            algorithmVersion: VisualAnalysisAlgorithm.currentVersion,
            visionRevisions: .pinnedV1,
            featurePrint: nil,
            aesthetics: VisualAestheticsResult(overallScore: 0.42, isUtility: false),
            faces: VisualFaceResult(count: 2, bestCaptureQuality: 0.91),
            text: VisualTextStatistics(observationCount: 3, normalizedCoverage: 0.17),
            containsBarcode: true,
            saliency: VisualSaliencyResult(
                salientObjectCount: 1,
                maximumValue: 0.86,
                noClearSubject: false
            ),
            lensSmudge: VisualLensSmudgeResult(confidence: 0.2),
            analyzedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
