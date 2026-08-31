import Foundation

enum VisualRecommendationKind: String, CaseIterable, Hashable, Sendable {
    case rapidRetakes
    case similarScreenshots
    case burst
    case utility
    case worthReviewing
    case documentLike
    case noClearSubject
    case smudgedCapture
}

enum VisualRecommendationCaution: String, CaseIterable, Hashable, Sendable {
    case reviewOnly
    case protectedItem
    case mayContainImportantInformation
    case containsBarcode
}

enum VisualRecommendationEvidence: Hashable, Sendable {
    case featurePrintDistance(
        assetID: String,
        relatedAssetID: String,
        distance: Float,
        threshold: Float
    )
    case captureTimeDelta(
        assetID: String,
        relatedAssetID: String,
        seconds: TimeInterval,
        window: TimeInterval
    )
    case sharedBurstIdentifier(String)
    case protectedItem(assetID: String)
    case protectedAlbum(assetID: String, albumIDs: [String])
    case favorite(assetID: String)
    case hidden(assetID: String)
    case edited(assetID: String)
    case raw(assetID: String)
    case livePhoto(assetID: String)
    case albumMembershipCount(assetID: String, count: Int)
    case resolution(assetID: String, pixelCount: Int64)
    case aestheticScore(assetID: String, score: Float)
    case faceCaptureQuality(assetID: String, score: Float)
    case utilityClassification(assetID: String)
    case recognizedText(assetID: String, observationCount: Int, normalizedCoverage: Double)
    case barcodeDetected(assetID: String)
    case noClearSubject(assetID: String)
    case lensSmudgeConfidence(assetID: String, confidence: Float)
    case stableIdentifierTieBreak(assetID: String)
}

struct VisualSimilarityGroup: Identifiable, Hashable, Sendable {
    let id: String
    let kind: VisualRecommendationKind
    let assetIDs: [String]
    let recommendedKeeperID: String
    let evidence: [VisualRecommendationEvidence]
    let keeperEvidence: [VisualRecommendationEvidence]
    let cautions: Set<VisualRecommendationCaution>

    var isReviewOnly: Bool { cautions.contains(.reviewOnly) }
}

struct VisualAssetRecommendation: Identifiable, Hashable, Sendable {
    let id: String
    let kind: VisualRecommendationKind
    let assetID: String
    let evidence: [VisualRecommendationEvidence]
    let cautions: Set<VisualRecommendationCaution>

    var isReviewOnly: Bool { cautions.contains(.reviewOnly) }
}

struct VisualRecommendationDiagnostics: Equatable, Sendable {
    var rapidCandidatePairCount = 0
    var screenshotCandidatePairCount = 0
    var featurePrintDistanceComparisonCount = 0
    var missingFeaturePrintPairCount = 0
    var incompatibleFeaturePrintPairCount = 0
    var invalidFeaturePrintDistancePairCount = 0

    var candidatePairCount: Int {
        rapidCandidatePairCount + screenshotCandidatePairCount
    }
}

struct VisualRecommendationResult: Equatable, Sendable {
    let groups: [VisualSimilarityGroup]
    let candidates: [VisualAssetRecommendation]
    let diagnostics: VisualRecommendationDiagnostics
}

struct VisualRecommendationConfiguration: Equatable, Sendable {
    var rapidRetakeWindow: TimeInterval
    var rapidRetakeDistanceThreshold: Float
    var maximumRapidCandidatesPerAsset: Int
    var screenshotDistanceThreshold: Float
    var maximumScreenshotCandidatesPerAsset: Int
    var screenshotDimensionBucketSize: Int
    var screenshotAspectRatioBucketCount: Int
    var worthReviewingAestheticThreshold: Float
    var minimumDocumentTextObservationCount: Int
    var minimumDocumentTextCoverage: Double
    var minimumLensSmudgeConfidence: Float

