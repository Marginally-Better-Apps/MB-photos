import Foundation

enum OrganizeEngine {
    static let defaultLargeVideoThreshold = OrganizeRecommendationDefaults.largeVideoMinimumKnownByteCount

    static func metrics(
        assets: [OrganizeAsset],
        analysisByAssetID: [String: AssetAnalysisRecord]
    ) -> OrganizeLibraryMetrics {
        let analyzed = assets.filter { knownByteCount(for: $0, analysisByAssetID: analysisByAssetID) != nil }
        let knownTotal = analyzed.reduce(into: Int64(0)) { total, item in
            addSaturating(knownByteCount(for: item, analysisByAssetID: analysisByAssetID) ?? 0, to: &total)
        }

        func bucket(_ kind: OrganizeBreakdownKind, matching predicate: (OrganizeAsset) -> Bool) -> OrganizeMetricBucket {
            let matches = assets.filter(predicate)
            let bytes = matches.reduce(into: Int64(0)) { total, item in
                addSaturating(knownByteCount(for: item, analysisByAssetID: analysisByAssetID) ?? 0, to: &total)
            }
            return OrganizeMetricBucket(kind: kind, itemCount: matches.count, knownByteCount: bytes)
        }

        return OrganizeLibraryMetrics(
            accessibleItemCount: assets.count,
            knownMediaByteCount: knownTotal,
            analyzedItemCount: analyzed.count,
            buckets: [
                bucket(.regularPhotos) {
                    $0.asset.mediaKind == .photo && !$0.asset.mediaSubtypes.contains(.screenshot)
                },
                bucket(.screenshots) { $0.asset.mediaSubtypes.contains(.screenshot) },
                bucket(.videos) { $0.asset.mediaKind == .video },
                bucket(.livePhotos) { $0.asset.mediaSubtypes.contains(.livePhoto) },
                bucket(.raw) { $0.asset.mediaSubtypes.contains(.raw) },
                bucket(.favorites) { $0.asset.isFavorite },
                bucket(.edited) { $0.asset.isEdited },
                bucket(.noAlbum) { $0.albumIDs.isEmpty }
            ]
        )
    }

    static func filtered(
        _ assets: [OrganizeAsset],
        by filter: OrganizeFilter,
        analysisByAssetID: [String: AssetAnalysisRecord],
        reviewStateByAssetID: [String: AssetReviewState]
    ) -> [OrganizeAsset] {
        assets.filter { item in
            if !filter.mediaKinds.isEmpty, !filter.mediaKinds.contains(item.asset.mediaKind) { return false }
            if !filter.mediaSubtypes.isEmpty,
               filter.mediaSubtypes.isDisjoint(with: item.asset.mediaSubtypes) { return false }

            if let start = filter.captureDateStart {
                guard let date = item.asset.creationDate, date >= start else { return false }
            }
            if let end = filter.captureDateEnd {
                guard let date = item.asset.creationDate, date <= end else { return false }
            }

            if !filter.formats.isEmpty {
                let requested = Set(filter.formats.map(normalizedFormat))
                let available = Set(item.asset.resources.flatMap { resource -> [String] in
                    var values: [String] = []
                    if let identifier = resource.uniformTypeIdentifier {
                        values.append(normalizedFormat(identifier))
                    }
                    let fileExtension = (resource.originalFilename as NSString).pathExtension
                    if !fileExtension.isEmpty { values.append(normalizedFormat(fileExtension)) }
                    return values
                })
                if requested.isDisjoint(with: available) { return false }
            }

            let knownBytes = knownByteCount(for: item, analysisByAssetID: analysisByAssetID)
            if let minimum = filter.minimumKnownByteCount {
                guard let knownBytes, knownBytes >= minimum else { return false }
            }
            if let maximum = filter.maximumKnownByteCount {
                guard let knownBytes, knownBytes <= maximum else { return false }
            }
            if let minimum = filter.minimumPixelCount, item.pixelCount < minimum { return false }
            if let maximum = filter.maximumPixelCount, item.pixelCount > maximum { return false }

            if !filter.orientations.isEmpty,
               !filter.orientations.contains(orientation(of: item.asset)) { return false }

            if let minimum = filter.minimumDurationMilliseconds {
                guard let duration = item.asset.durationMilliseconds, duration >= minimum else { return false }
            }
            if let maximum = filter.maximumDurationMilliseconds {
                guard let duration = item.asset.durationMilliseconds, duration <= maximum else { return false }
            }
            if let expected = filter.isFavorite, item.asset.isFavorite != expected { return false }
            if let expected = filter.isEdited, item.asset.isEdited != expected { return false }
            if let expected = filter.isHidden, item.asset.isHidden != expected { return false }
            if !filter.albumIDs.isEmpty, filter.albumIDs.isDisjoint(with: item.albumIDs) { return false }
            if let expected = filter.hasAlbum, (!item.albumIDs.isEmpty) != expected { return false }
            if let expected = filter.hasLocation, (item.asset.location != nil) != expected { return false }

            let reviewState = reviewStateByAssetID[item.id] ?? .unreviewed
            if !filter.reviewStates.isEmpty, !filter.reviewStates.contains(reviewState) { return false }

            let analysisStatus = validAnalysis(for: item, in: analysisByAssetID)?.status ?? .notAnalyzed
            if !filter.analysisStatuses.isEmpty, !filter.analysisStatuses.contains(analysisStatus) { return false }
            return true
        }
    }

    static func sorted(
        _ assets: [OrganizeAsset],
        by sort: OrganizeSort,
        analysisByAssetID: [String: AssetAnalysisRecord],
        reviewStateByAssetID: [String: AssetReviewState]
    ) -> [OrganizeAsset] {
        assets.sorted { lhs, rhs in
            let comparison: ComparisonResult = switch sort.metric {
            case .captureDate:
                compareOptional(lhs.asset.creationDate, rhs.asset.creationDate, direction: sort.direction)
            case .modificationDate:
                compareOptional(lhs.asset.modificationDate, rhs.asset.modificationDate, direction: sort.direction)
            case .filename:
                compareOptional(
                    lhs.originalFilename,
                    rhs.originalFilename,
                    direction: sort.direction,
                    comparator: compareText
                )
            case .analyzedByteCount:
                compareOptional(
                    knownByteCount(for: lhs, analysisByAssetID: analysisByAssetID),
                    knownByteCount(for: rhs, analysisByAssetID: analysisByAssetID),
                    direction: sort.direction
                )
            case .resolution:
                compare(lhs.pixelCount, rhs.pixelCount, direction: sort.direction)
            case .duration:
                compareOptional(
                    lhs.asset.durationMilliseconds,
                    rhs.asset.durationMilliseconds,
                    direction: sort.direction
                )
            case .albumCount:
                compare(lhs.albumIDs.count, rhs.albumIDs.count, direction: sort.direction)
            case .reviewState:
                compare(
                    reviewRank(reviewStateByAssetID[lhs.id] ?? .unreviewed),
                    reviewRank(reviewStateByAssetID[rhs.id] ?? .unreviewed),
                    direction: sort.direction
                )
            case .dateAdded:
                compareOptional(lhs.asset.addedDate, rhs.asset.addedDate, direction: sort.direction)
            }

            if comparison == .orderedSame { return OrganizeText.lessThan(lhs.id, rhs.id) }
            return comparison == .orderedAscending
        }
    }

    static func duplicateGroups(
        assets: [OrganizeAsset],
        analysisByAssetID: [String: AssetAnalysisRecord],
        protectedAlbumIDs: Set<String>
    ) -> [DuplicateGroup] {
        let grouped = Dictionary(grouping: assets) { item in
            validAnalysis(for: item, in: analysisByAssetID)?.exactDuplicateKey
        }

        return grouped.compactMap { key, members -> DuplicateGroup? in
            guard let key, members.count > 1 else { return nil }
            let ordered = members.sorted { keeperPrecedes($0, $1, protectedAlbumIDs: protectedAlbumIDs) }
            guard let keeper = ordered.first else { return nil }
            let reason = keeperReason(for: keeper, among: members, protectedAlbumIDs: protectedAlbumIDs)
            let totalBytes = members.reduce(into: Int64(0)) { total, item in
                addSaturating(knownByteCount(for: item, analysisByAssetID: analysisByAssetID) ?? 0, to: &total)
            }
            let keeperBytes = knownByteCount(for: keeper, analysisByAssetID: analysisByAssetID) ?? 0
            return DuplicateGroup(
                id: key,
                exactDuplicateKey: key,
                assetIDs: members.map(\.id).sorted(by: OrganizeText.lessThan),
                recommendedKeeperID: keeper.id,
                keeperReason: reason,
                reclaimableKnownByteCount: max(0, totalBytes - keeperBytes)
            )
        }
        .sorted { OrganizeText.lessThan($0.id, $1.id) }
    }

    static func recommendations(
        assets: [OrganizeAsset],
        analysisByAssetID: [String: AssetAnalysisRecord],
        reviewStateByAssetID: [String: AssetReviewState],
        protectedAlbumIDs: Set<String>,
        largeVideoThreshold: Int64 = defaultLargeVideoThreshold,
        referenceDate: Date = Date(),
        oldScreenshotMinimumAge: TimeInterval = OrganizeRecommendationDefaults.oldScreenshotMinimumAge,
        veryShortVideoMaximumDurationMilliseconds: Int = OrganizeRecommendationDefaults.veryShortVideoMaximumDurationMilliseconds,
        tinyImageMaximumPixelCount: Int64 = OrganizeRecommendationDefaults.tinyImageMaximumPixelCount,
        largeSpecialtyThreshold: Int64 = OrganizeRecommendationDefaults.largeSpecialtyMinimumKnownByteCount,
        decideLaterAssetIDs: Set<String> = []
    ) -> [OrganizeRecommendation] {
        let duplicates = duplicateGroups(
            assets: assets,
            analysisByAssetID: analysisByAssetID,
            protectedAlbumIDs: protectedAlbumIDs
        )
        let duplicateAssets = Set(duplicates.flatMap(\.assetIDs))
        let screenshotAssets = assets.filter { $0.asset.mediaSubtypes.contains(.screenshot) }
        let screenRecordingAssets = assets.filter {
            $0.asset.mediaKind == .video && $0.asset.mediaSubtypes.contains(.screenRecording)
        }
        let oldScreenshotCutoff = referenceDate.addingTimeInterval(-oldScreenshotMinimumAge)
        let oldScreenshotAssets = screenshotAssets.filter {
            guard let creationDate = $0.asset.creationDate else { return false }
            return creationDate <= oldScreenshotCutoff
        }
        let veryShortVideoAssets = assets.filter {
            guard $0.asset.mediaKind == .video,
                  let duration = $0.asset.durationMilliseconds else { return false }
            return duration <= veryShortVideoMaximumDurationMilliseconds
        }
        let tinyImageAssets = assets.filter {
            $0.asset.mediaKind == .photo && $0.pixelCount <= tinyImageMaximumPixelCount
        }
        let largeVideoAssets = assets.filter {
            $0.asset.mediaKind == .video &&
                (knownByteCount(for: $0, analysisByAssetID: analysisByAssetID) ?? -1) >= largeVideoThreshold
        }
        let largeSpecialtyAssets = assets.filter {
            !$0.asset.mediaSubtypes.isDisjoint(with: OrganizeRecommendationDefaults.specialtyMediaSubtypes) &&
                (knownByteCount(for: $0, analysisByAssetID: analysisByAssetID) ?? -1) >= largeSpecialtyThreshold
        }
        let burstCounts = Dictionary(grouping: assets.compactMap { item in
            item.asset.burstIdentifier.map { ($0, item) }
        }, by: { $0.0 }).mapValues(\.count)
        let burstAssets = assets.filter { item in
            item.asset.representsBurst || item.asset.burstIdentifier.map { burstCounts[$0, default: 0] > 1 } == true
        }
        let decideLaterAssets = assets.filter { decideLaterAssetIDs.contains($0.id) }
        let noAlbumAssets = assets.filter(\.albumIDs.isEmpty)
        let unreviewedAssets = assets.filter { reviewStateByAssetID[$0.id, default: .unreviewed] == .unreviewed }

        let analysisAvailability = recommendationAvailability(
            assets: assets,
            analysisByAssetID: analysisByAssetID
        )
        return [
            recommendation(
                kind: .exactDuplicates,
                assets: assets.filter { duplicateAssets.contains($0.id) },
                analysisByAssetID: analysisByAssetID,
                availability: analysisAvailability,
                duplicateGroups: duplicates,
                knownByteCountOverride: duplicates.reduce(into: Int64(0)) { total, group in
                    addSaturating(group.reclaimableKnownByteCount, to: &total)
                }
            ),
            recommendation(
                kind: .screenRecordings,
                assets: screenRecordingAssets,
                analysisByAssetID: analysisByAssetID
            ),
            recommendation(
                kind: .oldScreenshots,
                assets: oldScreenshotAssets,
                analysisByAssetID: analysisByAssetID
            ),
            recommendation(kind: .screenshots, assets: screenshotAssets, analysisByAssetID: analysisByAssetID),
            recommendation(
                kind: .veryShortVideos,
                assets: veryShortVideoAssets,
                analysisByAssetID: analysisByAssetID
            ),
            recommendation(
                kind: .tinyImages,
                assets: tinyImageAssets,
                analysisByAssetID: analysisByAssetID
            ),
            recommendation(
                kind: .largeVideos,
                assets: largeVideoAssets,
                analysisByAssetID: analysisByAssetID,
                availability: analysisAvailability
            ),
            recommendation(
                kind: .largeSpecialtyMedia,
                assets: largeSpecialtyAssets,
                analysisByAssetID: analysisByAssetID,
                availability: analysisAvailability
            ),
            recommendation(kind: .bursts, assets: burstAssets, analysisByAssetID: analysisByAssetID),
            recommendation(kind: .decideLater, assets: decideLaterAssets, analysisByAssetID: analysisByAssetID),
            recommendation(kind: .noAlbum, assets: noAlbumAssets, analysisByAssetID: analysisByAssetID),
            recommendation(kind: .unreviewed, assets: unreviewedAssets, analysisByAssetID: analysisByAssetID)
        ]
    }

    private static func recommendation(
        kind: RecommendationKind,
        assets: [OrganizeAsset],
        analysisByAssetID: [String: AssetAnalysisRecord],
        availability: RecommendationAvailability = .ready,
        duplicateGroups: [DuplicateGroup] = [],
        knownByteCountOverride: Int64? = nil
    ) -> OrganizeRecommendation {
        let ordered = orderedRecommendationAssets(
            kind: kind,
            assets: assets,
            analysisByAssetID: analysisByAssetID
        )
        return OrganizeRecommendation(
            kind: kind,
            assetIDs: ordered.map(\.id),
            knownByteCount: knownByteCountOverride ?? ordered.reduce(into: Int64(0)) { total, item in
                addSaturating(knownByteCount(for: item, analysisByAssetID: analysisByAssetID) ?? 0, to: &total)
            },
            availability: availability,
            duplicateGroups: duplicateGroups
        )
    }

    private static func orderedRecommendationAssets(
        kind: RecommendationKind,
        assets: [OrganizeAsset],
        analysisByAssetID: [String: AssetAnalysisRecord]
    ) -> [OrganizeAsset] {
        switch kind {
        case .screenshots, .screenRecordings, .oldScreenshots, .decideLater:
            return assets.sorted(by: oldestCaptureFirst)
        case .veryShortVideos:
            return assets.sorted { lhs, rhs in
                let left = lhs.asset.durationMilliseconds ?? .max
                let right = rhs.asset.durationMilliseconds ?? .max
                if left != right { return left < right }
                return oldestCaptureFirst(lhs, rhs)
            }
        case .tinyImages:
            return assets.sorted { lhs, rhs in
                if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount < rhs.pixelCount }
                return oldestCaptureFirst(lhs, rhs)
            }
        case .largeVideos, .largeSpecialtyMedia:
            return assets.sorted { lhs, rhs in
                let left = knownByteCount(for: lhs, analysisByAssetID: analysisByAssetID) ?? -1
                let right = knownByteCount(for: rhs, analysisByAssetID: analysisByAssetID) ?? -1
                if left != right { return left > right }
                return oldestCaptureFirst(lhs, rhs)
            }
        case .exactDuplicates,
             .bursts,
             .rapidRetakes,
             .similarPhotos,
             .similarScreenshots,
             .worthReviewing,
             .textHeavyDocuments,
             .noClearSubject,
             .smudgedCaptures,
             .noAlbum,
             .unreviewed:
            return assets.sorted { OrganizeText.lessThan($0.id, $1.id) }
        }
    }

    private static func oldestCaptureFirst(_ lhs: OrganizeAsset, _ rhs: OrganizeAsset) -> Bool {
        switch (lhs.asset.creationDate, rhs.asset.creationDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return OrganizeText.lessThan(lhs.id, rhs.id)
        }
    }

    private static func validAnalysis(
        for item: OrganizeAsset,
        in analysisByAssetID: [String: AssetAnalysisRecord]
    ) -> AssetAnalysisRecord? {
        guard let record = analysisByAssetID[item.id],
              record.sourceRevision == item.asset.analysisRevision else {
            return nil
        }
        return record
    }

    private static func knownByteCount(
        for item: OrganizeAsset,
        analysisByAssetID: [String: AssetAnalysisRecord]
    ) -> Int64? {
        validAnalysis(for: item, in: analysisByAssetID)?.knownByteCount
    }

    private static func recommendationAvailability(
        assets: [OrganizeAsset],
        analysisByAssetID: [String: AssetAnalysisRecord]
    ) -> RecommendationAvailability {
        guard !assets.isEmpty else { return .ready }
        let statuses = assets.map { validAnalysis(for: $0, in: analysisByAssetID)?.status ?? .notAnalyzed }
        let completeCount = statuses.filter { $0 == .complete }.count
        let hasInFlight = statuses.contains { $0 == .queued || $0 == .analyzing }
        if completeCount == assets.count { return .ready }
        if hasInFlight { return .analysisInProgress }
        if completeCount == 0 { return .analysisRequired }
        return .partial
    }

    private static func keeperPrecedes(
        _ lhs: OrganizeAsset,
        _ rhs: OrganizeAsset,
        protectedAlbumIDs: Set<String>
    ) -> Bool {
        let lhsProtected = isProtectedForKeeper(lhs, protectedAlbumIDs: protectedAlbumIDs)
        let rhsProtected = isProtectedForKeeper(rhs, protectedAlbumIDs: protectedAlbumIDs)
        if lhsProtected != rhsProtected { return lhsProtected }
        if lhs.asset.isFavorite != rhs.asset.isFavorite { return lhs.asset.isFavorite }
        if lhs.albumIDs.count != rhs.albumIDs.count { return lhs.albumIDs.count > rhs.albumIDs.count }
        return OrganizeText.lessThan(lhs.id, rhs.id)
    }

    private static func keeperReason(
        for keeper: OrganizeAsset,
        among members: [OrganizeAsset],
        protectedAlbumIDs: Set<String>
    ) -> DuplicateKeeperReason {
        let keeperProtected = !keeper.albumIDs.isDisjoint(with: protectedAlbumIDs)
        if keeperProtected, members.contains(where: { $0.albumIDs.isDisjoint(with: protectedAlbumIDs) }) {
            return .protectedAlbum
        }
        if keeper.asset.isHidden,
           members.contains(where: { !isProtectedForKeeper($0, protectedAlbumIDs: protectedAlbumIDs) }) {
            return .protectedItem
        }
        if keeper.asset.isFavorite, members.contains(where: { !$0.asset.isFavorite }) { return .favorite }
        if members.contains(where: { $0.albumIDs.count < keeper.albumIDs.count }) { return .moreAlbumMemberships }
        return .stableIdentifier
    }

    private static func isProtectedForKeeper(
        _ item: OrganizeAsset,
        protectedAlbumIDs: Set<String>
    ) -> Bool {
        item.asset.isFavorite
            || item.asset.isHidden
            || !item.albumIDs.isDisjoint(with: protectedAlbumIDs)
    }

    private static func orientation(of asset: PhotoAsset) -> OrganizeOrientation {
        if asset.pixelWidth == asset.pixelHeight { return .square }
        return asset.pixelWidth > asset.pixelHeight ? .landscape : .portrait
    }

    private static func normalizedFormat(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private static func reviewRank(_ state: AssetReviewState) -> Int {
        switch state {
        case .unreviewed: 0
        case .kept: 1
        case .queuedForRecentlyDeleted: 2
        }
    }

    private static func addSaturating(_ value: Int64, to total: inout Int64) {
        let (sum, overflow) = total.addingReportingOverflow(value)
        total = overflow ? .max : sum
    }

    private static func compare<T: Comparable>(
        _ lhs: T,
        _ rhs: T,
        direction: OrganizeSortDirection
    ) -> ComparisonResult {
        let result: ComparisonResult = lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        return direction == .ascending ? result : result.reversed
    }

    private static func compareOptional<T: Comparable>(
        _ lhs: T?,
        _ rhs: T?,
        direction: OrganizeSortDirection
    ) -> ComparisonResult {
        compareOptional(lhs, rhs, direction: direction) { left, right in
            left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        }
    }

    private static func compareOptional<T>(
        _ lhs: T?,
        _ rhs: T?,
        direction: OrganizeSortDirection,
        comparator: (T, T) -> ComparisonResult
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        case let (left?, right?):
            direction == .ascending ? comparator(left, right) : comparator(left, right).reversed
        }
    }

    private static func compareText(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return OrganizeText.lessThan(lhs, rhs) ? .orderedAscending : .orderedDescending
    }
}

// MARK: - Off-main organizer presentation pipeline

/// Value-only input for a presentation build. Keeping PhotoKit and UIKit objects out of
/// this type lets the organizer perform every library-sized calculation away from the
/// main actor.
struct OrganizePresentationInput: Sendable {
    let revision: UInt64
    let authorization: PhotoAuthorizationState
    let assets: [PhotoAsset]
    let albums: [PhotoAlbum]
    let albumIDsByAssetID: [String: [String]]
    let sourceRevisionByAssetID: [String: String]
    let analysisByAssetID: [String: AssetAnalysisRecord]
    let visualAnalysisByAssetID: [String: VisualAnalysisRecord]
    let analysisRun: AnalysisRunRecord?
    let reviewStateByAssetID: [String: AssetReviewStateRecord]
    let queueByAssetID: [String: DeletionQueueItem]
    let reviewSessionsByID: [UUID: ReviewSession]
    let protectedAlbumIDs: Set<String>
    let protectedAssetIDs: Set<String>
    let deletionBatches: [DeletionBatch]
    let deletedItems: [DeletedItemRecord]
    let activeReviewSessionOverride: OrganizeReviewSessionPresentation?
    let analysisOverride: OrganizeAnalysisPresentation?
    let selectedAssetIDs: Set<String>
}

