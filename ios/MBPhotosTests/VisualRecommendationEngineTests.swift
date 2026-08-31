@testable import MBPhotos
import Foundation
import XCTest

final class VisualRecommendationEngineTests: XCTestCase {
    func testRapidRetakesRequireBothTimeWindowAndFeatureDistance() throws {
        let first = asset(id: "first", date: 100)
        let similar = asset(id: "similar", date: 105)
        let visuallyDifferent = asset(id: "different", date: 106)
        let outsideWindow = asset(id: "late", date: 130)
        let assets = [outsideWindow, visuallyDifferent, similar, first]
        let analyses = analysisMap(
            assets,
            featureValues: ["first": 10, "similar": 18, "different": 90, "late": 12]
        )
        let configuration = VisualRecommendationConfiguration(
            rapidRetakeWindow: 10,
            rapidRetakeDistanceThreshold: 0.1,
            maximumRapidCandidatesPerAsset: 8
        )

        let result = VisualRecommendationEngine.recommendations(
            assets: assets,
            analysisByAssetID: analyses,
            configuration: configuration,
            featurePrintDistance: byteDistance
        )

        let group = try XCTUnwrap(result.groups.first { $0.kind == .rapidRetakes })
        XCTAssertEqual(group.assetIDs, ["first", "similar"])
        XCTAssertTrue(group.isReviewOnly)
        XCTAssertTrue(group.evidence.contains { evidence in
            if case let .featurePrintDistance(assetID, relatedID, distance, threshold) = evidence {
                return assetID == "first" && relatedID == "similar"
                    && abs(distance - 0.08) < 0.0001 && threshold == 0.1
            }
            return false
        })
        XCTAssertTrue(group.evidence.contains { evidence in
            if case let .captureTimeDelta(_, _, seconds, window) = evidence {
                return seconds == 5 && window == 10
            }
            return false
        })
        XCTAssertFalse(result.groups.contains { $0.assetIDs.contains("different") })
        XCTAssertFalse(result.groups.contains { $0.assetIDs.contains("late") })
    }

    func testScreenshotComparisonsStayBoundedInsideCoarseBucket() {
        let count = 60
        let maximumNeighbors = 3
        let assets = (0..<count).map { index in
            asset(id: String(format: "shot-%03d", index), date: Double(index), isScreenshot: true)
        }
        let analyses = analysisMap(
            assets,
            featureValues: Dictionary(uniqueKeysWithValues: assets.enumerated().map {
                ($0.element.id, UInt8($0.offset % 250))
            })
        )
        let configuration = VisualRecommendationConfiguration(
            screenshotDistanceThreshold: 0,
            maximumScreenshotCandidatesPerAsset: maximumNeighbors
        )

        let result = VisualRecommendationEngine.recommendations(
            assets: assets,
            analysisByAssetID: analyses,
            configuration: configuration,
            featurePrintDistance: { _, _ in 1 }
        )

        let expected = maximumNeighbors * count
            - (maximumNeighbors * (maximumNeighbors + 1) / 2)
        XCTAssertEqual(result.diagnostics.screenshotCandidatePairCount, expected)
        XCTAssertEqual(result.diagnostics.featurePrintDistanceComparisonCount, expected)
        XCTAssertLessThanOrEqual(
            result.diagnostics.featurePrintDistanceComparisonCount,
            count * maximumNeighbors
        )
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testFeatureDistanceThresholdIsInclusive() {
        let first = asset(id: "first", date: 100)
        let second = asset(id: "second", date: 101)
        let assets = [first, second]
        let analyses = analysisMap(assets, featureValues: ["first": 0, "second": 25])

        let included = VisualRecommendationEngine.recommendations(
            assets: assets,
            analysisByAssetID: analyses,
            configuration: VisualRecommendationConfiguration(
                rapidRetakeWindow: 10,
                rapidRetakeDistanceThreshold: 0.25
            ),
            featurePrintDistance: byteDistance
        )
        let excluded = VisualRecommendationEngine.recommendations(
            assets: assets,
            analysisByAssetID: analyses,
            configuration: VisualRecommendationConfiguration(
                rapidRetakeWindow: 10,
                rapidRetakeDistanceThreshold: 0.249
            ),
            featurePrintDistance: byteDistance
        )

        XCTAssertEqual(included.groups.filter { $0.kind == .rapidRetakes }.count, 1)
        XCTAssertTrue(excluded.groups.filter { $0.kind == .rapidRetakes }.isEmpty)
    }

    func testMissingAndIncompatibleFeaturePrintsNeverReachDistanceFunction() {
        let first = asset(id: "first", date: 100)
        let incompatible = asset(id: "incompatible", date: 101)
        let missing = asset(id: "missing", date: 102)
        let assets = [first, incompatible, missing]
        var analyses = analysisMap(
            assets,
            featureValues: ["first": 1, "incompatible": 2]
        )
        analyses["incompatible"] = analysis(
            for: incompatible,
            featureValue: 2,
            featureElementCount: 2
        )

        let result = VisualRecommendationEngine.recommendations(
            assets: assets,
            analysisByAssetID: analyses,
            configuration: VisualRecommendationConfiguration(
                rapidRetakeWindow: 10,
                maximumRapidCandidatesPerAsset: 8
            ),
            featurePrintDistance: { _, _ in
                XCTFail("Incompatible or missing prints must be rejected before distance evaluation.")
                return 0
            }
        )

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.diagnostics.featurePrintDistanceComparisonCount, 0)
        XCTAssertEqual(result.diagnostics.incompatibleFeaturePrintPairCount, 1)
        XCTAssertEqual(result.diagnostics.missingFeaturePrintPairCount, 2)
    }