    init(
        rapidRetakeWindow: TimeInterval = 15,
        rapidRetakeDistanceThreshold: Float = 10,
        maximumRapidCandidatesPerAsset: Int = 24,
        screenshotDistanceThreshold: Float = 6,
        maximumScreenshotCandidatesPerAsset: Int = 24,
        screenshotDimensionBucketSize: Int = 256,
        screenshotAspectRatioBucketCount: Int = 24,
        worthReviewingAestheticThreshold: Float = -0.55,
        minimumDocumentTextObservationCount: Int = 3,
        minimumDocumentTextCoverage: Double = 0.18,
        minimumLensSmudgeConfidence: Float = 0.5
    ) {
        precondition(rapidRetakeWindow >= 0 && rapidRetakeWindow.isFinite)
        precondition(rapidRetakeDistanceThreshold >= 0 && rapidRetakeDistanceThreshold.isFinite)
        precondition(maximumRapidCandidatesPerAsset >= 0)
        precondition(screenshotDistanceThreshold >= 0 && screenshotDistanceThreshold.isFinite)
        precondition(maximumScreenshotCandidatesPerAsset >= 0)
        precondition(screenshotDimensionBucketSize > 0)
        precondition(screenshotAspectRatioBucketCount > 0)
        precondition(worthReviewingAestheticThreshold.isFinite)
        precondition(minimumDocumentTextObservationCount >= 0)
        precondition(minimumDocumentTextCoverage >= 0 && minimumDocumentTextCoverage <= 1)
        precondition(
            minimumLensSmudgeConfidence.isFinite
                && (0 ... 1).contains(minimumLensSmudgeConfidence)
        )
        self.rapidRetakeWindow = rapidRetakeWindow
        self.rapidRetakeDistanceThreshold = rapidRetakeDistanceThreshold
        self.maximumRapidCandidatesPerAsset = maximumRapidCandidatesPerAsset
        self.screenshotDistanceThreshold = screenshotDistanceThreshold
        self.maximumScreenshotCandidatesPerAsset = maximumScreenshotCandidatesPerAsset
        self.screenshotDimensionBucketSize = screenshotDimensionBucketSize
        self.screenshotAspectRatioBucketCount = screenshotAspectRatioBucketCount
        self.worthReviewingAestheticThreshold = worthReviewingAestheticThreshold
        self.minimumDocumentTextObservationCount = minimumDocumentTextObservationCount
        self.minimumDocumentTextCoverage = minimumDocumentTextCoverage
        self.minimumLensSmudgeConfidence = minimumLensSmudgeConfidence
    }
}

typealias VisualFeaturePrintDistance = @Sendable (
    _ lhs: ArchivedVisualFeaturePrint,
    _ rhs: ArchivedVisualFeaturePrint
) -> Float?

enum VisualRecommendationEngine {
    static func recommendations(
        assets: [OrganizeAsset],
        analysisByAssetID: [String: VisualAnalysisRecord],
        protectedAssetIDs: Set<String> = [],
        protectedAlbumIDs: Set<String> = [],
        configuration: VisualRecommendationConfiguration = VisualRecommendationConfiguration(),
        featurePrintDistance: VisualFeaturePrintDistance = { $0.distance(to: $1) }
    ) -> VisualRecommendationResult {
        let orderedAssets = assets.sorted { OrganizeText.lessThan($0.id, $1.id) }
        let assetByID = Dictionary(uniqueKeysWithValues: orderedAssets.map { ($0.id, $0) })
        let validAnalysisByAssetID = Dictionary(
            uniqueKeysWithValues: orderedAssets.compactMap { item -> (String, VisualAnalysisRecord)? in
                guard let record = analysisByAssetID[item.id], record.isValid(for: item.asset) else {
                    return nil
                }
                return (item.id, record)
            }
        )

        var diagnostics = VisualRecommendationDiagnostics()
        let bursts = burstGroups(
            assets: orderedAssets,
            assetByID: assetByID,
            analysisByAssetID: validAnalysisByAssetID,
            protectedAssetIDs: protectedAssetIDs,
            protectedAlbumIDs: protectedAlbumIDs
        )
        let burstAssetIDs = Set(bursts.flatMap(\.assetIDs))
        let rapid = rapidRetakeGroups(
            assets: orderedAssets.filter { !burstAssetIDs.contains($0.id) },
            assetByID: assetByID,
            analysisByAssetID: validAnalysisByAssetID,
            protectedAssetIDs: protectedAssetIDs,
            protectedAlbumIDs: protectedAlbumIDs,
            configuration: configuration,
            featurePrintDistance: featurePrintDistance,
            diagnostics: &diagnostics
        )
        let screenshots = similarScreenshotGroups(
            assets: orderedAssets,
            assetByID: assetByID,
            analysisByAssetID: validAnalysisByAssetID,
            protectedAssetIDs: protectedAssetIDs,
            protectedAlbumIDs: protectedAlbumIDs,
            configuration: configuration,
            featurePrintDistance: featurePrintDistance,
            diagnostics: &diagnostics
        )
        let candidates = individualCandidates(
            assets: orderedAssets,
            analysisByAssetID: validAnalysisByAssetID,
            protectedAssetIDs: protectedAssetIDs,
            protectedAlbumIDs: protectedAlbumIDs,
            configuration: configuration
        )

        return VisualRecommendationResult(
            groups: (rapid + screenshots + bursts).sorted(by: groupOrder),
            candidates: candidates.sorted(by: candidateOrder),
            diagnostics: diagnostics
        )
    }