/// Immutable result of one organizer generation. The revision is checked both by the
/// worker and by the MainActor facade, so a cancelled/superseded build can never replace
/// newer UI state.
struct OrganizePresentationSnapshot: Sendable {
    let revision: UInt64
    let authorization: PhotoAuthorizationState
    let assets: [OrganizeAssetPresentation]
    let assetIndexByID: [String: Int]
    let albums: [OrganizeAlbumPresentation]
    let primaryBreakdown: [OrganizeBreakdownMetric]
    let secondaryBreakdown: [OrganizeBreakdownMetric]
    let reviewRecommendations: [OrganizeRecommendationPresentation]
    let organizeRecommendations: [OrganizeRecommendationPresentation]
    let queuedAssetIDs: Set<String>
    let queuedAssets: [OrganizeAssetPresentation]
    let queuedAssetIndexByID: [String: Int]
    let queuedAssetIDsInOrder: [String]
    let queueKnownBytes: Int64
    let queuedRecommendationKinds: [String: OrganizeRecommendationCategory]
    let protectedAlbumIDs: Set<String>
    let activeReviewSession: OrganizeReviewSessionPresentation?
    let duplicateGroups: [OrganizeDuplicateGroupPresentation]
    let deletedBatches: [OrganizeDeletedBatchPresentation]
    let analysis: OrganizeAnalysisPresentation
    let totalKnownBytes: Int64
    let analyzedItemCount: Int
    let availableFormats: [String]
    let hasAddedDates: Bool
    let deletedAuditRecordCount: Int
    let reviewDecisionAssetIDs: [OrganizeReviewChoice: [String]]
    let reviewDecisionAssetIndexByID: [OrganizeReviewChoice: [String: Int]]
    let retainedSelectedAssetIDs: Set<String>
}

/// Maps the raw ledger/catalog collections once. The coordinator keeps these immutable
/// indexes and uses O(1) lookups for protection and revision checks between builds.
struct OrganizeIndexedState: Sendable {
    let assetsByID: [String: PhotoAsset]
    let orderedAssets: [PhotoAsset]
    let orderedAssetIDs: [String]
    let albumIDsByAssetID: [String: [String]]
    let albumTitleByID: [String: String]
    let sourceRevisionByAssetID: [String: String]
    let analysisByAssetID: [String: AssetAnalysisRecord]
    let reviewStateByAssetID: [String: AssetReviewStateRecord]
    let queueByAssetID: [String: DeletionQueueItem]
    let reviewSessionsByID: [UUID: ReviewSession]
    let protectedAlbumIDs: Set<String>
    let protectedAssetIDs: Set<String>
}

/// Worker-owned review/queue state returned after one durable mutation. Callers may
/// replace presentation aliases with these values, but all subsequent copy-on-write
/// mutation remains isolated to `OrganizeWorker` rather than the main actor.
struct OrganizeReviewPersistenceSnapshot: Sendable {
    let reviewStateByAssetID: [String: AssetReviewStateRecord]
    let queueByAssetID: [String: DeletionQueueItem]
    let reviewSessionsByID: [UUID: ReviewSession]
}

struct OrganizeProtectionPersistenceSnapshot: Sendable {
    let generation: UInt64?
    let protectedAlbumIDs: Set<String>
    let protectedAssetIDs: Set<String>
}

struct OrganizeBrowseQuery: Equatable, Sendable, Hashable {
    /// Authoritative library/presentation generation.
    let revision: UInt64
    /// Action-sized worker mutations can change browse membership/order without
    /// producing a complete presentation snapshot. Keep that invalidation domain
    /// separate so local actions cannot make the next authoritative snapshot stale.
    let contentRevision: UInt64
    /// Monotonic invocation order assigned immediately before crossing the worker
    /// boundary. UI task identity uses the default zero value; the payload sent to
    /// the actor gets a unique sequence so a delayed older call cannot cancel newer work.
    let sequence: UInt64
    /// Stable scalar identity for a recommendation/all-items scope. The potentially
    /// huge ID set is payload only and is never hashed or compared on MainActor.
    let scopeKey: String
    let scopeAssetIDs: Set<String>?
    let configuration: OrganizeBrowseConfiguration

    init(
        revision: UInt64,
        contentRevision: UInt64 = 0,
        sequence: UInt64 = 0,
        scopeKey: String,
        scopeAssetIDs: Set<String>?,
        configuration: OrganizeBrowseConfiguration
    ) {
        self.revision = revision
        self.contentRevision = contentRevision
        self.sequence = sequence
        self.scopeKey = scopeKey
        self.scopeAssetIDs = scopeAssetIDs
        self.configuration = configuration
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
            && lhs.contentRevision == rhs.contentRevision
            && lhs.sequence == rhs.sequence
            && lhs.scopeKey == rhs.scopeKey
            && lhs.configuration == rhs.configuration
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(revision)
        hasher.combine(contentRevision)
        hasher.combine(sequence)
        hasher.combine(scopeKey)
        let filter = configuration.filter
        hasher.combine(configuration.sort.rawValue)
        hasher.combine(configuration.direction.rawValue)
        hasher.combine(configuration.grouping.rawValue)
        hasher.combine(filter.media.rawValue)
        hasher.combine(filter.screenshots.rawValue)
        hasher.combine(filter.livePhotos.rawValue)
        hasher.combine(filter.rawPhotos.rawValue)
        hasher.combine(filter.favorites.rawValue)
        hasher.combine(filter.edited.rawValue)
        hasher.combine(filter.hidden.rawValue)
        hasher.combine(filter.location.rawValue)
        hasher.combine(filter.reviewState.rawValue)
        hasher.combine(filter.analysisState.rawValue)
        hasher.combine(filter.albumMode.rawValue)
        hasher.combine(filter.selectedAlbumID)
        hasher.combine(filter.fileFormat)
        hasher.combine(filter.orientation?.rawValue)
        hasher.combine(filter.useStartDate)
        hasher.combine(filter.startDate)
        hasher.combine(filter.useEndDate)
        hasher.combine(filter.endDate)
        hasher.combine(filter.minimumBytes)
        hasher.combine(filter.minimumMegapixels)
        hasher.combine(filter.minimumDurationMilliseconds)
    }
}

struct OrganizeBrowseQueryResult: Sendable {
    let query: OrganizeBrowseQuery
    let sections: [OrganizeBrowseSection]
}

struct OrganizeDeletionRequestPlan: Sendable {
    let requestedItemsByID: [String: DeletionQueueItem]
    let requests: [PhotoAssetRevalidationRequest]
}

struct OrganizeDeletionValidationPlan: Sendable {
    let missingAssetIDs: [String]
    let changedAssetIDs: [String]
    let requiringReviewAssetIDs: [String]
    let currentAssets: [PhotoAsset]
    let currentAssetIDs: [String]
    let knownBytes: Int64
}

struct OrganizePreparedDeletionPlan: Sendable {
    let records: [DeletedItemRecord]
    let batch: DeletionBatch
}

struct OrganizePendingAnalysisAsset: Sendable {
    let position: Int
    let asset: PhotoAsset
}

enum OrganizeStorageAnalysisBucketID: String, CaseIterable, Hashable, Sendable {
    case photos
    case screenshots
    case videos
    case live
    case raw
    case favorites
    case edited
    case noAlbum = "no-album"

    static func memberships(
        for asset: PhotoAsset,
        albumIDs: [String]
    ) -> [OrganizeStorageAnalysisBucketID] {
        var result: [OrganizeStorageAnalysisBucketID] = []
        if asset.mediaKind == .photo && !asset.mediaSubtypes.contains(.screenshot) {
            result.append(.photos)
        }
        if asset.mediaSubtypes.contains(.screenshot) { result.append(.screenshots) }
        if asset.mediaKind == .video { result.append(.videos) }
        if asset.mediaSubtypes.contains(.livePhoto) { result.append(.live) }
        if asset.mediaSubtypes.contains(.raw) { result.append(.raw) }
        if asset.isFavorite { result.append(.favorites) }
        if asset.isEdited { result.append(.edited) }
        if albumIDs.isEmpty { result.append(.noAlbum) }
        return result
    }
}

struct OrganizeStorageAnalysisBucketProgress: Identifiable, Equatable, Sendable {
    let bucketID: OrganizeStorageAnalysisBucketID
    let itemCount: Int
    let processedAssetCount: Int
    let analyzedAssetCount: Int
    let unavailableAssetCount: Int
    let failedAssetCount: Int
    let knownBytes: Int64

    var id: String { bucketID.rawValue }
}

struct OrganizeStorageAnalysisProgress: Equatable, Sendable {
    let processedAssetCount: Int
    let analyzedAssetCount: Int
    let unavailableAssetCount: Int
    let failedAssetCount: Int
    let totalAssetCount: Int
    let totalKnownBytes: Int64
    /// Always contains exactly one entry for each stable bucket identifier, in
    /// `OrganizeStorageAnalysisBucketID.allCases` order.
    let buckets: [OrganizeStorageAnalysisBucketProgress]
}

struct OrganizeAnalysisProgressUpdate: Equatable, Sendable {
    let presentation: OrganizeAnalysisPresentation
    let storage: OrganizeStorageAnalysisProgress
    let currentAssetID: String?
    let currentAssetFilename: String?
}

struct OrganizeAnalysisWorkerInput: Sendable {
    let includeICloudItems: Bool
    let origin: AnalysisRunOrigin
    let orderedAssetIDs: [String]
    let assetsByID: [String: PhotoAsset]
    let sourceRevisionByAssetID: [String: String]
    let albumIDsByAssetID: [String: [String]]
    let analysisByAssetID: [String: AssetAnalysisRecord]
    let analysisRun: AnalysisRunRecord?
    let nextPosition: Int

    init(
        includeICloudItems: Bool,
        orderedAssetIDs: [String],
        assetsByID: [String: PhotoAsset],
        sourceRevisionByAssetID: [String: String],
        albumIDsByAssetID: [String: [String]] = [:],
        analysisByAssetID: [String: AssetAnalysisRecord],
        analysisRun: AnalysisRunRecord?,
        nextPosition: Int,
        origin: AnalysisRunOrigin = .userInitiated
    ) {
        self.includeICloudItems = includeICloudItems
        self.origin = origin
        self.orderedAssetIDs = orderedAssetIDs
        self.assetsByID = assetsByID
        self.sourceRevisionByAssetID = sourceRevisionByAssetID
        self.albumIDsByAssetID = albumIDsByAssetID
        self.analysisByAssetID = analysisByAssetID
        self.analysisRun = analysisRun
        self.nextPosition = nextPosition
    }
}

struct OrganizeAnalysisWorkerResult: Sendable {
    let analysisByAssetID: [String: AssetAnalysisRecord]
    let analysisRun: AnalysisRunRecord
    let nextPosition: Int
    let presentation: OrganizeAnalysisPresentation
    let storageProgress: OrganizeStorageAnalysisProgress
}

struct OrganizeQueueSelectionResult: Sendable {
    let protectedAssets: [OrganizeAssetPresentation]
    let queuedAssetIDs: Set<String>
    let queuedAssets: [OrganizeAssetPresentation]
    let queuedAssetIndexByID: [String: Int]
    let queuedAssetIDsInOrder: [String]
    let queueKnownBytes: Int64
    let recommendationKinds: [String: OrganizeRecommendationCategory]
}

enum OrganizeSelectionMutation: Equatable, Sendable {
    case toggle(assetID: String)
    case clear
}

struct OrganizeSelectionMutationResult: Sendable {
    let selectedAssetIDs: Set<String>
}

struct OrganizeReviewChoiceMutationRequest: Equatable, Sendable {
    let sessionID: UUID
    let choice: OrganizeReviewChoice
    let allowProtected: Bool
}

struct OrganizeReviewPresentationMutationResult: Sendable {
    let session: OrganizeReviewSessionPresentation
    let action: OrganizeReviewActionPresentation
    let assetID: String
    let previousChoice: OrganizeReviewChoice?
    let currentChoice: OrganizeReviewChoice?
    let isReviewed: Bool
    let queue: OrganizeQueueSelectionResult
    let reviewDecisionAssetIDs: [OrganizeReviewChoice: [String]]
    let reviewDecisionAssetIndexByID: [OrganizeReviewChoice: [String: Int]]
}

/// Action-sized replacement for the queue screen's "keep" gesture. The worker
/// updates its canonical asset and queue buffers in one actor turn, then the UI
/// installs only the returned presentation values without mutating shared storage.
struct OrganizeQueuedAssetReviewMutationResult: Sendable {
    let assetID: String
    let isReviewed: Bool
    let queue: OrganizeQueueSelectionResult
}

/// Worker-computed replacement for one protection toggle. The UI assigns this Set
/// atomically; it never mutates storage shared with a worker snapshot on MainActor.
struct OrganizeProtectedAlbumPresentationMutationResult: Sendable {
    let generation: UInt64
    let albumID: String
    let isProtected: Bool
    let protectedAlbumIDs: Set<String>
}

struct OrganizeDeletionHistoryState: Sendable {
    let batches: [DeletionBatch]
    let items: [DeletedItemRecord]
    let itemByID: [UUID: DeletedItemRecord]
}

/// Short names used by the UI query boundary. Keep the organizer-prefixed names for
/// source compatibility with existing call sites.
typealias BrowseQuery = OrganizeBrowseQuery
typealias BrowseQueryResult = OrganizeBrowseQueryResult

struct OrganizeDeletedHistoryQuery: Hashable, Sendable {
    let revision: UInt64
    let sequence: UInt64
    let searchText: String

    init(revision: UInt64, sequence: UInt64 = 0, searchText: String) {
        self.revision = revision
        self.sequence = sequence
        self.searchText = searchText
    }
}

struct OrganizeDeletedHistoryResult: Sendable {
    let query: OrganizeDeletedHistoryQuery
    let batches: [OrganizeDeletedBatchPresentation]
}

enum OrganizeWorkerError: Error, Equatable {
    case analysisAlreadyRunning
}

/// Lightweight counters used by synthetic responsiveness regressions. Keeping
/// these on the worker actor makes assertions deterministic without measuring
/// wall-clock timing or adding callbacks to production processing paths.
struct OrganizeWorkerInstrumentation: Equatable, Sendable {
    let presentationBuildInvocationCount: UInt64
    let committedAnalysisRecordCount: UInt64
}

private struct MutableStorageBucketProgress {
    var itemCount = 0
    var processedAssetCount = 0
    var analyzedAssetCount = 0
    var unavailableAssetCount = 0
    var failedAssetCount = 0
    var knownBytes: Int64 = 0
}

private struct OrganizeStorageAnalysisAccumulator {
    private(set) var processedAssetCount = 0
    private(set) var analyzedAssetCount = 0
    private(set) var unavailableAssetCount = 0
    private(set) var failedAssetCount = 0
    private(set) var totalKnownBytes: Int64 = 0
    private let totalAssetCount: Int
    private let albumIDsByAssetID: [String: [String]]
    private var pendingAssetIDs: Set<String>
    private var buckets: [OrganizeStorageAnalysisBucketID: MutableStorageBucketProgress]

    init(
        assets: [PhotoAsset],
        albumIDsByAssetID: [String: [String]],
        analysisByAssetID: [String: AssetAnalysisRecord],
        pendingAssetIDs: Set<String>
    ) {
        totalAssetCount = assets.count
        self.albumIDsByAssetID = albumIDsByAssetID
        self.pendingAssetIDs = pendingAssetIDs
        buckets = Dictionary(uniqueKeysWithValues: OrganizeStorageAnalysisBucketID.allCases.map {
            ($0, MutableStorageBucketProgress())
        })

        for asset in assets {
            let memberships = Self.memberships(for: asset, albumIDsByAssetID: albumIDsByAssetID)
            for bucketID in memberships { buckets[bucketID, default: .init()].itemCount += 1 }
            if !pendingAssetIDs.contains(asset.id) {
                processedAssetCount += 1
                for bucketID in memberships {
                    buckets[bucketID, default: .init()].processedAssetCount += 1
                }
            }
            guard let record = analysisByAssetID[asset.id],
                  record.sourceRevision == asset.analysisRevision else { continue }
            apply(record, memberships: memberships, direction: 1)
        }
    }

    mutating func commit(
        asset: PhotoAsset,
        previous: AssetAnalysisRecord?,
        replacement: AssetAnalysisRecord,
        countsAsProcessed: Bool
    ) {
        let memberships = Self.memberships(for: asset, albumIDsByAssetID: albumIDsByAssetID)
        if let previous, previous.sourceRevision == asset.analysisRevision {
            apply(previous, memberships: memberships, direction: -1)
        }
        if replacement.sourceRevision == asset.analysisRevision {
            apply(replacement, memberships: memberships, direction: 1)
        }
        if countsAsProcessed, pendingAssetIDs.remove(asset.id) != nil {
            processedAssetCount += 1
            for bucketID in memberships {
                buckets[bucketID, default: .init()].processedAssetCount += 1
            }
        }
    }

    func snapshot() -> OrganizeStorageAnalysisProgress {
        OrganizeStorageAnalysisProgress(
            processedAssetCount: min(max(processedAssetCount, 0), totalAssetCount),
            analyzedAssetCount: min(max(analyzedAssetCount, 0), totalAssetCount),
            unavailableAssetCount: min(max(unavailableAssetCount, 0), totalAssetCount),
            failedAssetCount: min(max(failedAssetCount, 0), totalAssetCount),
            totalAssetCount: totalAssetCount,
            totalKnownBytes: max(totalKnownBytes, 0),
            buckets: OrganizeStorageAnalysisBucketID.allCases.map { bucketID in
                let bucket = buckets[bucketID] ?? MutableStorageBucketProgress()
                return OrganizeStorageAnalysisBucketProgress(
                    bucketID: bucketID,
                    itemCount: bucket.itemCount,
                    processedAssetCount: min(max(bucket.processedAssetCount, 0), bucket.itemCount),
                    analyzedAssetCount: min(max(bucket.analyzedAssetCount, 0), bucket.itemCount),
                    unavailableAssetCount: min(max(bucket.unavailableAssetCount, 0), bucket.itemCount),
                    failedAssetCount: min(max(bucket.failedAssetCount, 0), bucket.itemCount),
                    knownBytes: max(bucket.knownBytes, 0)
                )
            }
        )
    }

    private static func memberships(
        for asset: PhotoAsset,
        albumIDsByAssetID: [String: [String]]
    ) -> [OrganizeStorageAnalysisBucketID] {
        OrganizeStorageAnalysisBucketID.memberships(
            for: asset,
            albumIDs: albumIDsByAssetID[asset.id] ?? []
        )
    }

    private mutating func apply(
        _ record: AssetAnalysisRecord,
        memberships: [OrganizeStorageAnalysisBucketID],
        direction: Int
    ) {
        let bytes = record.knownByteCount ?? 0
        switch record.status {
        case .complete:
            analyzedAssetCount += direction
            totalKnownBytes = Self.adjust(totalKnownBytes, by: bytes, direction: direction)
            for bucketID in memberships {
                var bucket = buckets[bucketID] ?? MutableStorageBucketProgress()
                bucket.analyzedAssetCount += direction
                bucket.knownBytes = Self.adjust(
                    bucket.knownBytes,
                    by: bytes,
                    direction: direction
                )
                buckets[bucketID] = bucket
            }
        case .unavailableLocally:
            unavailableAssetCount += direction
            for bucketID in memberships {
                buckets[bucketID, default: .init()].unavailableAssetCount += direction
            }
        case .failed:
            failedAssetCount += direction
            for bucketID in memberships {
                buckets[bucketID, default: .init()].failedAssetCount += direction
            }
        case .notAnalyzed, .queued, .analyzing:
            break
        }
    }

    private static func adjust(_ value: Int64, by amount: Int64, direction: Int) -> Int64 {
        guard direction > 0 else { return max(value - amount, 0) }
        let (sum, overflow) = value.addingReportingOverflow(amount)
        return overflow ? .max : sum
    }
}

private final class AssetAnalysisProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var fraction = 0.0

    func update(_ progress: AssetAnalysisProgress) {
        lock.lock()
        fraction = max(fraction, min(max(progress.fractionCompleted, 0), 1))
        lock.unlock()
    }

    func currentFraction() -> Double {
        lock.lock()
        let result = fraction
        lock.unlock()
        return result
    }
}

private actor OrganizeAnalysisProgressPublisher {
    private let sink: @Sendable (OrganizeAnalysisProgressUpdate) async -> Void
    private let clock = ContinuousClock()
    private var lastPublishedAt: ContinuousClock.Instant?
    private var pending: OrganizeAnalysisProgressUpdate?
    private var scheduledPublication: Task<Void, Never>?
    /// Chains sink calls so an older running update can never finish after the
    /// terminal snapshot when the async sink suspends (for example on MainActor).
    private var deliveryTask: Task<Void, Never>?
    private var isFinished = false

    init(sink: @escaping @Sendable (OrganizeAnalysisProgressUpdate) async -> Void) {
        self.sink = sink
    }

    func submit(_ update: OrganizeAnalysisProgressUpdate, immediately: Bool = false) async {
        guard !isFinished else { return }
        pending = update
        if immediately {
            scheduledPublication?.cancel()
            scheduledPublication = nil
            await publishPending()
            return
        }

        guard scheduledPublication == nil else { return }
        let minimumInterval = Duration.milliseconds(100)
        if let lastPublishedAt {
            let elapsed = lastPublishedAt.duration(to: clock.now)
            if elapsed < minimumInterval {
                let delay = minimumInterval - elapsed
                scheduledPublication = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    await self?.publishScheduled()
                }
                return
            }
        }
        await publishPending()
    }

    func finish(with update: OrganizeAnalysisProgressUpdate) async {
        guard !isFinished else { return }
        isFinished = true
        scheduledPublication?.cancel()
        scheduledPublication = nil
        pending = nil
        lastPublishedAt = clock.now
        await enqueueDelivery(update)
    }

    private func publishScheduled() async {
        scheduledPublication = nil
        await publishPending()
    }

    private func publishPending() async {
        guard let update = pending else { return }
        pending = nil
        lastPublishedAt = clock.now
        await enqueueDelivery(update)
    }

    private func enqueueDelivery(_ update: OrganizeAnalysisProgressUpdate) async {
        let precedingDelivery = deliveryTask
        let sink = sink
        let delivery = Task {
            if let precedingDelivery { await precedingDelivery.value }
            await sink(update)
        }
        deliveryTask = delivery
        await delivery.value
    }
}

