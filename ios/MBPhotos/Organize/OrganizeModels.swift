import Foundation

// MARK: - Browse and breakdown models

struct OrganizeAsset: Identifiable, Codable, Hashable, Sendable {
    let asset: PhotoAsset
    let albumIDs: Set<String>

    init(asset: PhotoAsset, albumIDs: Set<String> = []) {
        self.asset = asset
        self.albumIDs = albumIDs
    }

    var id: String { asset.id }
    var originalFilename: String? {
        asset.resources
            .map(\.originalFilename)
            .sorted(by: OrganizeText.lessThan)
            .first
    }
    var pixelCount: Int64 { Int64(asset.pixelWidth) * Int64(asset.pixelHeight) }
}

enum OrganizeSortMetric: String, Codable, CaseIterable, Sendable {
    case captureDate
    case modificationDate
    case filename
    case analyzedByteCount
    case resolution
    case duration
    case albumCount
    case reviewState
    case dateAdded
}

enum OrganizeSortDirection: String, Codable, CaseIterable, Sendable {
    case ascending
    case descending
}

struct OrganizeSort: Codable, Equatable, Sendable {
    var metric: OrganizeSortMetric
    var direction: OrganizeSortDirection

    init(metric: OrganizeSortMetric = .captureDate, direction: OrganizeSortDirection = .descending) {
        self.metric = metric
        self.direction = direction
    }
}

enum OrganizeGrouping: String, Codable, CaseIterable, Sendable {
    case none
    case month
    case year
    case mediaKind
    case album
    case reviewState
}

enum OrganizeOrientation: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
    case square
}

struct OrganizeFilter: Codable, Equatable, Sendable {
    var mediaKinds: Set<MediaKind> = []
    var mediaSubtypes: Set<AssetMediaSubtype> = []
    var captureDateStart: Date?
    var captureDateEnd: Date?
    var formats: Set<String> = []
    var minimumKnownByteCount: Int64?
    var maximumKnownByteCount: Int64?
    var minimumPixelCount: Int64?
    var maximumPixelCount: Int64?
    var orientations: Set<OrganizeOrientation> = []
    var minimumDurationMilliseconds: Int?
    var maximumDurationMilliseconds: Int?
    var isFavorite: Bool?
    var isEdited: Bool?
    var isHidden: Bool?
    var albumIDs: Set<String> = []
    var hasAlbum: Bool?
    var hasLocation: Bool?
    var reviewStates: Set<AssetReviewState> = []
    var analysisStatuses: Set<AnalysisStatus> = []

    init() {}
}

enum OrganizeBreakdownKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case regularPhotos
    case screenshots
    case videos
    case livePhotos
    case raw
    case favorites
    case edited
    case noAlbum

    var id: String { rawValue }
}

struct OrganizeMetricBucket: Identifiable, Codable, Equatable, Sendable {
    let kind: OrganizeBreakdownKind
    let itemCount: Int
    let knownByteCount: Int64

    var id: OrganizeBreakdownKind { kind }
}

struct OrganizeLibraryMetrics: Codable, Equatable, Sendable {
    let accessibleItemCount: Int
    let knownMediaByteCount: Int64
    let analyzedItemCount: Int
    let buckets: [OrganizeMetricBucket]

    var analysisCoverage: Double {
        guard accessibleItemCount > 0 else { return 1 }
        return Double(analyzedItemCount) / Double(accessibleItemCount)
    }
}

// MARK: - Analysis and recommendations

enum AnalysisStatus: String, Codable, CaseIterable, Sendable {
    case notAnalyzed
    case queued
    case analyzing
    case complete
    case unavailableLocally
    case failed
}

enum AnalysisRunStatus: String, Codable, Sendable {
    case running
    case paused
    case complete
    case failed
}

enum AnalysisRunOrigin: String, Codable, Sendable {
    case userInitiated
    case automaticMaintenance
}