    private static func rapidRetakeGroups(
        assets: [OrganizeAsset],
        assetByID: [String: OrganizeAsset],
        analysisByAssetID: [String: VisualAnalysisRecord],
        protectedAssetIDs: Set<String>,
        protectedAlbumIDs: Set<String>,
        configuration: VisualRecommendationConfiguration,
        featurePrintDistance: VisualFeaturePrintDistance,
        diagnostics: inout VisualRecommendationDiagnostics
    ) -> [VisualSimilarityGroup] {
        let candidates = assets.filter {
            $0.asset.mediaKind == .photo
                && !$0.asset.mediaSubtypes.contains(.screenshot)
                && $0.asset.creationDate != nil
        }.sorted(by: captureDateOrder)
        var union = VisualAssetUnionFind(ids: candidates.map(\.id))
        var matches: [VisualSimilarityMatch] = []

        for leftIndex in candidates.indices {
            let left = candidates[leftIndex]
            guard let leftDate = left.asset.creationDate else { continue }
            let upperBound = min(
                candidates.count,
                leftIndex + 1 + configuration.maximumRapidCandidatesPerAsset
            )
            guard leftIndex + 1 < upperBound else { continue }
            for rightIndex in (leftIndex + 1)..<upperBound {
                let right = candidates[rightIndex]
                guard let rightDate = right.asset.creationDate else { continue }
                let delta = rightDate.timeIntervalSince(leftDate)
                if delta > configuration.rapidRetakeWindow { break }
                diagnostics.rapidCandidatePairCount += 1
                guard let distance = compatibleDistance(
                    lhs: analysisByAssetID[left.id]?.featurePrint,
                    rhs: analysisByAssetID[right.id]?.featurePrint,
                    featurePrintDistance: featurePrintDistance,
                    diagnostics: &diagnostics
                ), distance <= configuration.rapidRetakeDistanceThreshold else {
                    continue
                }
                union.join(left.id, right.id)
                matches.append(
                    VisualSimilarityMatch(
                        lhsID: left.id,
                        rhsID: right.id,
                        distance: distance,
                        threshold: configuration.rapidRetakeDistanceThreshold,
                        captureTimeDelta: delta,
                        captureTimeWindow: configuration.rapidRetakeWindow
                    )
                )
            }
        }

        return similarityGroups(
            kind: .rapidRetakes,
            union: union,
            matches: matches,
            assetByID: assetByID,
            analysisByAssetID: analysisByAssetID,
            protectedAssetIDs: protectedAssetIDs,
            protectedAlbumIDs: protectedAlbumIDs
        )
    }