    func testProtectedMemberWinsOverHigherQualityBurstMember() throws {
        let protected = asset(
            id: "protected",
            date: 100,
            pixelWidth: 640,
            pixelHeight: 480,
            burstIdentifier: "burst"
        )
        let higherQuality = asset(
            id: "higher-quality",
            date: 100.1,
            isEdited: true,
            subtypes: [.raw, .livePhoto],
            albumIDs: ["one", "two"],
            pixelWidth: 8_064,
            pixelHeight: 6_048,
            burstIdentifier: "burst"
        )
        let analyses = [
            protected.id: analysis(for: protected, aesthetics: -0.9, faceQuality: 0.1),
            higherQuality.id: analysis(for: higherQuality, aesthetics: 0.9, faceQuality: 0.95)
        ]

        let result = VisualRecommendationEngine.recommendations(
            assets: [higherQuality, protected],
            analysisByAssetID: analyses,
            protectedAssetIDs: [protected.id],
            featurePrintDistance: byteDistance
        )

        let group = try XCTUnwrap(result.groups.first { $0.kind == .burst })
        XCTAssertEqual(group.recommendedKeeperID, protected.id)
        XCTAssertTrue(group.cautions.contains(.protectedItem))
        XCTAssertTrue(group.keeperEvidence.contains(.protectedItem(assetID: protected.id)))
        XCTAssertTrue(group.keeperEvidence.contains { evidence in
            if case let .resolution(assetID, pixelCount) = evidence {
                return assetID == protected.id && pixelCount == 307_200
            }
            return false
        })
    }

    func testKeeperQualityRankingUsesMetadataThenVisualScores() throws {
        let edited = asset(id: "edited", date: 100, isEdited: true, burstIdentifier: "metadata")
        let rawLive = asset(
            id: "raw-live",
            date: 101,
            subtypes: [.raw, .livePhoto],
            albumIDs: ["a", "b"],
            pixelWidth: 8_064,
            pixelHeight: 6_048,
            burstIdentifier: "metadata"
        )
        let lowerAesthetics = asset(id: "lower", date: 200, burstIdentifier: "aesthetics")
        let higherAesthetics = asset(id: "higher", date: 201, burstIdentifier: "aesthetics")
        let lowerFace = asset(id: "face-low", date: 300, burstIdentifier: "face")
        let higherFace = asset(id: "face-high", date: 301, burstIdentifier: "face")
        let assets = [edited, rawLive, lowerAesthetics, higherAesthetics, lowerFace, higherFace]
        let analyses = [
            edited.id: analysis(for: edited, aesthetics: -1, faceQuality: 0),
            rawLive.id: analysis(for: rawLive, aesthetics: 1, faceQuality: 1),
            lowerAesthetics.id: analysis(for: lowerAesthetics, aesthetics: 0.1, faceQuality: 0.9),
            higherAesthetics.id: analysis(for: higherAesthetics, aesthetics: 0.8, faceQuality: 0.1),
            lowerFace.id: analysis(for: lowerFace, aesthetics: 0.5, faceQuality: 0.2),
            higherFace.id: analysis(for: higherFace, aesthetics: 0.5, faceQuality: 0.9)
        ]

        let result = VisualRecommendationEngine.recommendations(
            assets: assets,
            analysisByAssetID: analyses,
            featurePrintDistance: byteDistance
        )
        let bursts = Dictionary(uniqueKeysWithValues: result.groups.filter { $0.kind == .burst }.map {
            ($0.assetIDs.sorted().joined(separator: ","), $0)
        })

        XCTAssertEqual(bursts["edited,raw-live"]?.recommendedKeeperID, edited.id)
        XCTAssertEqual(bursts["higher,lower"]?.recommendedKeeperID, higherAesthetics.id)
        XCTAssertEqual(bursts["face-high,face-low"]?.recommendedKeeperID, higherFace.id)
    }