struct AnalysisRunRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let includesICloudItems: Bool
    let origin: AnalysisRunOrigin
    let orderedAssetIDs: [String]
    var completedAssetIDs: Set<String>
    var status: AnalysisRunStatus
    let startedAt: Date
    var updatedAt: Date
    var errorMessage: String?

    init(
        id: UUID,
        includesICloudItems: Bool,
        orderedAssetIDs: [String],
        completedAssetIDs: Set<String>,
        status: AnalysisRunStatus,
        startedAt: Date,
        updatedAt: Date,
        errorMessage: String?,
        origin: AnalysisRunOrigin = .userInitiated
    ) {
        self.id = id
        self.includesICloudItems = includesICloudItems
        self.origin = origin
        self.orderedAssetIDs = orderedAssetIDs
        self.completedAssetIDs = completedAssetIDs
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case includesICloudItems
        case origin
        case orderedAssetIDs
        case completedAssetIDs
        case status
        case startedAt
        case updatedAt
        case errorMessage
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        includesICloudItems = try values.decode(Bool.self, forKey: .includesICloudItems)
        origin = try values.decodeIfPresent(AnalysisRunOrigin.self, forKey: .origin)
            ?? .userInitiated
        orderedAssetIDs = try values.decode([String].self, forKey: .orderedAssetIDs)
        completedAssetIDs = try values.decode(Set<String>.self, forKey: .completedAssetIDs)
        status = try values.decode(AnalysisRunStatus.self, forKey: .status)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    var completedAssetCount: Int { completedAssetIDs.count }
}

struct AssetAnalysisRecord: Identifiable, Codable, Equatable, Sendable {
    let assetID: String
    let sourceRevision: String
    var status: AnalysisStatus
    var fingerprint: AssetFingerprint?
    var updatedAt: Date
    var errorMessage: String?

    var id: String { assetID }
    var knownByteCount: Int64? {
        status == .complete ? fingerprint?.knownByteCount : nil
    }
    var exactDuplicateKey: String? {
        guard status == .complete, fingerprint?.resources.isEmpty == false else { return nil }
        return fingerprint?.exactDuplicateKey
    }
}

enum OrganizeRecommendationDefaults {
    static let oldScreenshotMinimumAge: TimeInterval = 90 * 24 * 60 * 60
    static let veryShortVideoMaximumDurationMilliseconds = 3_000
    static let tinyImageMaximumPixelCount: Int64 = 1_000_000
    static let largeVideoMinimumKnownByteCount: Int64 = 500_000_000
    static let largeSpecialtyMinimumKnownByteCount: Int64 = 100_000_000
    static let specialtyMediaSubtypes: Set<AssetMediaSubtype> = [
        .livePhoto,
        .panorama,
        .raw,
        .spatialMedia,
        .slowMotion,
        .highFrameRate,
        .timelapse,
        .cinematic
    ]
}

enum RecommendationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case exactDuplicates
    case screenshots
    case screenRecordings
    case oldScreenshots
    case veryShortVideos
    case tinyImages
    case largeVideos
    case largeSpecialtyMedia
    case bursts
    case rapidRetakes
    case similarPhotos
    case similarScreenshots
    case worthReviewing
    case textHeavyDocuments
    case noClearSubject
    case smudgedCaptures
    case decideLater
    case noAlbum
    case unreviewed

    var id: String { rawValue }
}

enum RecommendationAvailability: String, Codable, Sendable {
    case ready
    case analysisRequired
    case analysisInProgress
    case partial
}

enum DuplicateKeeperReason: String, Codable, Sendable {
    case protectedAlbum
    case protectedItem
    case favorite
    case moreAlbumMemberships
    case stableIdentifier
}

struct DuplicateGroup: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let exactDuplicateKey: String
    let assetIDs: [String]
    let recommendedKeeperID: String
    let keeperReason: DuplicateKeeperReason
    let reclaimableKnownByteCount: Int64
}

struct OrganizeRecommendation: Identifiable, Codable, Equatable, Sendable {
    let kind: RecommendationKind
    let assetIDs: [String]
    let knownByteCount: Int64
    let availability: RecommendationAvailability
    let duplicateGroups: [DuplicateGroup]

    var id: RecommendationKind { kind }
    var itemCount: Int { assetIDs.count }
}

// MARK: - Review session and durable decisions

enum ReviewDecision: String, Codable, CaseIterable, Sendable {
    case keep
    case moveToRecentlyDeleted
    case later

    var reviewState: AssetReviewState? {
        switch self {
        case .keep: .kept
        case .moveToRecentlyDeleted: .queuedForRecentlyDeleted
        case .later: nil
        }
    }
}

enum AssetReviewState: String, Codable, CaseIterable, Sendable {
    case unreviewed
    case kept
    case queuedForRecentlyDeleted
}

enum ReviewSessionStatus: String, Codable, Sendable {
    case active
    case completed
}