    private static func similarScreenshotGroups(
        assets: [OrganizeAsset],
        assetByID: [String: OrganizeAsset],
        analysisByAssetID: [String: VisualAnalysisRecord],
        protectedAssetIDs: Set<String>,
        protectedAlbumIDs: Set<String>,
        configuration: VisualRecommendationConfiguration,
        featurePrintDistance: VisualFeaturePrintDistance,
        diagnostics: inout VisualRecommendationDiagnostics
    ) -> [VisualSimilarityGroup] {
        let screenshots = assets.filter { $0.asset.mediaSubtypes.contains(.screenshot) }
        let buckets = Dictionary(grouping: screenshots) {
            screenshotBucket(
                for: $0,
                featurePrint: analysisByAssetID[$0.id]?.featurePrint,
                configuration: configuration
            )
        }
        var union = VisualAssetUnionFind(ids: screenshots.map(\.id))
        var matches: [VisualSimilarityMatch] = []

        for key in buckets.keys.sorted() {
            let bucket = (buckets[key] ?? []).sorted(by: captureDateOrder)
            for leftIndex in bucket.indices {
                let left = bucket[leftIndex]
                let upperBound = min(
                    bucket.count,
                    leftIndex + 1 + configuration.maximumScreenshotCandidatesPerAsset
                )
                guard leftIndex + 1 < upperBound else { continue }
                for rightIndex in (leftIndex + 1)..<upperBound {
                    let right = bucket[rightIndex]
                    diagnostics.screenshotCandidatePairCount += 1
                    guard let distance = compatibleDistance(
                        lhs: analysisByAssetID[left.id]?.featurePrint,
                        rhs: analysisByAssetID[right.id]?.featurePrint,
                        featurePrintDistance: featurePrintDistance,
                        diagnostics: &diagnostics
                    ), distance <= configuration.screenshotDistanceThreshold else {
                        continue
                    }
                    union.join(left.id, right.id)
                    matches.append(
                        VisualSimilarityMatch(
                            lhsID: left.id,
                            rhsID: right.id,
                            distance: distance,
                            threshold: configuration.screenshotDistanceThreshold,
                            captureTimeDelta: nil,
                            captureTimeWindow: nil
                        )
                    )
                }
            }
        }

        return similarityGroups(
            kind: .similarScreenshots,
            union: union,
            matches: matches,
            assetByID: assetByID,
            analysisByAssetID: analysisByAssetID,
            protectedAssetIDs: protectedAssetIDs,
            protectedAlbumIDs: protectedAlbumIDs
        )
    }

    private static func burstGroups(
        assets: [OrganizeAsset],
        assetByID: [String: OrganizeAsset],
        analysisByAssetID: [String: VisualAnalysisRecord],
        protectedAssetIDs: Set<String>,
        protectedAlbumIDs: Set<String>
    ) -> [VisualSimilarityGroup] {
        let grouped = Dictionary(grouping: assets.compactMap { item in
            item.asset.burstIdentifier.map { ($0, item) }
        }, by: { $0.0 })
        return grouped.compactMap { identifier, entries -> VisualSimilarityGroup? in
            let ids = entries.map(\.1.id).sorted(by: OrganizeText.lessThan)
            guard ids.count > 1 else { return nil }
            let keeper = recommendedKeeper(
                assetIDs: ids,
                assetByID: assetByID,
                analysisByAssetID: analysisByAssetID,
                protectedAssetIDs: protectedAssetIDs,
                protectedAlbumIDs: protectedAlbumIDs
            )
            return VisualSimilarityGroup(
                id: groupID(kind: .burst, assetIDs: ids),
                kind: .burst,
                assetIDs: ids,
                recommendedKeeperID: keeper.id,
                evidence: [.sharedBurstIdentifier(identifier)],
                keeperEvidence: keeper.evidence,
                cautions: groupCautions(
                    assetIDs: ids,
                    assetByID: assetByID,
                    analysisByAssetID: analysisByAssetID,
                    protectedAssetIDs: protectedAssetIDs,
                    protectedAlbumIDs: protectedAlbumIDs
                )
            )
        }
        .sorted(by: groupOrder)
    }

    private static func similarityGroups(
        kind: VisualRecommendationKind,
        union: VisualAssetUnionFind,
        matches: [VisualSimilarityMatch],
        assetByID: [String: OrganizeAsset],
        analysisByAssetID: [String: VisualAnalysisRecord],
        protectedAssetIDs: Set<String>,
        protectedAlbumIDs: Set<String>
    ) -> [VisualSimilarityGroup] {
        let matchesByRepresentative = Dictionary(grouping: matches) {
            union.representative(for: $0.lhsID)
        }
        return union.components().compactMap { ids -> VisualSimilarityGroup? in
            guard ids.count > 1 else { return nil }
            guard let firstID = ids.first else { return nil }
            let componentMatches = matchesByRepresentative[union.representative(for: firstID)] ?? []
            guard !componentMatches.isEmpty else { return nil }
            let evidence = componentMatches.flatMap(\.evidence)
            let keeper = recommendedKeeper(
                assetIDs: ids,
                assetByID: assetByID,
                analysisByAssetID: analysisByAssetID,
                protectedAssetIDs: protectedAssetIDs,
                protectedAlbumIDs: protectedAlbumIDs
            )
            return VisualSimilarityGroup(
                id: groupID(kind: kind, assetIDs: ids),
                kind: kind,
                assetIDs: ids,
                recommendedKeeperID: keeper.id,
                evidence: evidence,
                keeperEvidence: keeper.evidence,
                cautions: groupCautions(
                    assetIDs: ids,
                    assetByID: assetByID,
                    analysisByAssetID: analysisByAssetID,
                    protectedAssetIDs: protectedAssetIDs,
                    protectedAlbumIDs: protectedAlbumIDs
                )
            )
        }
        .sorted(by: groupOrder)
    }