    func testUtilityAndDocumentCandidatesRemainCautiousAndExplainable() throws {
        let item = asset(id: "document", date: 100)
        let record = analysis(
            for: item,
            aesthetics: -0.8,
            isUtility: true,
            textObservationCount: 8,
            textCoverage: 0.45,
            containsBarcode: true
        )

        let result = VisualRecommendationEngine.recommendations(
            assets: [item],
            analysisByAssetID: [item.id: record],
            featurePrintDistance: byteDistance
        )
        let byKind = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.kind, $0) })

        XCTAssertNotNil(byKind[.utility])
        XCTAssertNotNil(byKind[.worthReviewing])
        let document = try XCTUnwrap(byKind[.documentLike])
        XCTAssertTrue(document.isReviewOnly)
        XCTAssertTrue(document.cautions.contains(.mayContainImportantInformation))
        XCTAssertTrue(document.cautions.contains(.containsBarcode))
        XCTAssertFalse(document.evidence.isEmpty)
        XCTAssertTrue(document.evidence.contains(.barcodeDetected(assetID: item.id)))
    }

    func testNoSubjectAndLensSmudgeSignalsRemainReviewOnly() throws {
        let item = asset(id: "unclear", date: 100)
        let record = analysis(
            for: item,
            noClearSubject: true,
            lensSmudgeConfidence: 0.75
        )

        let result = VisualRecommendationEngine.recommendations(
            assets: [item],
            analysisByAssetID: [item.id: record],
            configuration: VisualRecommendationConfiguration(
                minimumLensSmudgeConfidence: 0.75
            ),
            featurePrintDistance: byteDistance
        )
        let byKind = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.kind, $0) })

        XCTAssertTrue(try XCTUnwrap(byKind[.noClearSubject]).isReviewOnly)
        XCTAssertTrue(try XCTUnwrap(byKind[.smudgedCapture]).isReviewOnly)
        XCTAssertEqual(
            byKind[.smudgedCapture]?.evidence,
            [.lensSmudgeConfidence(assetID: item.id, confidence: 0.75)]
        )
    }

    private let byteDistance: VisualFeaturePrintDistance = { lhs, rhs in
        guard let left = lhs.archive.first, let right = rhs.archive.first else { return nil }
        return abs(Float(left) - Float(right)) / 100
    }

    private func analysisMap(
        _ assets: [OrganizeAsset],
        featureValues: [String: UInt8]
    ) -> [String: VisualAnalysisRecord] {
        Dictionary(uniqueKeysWithValues: assets.map { item in
            (
                item.id,
                analysis(for: item, featureValue: featureValues[item.id])
            )
        })
    }

    private func analysis(
        for item: OrganizeAsset,
        featureValue: UInt8? = nil,
        featureRevision: Int = 2,
        featureElementCount: Int = 1,
        aesthetics: Float? = nil,
        isUtility: Bool = false,
        faceQuality: Float? = nil,
        textObservationCount: Int = 0,
        textCoverage: Double = 0,
        containsBarcode: Bool = false,
        noClearSubject: Bool = false,
        lensSmudgeConfidence: Float? = nil
    ) -> VisualAnalysisRecord {
        VisualAnalysisRecord(
            assetID: item.id,
            sourceRevision: item.asset.analysisRevision,
            algorithmVersion: VisualAnalysisAlgorithm.currentVersion,
            visionRevisions: .pinnedV1,
            featurePrint: featureValue.map {
                ArchivedVisualFeaturePrint(
                    requestRevision: featureRevision,
                    elementCount: featureElementCount,
                    elementTypeRawValue: 1,
                    archive: Data([$0])
                )
            },
            aesthetics: aesthetics.map {
                VisualAestheticsResult(overallScore: $0, isUtility: isUtility)
            },
            faces: VisualFaceResult(count: faceQuality == nil ? 0 : 1, bestCaptureQuality: faceQuality),
            text: VisualTextStatistics(
                observationCount: textObservationCount,
                normalizedCoverage: textCoverage
            ),
            containsBarcode: containsBarcode,
            saliency: noClearSubject
                ? VisualSaliencyResult(
                    salientObjectCount: 0,
                    maximumValue: nil,
                    noClearSubject: true
                )
                : nil,
            lensSmudge: lensSmudgeConfidence.map(VisualLensSmudgeResult.init(confidence:)),
            analyzedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func asset(
        id: String,
        date: TimeInterval,
        isScreenshot: Bool = false,
        isFavorite: Bool = false,
        isHidden: Bool = false,
        isEdited: Bool = false,
        subtypes: Set<AssetMediaSubtype> = [],
        albumIDs: Set<String> = [],
        pixelWidth: Int = 1_290,
        pixelHeight: Int = 2_796,
        burstIdentifier: String? = nil
    ) -> OrganizeAsset {
        var mediaSubtypes = subtypes
        if isScreenshot { mediaSubtypes.insert(.screenshot) }
        return OrganizeAsset(
            asset: PhotoAsset(
                id: id,
                mediaKind: .photo,
                mediaSubtypes: mediaSubtypes,
                creationDate: Date(timeIntervalSince1970: date),
                modificationDate: nil,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                durationMilliseconds: nil,
                location: nil,
                isFavorite: isFavorite,
                isEdited: isEdited,
                resources: [],
                isHidden: isHidden,
                burstIdentifier: burstIdentifier,
                representsBurst: burstIdentifier != nil
            ),
            albumIDs: albumIDs
        )
    }
}