struct ReviewAction: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let sequence: Int
    let assetID: String
    let decision: ReviewDecision
    let previousDecision: ReviewDecision?
    let cursorBefore: Int
    let cursorAfter: Int
    let createdAt: Date
    /// Exact presentation state used to restore undo after relaunch. Optional so
    /// records written before these fields existed remain decodable.
    let wasQueued: Bool?
    let wasReviewed: Bool?
}

struct ReviewSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let recommendationKind: RecommendationKind
    let orderedAssetIDs: [String]
    let createdAt: Date
    var updatedAt: Date
    var cursor: Int
    var decisions: [String: ReviewDecision]
    var actions: [ReviewAction]
    var status: ReviewSessionStatus

    init(
        id: UUID = UUID(),
        recommendationKind: RecommendationKind,
        orderedAssetIDs: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.recommendationKind = recommendationKind
        self.orderedAssetIDs = orderedAssetIDs
        self.createdAt = createdAt
        updatedAt = createdAt
        cursor = 0
        decisions = [:]
        actions = []
        status = orderedAssetIDs.isEmpty ? .completed : .active
    }

    var currentAssetID: String? {
        orderedAssetIDs.indices.contains(cursor) ? orderedAssetIDs[cursor] : nil
    }

    @discardableResult
    mutating func apply(_ decision: ReviewDecision, at date: Date = Date()) -> ReviewAction? {
        guard let assetID = currentAssetID else { return nil }
        let action = ReviewAction(
            id: UUID(),
            sessionID: id,
            sequence: actions.count,
            assetID: assetID,
            decision: decision,
            previousDecision: decisions[assetID],
            cursorBefore: cursor,
            cursorAfter: cursor + 1,
            createdAt: date,
            wasQueued: decisions[assetID] == .moveToRecentlyDeleted,
            wasReviewed: decisions[assetID] == .keep
        )
        decisions[assetID] = decision
        actions.append(action)
        cursor += 1
        updatedAt = date
        status = cursor >= orderedAssetIDs.count ? .completed : .active
        return action
    }

    @discardableResult
    mutating func undo(at date: Date = Date()) -> ReviewAction? {
        guard let action = actions.popLast() else { return nil }
        if let previous = action.previousDecision {
            decisions[action.assetID] = previous
        } else {
            decisions.removeValue(forKey: action.assetID)
        }
        cursor = action.cursorBefore
        updatedAt = date
        status = .active
        return action
    }
}

struct AssetReviewStateRecord: Identifiable, Codable, Equatable, Sendable {
    let assetID: String
    let sourceRevision: String
    let state: AssetReviewState
    let recommendationKind: RecommendationKind?
    let updatedAt: Date

    var id: String { assetID }
}

// MARK: - Recently Deleted queue and audit history

struct DeletionQueueItem: Identifiable, Codable, Equatable, Sendable {
    let assetID: String
    let sourceRevision: String
    let recommendationKind: RecommendationKind?
    let queuedAt: Date
    let protectionOverride: Bool
    let reviewSessionID: UUID?

    var id: String { assetID }
}

struct ProtectedAlbumRecord: Identifiable, Codable, Equatable, Sendable {
    let albumID: String
    let title: String
    let protectedAt: Date

    var id: String { albumID }
}

enum DeletionBatchStatus: String, Codable, Sendable {
    case preparing
    case movedToRecentlyDeleted
    /// PhotoKit may have completed the request, but the app terminated before its
    /// completion callback could be durably journaled. This is intentionally not
    /// treated as a confirmed move.
    case confirmationInterrupted
    case failed
    case cancelled
}

struct DeletionBatch: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let requestedAt: Date
    var completedAt: Date?
    var status: DeletionBatchStatus
    var itemCount: Int
    var knownByteCount: Int64
    var errorMessage: String?
}

enum DeletedItemResult: String, Codable, Sendable {
    case prepared
    case movedToRecentlyDeleted
    case confirmationInterrupted
}

struct DeletedItemRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let batchID: UUID
    let sourceLocalIdentifier: String
    let sourceRevision: String
    let originalFilename: String
    let mediaKind: MediaKind
    let creationDate: Date?
    let deletedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let durationMilliseconds: Int?
    let knownByteCount: Int64?
    let recommendationKind: RecommendationKind?
    let isLivePhoto: Bool
    let isRaw: Bool
    let isFavorite: Bool
    let isHidden: Bool
    let isEdited: Bool
    let result: DeletedItemResult
    var thumbnailRelativePath: String?
    var thumbnailExpiresAt: Date?
}

enum OrganizeText {
    static func lessThan(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let right = rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return left == right ? lhs < rhs : left < right
    }
}