    private static func individualCandidates(
        assets: [OrganizeAsset],
        analysisByAssetID: [String: VisualAnalysisRecord],
        protectedAssetIDs: Set<String>,
        protectedAlbumIDs: Set<String>,
        configuration: VisualRecommendationConfiguration
    ) -> [VisualAssetRecommendation] {
        var recommendations: [VisualAssetRecommendation] = []
        for item in assets {
            guard let analysis = analysisByAssetID[item.id] else { continue }
            let protected = isProtected(
                item,
                protectedAssetIDs: protectedAssetIDs,
                protectedAlbumIDs: protectedAlbumIDs
            )
            var baseCautions: Set<VisualRecommendationCaution> = [.reviewOnly]
            if protected { baseCautions.insert(.protectedItem) }

            if let aesthetics = analysis.aesthetics {
                if aesthetics.isUtility {
                    recommendations.append(
                        VisualAssetRecommendation(
                            id: candidateID(kind: .utility, assetID: item.id),
                            kind: .utility,
                            assetID: item.id,
                            evidence: [
                                .utilityClassification(assetID: item.id),
                                .aestheticScore(assetID: item.id, score: aesthetics.overallScore)
                            ],
                            cautions: baseCautions.union([.mayContainImportantInformation])
                        )
                    )
                }
                if aesthetics.overallScore.isFinite,
                   aesthetics.overallScore <= configuration.worthReviewingAestheticThreshold {
                    recommendations.append(
                        VisualAssetRecommendation(
                            id: candidateID(kind: .worthReviewing, assetID: item.id),
                            kind: .worthReviewing,
                            assetID: item.id,
                            evidence: [
                                .aestheticScore(assetID: item.id, score: aesthetics.overallScore)
                            ],
                            cautions: baseCautions
                        )
                    )
                }
            }

            let isTextHeavy = analysis.text.observationCount
                >= configuration.minimumDocumentTextObservationCount
                && analysis.text.normalizedCoverage >= configuration.minimumDocumentTextCoverage
            if isTextHeavy || analysis.containsBarcode {
                var evidence: [VisualRecommendationEvidence] = []
                var cautions = baseCautions.union([.mayContainImportantInformation])
                if isTextHeavy {
                    evidence.append(
                        .recognizedText(
                            assetID: item.id,
                            observationCount: analysis.text.observationCount,
                            normalizedCoverage: analysis.text.normalizedCoverage
                        )
                    )
                }
                if analysis.containsBarcode {
                    evidence.append(.barcodeDetected(assetID: item.id))
                    cautions.insert(.containsBarcode)
                }
                recommendations.append(
                    VisualAssetRecommendation(
                        id: candidateID(kind: .documentLike, assetID: item.id),
                        kind: .documentLike,
                        assetID: item.id,
                        evidence: evidence,
                        cautions: cautions
                    )
                )
            }

            if analysis.saliency?.noClearSubject == true {
                recommendations.append(
                    VisualAssetRecommendation(
                        id: candidateID(kind: .noClearSubject, assetID: item.id),
                        kind: .noClearSubject,
                        assetID: item.id,
                        evidence: [.noClearSubject(assetID: item.id)],
                        cautions: baseCautions
                    )
                )
            }

            if let smudge = analysis.lensSmudge,
               smudge.confidence >= configuration.minimumLensSmudgeConfidence {
                recommendations.append(
                    VisualAssetRecommendation(
                        id: candidateID(kind: .smudgedCapture, assetID: item.id),
                        kind: .smudgedCapture,
                        assetID: item.id,
                        evidence: [
                            .lensSmudgeConfidence(
                                assetID: item.id,
                                confidence: smudge.confidence
                            )
                        ],
                        cautions: baseCautions
                    )
                )
            }
        }
        return recommendations
    }