/// Single-flight worker for organizer snapshots and browse queries. Detached child work
/// is explicitly owned and cancelled by this actor; unlike a fire-and-forget detached
/// task, cancellation and stale-generation rejection are deterministic.
actor OrganizeWorker {
    private var latestIndexRequestGeneration: UInt64?
    private var latestPresentationRevision: UInt64 = 0
    private var presentationTask: Task<OrganizePresentationSnapshot, Error>?
    private var latestBrowseQuery: OrganizeBrowseQuery?
    private var browseTask: Task<OrganizeBrowseQueryResult, Error>?
    private var latestDeletedHistoryQuery: OrganizeDeletedHistoryQuery?
    private var deletedHistoryTask: Task<OrganizeDeletedHistoryResult, Error>?
    private var analysisLeaseID: UUID?
    private var activeAnalysisRunID: UUID?
    private var presentationBuildInvocationCount: UInt64 = 0
    private var committedAnalysisRecordCount: UInt64 = 0

    // The worker is the sole mutable owner of library-sized review, queue, session,
    // and protection maps. MainActor receives immutable aliases only; one review choice or
    // queue delta can therefore never trigger a library-sized COW on the UI thread.
    private var hasCanonicalState = false
    private var canonicalAssetsByID: [String: PhotoAsset] = [:]
    private var canonicalOrderedAssets: [PhotoAsset] = []
    private var canonicalAlbums: [PhotoAlbum] = []
    private var canonicalAlbumIDsByAssetID: [String: [String]] = [:]
    private var canonicalAlbumTitleByID: [String: String] = [:]
    private var canonicalSourceRevisionByAssetID: [String: String] = [:]
    private var canonicalReviewStateByAssetID: [String: AssetReviewStateRecord] = [:]
    private var canonicalQueueByAssetID: [String: DeletionQueueItem] = [:]
    private var canonicalReviewSessionsByID: [UUID: ReviewSession] = [:]
    private var canonicalProtectedAlbumIDs: Set<String> = []
    private var canonicalProtectedAssetIDs: Set<String> = []
    /// Protection inferred while building the current presentation (currently
    /// document-like OCR/barcode results). Keep this separate from durable album
    /// and asset-state protection so optimistic album toggles cannot erase it.
    private var canonicalDerivedProtectedAssetIDs: Set<String> = []
    private var canonicalPresentedProtectedAlbumIDs: Set<String> = []
    private var canonicalPresentedProtectedAssetIDs: Set<String> = []
    private var pendingProtectedAlbumPresentationDeltas: [UInt64: OrganizeProtectedAlbumPersistenceDelta] = [:]
    private var canonicalStateRevision: UInt64 = 0
    private var canonicalPresentationMutationRevision: UInt64 = 0

    // Derived presentation collections are also canonical here. Gesture APIs accept
    // only IDs/choices and mutate these buffers on the worker before returning an
    // immutable replacement, avoiding live MainActor aliases across suspension.
    private var canonicalPresentationAssets: [OrganizeAssetPresentation] = []
    private var canonicalPresentationAssetIndexByID: [String: Int] = [:]
    private var canonicalQueuedAssetIDs: Set<String> = []
    private var canonicalQueuedAssets: [OrganizeAssetPresentation] = []
    private var canonicalQueuedAssetIndexByID: [String: Int] = [:]
    private var canonicalQueuedAssetIDsInOrder: [String] = []
    private var canonicalQueueKnownBytes: Int64 = 0
    private var canonicalQueuedRecommendationKinds: [String: OrganizeRecommendationCategory] = [:]
    private var canonicalSelectedAssetIDs: Set<String> = []
    private var canonicalActiveReviewSession: OrganizeReviewSessionPresentation?
    private var canonicalReviewRecommendations: [OrganizeRecommendationPresentation] = []
    private var canonicalOrganizeRecommendations: [OrganizeRecommendationPresentation] = []
    private var canonicalReviewDecisionAssetIDs: [OrganizeReviewChoice: [String]] = [:]
    private var canonicalReviewDecisionAssetIndexByID: [OrganizeReviewChoice: [String: Int]] = [:]

    // Actor reentrancy would otherwise allow a second SQLite mutation to calculate
    // from state that the first mutation has persisted but not installed yet.
    private var stateMutationLeaseOwned = false
    private var stateMutationWaiters: [CheckedContinuation<Void, Never>] = []

    func instrumentation() -> OrganizeWorkerInstrumentation {
        OrganizeWorkerInstrumentation(
            presentationBuildInvocationCount: presentationBuildInvocationCount,
            committedAnalysisRecordCount: committedAnalysisRecordCount
        )
    }

    func activeAnalysisRunIdentifier() -> UUID? { activeAnalysisRunID }

    func presentedProtectedAssetIDs() -> Set<String> {
        hasCanonicalState ? canonicalPresentedProtectedAssetIDs : []
    }

    func index(
        assets: [PhotoAsset],
        albums: [PhotoAlbum],
        analysisByAssetID: [String: AssetAnalysisRecord],
        reviewStateByAssetID: [String: AssetReviewStateRecord],
        queueItems: [DeletionQueueItem],
        reviewSessions: [ReviewSession],
        protectedAlbums: [ProtectedAlbumRecord],
        requestGeneration: UInt64? = nil
    ) async throws -> OrganizeIndexedState {
        await acquireStateMutationLease()
        defer { releaseStateMutationLease() }
        try Task.checkCancellation()
        if let requestGeneration {
            if let latestIndexRequestGeneration,
               requestGeneration < latestIndexRequestGeneration {
                throw CancellationError()
            }
            latestIndexRequestGeneration = requestGeneration
        }
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var albumIDsByAssetID: [String: [String]] = [:]
        for (index, album) in albums.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            for assetID in album.assetIDs where assetsByID[assetID] != nil {
                albumIDsByAssetID[assetID, default: []].append(album.id)
            }
        }
        for assetID in albumIDsByAssetID.keys {
            albumIDsByAssetID[assetID]?.sort()
        }

        var sourceRevisionByAssetID: [String: String] = [:]
        sourceRevisionByAssetID.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            sourceRevisionByAssetID[asset.id] = asset.sourceRevision
        }

        let validAnalysis = analysisByAssetID.filter { assetID, record in
            guard let asset = assetsByID[assetID] else { return true }
            return record.sourceRevision == asset.analysisRevision
        }
        let storedValidReviewState = reviewStateByAssetID.filter { assetID, record in
            guard let currentRevision = sourceRevisionByAssetID[assetID] else { return true }
            return record.sourceRevision == currentRevision
        }
        let storedQueueByAssetID = Dictionary(uniqueKeysWithValues: queueItems.map { ($0.assetID, $0) })
        let storedReviewSessionsByID = Dictionary(uniqueKeysWithValues: reviewSessions.map { ($0.id, $0) })
        let storedProtectedAlbumIDs = Set(protectedAlbums.map(\.albumID))
        let validReviewState: [String: AssetReviewStateRecord]
        let queueByAssetID: [String: DeletionQueueItem]
        let reviewSessionsByID: [UUID: ReviewSession]
        let protectedAlbumIDs: Set<String>
        if hasCanonicalState {
            validReviewState = canonicalReviewStateByAssetID.filter { assetID, record in
                guard let currentRevision = sourceRevisionByAssetID[assetID] else { return true }
                return record.sourceRevision == currentRevision
            }
            queueByAssetID = canonicalQueueByAssetID
            reviewSessionsByID = canonicalReviewSessionsByID
            protectedAlbumIDs = canonicalProtectedAlbumIDs
        } else {
            validReviewState = storedValidReviewState
            queueByAssetID = storedQueueByAssetID
            reviewSessionsByID = storedReviewSessionsByID
            protectedAlbumIDs = storedProtectedAlbumIDs
        }
        let protectedAssetIDs = Self.protectedAssetIDs(
            assets: assets,
            albumIDsByAssetID: albumIDsByAssetID,
            protectedAlbumIDs: protectedAlbumIDs,
            reviewStateByAssetID: validReviewState
        )
        let orderedAssets = assets.sorted(by: Self.assetOrder)
        let albumTitleByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0.title) })

        canonicalAssetsByID = assetsByID
        canonicalOrderedAssets = orderedAssets
        canonicalAlbums = albums
        canonicalAlbumIDsByAssetID = albumIDsByAssetID
        canonicalAlbumTitleByID = albumTitleByID
        canonicalSourceRevisionByAssetID = sourceRevisionByAssetID
        canonicalReviewStateByAssetID = validReviewState
        canonicalQueueByAssetID = queueByAssetID
        canonicalReviewSessionsByID = reviewSessionsByID
        canonicalProtectedAlbumIDs = protectedAlbumIDs
        canonicalProtectedAssetIDs = protectedAssetIDs
        rebuildCanonicalPresentedProtection()
        hasCanonicalState = true
        canonicalStateDidChange()
        return OrganizeIndexedState(
            assetsByID: assetsByID,
            orderedAssets: orderedAssets,
            orderedAssetIDs: orderedAssets.map(\.id),
            albumIDsByAssetID: albumIDsByAssetID,
            albumTitleByID: albumTitleByID,
            sourceRevisionByAssetID: sourceRevisionByAssetID,
            analysisByAssetID: validAnalysis,
            reviewStateByAssetID: validReviewState,
            queueByAssetID: queueByAssetID,
            reviewSessionsByID: reviewSessionsByID,
            protectedAlbumIDs: protectedAlbumIDs,
            protectedAssetIDs: protectedAssetIDs
        )
    }

    func protectedAssetIDs(
        assets: [PhotoAsset],
        albumIDsByAssetID: [String: [String]],
        protectedAlbumIDs: Set<String>
    ) -> Set<String> {
        Self.protectedAssetIDs(
            assets: assets,
            albumIDsByAssetID: albumIDsByAssetID,
            protectedAlbumIDs: protectedAlbumIDs
        )
    }

    func analysisCheckpoint(
        orderedAssets: [PhotoAsset],
        analysisByAssetID: [String: AssetAnalysisRecord]
    ) throws -> (completedCount: Int, completedAssetIDs: Set<String>) {
        var completedAssetIDs: Set<String> = []
        completedAssetIDs.reserveCapacity(analysisByAssetID.count)
        for (index, asset) in orderedAssets.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            guard let record = analysisByAssetID[asset.id],
                  record.sourceRevision == asset.analysisRevision,
                  record.status == .complete else { continue }
            completedAssetIDs.insert(asset.id)
        }
        return (completedAssetIDs.count, completedAssetIDs)
    }

    func assets(
        for orderedIDs: [String],
        assetsByID: [String: PhotoAsset]
    ) throws -> [PhotoAsset] {
        var result: [PhotoAsset] = []
        result.reserveCapacity(orderedIDs.count)
        for (index, id) in orderedIDs.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if let asset = assetsByID[id] { result.append(asset) }
        }
        return result
    }

    func analysisWorkMatches(_ lhs: [String], _ rhs: [String]) throws -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if lhs[index] != rhs[index] { return false }
        }
        return true
    }

    func pendingAnalysisWork(
        orderedAssetIDs: [String],
        startPosition: Int,
        assetsByID: [String: PhotoAsset],
        analysisByAssetID: [String: AssetAnalysisRecord],
        origin: AnalysisRunOrigin
    ) throws -> [OrganizePendingAnalysisAsset] {
        var result: [OrganizePendingAnalysisAsset] = []
        for position in max(0, startPosition)..<orderedAssetIDs.count {
            if position.isMultiple(of: 128) { try Task.checkCancellation() }
            let id = orderedAssetIDs[position]
            guard let asset = assetsByID[id] else { continue }
            guard Self.analysisRequiresWork(
                asset: asset,
                record: analysisByAssetID[id],
                origin: origin
            ) else { continue }
            result.append(OrganizePendingAnalysisAsset(position: position, asset: asset))
        }
        return result
    }

    private static func analysisRequiresWork(
        asset: PhotoAsset,
        record: AssetAnalysisRecord?,
        origin: AnalysisRunOrigin
    ) -> Bool {
        guard let record,
              record.sourceRevision == asset.analysisRevision else { return true }
        switch record.status {
        case .complete:
            return false
        case .unavailableLocally, .failed:
            // Opportunistic upkeep only analyzes new/changed work. Explicit user
            // runs remain the retry path for iCloud-unavailable and failed items.
            return origin == .userInitiated
        case .notAnalyzed, .queued, .analyzing:
            return true
        }
    }

    private func resumedAnalysisPosition(
        requestedPosition: Int,
        orderedAssetIDs: [String],
        previouslyCompletedAssetIDs: Set<String>,
        assetsByID: [String: PhotoAsset],
        analysisByAssetID: [String: AssetAnalysisRecord]
    ) throws -> Int {
        let boundedPosition = min(max(requestedPosition, 0), orderedAssetIDs.count)
        for position in 0..<boundedPosition {
            if position.isMultiple(of: 128) { try Task.checkCancellation() }
            let assetID = orderedAssetIDs[position]
            guard previouslyCompletedAssetIDs.contains(assetID) else { continue }
            guard let asset = assetsByID[assetID],
                  let record = analysisByAssetID[assetID],
                  record.sourceRevision == asset.analysisRevision,
                  record.status == .complete else {
                return position
            }
        }
        return boundedPosition
    }

    func runAnalysis(
        _ input: OrganizeAnalysisWorkerInput,
        ledger: SQLiteLedger,
        analyzer: any AssetResourceAnalyzing,
        deferSuccessfulCompletion: Bool = false,
        analysisRunIdentified: @escaping @Sendable (
            _ runID: UUID,
            _ includeICloudItems: Bool,
            _ origin: AnalysisRunOrigin
        ) async -> Void = { _, _, _ in },
        progress: @escaping @Sendable (OrganizeAnalysisProgressUpdate) async -> Void
    ) async throws -> OrganizeAnalysisWorkerResult {
        guard analysisLeaseID == nil else { throw OrganizeWorkerError.analysisAlreadyRunning }
        let leaseID = UUID()
        analysisLeaseID = leaseID
        defer {
            if analysisLeaseID == leaseID { analysisLeaseID = nil }
            activeAnalysisRunID = nil
        }

        var records = input.analysisByAssetID
        let orderedAssets = try assets(for: input.orderedAssetIDs, assetsByID: input.assetsByID)
        let checkpoint = try analysisCheckpoint(
            orderedAssets: orderedAssets,
            analysisByAssetID: records
        )
        var completedCount = checkpoint.completedCount
        var run: AnalysisRunRecord
        let resumesExisting: Bool
        if let existing = input.analysisRun,
           existing.status == .paused,
           existing.includesICloudItems == input.includeICloudItems,
           existing.origin == input.origin,
           try analysisWorkMatches(existing.orderedAssetIDs, input.orderedAssetIDs) {
            run = existing
            run.status = .running
            run.updatedAt = Date()
            run.errorMessage = nil
            resumesExisting = true
        } else {
            run = AnalysisRunRecord(
                id: UUID(),
                includesICloudItems: input.includeICloudItems,
                orderedAssetIDs: input.orderedAssetIDs,
                completedAssetIDs: [],
                status: .running,
                startedAt: Date(),
                updatedAt: Date(),
                errorMessage: nil,
                origin: input.origin
            )
            resumesExisting = false
        }
        let previouslyCompletedAssetIDs = run.completedAssetIDs
        run.completedAssetIDs = checkpoint.completedAssetIDs
        let startPosition = if resumesExisting {
            try resumedAnalysisPosition(
                requestedPosition: input.nextPosition,
                orderedAssetIDs: input.orderedAssetIDs,
                previouslyCompletedAssetIDs: previouslyCompletedAssetIDs,
                assetsByID: input.assetsByID,
                analysisByAssetID: records
            )
        } else {
            0
        }
        if resumesExisting {
            try await ledger.checkpointAnalysisRun(
                id: run.id,
                status: .running,
                nextPosition: startPosition,
                completedAssetCount: completedCount,
                updatedAt: run.updatedAt
            )
        } else {
            try await ledger.createAnalysisRun(run)
        }
        activeAnalysisRunID = run.id
        await analysisRunIdentified(run.id, run.includesICloudItems, run.origin)
        var nextPosition = startPosition
        let publisher = OrganizeAnalysisProgressPublisher(sink: progress)
        let work: [OrganizePendingAnalysisAsset]
        do {
            work = try pendingAnalysisWork(
                orderedAssetIDs: input.orderedAssetIDs,
                startPosition: startPosition,
                assetsByID: input.assetsByID,
                analysisByAssetID: records,
                origin: input.origin
            )
        } catch is CancellationError {
            let pendingIDs: Set<String> = Set(orderedAssets.dropFirst(startPosition).compactMap { asset in
                Self.analysisRequiresWork(
                    asset: asset,
                    record: records[asset.id],
                    origin: input.origin
                ) ? asset.id : nil
            })
            var storage = OrganizeStorageAnalysisAccumulator(
                assets: orderedAssets,
                albumIDsByAssetID: input.albumIDsByAssetID,
                analysisByAssetID: records,
                pendingAssetIDs: pendingIDs
            )
            return try await pauseAnalysis(
                run: &run,
                records: records,
                nextPosition: nextPosition,
                storage: &storage,
                ledger: ledger,
                publisher: publisher
            )
        }
        var storage = OrganizeStorageAnalysisAccumulator(
            assets: orderedAssets,
            albumIDsByAssetID: input.albumIDsByAssetID,
            analysisByAssetID: records,
            pendingAssetIDs: Set(work.map(\.asset.id))
        )
        completedCount = storage.snapshot().analyzedAssetCount
        await publisher.submit(
            Self.analysisProgressUpdate(
                phase: .running,
                storage: storage.snapshot(),
                includesICloudItems: input.includeICloudItems,
                statusText: input.includeICloudItems
                    ? "Analyzing local and iCloud items…"
                    : "Analyzing locally available items…"
            ),
            immediately: true
        )

        for item in work {
            nextPosition = item.position
            if Task.isCancelled {
                return try await pauseAnalysis(
                    run: &run,
                    records: records,
                    nextPosition: nextPosition,
                    storage: &storage,
                    ledger: ledger,
                    publisher: publisher
                )
            }
            let asset = item.asset
            let previousRecord = records[asset.id]
            let filename = asset.resources.first?.originalFilename ?? "item"
            var record = AssetAnalysisRecord(
                assetID: asset.id,
                sourceRevision: asset.analysisRevision,
                status: .analyzing,
                fingerprint: nil,
                updatedAt: Date(),
                errorMessage: nil
            )
            records[asset.id] = record
            let storageBeforeAsset = storage.snapshot()
            await publisher.submit(
                Self.analysisProgressUpdate(
                    phase: .running,
                    storage: storageBeforeAsset,
                    includesICloudItems: input.includeICloudItems,
                    currentAssetID: asset.id,
                    currentAssetFilename: filename,
                    currentAssetFraction: 0,
                    statusText: "Analyzing \(filename)…"
                )
            )
            let relay = AssetAnalysisProgressRelay()
            let resourceProgressTask = Task { [publisher] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    await publisher.submit(
                        Self.analysisProgressUpdate(
                            phase: .running,
                            storage: storageBeforeAsset,
                            includesICloudItems: input.includeICloudItems,
                            currentAssetID: asset.id,
                            currentAssetFilename: filename,
                            currentAssetFraction: relay.currentFraction(),
                            statusText: "Analyzing \(filename)…"
                        )
                    )
                }
            }
            do {
                record.fingerprint = try await analyzer.analyze(
                    asset: asset,
                    includeNetwork: input.includeICloudItems,
                    progress: { relay.update($0) }
                )
                resourceProgressTask.cancel()
                await resourceProgressTask.value
                record.status = .complete
                record.updatedAt = Date()
                record.errorMessage = nil
            } catch {
                resourceProgressTask.cancel()
                await resourceProgressTask.value
                let serviceError = error as? OrganizePhotoServiceError
                let cancelled = error is CancellationError || {
                    if case .cancelled? = serviceError { return true }
                    return false
                }()
                if cancelled {
                    record.status = .queued
                    record.updatedAt = Date()
                    record.errorMessage = nil
                    records[asset.id] = record
                    return try await pauseAnalysis(
                        run: &run,
                        records: records,
                        nextPosition: nextPosition,
                        storage: &storage,
                        ledger: ledger,
                        committing: (asset, previousRecord, record),
                        publisher: publisher
                    )
                }
                if case .networkAccessRequired? = serviceError {
                    record.status = .unavailableLocally
                } else {
                    record.status = .failed
                }
                record.updatedAt = Date()
                record.errorMessage = error.localizedDescription
            }
            records[asset.id] = record
            run.updatedAt = Date()
            let committedNextPosition = item.position + 1
            do {
                try await ledger.commitAnalysisProgress(
                    record,
                    runID: run.id,
                    status: .running,
                    nextPosition: committedNextPosition,
                    updatedAt: run.updatedAt
                )
            } catch {
                await markAnalysisFailed(
                    run: &run,
                    nextPosition: nextPosition,
                    storage: storage.snapshot(),
                    persistenceError: error,
                    ledger: ledger,
                    publisher: publisher
                )
                throw error
            }
            committedAnalysisRecordCount &+= 1
            nextPosition = committedNextPosition
            storage.commit(
                asset: asset,
                previous: previousRecord,
                replacement: record,
                countsAsProcessed: true
            )
            completedCount = storage.snapshot().analyzedAssetCount
            if record.status == .complete {
                run.completedAssetIDs.insert(asset.id)
            }
            await publisher.submit(
                Self.analysisProgressUpdate(
                    phase: .running,
                    storage: storage.snapshot(),
                    includesICloudItems: input.includeICloudItems,
                    statusText: input.includeICloudItems
                        ? "Analyzing local and iCloud items…"
                        : "Analyzing locally available items…"
                )
            )
        }

        let finalStorage = storage.snapshot()
        let failedThisRun = input.origin == .userInitiated
            ? finalStorage.failedAssetCount > 0
            : work.contains { item in
                guard let record = records[item.asset.id] else { return false }
                return record.sourceRevision == item.asset.analysisRevision && record.status == .failed
            }
        let terminalPhase: OrganizeAnalysisPhase = failedThisRun
            ? .failed
            : deferSuccessfulCompletion ? .running : .complete
        let terminalRunStatus: AnalysisRunStatus = failedThisRun
            ? .failed
            : deferSuccessfulCompletion ? .running : .complete
        let terminalText = deferSuccessfulCompletion && !failedThisRun
            ? "Storage scan complete; preparing on-device smart analysis…"
            : Self.analysisTerminalStatusText(
                storage: finalStorage,
                includesICloudItems: input.includeICloudItems
            )
        run.status = terminalRunStatus
        run.updatedAt = Date()
        run.errorMessage = failedThisRun ? terminalText : nil
        // While the separate visual phase is pending, retain one durable cursor
        // unit. This lets crash recovery and automatic-maintenance resubmission
        // distinguish an interrupted smart scan from a fully completed run.
        let durableNextPosition = deferSuccessfulCompletion && !failedThisRun
            ? max(input.orderedAssetIDs.count - 1, 0)
            : input.orderedAssetIDs.count
        do {
            try await ledger.checkpointAnalysisRun(
                id: run.id,
                status: terminalRunStatus,
                nextPosition: durableNextPosition,
                completedAssetCount: finalStorage.analyzedAssetCount,
                allowPositionRewind: deferSuccessfulCompletion && !failedThisRun,
                updatedAt: run.updatedAt,
                errorMessage: run.errorMessage
            )
        } catch {
            await markAnalysisFailed(
                run: &run,
                nextPosition: nextPosition,
                storage: finalStorage,
                persistenceError: error,
                ledger: ledger,
                publisher: publisher
            )
            throw error
        }
        let terminalUpdate = Self.analysisProgressUpdate(
            phase: terminalPhase,
            storage: finalStorage,
            includesICloudItems: input.includeICloudItems,
            statusText: terminalText
        )
        await publisher.finish(with: terminalUpdate)
        return OrganizeAnalysisWorkerResult(
            analysisByAssetID: records,
            analysisRun: run,
            nextPosition: input.orderedAssetIDs.count,
            presentation: terminalUpdate.presentation,
            storageProgress: finalStorage
        )
    }

    private func pauseAnalysis(
        run: inout AnalysisRunRecord,
        records: [String: AssetAnalysisRecord],
        nextPosition: Int,
        storage: inout OrganizeStorageAnalysisAccumulator,
        ledger: SQLiteLedger,
        committing: (asset: PhotoAsset, previous: AssetAnalysisRecord?, record: AssetAnalysisRecord)? = nil,
        publisher: OrganizeAnalysisProgressPublisher
    ) async throws -> OrganizeAnalysisWorkerResult {
        run.status = .paused
        run.updatedAt = Date()
        do {
            if let committing {
                try await ledger.commitAnalysisProgress(
                    committing.record,
                    runID: run.id,
                    status: .paused,
                    nextPosition: nextPosition,
                    updatedAt: run.updatedAt
                )
                committedAnalysisRecordCount &+= 1
                storage.commit(
                    asset: committing.asset,
                    previous: committing.previous,
                    replacement: committing.record,
                    countsAsProcessed: false
                )
            } else {
                try await ledger.checkpointAnalysisRun(
                    id: run.id,
                    status: .paused,
                    nextPosition: nextPosition,
                    completedAssetCount: storage.snapshot().analyzedAssetCount,
                    updatedAt: run.updatedAt
                )
            }
        } catch {
            await markAnalysisFailed(
                run: &run,
                nextPosition: nextPosition,
                storage: storage.snapshot(),
                persistenceError: error,
                ledger: ledger,
                publisher: publisher
            )
            throw error
        }
        let finalStorage = storage.snapshot()
        let terminal = Self.analysisProgressUpdate(
            phase: .paused,
            storage: finalStorage,
            includesICloudItems: run.includesICloudItems,
            statusText: "Analysis paused. Resume when the app is active."
        )
        await publisher.finish(with: terminal)
        return OrganizeAnalysisWorkerResult(
            analysisByAssetID: records,
            analysisRun: run,
            nextPosition: nextPosition,
            presentation: terminal.presentation,
            storageProgress: finalStorage
        )
    }

    private func markAnalysisFailed(
        run: inout AnalysisRunRecord,
        nextPosition: Int,
        storage: OrganizeStorageAnalysisProgress,
        persistenceError: any Error,
        ledger: SQLiteLedger,
        publisher: OrganizeAnalysisProgressPublisher
    ) async {
        let message = "Analysis progress could not be saved: \(persistenceError.localizedDescription)"
        run.status = .failed
        run.updatedAt = Date()
        run.errorMessage = message
        try? await ledger.checkpointAnalysisRun(
            id: run.id,
            status: .failed,
            nextPosition: nextPosition,
            completedAssetCount: storage.analyzedAssetCount,
            updatedAt: run.updatedAt,
            errorMessage: message
        )
        await publisher.finish(
            with: Self.analysisProgressUpdate(
                phase: .failed,
                storage: storage,
                includesICloudItems: run.includesICloudItems,
                statusText: message
            )
        )
    }

    private static func analysisProgressUpdate(
        phase: OrganizeAnalysisPhase,
        storage: OrganizeStorageAnalysisProgress,
        includesICloudItems: Bool,
        currentAssetID: String? = nil,
        currentAssetFilename: String? = nil,
        currentAssetFraction: Double = 0,
        statusText: String
    ) -> OrganizeAnalysisProgressUpdate {
        OrganizeAnalysisProgressUpdate(
            presentation: OrganizeAnalysisPresentation(
                phase: phase,
                processedAssetCount: storage.processedAssetCount,
                completedAssetCount: storage.analyzedAssetCount,
                totalAssetCount: storage.totalAssetCount,
                currentAssetFraction: currentAssetID == nil ? 0 : min(max(currentAssetFraction, 0), 1),
                unavailableAssetCount: storage.unavailableAssetCount,
                failedAssetCount: storage.failedAssetCount,
                includesICloudItems: includesICloudItems,
                statusText: statusText
            ),
            storage: storage,
            currentAssetID: currentAssetID,
            currentAssetFilename: currentAssetFilename
        )
    }

    private static func analysisTerminalStatusText(
        storage: OrganizeStorageAnalysisProgress,
        includesICloudItems: Bool
    ) -> String {
        if storage.failedAssetCount > 0 {
            var issues: [String] = ["\(storage.failedAssetCount) failed"]
            if storage.unavailableAssetCount > 0 {
                issues.append("\(storage.unavailableAssetCount) require iCloud access")
            }
            return "Analysis finished with issues: \(issues.joined(separator: ", ")). Retry incomplete items."
        }
        if storage.unavailableAssetCount > 0 {
            return includesICloudItems
                ? "Analysis finished. \(storage.unavailableAssetCount) item(s) remain unavailable."
                : "Local analysis finished. \(storage.unavailableAssetCount) item(s) require iCloud access."
        }
        return "Library analysis is up to date. \(storage.analyzedAssetCount) item(s) sized."
    }

    func unavailableAnalysisCount(_ analysisByAssetID: [String: AssetAnalysisRecord]) -> Int {
        analysisByAssetID.values.reduce(into: 0) { count, record in
            if record.status == .unavailableLocally { count += 1 }
        }
    }

    func deletedItemIndex(_ items: [DeletedItemRecord]) -> [UUID: DeletedItemRecord] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    func domainReviewSession(
        from presentation: OrganizeReviewSessionPresentation,
        previous: ReviewSession?
    ) -> ReviewSession {
        var result = ReviewSession(
            id: presentation.id,
            recommendationKind: RecommendationKind(rawValue: presentation.recommendationKind.rawValue) ?? .unreviewed,
            orderedAssetIDs: presentation.assetIDs,
            createdAt: previous?.createdAt ?? Date()
        )
        result.updatedAt = Date()
        result.cursor = presentation.currentIndex
        result.decisions = Dictionary(uniqueKeysWithValues: presentation.decisions.map { key, value in
            (key, Self.reviewDecision(value))
        })
        result.actions = presentation.undoStack.enumerated().map { sequence, action in
            ReviewAction(
                id: action.id,
                sessionID: presentation.id,
                sequence: sequence,
                assetID: action.assetID,
                decision: Self.reviewDecision(action.choice),
                previousDecision: action.previousChoice.map(Self.reviewDecision),
                cursorBefore: action.previousIndex,
                cursorAfter: action.previousIndex + 1,
                createdAt: Date(),
                wasQueued: action.wasQueued,
                wasReviewed: action.wasReviewed
            )
        }
        result.status = presentation.isComplete ? .completed : .active
        return result
    }

    func persistReviewSession(
        from presentation: OrganizeReviewSessionPresentation,
        ledger: SQLiteLedger
    ) async throws -> OrganizeReviewPersistenceSnapshot {
        await acquireStateMutationLease()
        defer { releaseStateMutationLease() }
        try Task.checkCancellation()
        let session = domainReviewSession(
            from: presentation,
            previous: canonicalReviewSessionsByID[presentation.id]
        )
        try await ledger.saveReviewSession(session)
        canonicalReviewSessionsByID[session.id] = session
        if canonicalActiveReviewSession?.id != presentation.id {
            canonicalActiveReviewSession = presentation
        }
        canonicalStateDidChange()
        return reviewPersistenceSnapshot()
    }

    func persistReviewMutation(
        session: ReviewSession,
        action: ReviewActionPersistenceMutation,
        state: ReviewStatePersistenceMutation,
        queue: ReviewQueuePersistenceMutation,
        ledger: SQLiteLedger
    ) async throws -> OrganizeReviewPersistenceSnapshot {
        await acquireStateMutationLease()
        defer { releaseStateMutationLease() }
        try Task.checkCancellation()
        try await ledger.applyReviewMutation(
            session: session,
            action: action,
            state: state,
            queue: queue
        )

        var updatedSession = canonicalReviewSessionsByID[session.id] ?? session
        updatedSession.cursor = session.cursor
        updatedSession.status = session.status
        updatedSession.updatedAt = session.updatedAt
        switch action {
        case .none:
            break
        case let .append(value):
            updatedSession.actions.removeAll { $0.id == value.id || $0.sequence == value.sequence }
            updatedSession.actions.append(value)
            updatedSession.actions.sort { $0.sequence < $1.sequence }
            updatedSession.decisions[value.assetID] = value.decision
        case let .remove(actionID):
            if let removed = updatedSession.actions.first(where: { $0.id == actionID }) {
                if let previous = removed.previousDecision {
                    updatedSession.decisions[removed.assetID] = previous
                } else {
                    updatedSession.decisions.removeValue(forKey: removed.assetID)
                }
            }
            updatedSession.actions.removeAll { $0.id == actionID }
        }
        canonicalReviewSessionsByID[updatedSession.id] = updatedSession

        // The gesture API installed the newest active-session, review-state, and
        // queue presentation before this SQLite await began. Reapplying this older
        // persistence intent after actor reentrancy could regress a later review choice or
        // undo. Only the durable/domain session checkpoint advances here; canonical
        // presentation/state maps intentionally remain at their newest UI mutation.
        canonicalStateDidChange()
        return reviewPersistenceSnapshot()
    }

    func queueItems(
        requestedIDs: Set<String>,
        recommendations: [String: OrganizeRecommendationCategory],
        assetsByID: [String: PhotoAsset],
        protectedAssetIDs: Set<String>,
        existing: [String: DeletionQueueItem],
        activeSession: OrganizeReviewSessionPresentation?
    ) throws -> [String: DeletionQueueItem] {
        var replacement: [String: DeletionQueueItem] = [:]
        replacement.reserveCapacity(requestedIDs.count)
        for (index, assetID) in requestedIDs.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            guard let asset = assetsByID[assetID] else { continue }
            let sessionQueued = activeSession?.decisions[assetID] == .queueForRecentlyDeleted
            let sessionRecommendation = activeSession.flatMap {
                RecommendationKind(rawValue: $0.recommendationKind.rawValue)
            }
            let recommendation = recommendations[assetID]
                .flatMap { RecommendationKind(rawValue: $0.rawValue) }
                ?? (sessionQueued ? sessionRecommendation : nil)
            let old = existing[assetID]
            replacement[assetID] = DeletionQueueItem(
                assetID: assetID,
                sourceRevision: asset.sourceRevision,
                recommendationKind: recommendation ?? old?.recommendationKind,
                queuedAt: old?.queuedAt ?? Date(),
                protectionOverride: old?.protectionOverride ?? protectedAssetIDs.contains(assetID),
                reviewSessionID: sessionQueued ? activeSession?.id : old?.reviewSessionID
            )
        }
        return replacement
    }

    func replaceQueue(
        requestedIDs: Set<String>,
        recommendations: [String: OrganizeRecommendationCategory],
        assetsByID: [String: PhotoAsset],
        protectedAssetIDs: Set<String>,
        existing: [String: DeletionQueueItem],
        activeSession: OrganizeReviewSessionPresentation?,
        ledger: SQLiteLedger
    ) async throws -> [String: DeletionQueueItem] {
        await acquireStateMutationLease()
        defer { releaseStateMutationLease() }
        let replacement = try queueItems(
            requestedIDs: requestedIDs,
            recommendations: recommendations,
            assetsByID: hasCanonicalState ? canonicalAssetsByID : assetsByID,
            protectedAssetIDs: hasCanonicalState ? canonicalPresentedProtectedAssetIDs : protectedAssetIDs,
            existing: hasCanonicalState ? canonicalQueueByAssetID : existing,
            activeSession: activeSession
        )
        try await ledger.replaceRecentlyDeletedQueue(Array(replacement.values))
        canonicalQueueByAssetID = replacement
        rebuildCanonicalQueuePresentation()
        canonicalStateDidChange()
        return replacement
    }

    func applyQueueDelta(
        _ delta: OrganizeQueuePersistenceDelta,
        ledger: SQLiteLedger
    ) async throws -> [String: DeletionQueueItem] {
        await acquireStateMutationLease()
        defer { releaseStateMutationLease() }
        try Task.checkCancellation()

        var upserts: [DeletionQueueItem] = []
        var removals: [String] = []
        switch delta {
        case let .upsert(assetIDs, recommendationKind, allowProtected):
            upserts.reserveCapacity(assetIDs.count)
            let domainRecommendation = recommendationKind.flatMap {
                RecommendationKind(rawValue: $0.rawValue)
            }
            for (index, assetID) in assetIDs.enumerated() {
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                guard let asset = canonicalAssetsByID[assetID] else { continue }
                if canonicalPresentedProtectedAssetIDs.contains(assetID), !allowProtected { continue }
                let old = canonicalQueueByAssetID[assetID]
                upserts.append(
                    DeletionQueueItem(
                        assetID: assetID,
                        sourceRevision: asset.sourceRevision,
                        recommendationKind: domainRecommendation ?? old?.recommendationKind,
                        queuedAt: old?.queuedAt ?? Date(),
                        protectionOverride: old?.protectionOverride
                            ?? canonicalPresentedProtectedAssetIDs.contains(assetID),
                        reviewSessionID: old?.reviewSessionID
                    )
                )
            }
        case let .remove(assetIDs):
            removals = assetIDs
        }

        try await ledger.applyRecentlyDeletedQueueDelta(upserts: upserts, removals: removals)
        // UI mutations run ahead of their serialized writes. Preserve a newer
        // inverse gesture that may have entered this actor while SQLite suspended:
        // the worker-owned presentation Set is the latest intent for each ID.
        for assetID in removals where !canonicalQueuedAssetIDs.contains(assetID) {
            canonicalQueueByAssetID.removeValue(forKey: assetID)
        }
        for item in upserts where canonicalQueuedAssetIDs.contains(item.assetID) {
            canonicalQueueByAssetID[item.assetID] = item
        }
        canonicalStateDidChange()
        return canonicalQueueByAssetID
    }

    func synchronizeProtectedAlbums(
        requestedIDs: Set<String>,
        currentIDs: Set<String>,
        albumTitleByID: [String: String],
        assets: [PhotoAsset],
        albumIDsByAssetID: [String: [String]],
        ledger: SQLiteLedger
    ) async throws -> Set<String> {
        await acquireStateMutationLease()
        defer { releaseStateMutationLease() }
        let effectiveCurrentIDs = hasCanonicalState ? canonicalProtectedAlbumIDs : currentIDs
        let removedIDs = effectiveCurrentIDs.subtracting(requestedIDs)
        let addedIDs = requestedIDs.subtracting(effectiveCurrentIDs)
        for id in removedIDs { try await ledger.removeProtectedAlbum(id: id) }
        for id in addedIDs {
            try await ledger.saveProtectedAlbum(
                ProtectedAlbumRecord(
                    albumID: id,
                    title: (hasCanonicalState ? canonicalAlbumTitleByID[id] : albumTitleByID[id])
                        ?? "Protected Album",
                    protectedAt: Date()
                )
            )
        }
        let result = Self.protectedAssetIDs(
            assets: hasCanonicalState ? canonicalOrderedAssets : assets,
            albumIDsByAssetID: hasCanonicalState ? canonicalAlbumIDsByAssetID : albumIDsByAssetID,
            protectedAlbumIDs: requestedIDs,
            reviewStateByAssetID: hasCanonicalState ? canonicalReviewStateByAssetID : [:]
        )
        canonicalProtectedAlbumIDs = requestedIDs
        canonicalProtectedAssetIDs = result
        pendingProtectedAlbumPresentationDeltas.removeAll(keepingCapacity: false)
        rebuildCanonicalPresentedProtection()
        canonicalStateDidChange()
        return result
    }

    func applyProtectedAlbumDelta(
        _ delta: OrganizeProtectedAlbumPersistenceDelta,
        ledger: SQLiteLedger
    ) async throws -> OrganizeProtectionPersistenceSnapshot {
        await acquireStateMutationLease()
        defer { releaseStateMutationLease() }
        try Task.checkCancellation()
        if delta.isProtected {
            try await ledger.saveProtectedAlbum(
                ProtectedAlbumRecord(
                    albumID: delta.albumID,
                    title: canonicalAlbumTitleByID[delta.albumID] ?? "Protected Album",
                    protectedAt: Date()
                )
            )
            canonicalProtectedAlbumIDs.insert(delta.albumID)
        } else {
            try await ledger.removeProtectedAlbum(id: delta.albumID)
            canonicalProtectedAlbumIDs.remove(delta.albumID)
        }
        canonicalProtectedAssetIDs = Self.protectedAssetIDs(
            assets: canonicalOrderedAssets,
            albumIDsByAssetID: canonicalAlbumIDsByAssetID,
            protectedAlbumIDs: canonicalProtectedAlbumIDs,
            reviewStateByAssetID: canonicalReviewStateByAssetID
        )
        pendingProtectedAlbumPresentationDeltas.removeValue(forKey: delta.generation)
        rebuildCanonicalPresentedProtection()
        canonicalStateDidChange()
        return OrganizeProtectionPersistenceSnapshot(
            generation: delta.generation,
            protectedAlbumIDs: canonicalProtectedAlbumIDs,
            protectedAssetIDs: canonicalProtectedAssetIDs
        )
    }

    /// Drops one failed optimistic protection toggle and rebuilds the visible Set
    /// by replaying any newer queued deltas over the last durable canonical state.
    func rejectProtectedAlbumPresentationMutation(
        _ delta: OrganizeProtectedAlbumPersistenceDelta
    ) {
        pendingProtectedAlbumPresentationDeltas.removeValue(forKey: delta.generation)
        rebuildCanonicalPresentedProtection()
        canonicalPresentationDidChange()
    }

    func prepareAuditThumbnails(
        assets: [PhotoAsset],
        batchID: UUID,
        includeNetwork: Bool,
        now: Date,
        store: any AuditThumbnailStoring
    ) async throws -> [String: AuditThumbnailReference] {
        var result: [String: AuditThumbnailReference] = [:]
        result.reserveCapacity(assets.count)
        do {
            for (index, asset) in assets.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                result[asset.id] = try await store.prepareThumbnail(
                    assetID: asset.id,
                    batchID: batchID,
                    includeNetwork: includeNetwork,
                    now: now
                )
            }
            return result
        } catch {
            for reference in result.values {
                try? await store.removeThumbnail(relativePath: reference.relativePath)
            }
            throw error
        }
    }

    func removeAuditThumbnails(
        _ referencesByAssetID: [String: AuditThumbnailReference],
        store: any AuditThumbnailStoring
    ) async {
        for reference in referencesByAssetID.values {
            try? await store.removeThumbnail(relativePath: reference.relativePath)
        }
    }

    func cleanAuditThumbnails(
        relativePaths: [String],
        now: Date,
        store: any AuditThumbnailStoring
    ) async throws {
        for (index, path) in relativePaths.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            try? await store.removeThumbnail(relativePath: path)
        }
        try await store.removeExpired(now: now)
    }

    func removingQueueItems(
        assetIDs: [String],
        from items: [String: DeletionQueueItem]
    ) -> [String: DeletionQueueItem] {
        var result = items
        for id in assetIDs { result.removeValue(forKey: id) }
        return result
    }

    func removeQueueItems(
        assetIDs: [String],
        ledger: SQLiteLedger
    ) async throws -> [String: DeletionQueueItem] {
        await acquireStateMutationLease()
        defer { releaseStateMutationLease() }
        try Task.checkCancellation()
        try await ledger.applyRecentlyDeletedQueueDelta(upserts: [], removals: assetIDs)
        for assetID in assetIDs { canonicalQueueByAssetID.removeValue(forKey: assetID) }
        applyCanonicalQueuePresentationDelta(upserts: [], removals: assetIDs)
        canonicalStateDidChange()
        return canonicalQueueByAssetID
    }

    /// Mirrors the previous UI behavior after PhotoKit has already completed but the
    /// durable queue cleanup failed: hide confirmed items for this process while the
    /// unchanged database remains available for recovery on the next launch.
    func discardQueueItems(assetIDs: [String]) -> [String: DeletionQueueItem] {
        for assetID in assetIDs { canonicalQueueByAssetID.removeValue(forKey: assetID) }
        applyCanonicalQueuePresentationDelta(upserts: [], removals: assetIDs)
        canonicalStateDidChange()
        return canonicalQueueByAssetID
    }

    func addingDeletionHistory(
        batch: DeletionBatch,
        records: [DeletedItemRecord],
        batches: [DeletionBatch],
        items: [DeletedItemRecord],
        itemByID: [UUID: DeletedItemRecord]
    ) -> OrganizeDeletionHistoryState {
        var nextBatches = batches
        nextBatches.insert(batch, at: 0)
        var nextItems = items
        nextItems.insert(contentsOf: records, at: 0)
        var nextIndex = itemByID
        for record in records { nextIndex[record.id] = record }
        return OrganizeDeletionHistoryState(
            batches: nextBatches,
            items: nextItems,
            itemByID: nextIndex
        )
    }

    func deletedBatchPresentation(
        batch: DeletionBatch,
        records: [DeletedItemRecord]
    ) -> OrganizeDeletedBatchPresentation {
        let status: OrganizeDeletedRecordStatus = batch.status == .movedToRecentlyDeleted
            ? .movedToRecentlyDeleted
            : .confirmationInterrupted
        return OrganizeDeletedBatchPresentation(
            id: batch.id,
            deletedAt: batch.completedAt ?? batch.requestedAt,
            records: records.map {
                OrganizeDeletedItemPresentation(
                    id: $0.id,
                    sourceAssetID: $0.sourceLocalIdentifier,
                    sourceRevision: $0.sourceRevision,
                    originalFilename: $0.originalFilename,
                    mediaKind: $0.mediaKind,
                    captureDate: $0.creationDate,
                    deletedAt: $0.deletedAt,
                    pixelWidth: $0.pixelWidth,
                    pixelHeight: $0.pixelHeight,
                    durationMilliseconds: $0.durationMilliseconds,
                    knownBytes: $0.knownByteCount,
                    recommendationSource: $0.recommendationKind.map { Self.deletionRecommendationTitle($0) }
                        ?? "Manual Review",
                    isFavorite: $0.isFavorite,
                    isHidden: $0.isHidden,
                    isEdited: $0.isEdited,
                    isLivePhoto: $0.isLivePhoto,
                    isRAW: $0.isRaw,
                    status: status,
                    thumbnailExpiresAt: $0.thumbnailExpiresAt
                )
            },
            photoKitResult: status == .movedToRecentlyDeleted
                ? "Moved to Recently Deleted"
                : "Apple Photos result was not recorded; verify this batch in Apple Photos."
        )
    }

    private static func deletionRecommendationTitle(_ kind: RecommendationKind) -> String {
        switch kind {
        case .exactDuplicates: "Exact Duplicates"
        case .screenshots: "Screenshots"
        case .screenRecordings: "Screen Recordings"
        case .oldScreenshots: "Old Screenshots"
        case .veryShortVideos: "Very Short Videos"
        case .tinyImages: "Tiny Images"
        case .largeVideos: "Large Videos"
        case .largeSpecialtyMedia: "Large Specialty Media"
        case .bursts: "Bursts"
        case .rapidRetakes: "Rapid Retakes"
        case .similarPhotos: "Similar Photos"
        case .similarScreenshots: "Similar Screenshots"
        case .worthReviewing: "Worth Reviewing"
        case .textHeavyDocuments: "Documents & References"
        case .noClearSubject: "No Clear Subject"
        case .smudgedCaptures: "Possible Lens Smudge"
        case .decideLater: "Decide Later"
        case .noAlbum: "Not in an Album"
        case .unreviewed: "Unreviewed"
        }
    }

    func deletionRequestPlan(
        assetIDs: [String],
        queueByAssetID: [String: DeletionQueueItem]
    ) throws -> OrganizeDeletionRequestPlan {
        var items: [String: DeletionQueueItem] = [:]
        var requests: [PhotoAssetRevalidationRequest] = []
        items.reserveCapacity(assetIDs.count)
        requests.reserveCapacity(assetIDs.count)
        for (index, assetID) in assetIDs.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            guard let item = queueByAssetID[assetID] else { continue }
            items[assetID] = item
            requests.append(
                PhotoAssetRevalidationRequest(
                    assetID: assetID,
                    expectedSourceRevision: item.sourceRevision
                )
            )
        }
        return OrganizeDeletionRequestPlan(requestedItemsByID: items, requests: requests)
    }

    /// Performs the proportional membership comparison on the worker actor. The
    /// caller separately validates its constant-time intent generation immediately
    /// before and after this hop.
    func deletionQueueExactlyMatches(assetIDs: [String]) -> Bool {
        guard !Task.isCancelled,
              assetIDs.count == canonicalQueueByAssetID.count else { return false }
        var seen: Set<String> = []
        seen.reserveCapacity(assetIDs.count)
        for assetID in assetIDs {
            guard seen.insert(assetID).inserted,
                  canonicalQueueByAssetID[assetID] != nil else { return false }
        }
        return true
    }

    func beginReview(
        recommendationKind: OrganizeRecommendationCategory
    ) -> OrganizeReviewSessionPresentation? {
        if let existing = canonicalActiveReviewSession,
           existing.recommendationKind == recommendationKind,
           !existing.isComplete {
            return existing
        }
        guard let recommendation = (canonicalReviewRecommendations + canonicalOrganizeRecommendations)
            .first(where: { $0.kind == recommendationKind }) else { return nil }
        let remainingAssetIDs: [String]
        if recommendation.destination == .review {
            remainingAssetIDs = recommendation.assetIDs.filter { assetID in
                guard let index = canonicalPresentationAssetIndexByID[assetID],
                      canonicalPresentationAssets.indices.contains(index) else { return false }
                return !canonicalPresentationAssets[index].isReviewed
            }
        } else {
            remainingAssetIDs = recommendation.assetIDs
        }
        guard !remainingAssetIDs.isEmpty else { return nil }
        let session = OrganizeReviewSessionPresentation(
            id: UUID(),
            recommendationKind: recommendation.kind,
            title: recommendation.title,
            reason: recommendation.detail,
            assetIDs: remainingAssetIDs,
            currentIndex: 0,
            decisions: [:],
            undoStack: [],
            evidenceByAssetID: recommendation.evidenceByAssetID
        )
        canonicalActiveReviewSession = session
        canonicalReviewDecisionAssetIDs = [:]
        canonicalReviewDecisionAssetIndexByID = [:]
        canonicalPresentationDidChange()
        return session
    }

    func applyReviewChoice(
        _ request: OrganizeReviewChoiceMutationRequest
    ) throws -> OrganizeReviewPresentationMutationResult? {
        guard var session = canonicalActiveReviewSession,
              session.id == request.sessionID,
              let assetID = session.currentAssetID,
              let assetIndex = canonicalPresentationAssetIndexByID[assetID],
              canonicalPresentationAssets.indices.contains(assetIndex) else { return nil }
        let asset = canonicalPresentationAssets[assetIndex]
        if request.choice == .queueForRecentlyDeleted,
           canonicalPresentedProtectedAssetIDs.contains(assetID),
           !request.allowProtected {
            return nil
        }
        let action = OrganizeReviewActionPresentation(
            id: UUID(),
            assetID: assetID,
            choice: request.choice,
            previousChoice: session.decisions[assetID],
            previousIndex: session.currentIndex,
            wasQueued: canonicalQueuedAssetIDs.contains(assetID),
            wasReviewed: asset.isReviewed
        )
        session.undoStack.append(action)
        session.decisions[assetID] = request.choice
        session.currentIndex += 1
        canonicalActiveReviewSession = session
        if let previousChoice = action.previousChoice {
            removeCanonicalReviewDecisionAsset(assetID, choice: previousChoice)
        }
        addCanonicalReviewDecisionAsset(assetID, choice: request.choice)

        let queue: OrganizeQueueSelectionResult
        switch request.choice {
        case .keep:
            canonicalPresentationAssets[assetIndex].isReviewed = true
            queue = try removeQueueAssets(assetIDs: [assetID])
        case .queueForRecentlyDeleted:
            canonicalPresentationAssets[assetIndex].isReviewed = true
            queue = try queueSelection(
                requestedIDs: [assetID],
                allowProtected: request.allowProtected,
                recommendationKind: session.recommendationKind
            )
        case .later:
            queue = canonicalQueuePresentationResult()
        }
        optimisticallySetReviewState(
            assetID: assetID,
            choice: request.choice,
            recommendationKind: session.recommendationKind
        )
        canonicalPresentationDidChange()
        return OrganizeReviewPresentationMutationResult(
            session: session,
            action: action,
            assetID: assetID,
            previousChoice: action.previousChoice,
            currentChoice: request.choice,
            isReviewed: canonicalPresentationAssets[assetIndex].isReviewed,
            queue: queue,
            reviewDecisionAssetIDs: canonicalReviewDecisionAssetIDs,
            reviewDecisionAssetIndexByID: canonicalReviewDecisionAssetIndexByID
        )
    }

    func undoReviewChoice(
        sessionID: UUID
    ) throws -> OrganizeReviewPresentationMutationResult? {
        guard var session = canonicalActiveReviewSession,
              session.id == sessionID,
              let action = session.undoStack.popLast(),
              let assetIndex = canonicalPresentationAssetIndexByID[action.assetID],
              canonicalPresentationAssets.indices.contains(assetIndex) else { return nil }
        session.currentIndex = action.previousIndex
        if let previousChoice = action.previousChoice {
            session.decisions[action.assetID] = previousChoice
        } else {
            session.decisions.removeValue(forKey: action.assetID)
        }
        canonicalActiveReviewSession = session
        removeCanonicalReviewDecisionAsset(action.assetID, choice: action.choice)
        if let previousChoice = action.previousChoice {
            addCanonicalReviewDecisionAsset(action.assetID, choice: previousChoice)
        }
        canonicalPresentationAssets[assetIndex].isReviewed = action.wasReviewed
        let queue: OrganizeQueueSelectionResult
        if action.wasQueued {
            queue = try queueSelection(
                requestedIDs: [action.assetID],
                allowProtected: true,
                recommendationKind: session.recommendationKind
            )
        } else {
            queue = try removeQueueAssets(assetIDs: [action.assetID])
        }
        optimisticallySetReviewState(
            assetID: action.assetID,
            choice: action.previousChoice,
            recommendationKind: session.recommendationKind
        )
        canonicalPresentationDidChange()
        return OrganizeReviewPresentationMutationResult(
            session: session,
            action: action,
            assetID: action.assetID,
            previousChoice: action.choice,
            currentChoice: action.previousChoice,
            isReviewed: action.wasReviewed,
            queue: queue,
            reviewDecisionAssetIDs: canonicalReviewDecisionAssetIDs,
            reviewDecisionAssetIndexByID: canonicalReviewDecisionAssetIndexByID
        )
    }

    func queueSelection(
        requestedIDs: Set<String>,
        allowProtected: Bool,
        recommendationKind: OrganizeRecommendationCategory?,
        assets: [OrganizeAssetPresentation],
        assetIndexByID: [String: Int],
        queuedAssetIDs currentIDs: Set<String>,
        queuedAssets currentAssets: [OrganizeAssetPresentation],
        queuedAssetIndexByID currentIndex: [String: Int],
        queuedAssetIDsInOrder currentOrder: [String],
        queueKnownBytes currentBytes: Int64,
        recommendationKinds currentKinds: [String: OrganizeRecommendationCategory]
    ) throws -> OrganizeQueueSelectionResult {
        var protected: [OrganizeAssetPresentation] = []
        for (offset, id) in requestedIDs.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            guard let index = assetIndexByID[id], assets.indices.contains(index) else { continue }
            if assets[index].isProtected { protected.append(assets[index]) }
        }
        guard protected.isEmpty || allowProtected else {
            return OrganizeQueueSelectionResult(
                protectedAssets: protected,
                queuedAssetIDs: currentIDs,
                queuedAssets: currentAssets,
                queuedAssetIndexByID: currentIndex,
                queuedAssetIDsInOrder: currentOrder,
                queueKnownBytes: currentBytes,
                recommendationKinds: currentKinds
            )
        }
        var ids = currentIDs
        var queued = currentAssets
        var indexByID = currentIndex
        var order = currentOrder
        var bytes = currentBytes
        var kinds = currentKinds
        for (offset, id) in requestedIDs.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            guard let assetIndex = assetIndexByID[id],
                  assets.indices.contains(assetIndex) else { continue }
            guard ids.insert(id).inserted else { continue }
            let asset = assets[assetIndex]
            indexByID[id] = queued.count
            queued.append(asset)
            order.append(id)
            bytes = Self.saturatingAdd(bytes, asset.knownBytes ?? 0)
            if let recommendationKind, kinds[id] == nil { kinds[id] = recommendationKind }
        }
        return OrganizeQueueSelectionResult(
            protectedAssets: [],
            queuedAssetIDs: ids,
            queuedAssets: queued,
            queuedAssetIndexByID: indexByID,
            queuedAssetIDsInOrder: order,
            queueKnownBytes: bytes,
            recommendationKinds: kinds
        )
    }

    /// Production queue mutation boundary. Only the affected IDs cross from the UI;
    /// every queue-sized collection used to calculate the replacement is worker-owned.
    func queueSelection(
        requestedIDs: Set<String>,
        allowProtected: Bool,
        recommendationKind: OrganizeRecommendationCategory?
    ) throws -> OrganizeQueueSelectionResult {
        var protected: [OrganizeAssetPresentation] = []
        for (offset, assetID) in requestedIDs.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            guard canonicalPresentedProtectedAssetIDs.contains(assetID),
                  let index = canonicalPresentationAssetIndexByID[assetID],
                  canonicalPresentationAssets.indices.contains(index) else { continue }
            protected.append(canonicalPresentationAssets[index])
        }
        if !protected.isEmpty, !allowProtected {
            return canonicalQueuePresentationResult(protectedAssets: protected)
        }
        let result = try queueSelection(
            requestedIDs: requestedIDs,
            allowProtected: true,
            recommendationKind: recommendationKind,
            assets: canonicalPresentationAssets,
            assetIndexByID: canonicalPresentationAssetIndexByID,
            queuedAssetIDs: canonicalQueuedAssetIDs,
            queuedAssets: canonicalQueuedAssets,
            queuedAssetIndexByID: canonicalQueuedAssetIndexByID,
            queuedAssetIDsInOrder: canonicalQueuedAssetIDsInOrder,
            queueKnownBytes: canonicalQueueKnownBytes,
            recommendationKinds: canonicalQueuedRecommendationKinds
        )
        guard result.protectedAssets.isEmpty || allowProtected else { return result }
        optimisticallyUpsertQueue(
            assetIDs: requestedIDs,
            recommendationKind: recommendationKind,
            allowProtected: allowProtected
        )
        installCanonicalQueuePresentation(result)
        return result
    }

    func compactQueuePresentation() throws -> OrganizeQueueSelectionResult {
        let result = try Self.compactQueuePresentation(
            desiredIDs: canonicalQueuedAssetIDs,
            queuedAssets: canonicalQueuedAssets,
            recommendationKinds: canonicalQueuedRecommendationKinds
        )
        canonicalQueueByAssetID = canonicalQueueByAssetID.filter {
            result.queuedAssetIDs.contains($0.key)
        }
        installCanonicalQueuePresentation(result)
        return result
    }

    func removeQueueAssets(
        assetIDs: [String],
        additionalAssetIDs: [String] = []
    ) throws -> OrganizeQueueSelectionResult {
        let result = try removeQueueAssets(
            assetIDs: assetIDs,
            additionalAssetIDs: additionalAssetIDs,
            currentIDs: canonicalQueuedAssetIDs,
            queuedAssets: canonicalQueuedAssets,
            recommendationKinds: canonicalQueuedRecommendationKinds
        )
        for assetID in assetIDs { canonicalQueueByAssetID.removeValue(forKey: assetID) }
        for assetID in additionalAssetIDs { canonicalQueueByAssetID.removeValue(forKey: assetID) }
        installCanonicalQueuePresentation(result)
        return result
    }

    func removeQueueRecords(
        _ records: [OrganizeDeletedItemPresentation]
    ) throws -> OrganizeQueueSelectionResult {
        let result = try removeQueueRecords(
            records,
            currentIDs: canonicalQueuedAssetIDs,
            queuedAssets: canonicalQueuedAssets,
            recommendationKinds: canonicalQueuedRecommendationKinds
        )
        for record in records {
            canonicalQueueByAssetID.removeValue(forKey: record.sourceAssetID)
        }
        installCanonicalQueuePresentation(result)
        return result
    }

    /// Marks one queued asset as kept and removes it from the canonical queue in
    /// the same non-suspending actor operation. This is intentionally distinct
    /// from durable queue persistence: the caller still submits the matching
    /// `.remove` delta after installing the optimistic presentation result.
    func markQueuedAssetReviewedAndRemove(
        assetID: String
    ) throws -> OrganizeQueuedAssetReviewMutationResult {
        let recommendationKind = canonicalQueuedRecommendationKinds[assetID]
        var isReviewed = false
        if let index = canonicalPresentationAssetIndexByID[assetID],
           canonicalPresentationAssets.indices.contains(index) {
            canonicalPresentationAssets[index].isReviewed = true
            isReviewed = true
            optimisticallySetReviewState(
                assetID: assetID,
                choice: .keep,
                recommendationKind: recommendationKind
            )
        }
        let queue = try removeQueueAssets(assetIDs: [assetID])
        return OrganizeQueuedAssetReviewMutationResult(
            assetID: assetID,
            isReviewed: isReviewed,
            queue: queue
        )
    }

    func mutateSelection(
        _ mutation: OrganizeSelectionMutation
    ) -> OrganizeSelectionMutationResult {
        switch mutation {
        case let .toggle(assetID):
            guard canonicalPresentationAssetIndexByID[assetID] != nil else {
                return OrganizeSelectionMutationResult(selectedAssetIDs: canonicalSelectedAssetIDs)
            }
            if !canonicalSelectedAssetIDs.insert(assetID).inserted {
                canonicalSelectedAssetIDs.remove(assetID)
            }
        case .clear:
            canonicalSelectedAssetIDs.removeAll(keepingCapacity: false)
        }
        canonicalPresentationDidChange()
        return OrganizeSelectionMutationResult(selectedAssetIDs: canonicalSelectedAssetIDs)
    }

    /// Produces the optimistic protection-toggle replacement off-main without
    /// changing durable/canonical protection state. The subsequent persistence
    /// callback commits the delta and installs canonical asset protection; on
    /// failure, the coordinator's render naturally restores the prior state.
    func protectedAlbumPresentationMutation(
        _ delta: OrganizeProtectedAlbumPersistenceDelta
    ) -> OrganizeProtectedAlbumPresentationMutationResult {
        pendingProtectedAlbumPresentationDeltas[delta.generation] = delta
        rebuildCanonicalPresentedProtection()
        canonicalPresentationDidChange()
        return OrganizeProtectedAlbumPresentationMutationResult(
            generation: delta.generation,
            albumID: delta.albumID,
            isProtected: delta.isProtected,
            protectedAlbumIDs: canonicalPresentedProtectedAlbumIDs
        )
    }

    func compactQueuePresentation(
        desiredIDs: Set<String>,
        queuedAssets: [OrganizeAssetPresentation],
        recommendationKinds: [String: OrganizeRecommendationCategory]
    ) throws -> OrganizeQueueSelectionResult {
        try Self.compactQueuePresentation(
            desiredIDs: desiredIDs,
            queuedAssets: queuedAssets,
            recommendationKinds: recommendationKinds
        )
    }

    func removeQueueAssets(
        assetIDs: [String],
        additionalAssetIDs: [String] = [],
        currentIDs: Set<String>,
        queuedAssets: [OrganizeAssetPresentation],
        recommendationKinds: [String: OrganizeRecommendationCategory]
    ) throws -> OrganizeQueueSelectionResult {
        var removedIDs = Set<String>()
        removedIDs.reserveCapacity(assetIDs.count + additionalAssetIDs.count)
        for (index, id) in assetIDs.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            removedIDs.insert(id)
        }
        for (index, id) in additionalAssetIDs.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            removedIDs.insert(id)
        }
        return try Self.compactQueuePresentation(
            desiredIDs: currentIDs.subtracting(removedIDs),
            queuedAssets: queuedAssets,
            recommendationKinds: recommendationKinds
        )
    }

    func removeQueueRecords(
        _ records: [OrganizeDeletedItemPresentation],
        currentIDs: Set<String>,
        queuedAssets: [OrganizeAssetPresentation],
        recommendationKinds: [String: OrganizeRecommendationCategory]
    ) throws -> OrganizeQueueSelectionResult {
        var removedIDs = Set<String>()
        removedIDs.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            removedIDs.insert(record.sourceAssetID)
        }
        return try Self.compactQueuePresentation(
            desiredIDs: currentIDs.subtracting(removedIDs),
            queuedAssets: queuedAssets,
            recommendationKinds: recommendationKinds
        )
    }

    func upsertingDeletedBatch(
        _ batch: OrganizeDeletedBatchPresentation,
        in batches: [OrganizeDeletedBatchPresentation]
    ) throws -> [OrganizeDeletedBatchPresentation] {
        var result: [OrganizeDeletedBatchPresentation] = [batch]
        result.reserveCapacity(batches.count + 1)
        for (index, existing) in batches.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if existing.id != batch.id { result.append(existing) }
        }
        return result
    }

    func deletionValidationPlan(
        requestedAssetIDs: [String],
        requestPlan: OrganizeDeletionRequestPlan,
        validation: [PhotoAssetRevalidationResult],
        protectedAssetIDs: Set<String>,
        analysisByAssetID: [String: AssetAnalysisRecord]
    ) throws -> OrganizeDeletionValidationPlan {
        var missing = Set(requestedAssetIDs).subtracting(requestPlan.requestedItemsByID.keys)
        var changed: Set<String> = []
        var currentAssets: [PhotoAsset] = []
        currentAssets.reserveCapacity(validation.count)
        var knownBytes: Int64 = 0
        for (index, result) in validation.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            switch result.status {
            case .missing:
                missing.insert(result.request.assetID)
            case .changed:
                changed.insert(result.request.assetID)
            case .unchanged:
                guard let asset = result.currentAsset,
                      let queueItem = requestPlan.requestedItemsByID[result.request.assetID] else { continue }
                let protected = asset.isFavorite || asset.isHidden
                    || protectedAssetIDs.contains(asset.id)
                if protected, !queueItem.protectionOverride {
                    changed.insert(asset.id)
                } else {
                    currentAssets.append(asset)
                    knownBytes = Self.saturatingAdd(
                        knownBytes,
                        analysisByAssetID[asset.id]?.knownByteCount ?? 0
                    )
                }
            }
        }
        let requiringReview = missing.union(changed).sorted()
        return OrganizeDeletionValidationPlan(
            missingAssetIDs: missing.sorted(),
            changedAssetIDs: changed.sorted(),
            requiringReviewAssetIDs: requiringReview,
            currentAssets: currentAssets,
            currentAssetIDs: currentAssets.map(\.id),
            knownBytes: knownBytes
        )
    }

    func preparedDeletionPlan(
        currentAssets: [PhotoAsset],
        batchID: UUID,
        requestedAt: Date,
        requestPlan: OrganizeDeletionRequestPlan,
        thumbnailsByAssetID: [String: AuditThumbnailReference],
        analysisByAssetID: [String: AssetAnalysisRecord],
        knownBytes: Int64
    ) throws -> OrganizePreparedDeletionPlan {
        var records: [DeletedItemRecord] = []
        records.reserveCapacity(currentAssets.count)
        for (index, asset) in currentAssets.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let thumbnail = thumbnailsByAssetID[asset.id]
            records.append(
                DeletedItemRecord(
                    id: UUID(),
                    batchID: batchID,
                    sourceLocalIdentifier: asset.id,
                    sourceRevision: asset.sourceRevision,
                    originalFilename: asset.resources.map(\.originalFilename).sorted().first
                        ?? (asset.mediaKind == .video ? "Video" : "Photo"),
                    mediaKind: asset.mediaKind,
                    creationDate: asset.creationDate,
                    deletedAt: requestedAt,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    durationMilliseconds: asset.durationMilliseconds,
                    knownByteCount: analysisByAssetID[asset.id]?.knownByteCount,
                    recommendationKind: requestPlan.requestedItemsByID[asset.id]?.recommendationKind,
                    isLivePhoto: asset.mediaSubtypes.contains(.livePhoto),
                    isRaw: asset.mediaSubtypes.contains(.raw),
                    isFavorite: asset.isFavorite,
                    isHidden: asset.isHidden,
                    isEdited: asset.isEdited,
                    result: .prepared,
                    thumbnailRelativePath: thumbnail?.relativePath,
                    thumbnailExpiresAt: thumbnail?.expiresAt
                )
            )
        }
        return OrganizePreparedDeletionPlan(
            records: records,
            batch: DeletionBatch(
                id: batchID,
                requestedAt: requestedAt,
                completedAt: nil,
                status: .preparing,
                itemCount: records.count,
                knownByteCount: knownBytes,
                errorMessage: nil
            )
        )
    }

    func confirmedDeletionRecords(
        _ records: [DeletedItemRecord],
        deletedAt: Date
    ) -> [DeletedItemRecord] {
        records.map { record in
            DeletedItemRecord(
                id: record.id,
                batchID: record.batchID,
                sourceLocalIdentifier: record.sourceLocalIdentifier,
                sourceRevision: record.sourceRevision,
                originalFilename: record.originalFilename,
                mediaKind: record.mediaKind,
                creationDate: record.creationDate,
                deletedAt: deletedAt,
                pixelWidth: record.pixelWidth,
                pixelHeight: record.pixelHeight,
                durationMilliseconds: record.durationMilliseconds,
                knownByteCount: record.knownByteCount,
                recommendationKind: record.recommendationKind,
                isLivePhoto: record.isLivePhoto,
                isRaw: record.isRaw,
                isFavorite: record.isFavorite,
                isHidden: record.isHidden,
                isEdited: record.isEdited,
                result: .movedToRecentlyDeleted,
                thumbnailRelativePath: record.thumbnailRelativePath,
                thumbnailExpiresAt: record.thumbnailExpiresAt
            )
        }
    }

    func presentation(for input: OrganizePresentationInput) async throws -> OrganizePresentationSnapshot {
        guard input.revision >= latestPresentationRevision else { throw CancellationError() }
        latestPresentationRevision = max(latestPresentationRevision, input.revision)
        presentationTask?.cancel()
        presentationBuildInvocationCount &+= 1
        let stateRevision = canonicalStateRevision
        let presentationMutationRevision = canonicalPresentationMutationRevision
        let buildInput: OrganizePresentationInput
        if hasCanonicalState {
            buildInput = OrganizePresentationInput(
                revision: input.revision,
                authorization: input.authorization,
                assets: canonicalOrderedAssets,
                albums: canonicalAlbums,
                albumIDsByAssetID: canonicalAlbumIDsByAssetID,
                sourceRevisionByAssetID: canonicalSourceRevisionByAssetID,
                analysisByAssetID: input.analysisByAssetID,
                visualAnalysisByAssetID: input.visualAnalysisByAssetID,
                analysisRun: input.analysisRun,
                reviewStateByAssetID: canonicalReviewStateByAssetID,
                queueByAssetID: canonicalQueueByAssetID,
                reviewSessionsByID: canonicalReviewSessionsByID,
                protectedAlbumIDs: canonicalPresentedProtectedAlbumIDs,
                protectedAssetIDs: canonicalPresentedProtectedAssetIDs,
                deletionBatches: input.deletionBatches,
                deletedItems: input.deletedItems,
                activeReviewSessionOverride: canonicalActiveReviewSession,
                analysisOverride: input.analysisOverride,
                selectedAssetIDs: canonicalSelectedAssetIDs
            )
        } else {
            buildInput = input
        }
        let task = Task.detached(priority: .userInitiated) {
            try OrganizePresentationBuilder.build(buildInput)
        }
        presentationTask = task
        let snapshot = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard input.revision == latestPresentationRevision,
              stateRevision == canonicalStateRevision,
              presentationMutationRevision == canonicalPresentationMutationRevision else {
            throw CancellationError()
        }
        if input.revision == latestPresentationRevision { presentationTask = nil }
        installCanonicalPresentation(snapshot)
        return snapshot
    }

    func browse(
        _ query: OrganizeBrowseQuery,
        assets: [OrganizeAssetPresentation]
    ) async throws -> OrganizeBrowseQueryResult {
        if let latestBrowseQuery {
            guard query.revision > latestBrowseQuery.revision
                    || (query.revision == latestBrowseQuery.revision && query.sequence >= latestBrowseQuery.sequence)
            else { throw CancellationError() }
        }
        latestBrowseQuery = query
        browseTask?.cancel()
        let presentationMutationRevision = canonicalPresentationMutationRevision
        let task = Task.detached(priority: .userInitiated) {
            let sections = try OrganizeBrowseQueryEngine.sections(for: query, assets: assets)
            return OrganizeBrowseQueryResult(query: query, sections: sections)
        }
        browseTask = task
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard latestBrowseQuery == query,
              presentationMutationRevision == canonicalPresentationMutationRevision else {
            throw CancellationError()
        }
        if latestBrowseQuery == query { browseTask = nil }
        return result
    }

    /// Production browse boundary. Scope keys resolve against the worker-owned
    /// recommendation snapshot, so neither the whole asset array nor a recommendation-
    /// sized ID set remains aliased to mutable MainActor presentation state.
    func browse(_ query: OrganizeBrowseQuery) async throws -> OrganizeBrowseQueryResult {
        let scopeIDs: Set<String>? = if query.scopeKey == "all" {
            nil
        } else {
            (canonicalReviewRecommendations + canonicalOrganizeRecommendations)
                .first(where: { $0.kind.rawValue == query.scopeKey })?
                .assetIDSet
                ?? []
        }
        let resolved = OrganizeBrowseQuery(
            revision: query.revision,
            contentRevision: query.contentRevision,
            sequence: query.sequence,
            scopeKey: query.scopeKey,
            scopeAssetIDs: scopeIDs,
            configuration: query.configuration
        )
        return try await browse(resolved, assets: canonicalPresentationAssets)
    }

    func deletedHistory(
        _ query: OrganizeDeletedHistoryQuery,
        batches: [OrganizeDeletedBatchPresentation]
    ) async throws -> OrganizeDeletedHistoryResult {
        if let latestDeletedHistoryQuery {
            guard query.revision > latestDeletedHistoryQuery.revision
                    || (query.revision == latestDeletedHistoryQuery.revision
                        && query.sequence >= latestDeletedHistoryQuery.sequence)
            else { throw CancellationError() }
        }
        latestDeletedHistoryQuery = query
        deletedHistoryTask?.cancel()
        let task = Task.detached(priority: .userInitiated) {
            let search = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !search.isEmpty else {
                return OrganizeDeletedHistoryResult(query: query, batches: batches)
            }
            var filtered: [OrganizeDeletedBatchPresentation] = []
            filtered.reserveCapacity(batches.count)
            for (index, batch) in batches.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                var records: [OrganizeDeletedItemPresentation] = []
                records.reserveCapacity(batch.records.count)
                for (recordIndex, record) in batch.records.enumerated() {
                    if recordIndex.isMultiple(of: 128) { try Task.checkCancellation() }
                    if record.originalFilename.localizedCaseInsensitiveContains(search)
                        || record.recommendationSource.localizedCaseInsensitiveContains(search)
                        || record.mediaKind.rawValue.localizedCaseInsensitiveContains(search) {
                        records.append(record)
                    }
                }
                if !records.isEmpty {
                    filtered.append(
                        OrganizeDeletedBatchPresentation(
                            id: batch.id,
                            deletedAt: batch.deletedAt,
                            records: records,
                            photoKitResult: batch.photoKitResult
                        )
                    )
                }
            }
            return OrganizeDeletedHistoryResult(query: query, batches: filtered)
        }
        deletedHistoryTask = task
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard latestDeletedHistoryQuery == query else { throw CancellationError() }
        deletedHistoryTask = nil
        return result
    }

    private static func protectedAssetIDs(
        assets: [PhotoAsset],
        albumIDsByAssetID: [String: [String]],
        protectedAlbumIDs: Set<String>,
        reviewStateByAssetID: [String: AssetReviewStateRecord] = [:]
    ) -> Set<String> {
        var result: Set<String> = []
        result.reserveCapacity(assets.count / 4)
        for asset in assets {
            if isProtected(
                asset: asset,
                albumIDs: albumIDsByAssetID[asset.id] ?? [],
                protectedAlbumIDs: protectedAlbumIDs,
                reviewState: reviewStateByAssetID[asset.id]
            ) {
                result.insert(asset.id)
            }
        }
        return result
    }

    private static func isProtected(
        asset: PhotoAsset,
        albumIDs: [String],
        protectedAlbumIDs: Set<String>,
        reviewState: AssetReviewStateRecord?
    ) -> Bool {
        let isKept = reviewState.map { record in
            record.sourceRevision == asset.sourceRevision && record.state == .kept
        } == true
        return asset.isFavorite
            || asset.isHidden
            || asset.isEdited
            || asset.mediaSubtypes.contains(.raw)
            || isKept
            || albumIDs.contains(where: protectedAlbumIDs.contains)
    }

    private func reviewPersistenceSnapshot() -> OrganizeReviewPersistenceSnapshot {
        OrganizeReviewPersistenceSnapshot(
            reviewStateByAssetID: canonicalReviewStateByAssetID,
            queueByAssetID: canonicalQueueByAssetID,
            reviewSessionsByID: canonicalReviewSessionsByID
        )
    }

    private func installCanonicalPresentation(_ snapshot: OrganizePresentationSnapshot) {
        canonicalPresentationAssets = snapshot.assets
        canonicalPresentationAssetIndexByID = snapshot.assetIndexByID
        canonicalQueuedAssetIDs = snapshot.queuedAssetIDs
        canonicalQueuedAssets = snapshot.queuedAssets
        canonicalQueuedAssetIndexByID = snapshot.queuedAssetIndexByID
        canonicalQueuedAssetIDsInOrder = snapshot.queuedAssetIDsInOrder
        canonicalQueueKnownBytes = snapshot.queueKnownBytes
        canonicalQueuedRecommendationKinds = snapshot.queuedRecommendationKinds
        canonicalSelectedAssetIDs = snapshot.retainedSelectedAssetIDs
        canonicalActiveReviewSession = snapshot.activeReviewSession
        canonicalReviewRecommendations = snapshot.reviewRecommendations
        canonicalOrganizeRecommendations = snapshot.organizeRecommendations
        canonicalReviewDecisionAssetIDs = snapshot.reviewDecisionAssetIDs
        canonicalReviewDecisionAssetIndexByID = snapshot.reviewDecisionAssetIndexByID
        canonicalDerivedProtectedAssetIDs = Set(
            snapshot.reviewRecommendations
                .first(where: { $0.kind == .textHeavyDocuments })?
                .assetIDs ?? []
        )
        if pendingProtectedAlbumPresentationDeltas.isEmpty {
            canonicalPresentedProtectedAlbumIDs = snapshot.protectedAlbumIDs
            canonicalPresentedProtectedAssetIDs = canonicalProtectedAssetIDs
                .union(canonicalDerivedProtectedAssetIDs)
        } else {
            rebuildCanonicalPresentedProtection()
        }
        canonicalPresentationDidChange()
    }

    private func installCanonicalQueuePresentation(_ result: OrganizeQueueSelectionResult) {
        canonicalQueuedAssetIDs = result.queuedAssetIDs
        canonicalQueuedAssets = result.queuedAssets
        canonicalQueuedAssetIndexByID = result.queuedAssetIndexByID
        canonicalQueuedAssetIDsInOrder = result.queuedAssetIDsInOrder
        canonicalQueueKnownBytes = result.queueKnownBytes
        canonicalQueuedRecommendationKinds = result.recommendationKinds
        canonicalPresentationDidChange()
    }

    private func canonicalQueuePresentationResult(
        protectedAssets: [OrganizeAssetPresentation] = []
    ) -> OrganizeQueueSelectionResult {
        OrganizeQueueSelectionResult(
            protectedAssets: protectedAssets,
            queuedAssetIDs: canonicalQueuedAssetIDs,
            queuedAssets: canonicalQueuedAssets,
            queuedAssetIndexByID: canonicalQueuedAssetIndexByID,
            queuedAssetIDsInOrder: canonicalQueuedAssetIDsInOrder,
            queueKnownBytes: canonicalQueueKnownBytes,
            recommendationKinds: canonicalQueuedRecommendationKinds
        )
    }

    private func applyCanonicalQueuePresentationDelta(
        upserts: [DeletionQueueItem],
        removals: [String]
    ) {
        if !removals.isEmpty {
            let removed = Set(removals)
            canonicalQueuedAssetIDs.subtract(removed)
            canonicalQueuedAssets.removeAll { removed.contains($0.id) }
            canonicalQueuedAssetIDsInOrder.removeAll { removed.contains($0) }
            for assetID in removed { canonicalQueuedRecommendationKinds.removeValue(forKey: assetID) }
            canonicalQueuedAssetIndexByID = Dictionary(
                uniqueKeysWithValues: canonicalQueuedAssets.indices.map {
                    (canonicalQueuedAssets[$0].id, $0)
                }
            )
            canonicalQueueKnownBytes = canonicalQueuedAssets.compactMap(\.knownBytes)
                .reduce(0, Self.saturatingAdd)
        }
        for item in upserts {
            if let kind = item.recommendationKind.flatMap({
                OrganizeRecommendationCategory(rawValue: $0.rawValue)
            }) {
                canonicalQueuedRecommendationKinds[item.assetID] = kind
            }
            guard canonicalQueuedAssetIDs.insert(item.assetID).inserted,
                  let index = canonicalPresentationAssetIndexByID[item.assetID],
                  canonicalPresentationAssets.indices.contains(index) else { continue }
            let asset = canonicalPresentationAssets[index]
            canonicalQueuedAssetIndexByID[item.assetID] = canonicalQueuedAssets.count
            canonicalQueuedAssets.append(asset)
            canonicalQueuedAssetIDsInOrder.append(item.assetID)
            canonicalQueueKnownBytes = Self.saturatingAdd(
                canonicalQueueKnownBytes,
                asset.knownBytes ?? 0
            )
        }
    }

    private func optimisticallyUpsertQueue(
        assetIDs: Set<String>,
        recommendationKind: OrganizeRecommendationCategory?,
        allowProtected: Bool
    ) {
        let domainRecommendation = recommendationKind.flatMap {
            RecommendationKind(rawValue: $0.rawValue)
        }
        for assetID in assetIDs {
            guard let asset = canonicalAssetsByID[assetID] else { continue }
            if canonicalPresentedProtectedAssetIDs.contains(assetID), !allowProtected { continue }
            let old = canonicalQueueByAssetID[assetID]
            canonicalQueueByAssetID[assetID] = DeletionQueueItem(
                assetID: assetID,
                sourceRevision: asset.sourceRevision,
                recommendationKind: domainRecommendation ?? old?.recommendationKind,
                queuedAt: old?.queuedAt ?? Date(),
                protectionOverride: old?.protectionOverride
                    ?? canonicalPresentedProtectedAssetIDs.contains(assetID),
                reviewSessionID: old?.reviewSessionID
            )
        }
    }

    private func optimisticallySetReviewState(
        assetID: String,
        choice: OrganizeReviewChoice?,
        recommendationKind: OrganizeRecommendationCategory?
    ) {
        defer { refreshCanonicalProtection(for: assetID) }
        guard let choice else {
            canonicalReviewStateByAssetID.removeValue(forKey: assetID)
            return
        }
        let state: AssetReviewState
        switch choice {
        case .keep:
            state = .kept
        case .queueForRecentlyDeleted:
            state = .queuedForRecentlyDeleted
        case .later:
            canonicalReviewStateByAssetID.removeValue(forKey: assetID)
            return
        }
        guard let sourceRevision = canonicalSourceRevisionByAssetID[assetID] else { return }
        canonicalReviewStateByAssetID[assetID] = AssetReviewStateRecord(
            assetID: assetID,
            sourceRevision: sourceRevision,
            state: state,
            recommendationKind: recommendationKind.flatMap {
                RecommendationKind(rawValue: $0.rawValue)
            },
            updatedAt: Date()
        )
    }

    private func refreshCanonicalProtection(for assetID: String) {
        guard let asset = canonicalAssetsByID[assetID] else {
            canonicalProtectedAssetIDs.remove(assetID)
            canonicalPresentedProtectedAssetIDs.remove(assetID)
            return
        }
        let albumIDs = canonicalAlbumIDsByAssetID[assetID] ?? []
        let reviewState = canonicalReviewStateByAssetID[assetID]
        let isDurablyProtected = Self.isProtected(
            asset: asset,
            albumIDs: albumIDs,
            protectedAlbumIDs: canonicalProtectedAlbumIDs,
            reviewState: reviewState
        )
        if isDurablyProtected {
            canonicalProtectedAssetIDs.insert(assetID)
        } else {
            canonicalProtectedAssetIDs.remove(assetID)
        }

        let isPresentedProtected = Self.isProtected(
            asset: asset,
            albumIDs: albumIDs,
            protectedAlbumIDs: canonicalPresentedProtectedAlbumIDs,
            reviewState: reviewState
        ) || canonicalDerivedProtectedAssetIDs.contains(assetID)
        if isPresentedProtected {
            canonicalPresentedProtectedAssetIDs.insert(assetID)
        } else {
            canonicalPresentedProtectedAssetIDs.remove(assetID)
        }
    }

    private func addCanonicalReviewDecisionAsset(
        _ assetID: String,
        choice: OrganizeReviewChoice
    ) {
        guard canonicalReviewDecisionAssetIndexByID[choice]?[assetID] == nil else { return }
        let index = canonicalReviewDecisionAssetIDs[choice]?.count ?? 0
        canonicalReviewDecisionAssetIndexByID[choice, default: [:]][assetID] = index
        canonicalReviewDecisionAssetIDs[choice, default: []].append(assetID)
    }

    private func removeCanonicalReviewDecisionAsset(
        _ assetID: String,
        choice: OrganizeReviewChoice
    ) {
        guard let index = canonicalReviewDecisionAssetIndexByID[choice]?[assetID],
              let lastIndex = canonicalReviewDecisionAssetIDs[choice]?.indices.last,
              let lastID = canonicalReviewDecisionAssetIDs[choice]?[lastIndex] else { return }
        if index != lastIndex {
            canonicalReviewDecisionAssetIDs[choice]?[index] = lastID
            canonicalReviewDecisionAssetIndexByID[choice]?[lastID] = index
        }
        canonicalReviewDecisionAssetIDs[choice]?.removeLast()
        canonicalReviewDecisionAssetIndexByID[choice]?.removeValue(forKey: assetID)
        if canonicalReviewDecisionAssetIDs[choice]?.isEmpty == true {
            canonicalReviewDecisionAssetIDs.removeValue(forKey: choice)
            canonicalReviewDecisionAssetIndexByID.removeValue(forKey: choice)
        }
    }

    private func rebuildCanonicalPresentedProtection() {
        var albumIDs = canonicalProtectedAlbumIDs
        for delta in pendingProtectedAlbumPresentationDeltas.values.sorted(by: {
            $0.generation < $1.generation
        }) {
            if delta.isProtected {
                albumIDs.insert(delta.albumID)
            } else {
                albumIDs.remove(delta.albumID)
            }
        }
        canonicalPresentedProtectedAlbumIDs = albumIDs
        canonicalPresentedProtectedAssetIDs = Self.protectedAssetIDs(
            assets: canonicalOrderedAssets,
            albumIDsByAssetID: canonicalAlbumIDsByAssetID,
            protectedAlbumIDs: albumIDs,
            reviewStateByAssetID: canonicalReviewStateByAssetID
        ).union(canonicalDerivedProtectedAssetIDs)
    }

    private func rebuildCanonicalQueuePresentation() {
        canonicalQueuedAssetIDs = []
        canonicalQueuedAssets = []
        canonicalQueuedAssetIndexByID = [:]
        canonicalQueuedAssetIDsInOrder = []
        canonicalQueueKnownBytes = 0
        canonicalQueuedRecommendationKinds = [:]
        let orderedItems = canonicalPresentationAssets.compactMap {
            canonicalQueueByAssetID[$0.id]
        }
        applyCanonicalQueuePresentationDelta(
            upserts: orderedItems,
            removals: []
        )
    }

    private func acquireStateMutationLease() async {
        if !stateMutationLeaseOwned {
            stateMutationLeaseOwned = true
            return
        }
        await withCheckedContinuation { continuation in
            stateMutationWaiters.append(continuation)
        }
    }

    private func releaseStateMutationLease() {
        if stateMutationWaiters.isEmpty {
            stateMutationLeaseOwned = false
        } else {
            stateMutationWaiters.removeFirst().resume()
        }
    }

    private func canonicalStateDidChange() {
        canonicalStateRevision &+= 1
        canonicalPresentationDidChange()
    }

    private func canonicalPresentationDidChange() {
        canonicalPresentationMutationRevision &+= 1
        presentationTask?.cancel()
        presentationTask = nil
        browseTask?.cancel()
        browseTask = nil
    }

    private static func compactQueuePresentation(
        desiredIDs: Set<String>,
        queuedAssets: [OrganizeAssetPresentation],
        recommendationKinds: [String: OrganizeRecommendationCategory]
    ) throws -> OrganizeQueueSelectionResult {
        var retainedIDs = Set<String>()
        retainedIDs.reserveCapacity(min(desiredIDs.count, queuedAssets.count))
        var retainedAssets: [OrganizeAssetPresentation] = []
        retainedAssets.reserveCapacity(min(desiredIDs.count, queuedAssets.count))
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(min(desiredIDs.count, queuedAssets.count))
        var order: [String] = []
        order.reserveCapacity(min(desiredIDs.count, queuedAssets.count))
        var bytes: Int64 = 0
        var kinds: [String: OrganizeRecommendationCategory] = [:]
        kinds.reserveCapacity(min(desiredIDs.count, recommendationKinds.count))
        for (index, asset) in queuedAssets.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            guard desiredIDs.contains(asset.id), retainedIDs.insert(asset.id).inserted else { continue }
            indexByID[asset.id] = retainedAssets.count
            retainedAssets.append(asset)
            order.append(asset.id)
            bytes = saturatingAdd(bytes, asset.knownBytes ?? 0)
            if let kind = recommendationKinds[asset.id] { kinds[asset.id] = kind }
        }
        return OrganizeQueueSelectionResult(
            protectedAssets: [],
            queuedAssetIDs: retainedIDs,
            queuedAssets: retainedAssets,
            queuedAssetIndexByID: indexByID,
            queuedAssetIDsInOrder: order,
            queueKnownBytes: bytes,
            recommendationKinds: kinds
        )
    }

    private static func assetOrder(_ lhs: PhotoAsset, _ rhs: PhotoAsset) -> Bool {
        let left = lhs.creationDate ?? .distantPast
        let right = rhs.creationDate ?? .distantPast
        return left == right ? lhs.id < rhs.id : left > right
    }

    private static func reviewDecision(_ choice: OrganizeReviewChoice) -> ReviewDecision {
        switch choice {
        case .keep: .keep
        case .queueForRecentlyDeleted: .moveToRecentlyDeleted
        case .later: .later
        }
    }

    private static func reviewChoice(_ decision: ReviewDecision) -> OrganizeReviewChoice {
        switch decision {
        case .keep: .keep
        case .moveToRecentlyDeleted: .queueForRecentlyDeleted
        case .later: .later
        }
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

private enum OrganizePresentationBuilder {
    static func build(_ input: OrganizePresentationInput) throws -> OrganizePresentationSnapshot {
        try Task.checkCancellation()
        let albumTitles = Dictionary(uniqueKeysWithValues: input.albums.map { ($0.id, $0.title) })
        let safetyProtectedAssetIDs = input.assets.reduce(into: input.protectedAssetIDs) { result, asset in
            let sourceRevision = input.sourceRevisionByAssetID[asset.id] ?? asset.sourceRevision
            let isDurablyKept = input.reviewStateByAssetID[asset.id].map { record in
                record.sourceRevision == sourceRevision && record.state == .kept
            } == true
            if asset.isFavorite
                || asset.isHidden
                || asset.isEdited
                || asset.mediaSubtypes.contains(.raw)
                || isDurablyKept {
                result.insert(asset.id)
            }
        }
        let visualRecommendations = VisualRecommendationEngine.recommendations(
            assets: input.assets.map {
                OrganizeAsset(
                    asset: $0,
                    albumIDs: Set(input.albumIDsByAssetID[$0.id] ?? [])
                )
            },
            analysisByAssetID: input.visualAnalysisByAssetID,
            protectedAssetIDs: safetyProtectedAssetIDs,
            protectedAlbumIDs: input.protectedAlbumIDs
        )
        let documentLikeAssetIDs = Set(
            visualRecommendations.candidates.lazy
                .filter { $0.kind == .documentLike }
                .map(\.assetID)
        )
        let guardedAssetIDs = safetyProtectedAssetIDs.union(documentLikeAssetIDs)
        var presentations: [OrganizeAssetPresentation] = []
        presentations.reserveCapacity(input.assets.count)

        for (index, asset) in input.assets.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let revision = input.sourceRevisionByAssetID[asset.id] ?? asset.sourceRevision
            let analysis = input.analysisByAssetID[asset.id].flatMap { record in
                record.sourceRevision == asset.analysisRevision ? record : nil
            }
            let reviewState = input.reviewStateByAssetID[asset.id].flatMap { record in
                record.sourceRevision == revision ? record.state : nil
            }
            let assetAlbumIDs = input.albumIDsByAssetID[asset.id] ?? []
            let filename = asset.resources.map(\.originalFilename).sorted().first
                ?? (asset.mediaKind == .video ? "Video" : "Photo")
            let format = (filename as NSString).pathExtension.uppercased()
            presentations.append(
                OrganizeAssetPresentation(
                    id: asset.id,
                    originalFilename: filename,
                    mediaKind: asset.mediaKind,
                    creationDate: asset.creationDate,
                    modificationDate: asset.modificationDate,
                    addedDate: asset.addedDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    durationMilliseconds: asset.durationMilliseconds,
                    knownBytes: analysis?.knownByteCount,
                    albumIDs: assetAlbumIDs,
                    albumNames: assetAlbumIDs.compactMap { albumTitles[$0] },
                    fileFormat: format.isEmpty ? nil : format,
                    sourceRevision: revision,
                    burstIdentifier: asset.burstIdentifier,
                    hasLocation: asset.location != nil,
                    isFavorite: asset.isFavorite,
                    isHidden: asset.isHidden,
                    isEdited: asset.isEdited,
                    isLivePhoto: asset.mediaSubtypes.contains(.livePhoto),
                    isRAW: asset.mediaSubtypes.contains(.raw),
                    isScreenshot: asset.mediaSubtypes.contains(.screenshot),
                    isProtected: guardedAssetIDs.contains(asset.id),
                    isReviewed: reviewState == .kept || reviewState == .queuedForRecentlyDeleted,
                    analysisState: analysisPresentationState(analysis?.status)
                )
            )
        }
        presentations.sort(by: assetPresentationOrder)
        try Task.checkCancellation()

        let assetIndexByID = Dictionary(uniqueKeysWithValues: presentations.indices.map {
            (presentations[$0].id, $0)
        })
        let presentationByID = Dictionary(uniqueKeysWithValues: presentations.map { ($0.id, $0) })
        let accessibleAssetIDs = Set(assetIndexByID.keys)
        let duplicateGroups = duplicatePresentations(
            assets: presentations,
            analysisByAssetID: input.analysisByAssetID
        )
        let screenRecordingAssetIDs = Set(input.assets.lazy.compactMap { asset in
            asset.mediaKind == .video && asset.mediaSubtypes.contains(.screenRecording)
                ? asset.id
                : nil
        })
        let specialtyMediaAssetIDs = Set(input.assets.lazy.compactMap { asset in
            !asset.mediaSubtypes.isDisjoint(with: OrganizeRecommendationDefaults.specialtyMediaSubtypes)
                ? asset.id
                : nil
        })
        let deferredAssetIDs = latestDecideLaterAssetIDs(
            reviewSessionsByID: input.reviewSessionsByID,
            accessibleAssetIDs: accessibleAssetIDs
        )
        let derived = derivedPresentation(
            assets: presentations,
            assetByID: presentationByID,
            duplicateGroups: duplicateGroups,
            screenRecordingAssetIDs: screenRecordingAssetIDs,
            specialtyMediaAssetIDs: specialtyMediaAssetIDs,
            decideLaterAssetIDs: deferredAssetIDs,
            visualRecommendations: visualRecommendations,
            referenceDate: Date()
        )
        let queuedAssetIDs = Set(input.queueByAssetID.keys).intersection(accessibleAssetIDs)
        let queuedAssets = presentations.filter { queuedAssetIDs.contains($0.id) }
        let queuedAssetIndexByID = Dictionary(uniqueKeysWithValues: queuedAssets.indices.map {
            (queuedAssets[$0].id, $0)
        })
        let queueKnownBytes = queuedAssets.compactMap(\.knownBytes).reduce(0, saturatingAdd)
        let storedActiveSession = input.activeReviewSessionOverride ?? input.reviewSessionsByID.values
            .filter { $0.status == .active }
            .max { $0.updatedAt < $1.updatedAt }
            .map(reviewSessionPresentation)
        let activeSession = storedActiveSession.map { stored -> OrganizeReviewSessionPresentation in
            var enriched = stored
            if let recommendation = (derived.reviewRecommendations + derived.organizeRecommendations)
                .first(where: { $0.kind == stored.recommendationKind }) {
                enriched.evidenceByAssetID = recommendation.evidenceByAssetID
            }
            return enriched
        }
        var queuedRecommendationKinds: [String: OrganizeRecommendationCategory] = [:]
        queuedRecommendationKinds.reserveCapacity(queuedAssetIDs.count)
        for assetID in queuedAssetIDs {
            guard let kind = input.queueByAssetID[assetID]?.recommendationKind,
                  let presentationKind = OrganizeRecommendationCategory(rawValue: kind.rawValue) else { continue }
            queuedRecommendationKinds[assetID] = presentationKind
        }
        var reviewDecisionAssetIDs: [OrganizeReviewChoice: [String]] = [:]
        var reviewDecisionAssetIndexByID: [OrganizeReviewChoice: [String: Int]] = [:]
        if let activeSession {
            for assetID in activeSession.assetIDs {
                guard let choice = activeSession.decisions[assetID] else { continue }
                reviewDecisionAssetIndexByID[choice, default: [:]][assetID] = reviewDecisionAssetIDs[choice, default: []].count
                reviewDecisionAssetIDs[choice, default: []].append(assetID)
            }
        }
        let deletedBatches = deletedBatchPresentations(
            batches: input.deletionBatches,
            items: input.deletedItems
        )
        let analysis = analysisPresentation(input)
        let totalKnownBytes = presentations.compactMap(\.knownBytes).reduce(0, saturatingAdd)
        let analyzedItemCount = presentations.reduce(into: 0) { count, asset in
            if asset.analysisState == .analyzed { count += 1 }
        }
        let availableFormats = Array(Set(presentations.compactMap(\.fileFormat))).sorted()
        let albums = input.albums.map {
            OrganizeAlbumPresentation(id: $0.id, title: $0.title, assetCount: $0.assetIDs.count)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return OrganizePresentationSnapshot(
            revision: input.revision,
            authorization: input.authorization,
            assets: presentations,
            assetIndexByID: assetIndexByID,
            albums: albums,
            primaryBreakdown: derived.primaryBreakdown,
            secondaryBreakdown: derived.secondaryBreakdown,
            reviewRecommendations: derived.reviewRecommendations,
            organizeRecommendations: derived.organizeRecommendations,
            queuedAssetIDs: queuedAssetIDs,
            queuedAssets: queuedAssets,
            queuedAssetIndexByID: queuedAssetIndexByID,
            queuedAssetIDsInOrder: queuedAssets.map(\.id),
            queueKnownBytes: queueKnownBytes,
            queuedRecommendationKinds: queuedRecommendationKinds,
            protectedAlbumIDs: input.protectedAlbumIDs,
            activeReviewSession: activeSession,
            duplicateGroups: duplicateGroups,
            deletedBatches: deletedBatches,
            analysis: analysis,
            totalKnownBytes: totalKnownBytes,
            analyzedItemCount: analyzedItemCount,
            availableFormats: availableFormats,
            hasAddedDates: presentations.contains { $0.addedDate != nil },
            deletedAuditRecordCount: input.deletedItems.count,
            reviewDecisionAssetIDs: reviewDecisionAssetIDs,
            reviewDecisionAssetIndexByID: reviewDecisionAssetIndexByID,
            retainedSelectedAssetIDs: input.selectedAssetIDs.intersection(accessibleAssetIDs)
        )
    }

    private struct DerivedPresentation {
        let primaryBreakdown: [OrganizeBreakdownMetric]
        let secondaryBreakdown: [OrganizeBreakdownMetric]
        let reviewRecommendations: [OrganizeRecommendationPresentation]
        let organizeRecommendations: [OrganizeRecommendationPresentation]
    }

    private static func derivedPresentation(
        assets: [OrganizeAssetPresentation],
        assetByID: [String: OrganizeAssetPresentation],
        duplicateGroups: [OrganizeDuplicateGroupPresentation],
        screenRecordingAssetIDs: Set<String>,
        specialtyMediaAssetIDs: Set<String>,
        decideLaterAssetIDs: Set<String>,
        visualRecommendations: VisualRecommendationResult,
        referenceDate: Date
    ) -> DerivedPresentation {
        let regularPhotos = assets.filter { $0.mediaKind == .photo && !$0.isScreenshot }
        let screenshots = assets.filter(\.isScreenshot)
        let videos = assets.filter { $0.mediaKind == .video }
        let primary = [
            metric("photos", "Photos", "photo", regularPhotos, .blue, false),
            metric("screenshots", "Screenshots", "rectangle.inset.filled.and.person.filled", screenshots, .purple, false),
            metric("videos", "Videos", "video", videos, .orange, false)
        ]
        let secondary = [
            metric("live", "Live Photos", "livephoto", assets.filter(\.isLivePhoto), .purple, true),
            metric("raw", "RAW", "camera.aperture", assets.filter(\.isRAW), .gray, true),
            metric("favorites", "Favorites", "heart.fill", assets.filter(\.isFavorite), .orange, true),
            metric("edited", "Edited", "slider.horizontal.3", assets.filter(\.isEdited), .green, true),
            metric("no-album", "No Album", "rectangle.stack.badge.minus", assets.filter { $0.albumCount == 0 }, .blue, true)
        ]

        var review: [OrganizeRecommendationPresentation] = []
        let duplicateIDs = Array(Set(duplicateGroups.flatMap(\.assetIDs))).sorted()
        if !duplicateIDs.isEmpty {
            review.append(recommendation(
                .exactDuplicates,
                "Exact Duplicates",
                "Compare byte-identical files and choose which copies to keep.",
                "square.on.square",
                duplicateIDs,
                .duplicates,
                assetByID: assetByID
            ))
        }
        let rapidRetakeGroups = visualRecommendations.groups.filter { $0.kind == .rapidRetakes }
        if let rapidRetakes = visualGroupRecommendation(
            groups: rapidRetakeGroups,
            kind: .rapidRetakes,
            title: "Rapid Retakes",
            detail: "Compare photos taken seconds apart; Vision suggests a keeper but never selects anything for deletion.",
            systemImage: "camera.on.rectangle",
            assetByID: assetByID
        ) {
            review.append(rapidRetakes)
        }
        let similarScreenshotGroups = visualRecommendations.groups.filter {
            $0.kind == .similarScreenshots
        }
        if let similarScreenshots = visualGroupRecommendation(
            groups: similarScreenshotGroups,
            kind: .similarScreenshots,
            title: "Similar Screenshots",
            detail: "Compare visually repeated, resized, or cropped screenshots in bounded groups.",
            systemImage: "rectangle.on.rectangle.angled",
            assetByID: assetByID
        ) {
            review.append(similarScreenshots)
        }
        let screenRecordingIDs = assets
            .filter { screenRecordingAssetIDs.contains($0.id) }
            .sorted(by: oldestPresentationCaptureFirst)
            .map(\.id)
        if !screenRecordingIDs.isEmpty {
            review.append(recommendation(
                .screenRecordings,
                "Screen Recordings",
                "Review screen recordings, starting with the oldest.",
                "record.circle",
                screenRecordingIDs,
                .review,
                assetByID: assetByID
            ))
        }
        let oldScreenshotCutoff = referenceDate.addingTimeInterval(
            -OrganizeRecommendationDefaults.oldScreenshotMinimumAge
        )
        let oldScreenshotIDs = screenshots
            .filter { asset in
                guard let creationDate = asset.creationDate else { return false }
                return creationDate <= oldScreenshotCutoff
            }
            .sorted(by: oldestPresentationCaptureFirst)
            .map(\.id)
        if !oldScreenshotIDs.isEmpty {
            review.append(recommendation(
                .oldScreenshots,
                "Old Screenshots",
                "Review screenshots captured at least 90 days ago, starting with the oldest.",
                "calendar.badge.clock",
                oldScreenshotIDs,
                .review,
                assetByID: assetByID
            ))
        }
        let screenshotIDs = screenshots.sorted(by: oldestPresentationCaptureFirst).map(\.id)
        if !screenshotIDs.isEmpty {
            review.append(recommendation(
                .screenshots,
                "Screenshots",
                "Review screenshots, starting with the oldest.",
                "rectangle.inset.filled.and.person.filled",
                screenshotIDs,
                .review,
                assetByID: assetByID
            ))
        }
        let veryShortVideoIDs = videos
            .filter {
                guard let duration = $0.durationMilliseconds else { return false }
                return duration <= OrganizeRecommendationDefaults.veryShortVideoMaximumDurationMilliseconds
            }
            .sorted(by: shortestVideoFirst)
            .map(\.id)
        if !veryShortVideoIDs.isEmpty {
            review.append(recommendation(
                .veryShortVideos,
                "Very Short Videos",
                "Review videos no longer than 3 seconds, starting with the shortest.",
                "video.badge.checkmark",
                veryShortVideoIDs,
                .review,
                assetByID: assetByID
            ))
        }
        let tinyImageIDs = assets
            .filter {
                $0.mediaKind == .photo &&
                    presentationPixelCount($0)
                        <= OrganizeRecommendationDefaults.tinyImageMaximumPixelCount
            }
            .sorted(by: smallestImageFirst)
            .map(\.id)
        if !tinyImageIDs.isEmpty {
            review.append(recommendation(
                .tinyImages,
                "Tiny Images",
                "Review images no larger than 1 megapixel, starting with the smallest.",
                "photo.badge.exclamationmark",
                tinyImageIDs,
                .review,
                assetByID: assetByID
            ))
        }
        let largeVideoIDs = videos
            .filter { ($0.knownBytes ?? -1) >= OrganizeRecommendationDefaults.largeVideoMinimumKnownByteCount }
            .sorted(by: largestKnownFileFirst)
            .map(\.id)
        if !largeVideoIDs.isEmpty {
            review.append(recommendation(
                .largeVideos,
                "Large Videos",
                "Review videos that are at least 500 MB.",
                "video.badge.ellipsis",
                largeVideoIDs,
                .review,
                assetByID: assetByID
            ))
        }
        let largeSpecialtyIDs = assets
            .filter {
                specialtyMediaAssetIDs.contains($0.id) &&
                    ($0.knownBytes ?? -1) >= OrganizeRecommendationDefaults.largeSpecialtyMinimumKnownByteCount
            }
            .sorted(by: largestKnownFileFirst)
            .map(\.id)
        if !largeSpecialtyIDs.isEmpty {
            review.append(recommendation(
                .largeSpecialtyMedia,
                "Large Specialty Media",
                "Review large Live, RAW, panorama, spatial, and specialty camera media, starting with the largest.",
                "camera.filters",
                largeSpecialtyIDs,
                .review,
                assetByID: assetByID
            ))
        }
        let burstGroups = visualRecommendations.groups.filter { $0.kind == .burst }
        let burstIDs = assets.filter { $0.burstIdentifier != nil }.map(\.id)
        if !burstIDs.isEmpty {
            review.append(recommendation(
                .bursts,
                "Best of Bursts",
                "Choose the strongest frames from each burst; Vision suggests a keeper when analysis is available.",
                "square.stack.3d.up",
                burstIDs,
                .review,
                assetByID: assetByID,
                evidenceByAssetID: visualGroupEvidence(
                    groups: burstGroups,
                    assetByID: assetByID
                )
            ))
        }

        let worthReviewingCandidates = visualRecommendations.candidates.filter {
            $0.kind == .utility || $0.kind == .worthReviewing
        }
        if let worthReviewing = visualCandidateRecommendation(
            candidates: worthReviewingCandidates,
            kind: .worthReviewing,
            title: "Worth Reviewing",
            detail: "Review utility/reference captures and lower-aesthetics images. These are suggestions, not judgments or deletion choices.",
            systemImage: "sparkles.rectangle.stack",
            assetByID: assetByID
        ) {
            review.append(worthReviewing)
        }

        let documentCandidates = visualRecommendations.candidates.filter {
            $0.kind == .documentLike
        }
        if let documents = visualCandidateRecommendation(
            candidates: documentCandidates,
            kind: .textHeavyDocuments,
            title: "Documents & References",
            detail: "Review text-heavy images, receipts, tickets, notes, and barcodes. Content stays on device and these items require a protection override.",
            systemImage: "doc.text.viewfinder",
            assetByID: assetByID
        ) {
            review.append(documents)
        }

        let noSubjectCandidates = visualRecommendations.candidates.filter {
            $0.kind == .noClearSubject
        }
        if let noSubject = visualCandidateRecommendation(
            candidates: noSubjectCandidates,
            kind: .noClearSubject,
            title: "No Clear Subject",
            detail: "Review captures where Vision found no clear salient subject.",
            systemImage: "viewfinder",
            assetByID: assetByID
        ) {
            review.append(noSubject)
        }

        let smudgeCandidates = visualRecommendations.candidates.filter {
            $0.kind == .smudgedCapture
        }
        if let smudged = visualCandidateRecommendation(
            candidates: smudgeCandidates,
            kind: .smudgedCaptures,
            title: "Possible Lens Smudge",
            detail: "Review captures flagged by the optional iOS 26 lens-smudge detector.",
            systemImage: "camera.viewfinder",
            assetByID: assetByID
        ) {
            review.append(smudged)
        }

        let decideLaterIDs = assets
            .filter { decideLaterAssetIDs.contains($0.id) }
            .sorted(by: oldestPresentationCaptureFirst)
            .map(\.id)
        if !decideLaterIDs.isEmpty {
            review.append(recommendation(
                .decideLater,
                "Decide Later",
                "Return to items previously marked Later, starting with the oldest capture.",
                "bookmark",
                decideLaterIDs,
                .review,
                assetByID: assetByID
            ))
        }

        let unreviewedIDs = assets.filter { !$0.isReviewed }.map(\.id)
        if !unreviewedIDs.isEmpty {
            review.append(recommendation(
                .unreviewed,
                "Unreviewed",
                "Review items you have not reviewed yet.",
                "checkmark.circle.badge.questionmark",
                unreviewedIDs,
                .review,
                assetByID: assetByID
            ))
        }

        var organize: [OrganizeRecommendationPresentation] = []
        let noAlbumIDs = assets.filter { $0.albumCount == 0 }.map(\.id)
        if !noAlbumIDs.isEmpty {
            organize.append(recommendation(
                .noAlbum,
                "Not in an Album",
                "Browse items that are not in a user-created album.",
                "rectangle.stack.badge.minus",
                noAlbumIDs,
                .browse,
                assetByID: assetByID
            ))
        }
        return DerivedPresentation(
            primaryBreakdown: primary,
            secondaryBreakdown: secondary,
            reviewRecommendations: review,
            organizeRecommendations: organize
        )
    }

    private static func metric(
        _ id: String,
        _ title: String,
        _ systemImage: String,
        _ assets: [OrganizeAssetPresentation],
        _ tint: OrganizeMetricTint,
        _ overlaps: Bool
    ) -> OrganizeBreakdownMetric {
        OrganizeBreakdownMetric(
            id: id,
            title: title,
            systemImage: systemImage,
            itemCount: assets.count,
            knownBytes: assets.compactMap(\.knownBytes).reduce(0, saturatingAdd),
            processedAssetCount: assets.reduce(into: 0) { count, asset in
                if asset.analysisState != .notAnalyzed { count += 1 }
            },
            analyzedAssetCount: assets.reduce(into: 0) { count, asset in
                if asset.analysisState == .analyzed { count += 1 }
            },
            unavailableAssetCount: assets.reduce(into: 0) { count, asset in
                if asset.analysisState == .unavailable { count += 1 }
            },
            failedAssetCount: assets.reduce(into: 0) { count, asset in
                if asset.analysisState == .failed { count += 1 }
            },
            tint: tint,
            overlapsPrimaryCategories: overlaps
        )
    }

    private static func recommendation(
        _ kind: OrganizeRecommendationCategory,
        _ title: String,
        _ detail: String,
        _ systemImage: String,
        _ ids: [String],
        _ destination: OrganizeRecommendationDestination,
        assetByID: [String: OrganizeAssetPresentation],
        knownBytes: Int64? = nil,
        evidenceByAssetID: [String: String] = [:]
    ) -> OrganizeRecommendationPresentation {
        OrganizeRecommendationPresentation(
            kind: kind,
            title: title,
            detail: detail,
            systemImage: systemImage,
            assetIDs: ids,
            assetIDSet: Set(ids),
            knownBytes: knownBytes ?? ids.compactMap { assetByID[$0]?.knownBytes }.reduce(0, saturatingAdd),
            destination: destination,
            evidenceByAssetID: evidenceByAssetID
        )
    }

    private static func visualGroupRecommendation(
        groups: [VisualSimilarityGroup],
        kind: OrganizeRecommendationCategory,
        title: String,
        detail: String,
        systemImage: String,
        assetByID: [String: OrganizeAssetPresentation]
    ) -> OrganizeRecommendationPresentation? {
        let ids = orderedUniqueAssetIDs(
            groups.flatMap(\.assetIDs),
            assetByID: assetByID
        )
        guard !ids.isEmpty else { return nil }
        return recommendation(
            kind,
            title,
            detail,
            systemImage,
            ids,
            .review,
            assetByID: assetByID,
            evidenceByAssetID: visualGroupEvidence(
                groups: groups,
                assetByID: assetByID
            )
        )
    }

    private static func visualCandidateRecommendation(
        candidates: [VisualAssetRecommendation],
        kind: OrganizeRecommendationCategory,
        title: String,
        detail: String,
        systemImage: String,
        assetByID: [String: OrganizeAssetPresentation]
    ) -> OrganizeRecommendationPresentation? {
        let ids = orderedUniqueAssetIDs(
            candidates.map(\.assetID),
            assetByID: assetByID
        )
        guard !ids.isEmpty else { return nil }
        let candidatesByAssetID = Dictionary(grouping: candidates, by: \.assetID)
        let evidenceByAssetID = Dictionary(uniqueKeysWithValues: ids.map { assetID in
            (
                assetID,
                visualCandidateEvidence(
                    candidatesByAssetID[assetID] ?? [],
                    asset: assetByID[assetID]
                )
            )
        })
        return recommendation(
            kind,
            title,
            detail,
            systemImage,
            ids,
            .review,
            assetByID: assetByID,
            evidenceByAssetID: evidenceByAssetID
        )
    }

    private static func orderedUniqueAssetIDs(
        _ assetIDs: [String],
        assetByID: [String: OrganizeAssetPresentation]
    ) -> [String] {
        var seen: Set<String> = []
        return assetIDs.filter { assetID in
            assetByID[assetID] != nil && seen.insert(assetID).inserted
        }
    }

    private static func visualGroupEvidence(
        groups: [VisualSimilarityGroup],
        assetByID: [String: OrganizeAssetPresentation]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for group in groups {
            let keeperName = assetByID[group.recommendedKeeperID]?.originalFilename
                ?? "the suggested keeper"
            for assetID in group.assetIDs where assetByID[assetID] != nil {
                var parts: [String] = []
                switch group.kind {
                case .rapidRetakes:
                    parts.append("Vision matched this within a rapid capture sequence.")
                case .similarScreenshots:
                    parts.append("Vision matched this to another screenshot in a bounded comparison group.")
                case .burst:
                    parts.append("This belongs to a PhotoKit burst.")
                default:
                    parts.append("Vision placed this in a visually similar review group.")
                }

                let distances = group.evidence.compactMap { evidence -> (Float, Float)? in
                    guard case let .featurePrintDistance(
                        firstID,
                        relatedID,
                        distance,
                        threshold
                    ) = evidence,
                    firstID == assetID || relatedID == assetID else { return nil }
                    return (distance, threshold)
                }
                if let nearest = distances.min(by: { $0.0 < $1.0 }) {
                    parts.append(
                        "Feature-print distance \(formatScore(nearest.0)) (match cutoff \(formatScore(nearest.1)))."
                    )
                }

                let deltas = group.evidence.compactMap { evidence -> TimeInterval? in
                    guard case let .captureTimeDelta(
                        firstID,
                        relatedID,
                        seconds,
                        _
                    ) = evidence,
                    firstID == assetID || relatedID == assetID else { return nil }
                    return seconds
                }
                if let closest = deltas.min() {
                    parts.append("Taken \(formatTimeGap(closest)) from a matched photo.")
                }

                if assetID == group.recommendedKeeperID {
                    let keeperReasons = visualKeeperReasons(group.keeperEvidence)
                    parts.append(
                        keeperReasons.isEmpty
                            ? "Suggested keeper after comparing safety and quality signals."
                            : "Suggested keeper: \(keeperReasons.joined(separator: ", "))."
                    )
                } else {
                    parts.append("Suggested keeper for comparison: \(keeperName).")
                }
                if assetByID[assetID]?.isProtected == true {
                    parts.append("This item is guarded and requires an explicit override to queue.")
                }
                if group.cautions.contains(.mayContainImportantInformation) {
                    parts.append("The group may contain text or other important reference information.")
                }
                result[assetID] = parts.joined(separator: " ")
            }
        }
        return result
    }

    private static func visualKeeperReasons(
        _ evidence: [VisualRecommendationEvidence]
    ) -> [String] {
        var reasons: [String] = []
        for item in evidence {
            let reason: String? = switch item {
            case .protectedItem, .protectedAlbum: "protected status"
            case .favorite: "favorite"
            case .hidden: "hidden item"
            case .edited: "edited version"
            case .raw: "RAW original"
            case .livePhoto: "Live Photo"
            case let .albumMembershipCount(_, count) where count > 0:
                "\(count) album membership\(count == 1 ? "" : "s")"
            case let .resolution(_, pixelCount):
                String(format: "%.1f MP", Double(pixelCount) / 1_000_000)
            case let .aestheticScore(_, score):
                "aesthetics \(formatScore(score))"
            case let .faceCaptureQuality(_, score):
                "face quality \(formatScore(score))"
            default: nil
            }
            if let reason, !reasons.contains(reason) { reasons.append(reason) }
        }
        return Array(reasons.prefix(4))
    }

    private static func visualCandidateEvidence(
        _ candidates: [VisualAssetRecommendation],
        asset: OrganizeAssetPresentation?
    ) -> String {
        var parts: [String] = []
        func appendUnique(_ text: String) {
            if !parts.contains(text) { parts.append(text) }
        }
        for evidence in candidates.flatMap(\.evidence) {
            switch evidence {
            case .utilityClassification:
                appendUnique("Vision classified this as a utility or reference image.")
            case let .aestheticScore(_, score):
                appendUnique("Vision aesthetics score: \(formatScore(score)) on a −1 to 1 scale.")
            case let .recognizedText(_, count, coverage):
                appendUnique(
                    "On-device OCR found \(count) text region\(count == 1 ? "" : "s") covering about \(Int((coverage * 100).rounded()))% of the image. Recognized words were not saved."
                )
            case .barcodeDetected:
                appendUnique("A barcode or QR code was detected; its payload was not saved.")
            case .noClearSubject:
                appendUnique("Vision returned no clear objectness-based salient subject.")
            case let .lensSmudgeConfidence(_, confidence):
                appendUnique("iOS 26 lens-smudge confidence: \(Int((confidence * 100).rounded()))%.")
            default:
                continue
            }
        }
        if asset?.isProtected == true {
            appendUnique("This item is guarded and requires an explicit override to queue.")
        }
        return parts.isEmpty ? "Review-only Vision suggestion." : parts.joined(separator: " ")
    }

    private static func formatScore(_ score: Float) -> String {
        String(format: "%.2f", score)
    }

    private static func formatTimeGap(_ interval: TimeInterval) -> String {
        if interval < 1 { return "less than a second" }
        let seconds = Int(interval.rounded())
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }

    private static func latestDecideLaterAssetIDs(
        reviewSessionsByID: [UUID: ReviewSession],
        accessibleAssetIDs: Set<String>
    ) -> Set<String> {
        let sessions = reviewSessionsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var latestDecisionByAssetID: [String: ReviewDecision] = [:]
        for session in sessions {
            for assetID in session.decisions.keys.sorted(by: OrganizeText.lessThan) {
                guard accessibleAssetIDs.contains(assetID),
                      let decision = session.decisions[assetID] else { continue }
                latestDecisionByAssetID[assetID] = decision
            }
        }
        return Set(latestDecisionByAssetID.compactMap { assetID, decision in
            decision == .later ? assetID : nil
        })
    }

    private static func oldestPresentationCaptureFirst(
        _ lhs: OrganizeAssetPresentation,
        _ rhs: OrganizeAssetPresentation
    ) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return OrganizeText.lessThan(lhs.id, rhs.id)
        }
    }

    private static func shortestVideoFirst(
        _ lhs: OrganizeAssetPresentation,
        _ rhs: OrganizeAssetPresentation
    ) -> Bool {
        let left = lhs.durationMilliseconds ?? .max
        let right = rhs.durationMilliseconds ?? .max
        if left != right { return left < right }
        return oldestPresentationCaptureFirst(lhs, rhs)
    }

    private static func presentationPixelCount(_ asset: OrganizeAssetPresentation) -> Int64 {
        let width = Int64(max(asset.pixelWidth, 0))
        let height = Int64(max(asset.pixelHeight, 0))
        let (product, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? .max : product
    }

    private static func smallestImageFirst(
        _ lhs: OrganizeAssetPresentation,
        _ rhs: OrganizeAssetPresentation
    ) -> Bool {
        let left = presentationPixelCount(lhs)
        let right = presentationPixelCount(rhs)
        if left != right { return left < right }
        return oldestPresentationCaptureFirst(lhs, rhs)
    }

    private static func largestKnownFileFirst(
        _ lhs: OrganizeAssetPresentation,
        _ rhs: OrganizeAssetPresentation
    ) -> Bool {
        let left = lhs.knownBytes ?? -1
        let right = rhs.knownBytes ?? -1
        if left != right { return left > right }
        return oldestPresentationCaptureFirst(lhs, rhs)
    }

    private static func duplicatePresentations(
        assets: [OrganizeAssetPresentation],
        analysisByAssetID: [String: AssetAnalysisRecord]
    ) -> [OrganizeDuplicateGroupPresentation] {
        let grouped = Dictionary(grouping: assets) { asset -> String? in
            guard let record = analysisByAssetID[asset.id],
                  asset.knownBytes != nil,
                  record.status == .complete else { return nil }
            return record.exactDuplicateKey
        }
        return grouped.compactMap { key, members -> OrganizeDuplicateGroupPresentation? in
            guard let key, members.count > 1 else { return nil }
            let totalBytes = members.compactMap(\.knownBytes).reduce(0, saturatingAdd)
            guard let retainedCopyBytes = members.first?.knownBytes else { return nil }
            return OrganizeDuplicateGroupPresentation(
                id: key,
                assetIDs: members.map(\.id).sorted(by: OrganizeText.lessThan),
                knownReclaimableBytes: max(0, totalBytes - retainedCopyBytes)
            )
        }.sorted { OrganizeText.lessThan($0.id, $1.id) }
    }

    private static func analysisPresentation(_ input: OrganizePresentationInput) -> OrganizeAnalysisPresentation {
        if let override = input.analysisOverride,
           override.phase == .running || override.phase == .paused {
            return override
        }
        var relevantCount = 0
        var completedCount = 0
        var unavailableCount = 0
        var failedCount = 0
        for asset in input.assets {
            guard let record = input.analysisByAssetID[asset.id],
                  record.sourceRevision == asset.analysisRevision else { continue }
            relevantCount += 1
            if record.status == .complete { completedCount += 1 }
            if record.status == .unavailableLocally { unavailableCount += 1 }
            if record.status == .failed { failedCount += 1 }
        }
        guard relevantCount > 0 else { return OrganizeAnalysisPresentation() }
        let processedCount = completedCount + unavailableCount + failedCount
        let phase: OrganizeAnalysisPhase = switch input.analysisRun?.status {
        case .running: .running
        case .paused: .paused
        case .failed: .failed
        case .complete, nil: processedCount < input.assets.count ? .notStarted : .complete
        }
        return OrganizeAnalysisPresentation(
            phase: phase,
            processedAssetCount: processedCount,
            completedAssetCount: completedCount,
            totalAssetCount: input.assets.count,
            unavailableAssetCount: unavailableCount,
            failedAssetCount: failedCount,
            includesICloudItems: input.analysisRun?.includesICloudItems ?? false,
            statusText: failedCount > 0
                ? "Analysis finished with issues: \(failedCount) failed. Retry incomplete items."
                : unavailableCount > 0
                    ? "Local analysis is complete; \(unavailableCount) item(s) require iCloud access."
                    : completedCount < input.assets.count
                        ? "Analysis is incomplete. Resume to size the remaining items."
                        : "Library analysis is up to date."
        )
    }

    private static func reviewSessionPresentation(_ session: ReviewSession) -> OrganizeReviewSessionPresentation {
        OrganizeReviewSessionPresentation(
            id: session.id,
            recommendationKind: OrganizeRecommendationCategory(rawValue: session.recommendationKind.rawValue) ?? .unreviewed,
            title: recommendationTitle(session.recommendationKind),
            reason: recommendationReason(session.recommendationKind),
            assetIDs: session.orderedAssetIDs,
            currentIndex: session.cursor,
            decisions: Dictionary(uniqueKeysWithValues: session.decisions.map { key, value in
                (key, reviewChoice(value))
            }),
            undoStack: session.actions.map {
                OrganizeReviewActionPresentation(
                    id: $0.id,
                    assetID: $0.assetID,
                    choice: reviewChoice($0.decision),
                    previousChoice: $0.previousDecision.map(reviewChoice),
                    previousIndex: $0.cursorBefore,
                    wasQueued: $0.wasQueued ?? ($0.previousDecision == .moveToRecentlyDeleted),
                    wasReviewed: $0.wasReviewed ?? ($0.previousDecision == .keep)
                )
            }
        )
    }

    private static func deletedBatchPresentations(
        batches: [DeletionBatch],
        items: [DeletedItemRecord]
    ) -> [OrganizeDeletedBatchPresentation] {
        let batchesByID = Dictionary(uniqueKeysWithValues: batches.map { ($0.id, $0) })
        return Dictionary(grouping: items, by: \.batchID).compactMap { batchID, records in
            guard let batch = batchesByID[batchID],
                  batch.status == .movedToRecentlyDeleted || batch.status == .confirmationInterrupted else {
                return nil
            }
            let status: OrganizeDeletedRecordStatus = batch.status == .movedToRecentlyDeleted
                ? .movedToRecentlyDeleted
                : .confirmationInterrupted
            return OrganizeDeletedBatchPresentation(
                id: batch.id,
                deletedAt: batch.completedAt ?? batch.requestedAt,
                records: records.map {
                    OrganizeDeletedItemPresentation(
                        id: $0.id,
                        sourceAssetID: $0.sourceLocalIdentifier,
                        sourceRevision: $0.sourceRevision,
                        originalFilename: $0.originalFilename,
                        mediaKind: $0.mediaKind,
                        captureDate: $0.creationDate,
                        deletedAt: $0.deletedAt,
                        pixelWidth: $0.pixelWidth,
                        pixelHeight: $0.pixelHeight,
                        durationMilliseconds: $0.durationMilliseconds,
                        knownBytes: $0.knownByteCount,
                        recommendationSource: $0.recommendationKind.map(recommendationTitle) ?? "Manual Review",
                        isFavorite: $0.isFavorite,
                        isHidden: $0.isHidden,
                        isEdited: $0.isEdited,
                        isLivePhoto: $0.isLivePhoto,
                        isRAW: $0.isRaw,
                        status: status,
                        thumbnailExpiresAt: $0.thumbnailExpiresAt
                    )
                },
                photoKitResult: status == .movedToRecentlyDeleted
                    ? "Moved to Recently Deleted"
                    : "Apple Photos result was not recorded; verify this batch in Apple Photos."
            )
        }.sorted { $0.deletedAt > $1.deletedAt }
    }

    private static func analysisPresentationState(_ status: AnalysisStatus?) -> OrganizeAssetAnalysisState {
        switch status {
        case .complete: .analyzed
        case .unavailableLocally: .unavailable
        case .failed: .failed
        default: .notAnalyzed
        }
    }

    private static func reviewChoice(_ decision: ReviewDecision) -> OrganizeReviewChoice {
        switch decision {
        case .keep: .keep
        case .moveToRecentlyDeleted: .queueForRecentlyDeleted
        case .later: .later
        }
    }

    private static func recommendationTitle(_ kind: RecommendationKind) -> String {
        switch kind {
        case .exactDuplicates: "Exact Duplicates"
        case .screenshots: "Screenshots"
        case .screenRecordings: "Screen Recordings"
        case .oldScreenshots: "Old Screenshots"
        case .veryShortVideos: "Very Short Videos"
        case .tinyImages: "Tiny Images"
        case .largeVideos: "Large Videos"
        case .largeSpecialtyMedia: "Large Specialty Media"
        case .bursts: "Bursts"
        case .rapidRetakes: "Rapid Retakes"
        case .similarPhotos: "Similar Photos"
        case .similarScreenshots: "Similar Screenshots"
        case .worthReviewing: "Worth Reviewing"
        case .textHeavyDocuments: "Documents & References"
        case .noClearSubject: "No Clear Subject"
        case .smudgedCaptures: "Possible Lens Smudge"
        case .decideLater: "Decide Later"
        case .noAlbum: "Not in an Album"
        case .unreviewed: "Unreviewed"
        }
    }

    private static func recommendationReason(_ kind: RecommendationKind) -> String {
        switch kind {
        case .exactDuplicates: "Compare byte-identical media and decide which copies to keep."
        case .screenshots: "Review screenshots, starting with the oldest."
        case .screenRecordings: "Review screen recordings, starting with the oldest."
        case .oldScreenshots: "Review screenshots captured at least 90 days ago, starting with the oldest."
        case .veryShortVideos: "Review videos no longer than 3 seconds, starting with the shortest."
        case .tinyImages: "Review images no larger than 1 megapixel, starting with the smallest."
        case .largeVideos: "Review videos that are at least 500 MB."
        case .largeSpecialtyMedia: "Review large Live, RAW, panorama, spatial, and specialty camera media, starting with the largest."
        case .bursts: "Choose the frames worth keeping from each burst."
        case .rapidRetakes: "Compare visually similar photos taken seconds apart."
        case .similarPhotos: "Compare visually similar photos in bounded groups."
        case .similarScreenshots: "Compare visually repeated, resized, or cropped screenshots."
        case .worthReviewing: "Review utility captures and lower-aesthetics suggestions without automatic deletion."
        case .textHeavyDocuments: "Review guarded text-heavy documents and temporary references."
        case .noClearSubject: "Review captures where Vision found no clear salient subject."
        case .smudgedCaptures: "Review captures flagged by the optional lens-smudge detector."
        case .decideLater: "Return to items previously marked Later, starting with the oldest capture."
        case .noAlbum: "Review items outside user-created albums."
        case .unreviewed: "Continue through items that have not been reviewed yet."
        }
    }

    private static func assetPresentationOrder(
        _ lhs: OrganizeAssetPresentation,
        _ rhs: OrganizeAssetPresentation
    ) -> Bool {
        let left = lhs.creationDate ?? .distantPast
        let right = rhs.creationDate ?? .distantPast
        return left == right ? lhs.id < rhs.id : left > right
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

private enum OrganizeBrowseQueryEngine {
    private struct GroupKey: Hashable {
        let id: String
        let title: String
        let chronologicalDate: Date?
    }

    static func sections(
        for query: OrganizeBrowseQuery,
        assets: [OrganizeAssetPresentation]
    ) throws -> [OrganizeBrowseSection] {
        let filter = query.configuration.filter
        let calendar = Calendar.current
        let startDate = filter.useStartDate ? calendar.startOfDay(for: filter.startDate) : nil
        let endDate = filter.useEndDate
            ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: filter.endDate))
            : nil
        var result: [OrganizeAssetPresentation] = []
        result.reserveCapacity(query.scopeAssetIDs?.count ?? assets.count)
        for (index, asset) in assets.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if let scope = query.scopeAssetIDs, !scope.contains(asset.id) { continue }
            if matches(asset, filter: filter, startDate: startDate, endDate: endDate) {
                result.append(asset)
            }
        }
        try Task.checkCancellation()
        result.sort { orderedBefore($0, $1, configuration: query.configuration) }
        try Task.checkCancellation()

        guard query.configuration.grouping != .none else {
            return [OrganizeBrowseSection(id: "all", title: nil, assets: result)]
        }
        var grouped: [GroupKey: [OrganizeAssetPresentation]] = [:]
        for (index, asset) in result.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let key = groupKey(
                for: asset,
                grouping: query.configuration.grouping,
                calendar: calendar
            )
            grouped[key, default: []].append(asset)
        }
        return grouped.keys.sorted {
            groupOrderedBefore($0, $1, configuration: query.configuration)
        }.map { key in
            OrganizeBrowseSection(id: key.id, title: key.title, assets: grouped[key] ?? [])
        }
    }

    private static func matches(
        _ asset: OrganizeAssetPresentation,
        filter: OrganizeBrowseFilter,
        startDate: Date?,
        endDate: Date?
    ) -> Bool {
        if filter.media == .photos, asset.mediaKind != .photo { return false }
        if filter.media == .videos, asset.mediaKind != .video { return false }
        if !matches(asset.isScreenshot, filter.screenshots) { return false }
        if !matches(asset.isLivePhoto, filter.livePhotos) { return false }
        if !matches(asset.isRAW, filter.rawPhotos) { return false }
        if !matches(asset.isFavorite, filter.favorites) { return false }
        if !matches(asset.isEdited, filter.edited) { return false }
        if !matches(asset.isHidden, filter.hidden) { return false }
        if !matches(asset.hasLocation, filter.location) { return false }
        if filter.reviewState == .reviewed, !asset.isReviewed { return false }
        if filter.reviewState == .unreviewed, asset.isReviewed { return false }
        if filter.analysisState == .analyzed, asset.analysisState != .analyzed { return false }
        if filter.analysisState == .pending, asset.analysisState == .analyzed { return false }
        if filter.albumMode == .noAlbum, asset.albumCount != 0 { return false }
        if filter.albumMode == .selectedAlbum {
            guard let albumID = filter.selectedAlbumID, asset.albumIDs.contains(albumID) else { return false }
        }
        if let format = filter.fileFormat, asset.fileFormat != format { return false }
        if let orientation = filter.orientation {
            let actual: OrganizeOrientation
            if asset.pixelWidth == asset.pixelHeight { actual = .square }
            else if asset.pixelWidth > asset.pixelHeight { actual = .landscape }
            else { actual = .portrait }
            if actual != orientation { return false }
        }
        if let startDate, (asset.creationDate ?? .distantPast) < startDate { return false }
        if let endDate, (asset.creationDate ?? .distantFuture) >= endDate { return false }
        if let minimumBytes = filter.minimumBytes, (asset.knownBytes ?? -1) < minimumBytes { return false }
        if let minimumMegapixels = filter.minimumMegapixels, asset.megapixels < minimumMegapixels { return false }
        if let minimumDuration = filter.minimumDurationMilliseconds,
           (asset.durationMilliseconds ?? -1) < minimumDuration { return false }
        return true
    }

    private static func matches(_ value: Bool, _ filter: OrganizeTriStateFilter) -> Bool {
        switch filter {
        case .any: true
        case .only: value
        case .exclude: !value
        }
    }

    private static func orderedBefore(
        _ lhs: OrganizeAssetPresentation,
        _ rhs: OrganizeAssetPresentation,
        configuration: OrganizeBrowseConfiguration
    ) -> Bool {
        let result: ComparisonResult
        switch configuration.sort {
        case .creationDate: result = compareOptional(lhs.creationDate, rhs.creationDate)
        case .modificationDate: result = compareOptional(lhs.modificationDate, rhs.modificationDate)
        case .addedDate: result = compareOptional(lhs.addedDate, rhs.addedDate)
        case .filename: result = lhs.originalFilename.localizedStandardCompare(rhs.originalFilename)
        case .knownSize: result = compareOptional(lhs.knownBytes, rhs.knownBytes)
        case .resolution: result = compare(Int64(lhs.pixelWidth) * Int64(lhs.pixelHeight), Int64(rhs.pixelWidth) * Int64(rhs.pixelHeight))
        case .duration: result = compareOptional(lhs.durationMilliseconds, rhs.durationMilliseconds)
        case .albumCount: result = compare(lhs.albumCount, rhs.albumCount)
        case .reviewState: result = compare(lhs.isReviewed ? 1 : 0, rhs.isReviewed ? 1 : 0)
        }
        if result == .orderedSame { return lhs.id < rhs.id }
        if configuration.direction == .ascending { return result == .orderedAscending }
        if isMissingSortValue(lhs, sort: configuration.sort) != isMissingSortValue(rhs, sort: configuration.sort) {
            return !isMissingSortValue(lhs, sort: configuration.sort)
        }
        return result == .orderedDescending
    }

    private static func isMissingSortValue(
        _ asset: OrganizeAssetPresentation,
        sort: OrganizeBrowseSortOption
    ) -> Bool {
        switch sort {
        case .creationDate: asset.creationDate == nil
        case .modificationDate: asset.modificationDate == nil
        case .addedDate: asset.addedDate == nil
        case .knownSize: asset.knownBytes == nil
        case .duration: asset.durationMilliseconds == nil
        default: false
        }
    }

    private static func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.none, .none): .orderedSame
        case (.none, .some): .orderedDescending
        case (.some, .none): .orderedAscending
        case let (.some(lhs), .some(rhs)): compare(lhs, rhs)
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func groupKey(
        for asset: OrganizeAssetPresentation,
        grouping: OrganizeBrowseGrouping,
        calendar: Calendar
    ) -> GroupKey {
        switch grouping {
        case .none:
            return GroupKey(id: "all", title: "", chronologicalDate: nil)
        case .month:
            guard let date = asset.creationDate,
                  let start = calendar.dateInterval(of: .month, for: date)?.start else {
                return GroupKey(id: "date-unknown", title: "Date Unknown", chronologicalDate: nil)
            }
            return GroupKey(
                id: "month-\(start.timeIntervalSinceReferenceDate)",
                title: date.formatted(.dateTime.month(.wide).year()),
                chronologicalDate: start
            )
        case .year:
            guard let date = asset.creationDate,
                  let start = calendar.dateInterval(of: .year, for: date)?.start else {
                return GroupKey(id: "date-unknown", title: "Date Unknown", chronologicalDate: nil)
            }
            return GroupKey(
                id: "year-\(start.timeIntervalSinceReferenceDate)",
                title: date.formatted(.dateTime.year()),
                chronologicalDate: start
            )
        case .mediaType:
            let title = asset.mediaKind == .video ? "Videos" : "Photos"
            return GroupKey(id: title, title: title, chronologicalDate: nil)
        case .album:
            let title = asset.albumNames.first ?? "Not in an Album"
            return GroupKey(id: title, title: title, chronologicalDate: nil)
        case .reviewState:
            let title = asset.isReviewed ? "Reviewed" : "Unreviewed"
            return GroupKey(id: title, title: title, chronologicalDate: nil)
        }
    }

    private static func groupOrderedBefore(
        _ lhs: GroupKey,
        _ rhs: GroupKey,
        configuration: OrganizeBrowseConfiguration
    ) -> Bool {
        guard configuration.grouping == .month || configuration.grouping == .year else {
            return lhs.title < rhs.title
        }

        switch (lhs.chronologicalDate, rhs.chronologicalDate) {
        case let (.some(left), .some(right)):
            if left == right { return lhs.id < rhs.id }
            return configuration.direction == .ascending ? left < right : left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.id < rhs.id
        }
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}