    private static func compatibleDistance(
        lhs: ArchivedVisualFeaturePrint?,
        rhs: ArchivedVisualFeaturePrint?,
        featurePrintDistance: VisualFeaturePrintDistance,
        diagnostics: inout VisualRecommendationDiagnostics
    ) -> Float? {
        guard let lhs, let rhs else {
            diagnostics.missingFeaturePrintPairCount += 1
            return nil
        }
        guard lhs.requestRevision == rhs.requestRevision,
              lhs.elementCount == rhs.elementCount,
              lhs.elementTypeRawValue == rhs.elementTypeRawValue else {
            diagnostics.incompatibleFeaturePrintPairCount += 1
            return nil
        }
        diagnostics.featurePrintDistanceComparisonCount += 1
        guard let distance = featurePrintDistance(lhs, rhs), distance.isFinite, distance >= 0 else {
            diagnostics.invalidFeaturePrintDistancePairCount += 1
            return nil
        }
        return distance
    }

    private static func recommendedKeeper(
        assetIDs: [String],
        assetByID: [String: OrganizeAsset],
        analysisByAssetID: [String: VisualAnalysisRecord],
        protectedAssetIDs: Set<String>,
        protectedAlbumIDs: Set<String>
    ) -> (id: String, evidence: [VisualRecommendationEvidence]) {
        let candidates = assetIDs.compactMap { id -> VisualKeeperCandidate? in
            guard let item = assetByID[id] else { return nil }
            let analysis = analysisByAssetID[id]
            return VisualKeeperCandidate(
                item: item,
                analysis: analysis,
                isProtected: isProtected(
                    item,
                    protectedAssetIDs: protectedAssetIDs,
                    protectedAlbumIDs: protectedAlbumIDs
                )
            )
        }
        guard let winner = candidates.sorted(by: keeperOrder).first else {
            let fallback = assetIDs.sorted(by: OrganizeText.lessThan).first ?? ""
            return (fallback, [.stableIdentifierTieBreak(assetID: fallback)])
        }

        var evidence: [VisualRecommendationEvidence] = []
        let item = winner.item
        let protectedAlbums = item.albumIDs.intersection(protectedAlbumIDs).sorted(by: OrganizeText.lessThan)
        if protectedAssetIDs.contains(item.id) {
            evidence.append(.protectedItem(assetID: item.id))
        }
        if !protectedAlbums.isEmpty {
            evidence.append(.protectedAlbum(assetID: item.id, albumIDs: protectedAlbums))
        }
        if item.asset.isFavorite { evidence.append(.favorite(assetID: item.id)) }
        if item.asset.isHidden { evidence.append(.hidden(assetID: item.id)) }
        if item.asset.isEdited { evidence.append(.edited(assetID: item.id)) }
        if item.asset.mediaSubtypes.contains(.raw) { evidence.append(.raw(assetID: item.id)) }
        if item.asset.mediaSubtypes.contains(.livePhoto) { evidence.append(.livePhoto(assetID: item.id)) }
        evidence.append(.albumMembershipCount(assetID: item.id, count: item.albumIDs.count))
        evidence.append(.resolution(assetID: item.id, pixelCount: item.pixelCount))
        if let score = winner.aestheticScore {
            evidence.append(.aestheticScore(assetID: item.id, score: score))
        }
        if let quality = winner.faceQuality {
            evidence.append(.faceCaptureQuality(assetID: item.id, score: quality))
        }
        if candidates.allSatisfy({ $0.rankingValuesEqual(to: winner) }) {
            evidence.append(.stableIdentifierTieBreak(assetID: item.id))
        }
        return (item.id, evidence)
    }

    private static func keeperOrder(_ lhs: VisualKeeperCandidate, _ rhs: VisualKeeperCandidate) -> Bool {
        if lhs.isProtected != rhs.isProtected { return lhs.isProtected }
        if lhs.item.asset.isFavorite != rhs.item.asset.isFavorite { return lhs.item.asset.isFavorite }
        if lhs.item.asset.isHidden != rhs.item.asset.isHidden { return lhs.item.asset.isHidden }
        if lhs.item.asset.isEdited != rhs.item.asset.isEdited { return lhs.item.asset.isEdited }
        if lhs.isRAW != rhs.isRAW { return lhs.isRAW }
        if lhs.isLivePhoto != rhs.isLivePhoto { return lhs.isLivePhoto }
        if lhs.item.albumIDs.count != rhs.item.albumIDs.count {
            return lhs.item.albumIDs.count > rhs.item.albumIDs.count
        }
        if lhs.item.pixelCount != rhs.item.pixelCount { return lhs.item.pixelCount > rhs.item.pixelCount }
        if lhs.aestheticScore != rhs.aestheticScore {
            return optionalScorePrecedes(lhs.aestheticScore, rhs.aestheticScore)
        }
        if lhs.faceQuality != rhs.faceQuality {
            return optionalScorePrecedes(lhs.faceQuality, rhs.faceQuality)
        }
        return OrganizeText.lessThan(lhs.item.id, rhs.item.id)
    }

    private static func optionalScorePrecedes(_ lhs: Float?, _ rhs: Float?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?): left > right
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): false
        }
    }

    private static func isProtected(
        _ item: OrganizeAsset,
        protectedAssetIDs: Set<String>,
        protectedAlbumIDs: Set<String>
    ) -> Bool {
        protectedAssetIDs.contains(item.id)
            || item.asset.isFavorite
            || item.asset.isHidden
            || !item.albumIDs.isDisjoint(with: protectedAlbumIDs)
    }

    private static func groupCautions(
        assetIDs: [String],
        assetByID: [String: OrganizeAsset],
        analysisByAssetID: [String: VisualAnalysisRecord],
        protectedAssetIDs: Set<String>,
        protectedAlbumIDs: Set<String>
    ) -> Set<VisualRecommendationCaution> {
        var cautions: Set<VisualRecommendationCaution> = [.reviewOnly]
        if assetIDs.contains(where: { id in
            assetByID[id].map {
                isProtected(
                    $0,
                    protectedAssetIDs: protectedAssetIDs,
                    protectedAlbumIDs: protectedAlbumIDs
                )
            } ?? false
        }) {
            cautions.insert(.protectedItem)
        }
        if assetIDs.contains(where: { id in
            guard let analysis = analysisByAssetID[id] else { return false }
            return analysis.containsBarcode
                || analysis.text.observationCount > 0
                || analysis.text.normalizedCoverage > 0
        }) {
            cautions.insert(.mayContainImportantInformation)
        }
        if assetIDs.contains(where: { analysisByAssetID[$0]?.containsBarcode == true }) {
            cautions.insert(.containsBarcode)
        }
        return cautions
    }

    private static func screenshotBucket(
        for item: OrganizeAsset,
        featurePrint: ArchivedVisualFeaturePrint?,
        configuration: VisualRecommendationConfiguration
    ) -> VisualScreenshotBucket {
        let width = max(item.asset.pixelWidth, 1)
        let height = max(item.asset.pixelHeight, 1)
        let shortEdge = min(width, height)
        let longEdge = max(width, height)
        let orientation = width == height ? 0 : (width < height ? 1 : 2)
        let aspectRatio = Double(shortEdge) / Double(longEdge)
        return VisualScreenshotBucket(
            orientation: orientation,
            aspectRatioBucket: Int(
                (aspectRatio * Double(configuration.screenshotAspectRatioBucketCount)).rounded()
            ),
            longEdgeBucket: longEdge / configuration.screenshotDimensionBucketSize,
            featureRevision: featurePrint?.requestRevision,
            featureElementCount: featurePrint?.elementCount,
            featureElementType: featurePrint?.elementTypeRawValue
        )
    }

    private static func captureDateOrder(_ lhs: OrganizeAsset, _ rhs: OrganizeAsset) -> Bool {
        switch (lhs.asset.creationDate, rhs.asset.creationDate) {
        case let (left?, right?) where left != right: left < right
        case (_?, nil): true
        case (nil, _?): false
        default: OrganizeText.lessThan(lhs.id, rhs.id)
        }
    }

    private static func groupOrder(_ lhs: VisualSimilarityGroup, _ rhs: VisualSimilarityGroup) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return OrganizeText.lessThan(lhs.kind.rawValue, rhs.kind.rawValue)
        }
        return OrganizeText.lessThan(lhs.id, rhs.id)
    }

    private static func candidateOrder(
        _ lhs: VisualAssetRecommendation,
        _ rhs: VisualAssetRecommendation
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return OrganizeText.lessThan(lhs.kind.rawValue, rhs.kind.rawValue)
        }
        return OrganizeText.lessThan(lhs.assetID, rhs.assetID)
    }

    private static func groupID(kind: VisualRecommendationKind, assetIDs: [String]) -> String {
        "\(kind.rawValue):\(assetIDs.sorted(by: OrganizeText.lessThan).joined(separator: "|"))"
    }

    private static func candidateID(kind: VisualRecommendationKind, assetID: String) -> String {
        "\(kind.rawValue):\(assetID)"
    }
}

private struct VisualSimilarityMatch: Sendable {
    let lhsID: String
    let rhsID: String
    let distance: Float
    let threshold: Float
    let captureTimeDelta: TimeInterval?
    let captureTimeWindow: TimeInterval?

    var evidence: [VisualRecommendationEvidence] {
        var result: [VisualRecommendationEvidence] = [
            .featurePrintDistance(
                assetID: lhsID,
                relatedAssetID: rhsID,
                distance: distance,
                threshold: threshold
            )
        ]
        if let captureTimeDelta, let captureTimeWindow {
            result.append(
                .captureTimeDelta(
                    assetID: lhsID,
                    relatedAssetID: rhsID,
                    seconds: captureTimeDelta,
                    window: captureTimeWindow
                )
            )
        }
        return result
    }
}

private struct VisualKeeperCandidate: Sendable {
    let item: OrganizeAsset
    let analysis: VisualAnalysisRecord?
    let isProtected: Bool

    var isRAW: Bool { item.asset.mediaSubtypes.contains(.raw) }
    var isLivePhoto: Bool { item.asset.mediaSubtypes.contains(.livePhoto) }
    var aestheticScore: Float? {
        analysis?.aesthetics?.overallScore.finiteValue
    }
    var faceQuality: Float? {
        analysis?.faces.bestCaptureQuality?.finiteValue
    }

    func rankingValuesEqual(to other: VisualKeeperCandidate) -> Bool {
        isProtected == other.isProtected
            && item.asset.isFavorite == other.item.asset.isFavorite
            && item.asset.isHidden == other.item.asset.isHidden
            && item.asset.isEdited == other.item.asset.isEdited
            && isRAW == other.isRAW
            && isLivePhoto == other.isLivePhoto
            && item.albumIDs.count == other.item.albumIDs.count
            && item.pixelCount == other.item.pixelCount
            && aestheticScore == other.aestheticScore
            && faceQuality == other.faceQuality
    }
}

private struct VisualScreenshotBucket: Hashable, Comparable, Sendable {
    let orientation: Int
    let aspectRatioBucket: Int
    let longEdgeBucket: Int
    let featureRevision: Int?
    let featureElementCount: Int?
    let featureElementType: UInt?

    static func < (lhs: VisualScreenshotBucket, rhs: VisualScreenshotBucket) -> Bool {
        let left = lhs.sortKey
        let right = rhs.sortKey
        return left.lexicographicallyPrecedes(right)
    }

    private var sortKey: [UInt64] {
        [
            UInt64(orientation),
            UInt64(aspectRatioBucket),
            UInt64(longEdgeBucket),
            featureRevision.map { UInt64($0) &+ 1 } ?? 0,
            featureElementCount.map { UInt64($0) &+ 1 } ?? 0,
            featureElementType.map { UInt64($0) &+ 1 } ?? 0
        ]
    }
}

private struct VisualAssetUnionFind: Sendable {
    private var parentByID: [String: String]

    init(ids: [String]) {
        parentByID = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
    }

    mutating func join(_ lhs: String, _ rhs: String) {
        let leftRoot = root(of: lhs)
        let rightRoot = root(of: rhs)
        guard leftRoot != rightRoot else { return }
        let first = OrganizeText.lessThan(leftRoot, rightRoot) ? leftRoot : rightRoot
        let second = first == leftRoot ? rightRoot : leftRoot
        parentByID[second] = first
    }

    func components() -> [[String]] {
        var grouped: [String: [String]] = [:]
        for id in parentByID.keys {
            grouped[readOnlyRoot(of: id), default: []].append(id)
        }
        return grouped.values.map { $0.sorted(by: OrganizeText.lessThan) }
            .sorted { lhs, rhs in
                guard let left = lhs.first, let right = rhs.first else { return lhs.count < rhs.count }
                return OrganizeText.lessThan(left, right)
            }
    }

    func representative(for id: String) -> String {
        readOnlyRoot(of: id)
    }

    private mutating func root(of id: String) -> String {
        guard let parent = parentByID[id], parent != id else { return id }
        let result = root(of: parent)
        parentByID[id] = result
        return result
    }

    private func readOnlyRoot(of id: String) -> String {
        var current = id
        while let parent = parentByID[current], parent != current {
            current = parent
        }
        return current
    }
}

private extension Float {
    var finiteValue: Float? { isFinite ? self : nil }
}
