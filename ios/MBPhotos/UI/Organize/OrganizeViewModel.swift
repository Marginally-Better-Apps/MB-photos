import AVFoundation
import Foundation
@preconcurrency import Photos
import SwiftUI
import UIKit

// MARK: - Presentation types

enum OrganizeRecommendationCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
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

enum OrganizeRecommendationDestination: Hashable, Sendable {
    case review
    case browse
    case duplicates
}

struct OrganizeRecommendationPresentation: Identifiable, Hashable, Sendable {
    let kind: OrganizeRecommendationCategory
    let title: String
    let detail: String
    let systemImage: String
    let assetIDs: [String]
    let assetIDSet: Set<String>
    let knownBytes: Int64
    let destination: OrganizeRecommendationDestination
    /// Per-item evidence is deliberately presentation-only. Durable review
    /// decisions retain the recommendation category, while changing Vision
    /// revisions can safely rebuild the explanation on the next render.
    let evidenceByAssetID: [String: String]

    init(
        kind: OrganizeRecommendationCategory,
        title: String,
        detail: String,
        systemImage: String,
        assetIDs: [String],
        assetIDSet: Set<String>,
        knownBytes: Int64,
        destination: OrganizeRecommendationDestination,
        evidenceByAssetID: [String: String] = [:]
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.assetIDs = assetIDs
        self.assetIDSet = assetIDSet
        self.knownBytes = knownBytes
        self.destination = destination
        self.evidenceByAssetID = evidenceByAssetID
    }

    var id: OrganizeRecommendationCategory { kind }
    var itemCount: Int { assetIDs.count }

    func evidence(for assetID: String) -> String {
        evidenceByAssetID[assetID] ?? detail
    }
}

enum OrganizePrimaryReviewEntry: Equatable, Sendable {
    case resume(OrganizeReviewSessionPresentation)
    case start(OrganizeRecommendationPresentation)
    case complete

    var remainingItemCount: Int {
        switch self {
        case let .resume(session):
            max(session.assetIDs.count - session.currentIndex, 0)
        case let .start(recommendation):
            recommendation.itemCount
        case .complete:
            0
        }
    }

    func remainingKnownBytes(
        knownBytesForAssetID: (String) -> Int64?
    ) -> Int64 {
        switch self {
        case let .resume(session):
            return session.assetIDs
                .dropFirst(min(session.currentIndex, session.assetIDs.count))
                .reduce(into: Int64(0)) { total, id in
                    total = Self.saturatingAdd(total, knownBytesForAssetID(id) ?? 0)
                }
        case let .start(recommendation):
            return recommendation.knownBytes
        case .complete:
            return 0
        }
    }

    /// Returns the next review IDs without reordering or backfilling gaps. Stopping
    /// at the first unavailable ID keeps the dashboard's front card aligned with
    /// the item the review deck will actually attempt to open.
    func previewAssetIDs(
        limit: Int = 3,
        isAvailable: (String) -> Bool = { _ in true }
    ) -> [String] {
        guard limit > 0 else { return [] }

        let remainingIDs: ArraySlice<String>
        switch self {
        case let .resume(session):
            remainingIDs = session.assetIDs.dropFirst(min(session.currentIndex, session.assetIDs.count))
        case let .start(recommendation):
            remainingIDs = recommendation.assetIDs[...]
        case .complete:
            return []
        }

        var previewIDs: [String] = []
        previewIDs.reserveCapacity(min(limit, remainingIDs.count))
        for id in remainingIDs.prefix(limit) {
            guard isAvailable(id) else { break }
            previewIDs.append(id)
        }
        return previewIDs
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

enum OrganizeMetricTint: Hashable, Sendable {
    case blue
    case purple
    case orange
    case green
    case gray
}

struct OrganizeBreakdownMetric: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let itemCount: Int
    let knownBytes: Int64
    let processedAssetCount: Int
    let analyzedAssetCount: Int
    let unavailableAssetCount: Int
    let failedAssetCount: Int
    let tint: OrganizeMetricTint
    let overlapsPrimaryCategories: Bool

    init(
        id: String,
        title: String,
        systemImage: String,
        itemCount: Int,
        knownBytes: Int64,
        processedAssetCount: Int = 0,
        analyzedAssetCount: Int = 0,
        unavailableAssetCount: Int = 0,
        failedAssetCount: Int = 0,
        tint: OrganizeMetricTint,
        overlapsPrimaryCategories: Bool
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.itemCount = itemCount
        self.knownBytes = knownBytes
        self.processedAssetCount = min(max(processedAssetCount, 0), itemCount)
        self.analyzedAssetCount = min(max(analyzedAssetCount, 0), itemCount)
        self.unavailableAssetCount = min(max(unavailableAssetCount, 0), itemCount)
        self.failedAssetCount = min(max(failedAssetCount, 0), itemCount)
        self.tint = tint
        self.overlapsPrimaryCategories = overlapsPrimaryCategories
    }

    var pendingAssetCount: Int {
        max(itemCount - processedAssetCount, 0)
    }

    var hasPendingAnalysis: Bool { pendingAssetCount > 0 }
}

enum OrganizeAnalysisPhase: Equatable, Sendable {
    case notStarted
    case running
    case paused
    case complete
    case failed
}

struct OrganizeAnalysisPresentation: Equatable, Sendable {
    var phase: OrganizeAnalysisPhase = .notStarted
    /// Assets durably attempted in the current library snapshot, including items
    /// whose originals are unavailable locally or whose analysis failed.
    var processedAssetCount = 0
    /// Assets with a complete, exact resource fingerprint and known byte count.
    var completedAssetCount = 0
    var totalAssetCount = 0
    var currentAssetFraction = 0.0
    var unavailableAssetCount = 0
    var failedAssetCount = 0
    var includesICloudItems = false
    var statusText = "Analyze the accessible library to calculate exact original media sizes and find byte-identical duplicates."

    var fractionComplete: Double {
        guard totalAssetCount > 0 else { return 0 }
        let processed = min(max(processedAssetCount, 0), totalAssetCount)
        let current = min(max(currentAssetFraction, 0), 1)
        return min(max((Double(processed) + current) / Double(totalAssetCount), 0), 1)
    }
}

enum OrganizeAssetAnalysisState: String, CaseIterable, Hashable, Sendable {
    case notAnalyzed
    case analyzed
    case unavailable
    case failed
}

struct OrganizeAssetPresentation: Identifiable, Hashable, Sendable {
    let id: String
    let originalFilename: String
    let mediaKind: MediaKind
    let creationDate: Date?
    let modificationDate: Date?
    let addedDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let durationMilliseconds: Int?
    let knownBytes: Int64?
    let albumIDs: [String]
    let albumNames: [String]
    let fileFormat: String?
    let sourceRevision: String
    let burstIdentifier: String?
    let hasLocation: Bool
    let isFavorite: Bool
    let isHidden: Bool
    let isEdited: Bool
    let isLivePhoto: Bool
    let isRAW: Bool
    let isScreenshot: Bool
    let isProtected: Bool
    var isReviewed: Bool
    var analysisState: OrganizeAssetAnalysisState

    var albumCount: Int { albumIDs.count }
    var megapixels: Double { Double(pixelWidth * pixelHeight) / 1_000_000 }
    var isVideo: Bool { mediaKind == .video }

    var protectionSummary: String? {
        var reasons: [String] = []
        if isFavorite { reasons.append("Favorite") }
        if isHidden { reasons.append("Hidden") }
        if isEdited { reasons.append("Edited") }
        if isRAW { reasons.append("RAW") }
        if isProtected, reasons.isEmpty { reasons.append("Protected") }
        return reasons.isEmpty ? nil : reasons.joined(separator: ", ")
    }
}

enum OrganizeBrowseSortOption: String, CaseIterable, Identifiable, Sendable {
    case creationDate
    case modificationDate
    case addedDate
    case filename
    case knownSize
    case resolution
    case duration
    case albumCount
    case reviewState

    var id: String { rawValue }

    var label: String {
        switch self {
        case .creationDate: "Capture Date"
        case .modificationDate: "Modified Date"
        case .addedDate: "Date Added"
        case .filename: "Filename"
        case .knownSize: "Analyzed Size"
        case .resolution: "Resolution"
        case .duration: "Duration"
        case .albumCount: "Album Count"
        case .reviewState: "Review State"
        }
    }

    var systemImage: String {
        switch self {
        case .creationDate, .modificationDate, .addedDate: "calendar"
        case .filename: "textformat"
        case .knownSize: "externaldrive"
        case .resolution: "aspectratio"
        case .duration: "timer"
        case .albumCount: "rectangle.stack"
        case .reviewState: "checkmark.circle"
        }
    }
}

enum OrganizeBrowseGrouping: String, CaseIterable, Identifiable, Sendable {
    case none
    case month
    case year
    case mediaType
    case album
    case reviewState

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .month: "Month"
        case .year: "Year"
        case .mediaType: "Media Type"
        case .album: "Album"
        case .reviewState: "Review State"
        }
    }
}

enum OrganizeMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case photos
    case videos

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum OrganizeTriStateFilter: String, CaseIterable, Identifiable, Sendable {
    case any
    case only
    case exclude

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum OrganizeAlbumFilterMode: String, CaseIterable, Identifiable, Sendable {
    case any
    case noAlbum
    case selectedAlbum

    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: "Any Album State"
        case .noAlbum: "Not in an Album"
        case .selectedAlbum: "In Selected Album"
        }
    }
}

enum OrganizeReviewStateFilter: String, CaseIterable, Identifiable, Sendable {
    case any
    case reviewed
    case unreviewed

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum OrganizeAnalysisFilter: String, CaseIterable, Identifiable, Sendable {
    case any
    case analyzed
    case pending

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct OrganizeBrowseFilter: Equatable, Sendable {
    var media: OrganizeMediaFilter = .all
    var screenshots: OrganizeTriStateFilter = .any
    var livePhotos: OrganizeTriStateFilter = .any
    var rawPhotos: OrganizeTriStateFilter = .any
    var favorites: OrganizeTriStateFilter = .any
    var edited: OrganizeTriStateFilter = .any
    var hidden: OrganizeTriStateFilter = .any
    var location: OrganizeTriStateFilter = .any
    var reviewState: OrganizeReviewStateFilter = .any
    var analysisState: OrganizeAnalysisFilter = .any
    var albumMode: OrganizeAlbumFilterMode = .any
    var selectedAlbumID: String?
    var fileFormat: String?
    var orientation: OrganizeOrientation?
    var useStartDate = false
    var startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    var useEndDate = false
    var endDate = Date()
    var minimumBytes: Int64?
    var minimumMegapixels: Double?
    var minimumDurationMilliseconds: Int?

    var isActive: Bool {
        media != .all
            || screenshots != .any
            || livePhotos != .any
            || rawPhotos != .any
            || favorites != .any
            || edited != .any
            || hidden != .any
            || location != .any
            || reviewState != .any
            || analysisState != .any
            || albumMode != .any
            || selectedAlbumID != nil
            || fileFormat != nil
            || orientation != nil
            || useStartDate
            || useEndDate
            || minimumBytes != nil
            || minimumMegapixels != nil
            || minimumDurationMilliseconds != nil
    }
}

struct OrganizeBrowseConfiguration: Equatable, Sendable {
    var sort: OrganizeBrowseSortOption = .creationDate
    var direction: OrganizeSortDirection = .descending
    var grouping: OrganizeBrowseGrouping = .month
    var filter = OrganizeBrowseFilter()
}

struct OrganizeBrowseSection: Identifiable, Sendable {
    let id: String
    let title: String?
    let assets: [OrganizeAssetPresentation]
}

enum OrganizeReviewChoice: String, Hashable, Sendable {
    case keep
    case queueForRecentlyDeleted
    case later
}

struct OrganizeReviewActionPresentation: Hashable, Sendable {
    let id: UUID
    let assetID: String
    let choice: OrganizeReviewChoice
    let previousChoice: OrganizeReviewChoice?
    let previousIndex: Int
    let wasQueued: Bool
    let wasReviewed: Bool
}

struct OrganizeReviewSessionPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let recommendationKind: OrganizeRecommendationCategory
    let title: String
    let reason: String
    let assetIDs: [String]
    var currentIndex: Int
    var decisions: [String: OrganizeReviewChoice]
    var undoStack: [OrganizeReviewActionPresentation]
    var evidenceByAssetID: [String: String]

    init(
        id: UUID,
        recommendationKind: OrganizeRecommendationCategory,
        title: String,
        reason: String,
        assetIDs: [String],
        currentIndex: Int,
        decisions: [String: OrganizeReviewChoice],
        undoStack: [OrganizeReviewActionPresentation],
        evidenceByAssetID: [String: String] = [:]
    ) {
        self.id = id
        self.recommendationKind = recommendationKind
        self.title = title
        self.reason = reason
        self.assetIDs = assetIDs
        self.currentIndex = currentIndex
        self.decisions = decisions
        self.undoStack = undoStack
        self.evidenceByAssetID = evidenceByAssetID
    }

    var currentAssetID: String? {
        guard assetIDs.indices.contains(currentIndex) else { return nil }
        return assetIDs[currentIndex]
    }

    var isComplete: Bool { currentIndex >= assetIDs.count }
    var completedCount: Int { min(currentIndex, assetIDs.count) }

    func evidence(for assetID: String) -> String {
        evidenceByAssetID[assetID] ?? reason
    }
}

struct OrganizeDuplicateGroupPresentation: Identifiable, Hashable, Sendable {
    let id: String
    let assetIDs: [String]
    let knownReclaimableBytes: Int64
}

enum OrganizeDeletedRecordStatus: String, Hashable, Sendable {
    case movedToRecentlyDeleted
    case confirmationInterrupted

    var label: String {
        switch self {
        case .movedToRecentlyDeleted: "Moved to Recently Deleted"
        case .confirmationInterrupted: "Result Not Recorded"
        }
    }
}

struct OrganizeDeletedItemPresentation: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceAssetID: String
    let sourceRevision: String
    let originalFilename: String
    let mediaKind: MediaKind
    let captureDate: Date?
    let deletedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let durationMilliseconds: Int?
    let knownBytes: Int64?
    let recommendationSource: String
    let isFavorite: Bool
    let isHidden: Bool
    let isEdited: Bool
    let isLivePhoto: Bool
    let isRAW: Bool
    let status: OrganizeDeletedRecordStatus
    let thumbnailExpiresAt: Date?

    var hasLiveThumbnail: Bool {
        guard let thumbnailExpiresAt else { return false }
        return thumbnailExpiresAt > Date()
    }
}

struct OrganizeDeletedBatchPresentation: Identifiable, Hashable, Sendable {
    let id: UUID
    let deletedAt: Date
    let records: [OrganizeDeletedItemPresentation]
    let photoKitResult: String
}

enum OrganizeMoveOutcome: Sendable {
    case moved(OrganizeDeletedBatchPresentation, auditWarning: String?)
    case needsReview(missingAssetIDs: [String], changedAssetIDs: [String])
}

/// A queue persistence intent contains only the IDs affected by one UI action.
/// It deliberately never owns the view model's complete live queue collections.
enum OrganizeQueuePersistenceDelta: Equatable, Sendable {
    case upsert(
        assetIDs: Set<String>,
        recommendationKind: OrganizeRecommendationCategory?,
        allowProtected: Bool
    )
    case remove(assetIDs: [String])
}

/// Monotonic, single-album persistence intent. Generations let the receiver reject
/// obsolete completion-side presentation updates even though writes are serialized.
struct OrganizeProtectedAlbumPersistenceDelta: Equatable, Sendable {
    let generation: UInt64
    let albumID: String
    let isProtected: Bool
}

struct OrganizeAlbumPresentation: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let assetCount: Int
}

struct OrganizeUserMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Integration callbacks

typealias OrganizeDeletionIntentValidator = @MainActor @Sendable () -> Bool

/// All side effects enter through this value. The SwiftUI presentation never talks to PhotoKit,
/// the database, or the thumbnail cache directly.
struct OrganizeViewModelCallbacks {
    var requestAuthorization: (@MainActor () async -> Void)?
    var presentLimitedPicker: (@MainActor () -> Void)?
    var openSettings: (@MainActor () -> Void)?
    var refreshLibrary: (@MainActor () async -> Void)?
    var loadThumbnail: (@MainActor (_ assetID: String, _ size: CGSize) async -> UIImage?)?
    var loadVideoPlayer: (@MainActor (_ assetID: String) async -> AVPlayer?)?
    var loadLivePhoto: (@MainActor (_ assetID: String, _ size: CGSize) async -> PHLivePhoto?)?
    var loadDeletedThumbnail: (@MainActor (_ recordID: UUID, _ size: CGSize) async -> UIImage?)?
    var startAnalysis: (@MainActor (_ includeICloudItems: Bool) async throws -> Void)?
    var persistReviewSession: (@MainActor (_ session: OrganizeReviewSessionPresentation) async -> Void)?
    var persistReviewChoice: (@MainActor (_ sessionID: UUID, _ action: OrganizeReviewActionPresentation, _ resultingCursor: Int, _ isComplete: Bool) async -> Void)?
    var persistReviewUndo: (@MainActor (_ sessionID: UUID, _ action: OrganizeReviewActionPresentation, _ resultingCursor: Int) async -> Void)?
    var persistQueue: (@MainActor (_ assetIDs: Set<String>, _ recommendations: [String: OrganizeRecommendationCategory]) async -> Void)?
    var persistQueueDelta: (@MainActor (_ delta: OrganizeQueuePersistenceDelta) async -> Void)?
    var persistProtectedAlbums: (@MainActor (_ albumIDs: Set<String>) async -> Void)?
    var persistProtectedAlbumDelta: (@MainActor (_ delta: OrganizeProtectedAlbumPersistenceDelta) async -> Void)?
    var moveToRecentlyDeleted: (@MainActor (
        _ assetIDs: [String],
        _ intentValidator: @escaping OrganizeDeletionIntentValidator
    ) async throws -> OrganizeMoveOutcome)?
    var cleanExpiredThumbnails: (@MainActor () async -> Void)?
    var autoAnalyzePreferenceChanged: (@MainActor (_ isEnabled: Bool) -> Void)?

    init(
        requestAuthorization: (@MainActor () async -> Void)? = nil,
        presentLimitedPicker: (@MainActor () -> Void)? = nil,
        openSettings: (@MainActor () -> Void)? = nil,
        refreshLibrary: (@MainActor () async -> Void)? = nil,
        loadThumbnail: (@MainActor (_ assetID: String, _ size: CGSize) async -> UIImage?)? = nil,
        loadVideoPlayer: (@MainActor (_ assetID: String) async -> AVPlayer?)? = nil,
        loadLivePhoto: (@MainActor (_ assetID: String, _ size: CGSize) async -> PHLivePhoto?)? = nil,
        loadDeletedThumbnail: (@MainActor (_ recordID: UUID, _ size: CGSize) async -> UIImage?)? = nil,
        startAnalysis: (@MainActor (_ includeICloudItems: Bool) async throws -> Void)? = nil,
        persistReviewSession: (@MainActor (_ session: OrganizeReviewSessionPresentation) async -> Void)? = nil,
        persistReviewChoice: (@MainActor (_ sessionID: UUID, _ action: OrganizeReviewActionPresentation, _ resultingCursor: Int, _ isComplete: Bool) async -> Void)? = nil,
        persistReviewUndo: (@MainActor (_ sessionID: UUID, _ action: OrganizeReviewActionPresentation, _ resultingCursor: Int) async -> Void)? = nil,
        persistQueue: (@MainActor (_ assetIDs: Set<String>, _ recommendations: [String: OrganizeRecommendationCategory]) async -> Void)? = nil,
        persistQueueDelta: (@MainActor (_ delta: OrganizeQueuePersistenceDelta) async -> Void)? = nil,
        persistProtectedAlbums: (@MainActor (_ albumIDs: Set<String>) async -> Void)? = nil,
        persistProtectedAlbumDelta: (@MainActor (_ delta: OrganizeProtectedAlbumPersistenceDelta) async -> Void)? = nil,
        moveToRecentlyDeleted: (@MainActor (
            _ assetIDs: [String],
            _ intentValidator: @escaping OrganizeDeletionIntentValidator
        ) async throws -> OrganizeMoveOutcome)? = nil,
        cleanExpiredThumbnails: (@MainActor () async -> Void)? = nil,
        autoAnalyzePreferenceChanged: (@MainActor (_ isEnabled: Bool) -> Void)? = nil
    ) {
        self.requestAuthorization = requestAuthorization
        self.presentLimitedPicker = presentLimitedPicker
        self.openSettings = openSettings
        self.refreshLibrary = refreshLibrary
        self.loadThumbnail = loadThumbnail
        self.loadVideoPlayer = loadVideoPlayer
        self.loadLivePhoto = loadLivePhoto
        self.loadDeletedThumbnail = loadDeletedThumbnail
        self.startAnalysis = startAnalysis
        self.persistReviewSession = persistReviewSession
        self.persistReviewChoice = persistReviewChoice
        self.persistReviewUndo = persistReviewUndo
        self.persistQueue = persistQueue
        self.persistQueueDelta = persistQueueDelta
        self.persistProtectedAlbums = persistProtectedAlbums
        self.persistProtectedAlbumDelta = persistProtectedAlbumDelta
        self.moveToRecentlyDeleted = moveToRecentlyDeleted
        self.cleanExpiredThumbnails = cleanExpiredThumbnails
        self.autoAnalyzePreferenceChanged = autoAnalyzePreferenceChanged
    }
}

// MARK: - Observable presentation facade

@MainActor
final class OrganizeViewModel: ObservableObject {
    static let autoAnalyzeDefaultsKey = "organize.auto-analyze-enabled"

    @Published private(set) var presentationRevision: UInt64 = 0
    @Published private(set) var browseContentRevision: UInt64 = 0
    @Published private(set) var authorization: PhotoAuthorizationState
    @Published private(set) var assets: [OrganizeAssetPresentation] = []
    @Published private(set) var albums: [OrganizeAlbumPresentation] = []
    @Published private(set) var primaryBreakdown: [OrganizeBreakdownMetric] = []
    @Published private(set) var secondaryBreakdown: [OrganizeBreakdownMetric] = []
    @Published private(set) var reviewRecommendations: [OrganizeRecommendationPresentation] = []
    @Published private(set) var organizeRecommendations: [OrganizeRecommendationPresentation] = []
    @Published var browseConfiguration = OrganizeBrowseConfiguration()
    @Published private(set) var selectedAssetIDs: Set<String> = []
    @Published private(set) var queuedAssetIDs: Set<String> = []
    @Published private(set) var protectedAlbumIDs: Set<String> = []
    @Published private(set) var activeReviewSession: OrganizeReviewSessionPresentation?
    @Published private(set) var duplicateGroups: [OrganizeDuplicateGroupPresentation] = []
    @Published private(set) var deletedBatches: [OrganizeDeletedBatchPresentation] = []
    @Published var analysis = OrganizeAnalysisPresentation()
    @Published private(set) var totalKnownBytes: Int64 = 0
    @Published private(set) var analyzedItemCount = 0
    @Published private(set) var queueKnownBytes: Int64 = 0
    @Published private(set) var queuedAssets: [OrganizeAssetPresentation] = []
    @Published private(set) var availableFormats: [String] = []
    @Published private(set) var hasAssetsWithAddedDate = false
    @Published private(set) var deletedAuditRecordCount = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMovingToRecentlyDeleted = false
    @Published private(set) var autoAnalyzeEnabled: Bool
    @Published var userMessage: OrganizeUserMessage? {
        didSet {
            guard let userMessage, userMessage != oldValue else { return }
            CrashLogStore.shared.record(
                .info,
                category: "Organize",
                message: userMessage.message,
                metadata: ["title": userMessage.title]
            )
        }
    }

    private(set) var callbacks: OrganizeViewModelCallbacks
    private let settingsDefaults: UserDefaults
    private var worker = OrganizeWorker()
    private var fallbackPresentationTask: Task<Void, Never>?
    private var assetIndexByID: [String: Int] = [:]
    private var queuedAssetIndexByID: [String: Int] = [:]
    private var queuedAssetIDsInOrder: [String] = []
    private var reviewDecisionAssetIDs: [OrganizeReviewChoice: [String]] = [:]
    private var reviewDecisionAssetIndexByID: [OrganizeReviewChoice: [String: Int]] = [:]
    private var queuedRecommendationKinds: [String: OrganizeRecommendationCategory] = [:]
    private var queuePersistenceTask: Task<Void, Never>?
    private var protectedAlbumPersistenceTask: Task<Void, Never>?
    private var protectedAlbumPersistenceGeneration: UInt64 = 0
    private var protectedAlbumPersistenceCompletedGeneration: UInt64 = 0
    private var protectedAlbumPersistenceExecutingGeneration: UInt64?
    private var presentationMutationTask: Task<Void, Never>?
    private var presentationMutationGeneration: UInt64 = 0
    private var reviewPersistenceTask: Task<Void, Never>?
    private var browseRequestSequence: UInt64 = 0
    private var deletedHistoryRequestSequence: UInt64 = 0
    private var deletionIntentGeneration: UInt64 = 0
    /// Review mutations change the worker-owned asset array. Keep only the
    /// action-sized UI overlay here so MainActor never copy-on-write mutates the
    /// library-sized array it shares with the worker.
    private var reviewedAssetOverrides: [String: Bool] = [:]

    private enum PresentationMutationIntent: Sendable {
        case selection(OrganizeSelectionMutation)
        case beginReview(OrganizeRecommendationCategory)
        case reviewChoice(OrganizeReviewChoiceMutationRequest)
        case undoReview(sessionID: UUID)
        case queue(
            assetIDs: Set<String>,
            allowProtected: Bool,
            recommendationKind: OrganizeRecommendationCategory?
        )
        case removeQueueAssets(assetIDs: [String], additionalAssetIDs: [String])
        case removeQueueRecords([OrganizeDeletedItemPresentation])
        case keepQueuedAsset(assetID: String)
        case setAlbumProtection(albumID: String, isProtected: Bool)
    }

    private enum PresentationMutationOutcome: Sendable {
        case none
        case reviewAccepted(Bool)
        case protectedAssets([OrganizeAssetPresentation])
    }

    private final class PresentationMutationOutcomeBox {
        var value: PresentationMutationOutcome = .none
    }

    private struct PresentationStorage: Sendable {
        let assets: [OrganizeAssetPresentation]
        let assetIndexByID: [String: Int]
        let albums: [OrganizeAlbumPresentation]
        let primaryBreakdown: [OrganizeBreakdownMetric]
        let secondaryBreakdown: [OrganizeBreakdownMetric]
        let reviewRecommendations: [OrganizeRecommendationPresentation]
        let organizeRecommendations: [OrganizeRecommendationPresentation]
        let selectedAssetIDs: Set<String>
        let queuedAssetIDs: Set<String>
        let queuedAssets: [OrganizeAssetPresentation]
        let queuedAssetIndexByID: [String: Int]
        let queuedAssetIDsInOrder: [String]
        let queuedRecommendationKinds: [String: OrganizeRecommendationCategory]
        let protectedAlbumIDs: Set<String>
        let activeReviewSession: OrganizeReviewSessionPresentation?
        let duplicateGroups: [OrganizeDuplicateGroupPresentation]
        let deletedBatches: [OrganizeDeletedBatchPresentation]
        let availableFormats: [String]
        let reviewDecisionAssetIDs: [OrganizeReviewChoice: [String]]
        let reviewDecisionAssetIndexByID: [OrganizeReviewChoice: [String: Int]]
    }

    /// Used only to retire a replaced queue snapshot. It never crosses an await or
    /// participates in worker calculations.
    private struct QueuePresentationStorage: Sendable {
        let queuedAssetIDs: Set<String>
        let queuedAssets: [OrganizeAssetPresentation]
        let queuedAssetIndexByID: [String: Int]
        let queuedAssetIDsInOrder: [String]
        let recommendationKinds: [String: OrganizeRecommendationCategory]
    }

    private struct ReviewPresentationStorage: Sendable {
        let session: OrganizeReviewSessionPresentation?
        let decisionAssetIDs: [OrganizeReviewChoice: [String]]
        let decisionAssetIndexByID: [OrganizeReviewChoice: [String: Int]]
    }

    private struct QueuePersistenceStorage: Sendable {
        let assetIDs: Set<String>
        let recommendations: [String: OrganizeRecommendationCategory]
    }

    init(
        authorization: PhotoAuthorizationState = .notDetermined,
        assets: [PhotoAsset] = [],
        albums: [PhotoAlbum] = [],
        callbacks: OrganizeViewModelCallbacks = .init(),
        settingsDefaults: UserDefaults = .standard
    ) {
        self.authorization = authorization
        self.callbacks = callbacks
        self.settingsDefaults = settingsDefaults
        autoAnalyzeEnabled = settingsDefaults.object(
            forKey: Self.autoAnalyzeDefaultsKey
        ) as? Bool ?? true
        applyLibrary(authorization: authorization, assets: assets, albums: albums)
    }

    func installCallbacks(_ callbacks: OrganizeViewModelCallbacks) {
        self.callbacks = callbacks
    }

    func installWorker(_ worker: OrganizeWorker) {
        cancelAndRetireFallbackPresentationTask()
        invalidatePresentationMutations()
        self.worker = worker
    }

    /// Provides a basic metadata-only adapter while the persistence-backed coordinator is loading.
    /// Rich integrations can call `replacePresentation` with hidden, burst, analysis, and history data.
    func applyLibrary(
        authorization: PhotoAuthorizationState,
        assets sourceAssets: [PhotoAsset],
        albums sourceAlbums: [PhotoAlbum]
    ) {
        self.authorization = authorization
        cancelAndRetireFallbackPresentationTask()
        guard !sourceAssets.isEmpty || !sourceAlbums.isEmpty else { return }
        let revision = presentationRevision &+ 1
        let worker = worker
        fallbackPresentationTask = Task.detached(priority: .userInitiated) { [weak self, worker] in
            do {
                let indexed = try await worker.index(
                    assets: sourceAssets,
                    albums: sourceAlbums,
                    analysisByAssetID: [:],
                    reviewStateByAssetID: [:],
                    queueItems: [],
                    reviewSessions: [],
                    protectedAlbums: []
                )
                let snapshot = try await worker.presentation(
                    for: OrganizePresentationInput(
                        revision: revision,
                        authorization: authorization,
                        assets: indexed.orderedAssets,
                        albums: sourceAlbums,
                        albumIDsByAssetID: indexed.albumIDsByAssetID,
                        sourceRevisionByAssetID: indexed.sourceRevisionByAssetID,
                        analysisByAssetID: indexed.analysisByAssetID,
                        visualAnalysisByAssetID: [:],
                        analysisRun: nil,
                        reviewStateByAssetID: indexed.reviewStateByAssetID,
                        queueByAssetID: indexed.queueByAssetID,
                        reviewSessionsByID: indexed.reviewSessionsByID,
                        protectedAlbumIDs: indexed.protectedAlbumIDs,
                        protectedAssetIDs: indexed.protectedAssetIDs,
                        deletionBatches: [],
                        deletedItems: [],
                        activeReviewSessionOverride: nil,
                        analysisOverride: nil,
                        selectedAssetIDs: []
                    )
                )
                guard !Task.isCancelled else { return }
                if let self {
                    await self.apply(snapshot: consume snapshot)
                }
            } catch is CancellationError {
                // A persistence-backed coordinator superseded the metadata fallback.
            } catch {
                await self?.reportLibraryPresentationError(error.localizedDescription)
            }
        }
    }

    /// Applies one immutable generation. No library-sized mapping, grouping, sorting,
    /// or reduction is performed on the main actor.
    func apply(snapshot: consuming OrganizePresentationSnapshot) {
        guard snapshot.revision >= presentationRevision else {
            PresentationStorageRetirement.retire(consume snapshot)
            return
        }
        let hasPendingProtectionWrite = protectedAlbumPersistenceCompletedGeneration
            < protectedAlbumPersistenceGeneration
        let acceptsProtectedAlbumSnapshot = !hasPendingProtectionWrite
            || protectedAlbumPersistenceExecutingGeneration == protectedAlbumPersistenceGeneration
        let previous = currentPresentationStorage(
            includeProtectedAlbumIDs: acceptsProtectedAlbumSnapshot
        )
        cancelAndRetireFallbackPresentationTask()
        invalidatePresentationMutations()
        presentationRevision = snapshot.revision
        authorization = snapshot.authorization
        assets = snapshot.assets
        assetIndexByID = snapshot.assetIndexByID
        albums = snapshot.albums
        primaryBreakdown = snapshot.primaryBreakdown
        secondaryBreakdown = snapshot.secondaryBreakdown
        reviewRecommendations = snapshot.reviewRecommendations
        organizeRecommendations = snapshot.organizeRecommendations
        queuedAssetIDs = snapshot.queuedAssetIDs
        queuedAssets = snapshot.queuedAssets
        queuedAssetIndexByID = snapshot.queuedAssetIndexByID
        queuedAssetIDsInOrder = snapshot.queuedAssetIDsInOrder
        queueKnownBytes = snapshot.queueKnownBytes
        queuedRecommendationKinds = snapshot.queuedRecommendationKinds
        if acceptsProtectedAlbumSnapshot {
            protectedAlbumIDs = snapshot.protectedAlbumIDs
        }
        activeReviewSession = snapshot.activeReviewSession
        duplicateGroups = snapshot.duplicateGroups
        deletedBatches = snapshot.deletedBatches
        analysis = snapshot.analysis
        totalKnownBytes = snapshot.totalKnownBytes
        analyzedItemCount = snapshot.analyzedItemCount
        availableFormats = snapshot.availableFormats
        hasAssetsWithAddedDate = snapshot.hasAddedDates
        deletedAuditRecordCount = snapshot.deletedAuditRecordCount
        reviewDecisionAssetIDs = snapshot.reviewDecisionAssetIDs
        reviewDecisionAssetIndexByID = snapshot.reviewDecisionAssetIndexByID
        let previousReviewedAssetOverrides = reviewedAssetOverrides
        reviewedAssetOverrides = [:]
        selectedAssetIDs = snapshot.retainedSelectedAssetIDs
        invalidateBrowseContent()
        PresentationStorageRetirement.retire(consume previous)
        if !previousReviewedAssetOverrides.isEmpty {
            PresentationStorageRetirement.retire(consume previousReviewedAssetOverrides)
        }
        // The worker intentionally retains the installed collection buffers as its
        // canonical presentation. Releasing this now-empty shell synchronously is a
        // constant amount of work and avoids an asynchronous alias that would force
        // copy-on-write when a later worker mutation updates those buffers.
    }

    func waitForPendingPresentation() async { await fallbackPresentationTask?.value }

    func waitForPendingPresentationMutations() async {
        await presentationMutationTask?.value
    }

    func waitForPendingQueuePersistence() async {
        await presentationMutationTask?.value
        await queuePersistenceTask?.value
    }

    func waitForPendingProtectedAlbumPersistence() async {
        await protectedAlbumPersistenceTask?.value
    }

    var accessibleItemCount: Int { assets.count }
    var analysisCoverage: Double {
        guard !assets.isEmpty else { return 0 }
        return Double(analyzedItemCount) / Double(assets.count)
    }
    var activeSessionIsResumable: Bool {
        guard let activeReviewSession else { return false }
        return !activeReviewSession.isComplete && activeReviewSession.currentIndex > 0
    }

    var primaryReviewRecommendation: OrganizeRecommendationPresentation? {
        reviewRecommendations
            .first { $0.kind == .unreviewed }
            .flatMap(remainingReviewRecommendation)
    }

    var primaryReviewEntry: OrganizePrimaryReviewEntry {
        if let activeReviewSession, !activeReviewSession.isComplete {
            return .resume(activeReviewSession)
        }
        if let primaryReviewRecommendation {
            return .start(primaryReviewRecommendation)
        }
        return .complete
    }

    var alternateReviewRecommendations: [OrganizeRecommendationPresentation] {
        reviewRecommendations
            .filter { $0.kind != .unreviewed }
            .compactMap(remainingReviewRecommendation)
    }

    /// Recommendation snapshots describe category membership, which can overlap.
    /// Remove items already decided in another stack before presenting or starting
    /// a new review, while leaving non-review destinations to their own workflows.
    func remainingReviewRecommendation(
        _ recommendation: OrganizeRecommendationPresentation
    ) -> OrganizeRecommendationPresentation? {
        guard recommendation.destination == .review else { return recommendation }

        var remainingAssetIDs: [String] = []
        remainingAssetIDs.reserveCapacity(recommendation.assetIDs.count)
        var remainingKnownBytes: Int64 = 0

        for assetID in recommendation.assetIDs {
            guard let asset = asset(id: assetID), !asset.isReviewed else { continue }
            remainingAssetIDs.append(assetID)
            let (sum, overflow) = remainingKnownBytes.addingReportingOverflow(asset.knownBytes ?? 0)
            remainingKnownBytes = overflow ? .max : sum
        }

        guard !remainingAssetIDs.isEmpty else { return nil }
        let remainingAssetIDSet = Set(remainingAssetIDs)
        return OrganizeRecommendationPresentation(
            kind: recommendation.kind,
            title: recommendation.title,
            detail: recommendation.detail,
            systemImage: recommendation.systemImage,
            assetIDs: remainingAssetIDs,
            assetIDSet: remainingAssetIDSet,
            knownBytes: remainingKnownBytes,
            destination: recommendation.destination,
            evidenceByAssetID: recommendation.evidenceByAssetID.filter {
                remainingAssetIDSet.contains($0.key)
            }
        )
    }

    func asset(id: String) -> OrganizeAssetPresentation? {
        guard let index = assetIndexByID[id], assets.indices.contains(index) else { return nil }
        var asset = assets[index]
        if let isReviewed = reviewedAssetOverrides[id] { asset.isReviewed = isReviewed }
        return asset
    }

    func requestAuthorization() async {
        await callbacks.requestAuthorization?()
    }

    func presentLimitedPicker() {
        callbacks.presentLimitedPicker?()
    }

    func openSettings() {
        callbacks.openSettings?()
    }

    func setAutoAnalyzeEnabled(_ isEnabled: Bool) {
        guard autoAnalyzeEnabled != isEnabled else { return }
        autoAnalyzeEnabled = isEnabled
        settingsDefaults.set(isEnabled, forKey: Self.autoAnalyzeDefaultsKey)
        callbacks.autoAnalyzePreferenceChanged?(isEnabled)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await callbacks.refreshLibrary?()
        isRefreshing = false
    }

    func cleanExpiredThumbnails() async {
        await callbacks.cleanExpiredThumbnails?()
    }

    func thumbnail(assetID: String, size: CGSize) async -> UIImage? {
        await callbacks.loadThumbnail?(assetID, size)
    }

    func videoPlayer(assetID: String) async -> AVPlayer? {
        await callbacks.loadVideoPlayer?(assetID)
    }

    func livePhoto(assetID: String, size: CGSize) async -> PHLivePhoto? {
        await callbacks.loadLivePhoto?(assetID, size)
    }

    func deletedThumbnail(recordID: UUID, size: CGSize) async -> UIImage? {
        await callbacks.loadDeletedThumbnail?(recordID, size)
    }

    func startAnalysis(includeICloudItems: Bool) async {
        guard analysis.phase != .running else { return }
        guard let startAnalysis = callbacks.startAnalysis else {
            userMessage = OrganizeUserMessage(
                title: "Analysis Unavailable",
                message: "The library analysis service is not available yet. Metadata breakdowns remain available."
            )
            return
        }
        let resumesPausedRun = analysis.phase == .paused
        if !resumesPausedRun {
            analysis.processedAssetCount = analysis.completedAssetCount
            primaryBreakdown = primaryBreakdown.map { preparingForFreshAnalysis($0) }
            secondaryBreakdown = secondaryBreakdown.map { preparingForFreshAnalysis($0) }
        }
        analysis.phase = .running
        analysis.totalAssetCount = assets.count
        analysis.currentAssetFraction = 0
        analysis.includesICloudItems = includeICloudItems
        analysis.statusText = includeICloudItems ? "Analyzing local and iCloud items…" : "Analyzing locally available items…"
        do {
            try await startAnalysis(includeICloudItems)
        } catch {
            analysis.phase = .failed
            analysis.statusText = error.localizedDescription
            userMessage = OrganizeUserMessage(title: "Analysis Stopped", message: error.localizedDescription)
        }
    }

    func setAnalysis(_ analysis: OrganizeAnalysisPresentation) {
        self.analysis = analysis
    }

    /// Installs the worker's small, absolute storage snapshot without rebuilding
    /// or copy-on-write mutating the library-sized asset presentation. The final
    /// whole-library render remains authoritative for browse and recommendation data.
    func applyAnalysisProgress(_ update: OrganizeAnalysisProgressUpdate) {
        analysis = update.presentation
        totalKnownBytes = update.storage.totalKnownBytes
        analyzedItemCount = update.storage.analyzedAssetCount

        let bucketsByID = Dictionary(
            uniqueKeysWithValues: update.storage.buckets.map { ($0.id, $0) }
        )
        primaryBreakdown = applyingStorageProgress(
            bucketsByID,
            to: primaryBreakdown
        )
        secondaryBreakdown = applyingStorageProgress(
            bucketsByID,
            to: secondaryBreakdown
        )
    }

    private func applyingStorageProgress(
        _ bucketsByID: [String: OrganizeStorageAnalysisBucketProgress],
        to metrics: [OrganizeBreakdownMetric]
    ) -> [OrganizeBreakdownMetric] {
        metrics.map { metric in
            guard let bucket = bucketsByID[metric.id] else { return metric }
            return OrganizeBreakdownMetric(
                id: metric.id,
                title: metric.title,
                systemImage: metric.systemImage,
                itemCount: bucket.itemCount,
                knownBytes: bucket.knownBytes,
                processedAssetCount: bucket.processedAssetCount,
                analyzedAssetCount: bucket.analyzedAssetCount,
                unavailableAssetCount: bucket.unavailableAssetCount,
                failedAssetCount: bucket.failedAssetCount,
                tint: metric.tint,
                overlapsPrimaryCategories: metric.overlapsPrimaryCategories
            )
        }
    }

    private func preparingForFreshAnalysis(
        _ metric: OrganizeBreakdownMetric
    ) -> OrganizeBreakdownMetric {
        OrganizeBreakdownMetric(
            id: metric.id,
            title: metric.title,
            systemImage: metric.systemImage,
            itemCount: metric.itemCount,
            knownBytes: metric.knownBytes,
            processedAssetCount: metric.analyzedAssetCount,
            analyzedAssetCount: metric.analyzedAssetCount,
            unavailableAssetCount: metric.unavailableAssetCount,
            failedAssetCount: metric.failedAssetCount,
            tint: metric.tint,
            overlapsPrimaryCategories: metric.overlapsPrimaryCategories
        )
    }

    func setDuplicateGroups(_ groups: [OrganizeDuplicateGroupPresentation]) {
        let previous = duplicateGroups
        duplicateGroups = groups
        if !previous.isEmpty { PresentationStorageRetirement.retire(consume previous) }
    }

    func setDeletedBatches(_ batches: [OrganizeDeletedBatchPresentation]) {
        let previous = deletedBatches
        deletedBatches = batches
        if !previous.isEmpty { PresentationStorageRetirement.retire(consume previous) }
    }

    func beginReview(_ recommendation: OrganizeRecommendationPresentation) async {
        if let session = activeReviewSession,
           session.recommendationKind == recommendation.kind,
           !session.isComplete {
            return
        }
        guard beginDeletionSensitiveMutation() else { return }
        _ = await enqueuePresentationMutation(.beginReview(recommendation.kind))
    }

    func currentReviewAsset() -> OrganizeAssetPresentation? {
        guard let id = activeReviewSession?.currentAssetID else { return nil }
        return asset(id: id)
    }

    func applyReviewChoice(
        _ choice: OrganizeReviewChoice,
        allowProtected: Bool = false
    ) async -> Bool {
        guard beginDeletionSensitiveMutation() else { return false }
        guard let session = activeReviewSession,
              let assetID = session.currentAssetID,
              let asset = asset(id: assetID) else { return false }
        if choice == .queueForRecentlyDeleted, asset.isProtected, !allowProtected {
            return false
        }
        let outcome = await enqueuePresentationMutation(
            .reviewChoice(
                OrganizeReviewChoiceMutationRequest(
                    sessionID: session.id,
                    choice: choice,
                    allowProtected: allowProtected
                )
            )
        )
        if case let .reviewAccepted(accepted) = outcome {
            return accepted
        }
        return false
    }

    func undoLastReviewChoice() async {
        guard beginDeletionSensitiveMutation() else { return }
        guard let sessionID = activeReviewSession?.id else { return }
        _ = await enqueuePresentationMutation(.undoReview(sessionID: sessionID))
    }

    func toggleSelection(_ assetID: String) async {
        _ = await enqueuePresentationMutation(.selection(.toggle(assetID: assetID)))
    }

    func clearSelection() async {
        _ = await enqueuePresentationMutation(.selection(.clear))
    }

    /// Published assignment is constant-time, but releasing the last reference
    /// to a large Set destroys every String. Keep the old storage alive until a
    /// utility executor can dispose it instead of doing that work on MainActor.
    private func replaceSelection(with replacement: Set<String>) {
        let previous = selectedAssetIDs
        selectedAssetIDs = replacement
        guard !previous.isEmpty else { return }
        PresentationStorageRetirement.retire(consume previous)
    }

    @discardableResult
    func queueAssets(
        _ assetIDs: Set<String>,
        allowProtected: Bool = false,
        recommendationKind: OrganizeRecommendationCategory? = nil
    ) async -> [OrganizeAssetPresentation] {
        guard beginDeletionSensitiveMutation() else { return [] }
        let outcome = await enqueuePresentationMutation(
            .queue(
                assetIDs: assetIDs,
                allowProtected: allowProtected,
                recommendationKind: recommendationKind
            )
        )
        if case let .protectedAssets(protectedAssets) = outcome {
            return protectedAssets
        }
        return []
    }

    func queueAssetsInBackground(
        _ assetIDs: Set<String>,
        allowProtected: Bool = false,
        recommendationKind: OrganizeRecommendationCategory? = nil
    ) async -> [OrganizeAssetPresentation] {
        await queueAssets(
            assetIDs,
            allowProtected: allowProtected,
            recommendationKind: recommendationKind
        )
    }

    func removeFromQueue(_ assetID: String) async {
        guard beginDeletionSensitiveMutation() else { return }
        _ = await enqueuePresentationMutation(
            .removeQueueAssets(assetIDs: [assetID], additionalAssetIDs: [])
        )
        persistQueue(.remove(assetIDs: [assetID]))
    }

    func keepQueuedAsset(_ assetID: String) async {
        guard beginDeletionSensitiveMutation() else { return }
        _ = await enqueuePresentationMutation(.keepQueuedAsset(assetID: assetID))
        persistQueue(.remove(assetIDs: [assetID]))
    }

    func setAlbumProtected(_ albumID: String, isProtected: Bool) async {
        guard beginDeletionSensitiveMutation() else { return }
        _ = await enqueuePresentationMutation(
            .setAlbumProtection(albumID: albumID, isProtected: isProtected)
        )
    }

    func moveQueueToRecentlyDeleted() async {
        guard !queuedAssetIDs.isEmpty, !isMovingToRecentlyDeleted else { return }
        guard let move = callbacks.moveToRecentlyDeleted else {
            userMessage = OrganizeUserMessage(
                title: "Recently Deleted Unavailable",
                message: "The deletion coordinator is not connected. The queue has been kept unchanged."
            )
            return
        }
        isMovingToRecentlyDeleted = true
        defer { isMovingToRecentlyDeleted = false }
        // Capture before the first drain suspension. A queue/review/protection
        // attempt arriving while older writes unwind must invalidate this move,
        // rather than becoming part of a newer post-drain baseline.
        guard let intentValidator = activeDeletionIntentValidator() else { return }
        // The final operation must see the newest durable queue snapshot. This also
        // prevents an older staged write from repopulating the queue after the
        // coordinator has cleared a successful PhotoKit batch.
        await presentationMutationTask?.value
        await queuePersistenceTask?.value
        await reviewPersistenceTask?.value
        await protectedAlbumPersistenceTask?.value
        guard !queuedAssetIDsInOrder.isEmpty,
              intentValidator() else { return }
        do {
            let requestedIDs = queuedAssetIDsInOrder
            let outcome: OrganizeMoveOutcome
            do {
                outcome = try await move(requestedIDs, intentValidator)
            } catch {
                PresentationStorageRetirement.retire(consume requestedIDs)
                throw error
            }
            PresentationStorageRetirement.retire(consume requestedIDs)
            do {
                switch outcome {
                case let .moved(batch, auditWarning):
                    let count = batch.records.count
                    await removeQueueRecordsFromPresentation(batch.records)
                    let previousDeletedBatches = deletedBatches
                    deletedBatches = try await worker.upsertingDeletedBatch(
                        batch,
                        in: previousDeletedBatches
                    )
                    if !previousDeletedBatches.isEmpty {
                        PresentationStorageRetirement.retire(consume previousDeletedBatches)
                    }
                    let completion = "\(count) item\(count == 1 ? " was" : "s were") moved to Recently Deleted. To remove \(count == 1 ? "it" : "them") permanently, open Apple Photos, find Recently Deleted under Utilities, and clear it there."
                    userMessage = OrganizeUserMessage(
                        title: auditWarning == nil ? "Moved to Recently Deleted" : "Moved, but Audit Needs Attention",
                        message: [completion, auditWarning].compactMap { $0 }.joined(separator: "\n\n")
                    )
                case let .needsReview(missingAssetIDs, changedAssetIDs):
                    var parts: [String] = []
                    if !missingAssetIDs.isEmpty { parts.append("\(missingAssetIDs.count) missing item(s) were removed from the queue") }
                    if !changedAssetIDs.isEmpty { parts.append("\(changedAssetIDs.count) changed or newly protected item(s) were removed and need another review") }
                    await removeQueueAssetIDsFromPresentation(
                        missingAssetIDs,
                        additionalAssetIDs: changedAssetIDs
                    )
                    userMessage = OrganizeUserMessage(
                        title: "Review Queue Again",
                        message: parts.joined(separator: ". ") + ". Nothing was moved."
                    )
                }
            } catch {
                PresentationStorageRetirement.retire(consume outcome)
                throw error
            }
            PresentationStorageRetirement.retire(consume outcome)
        } catch {
            userMessage = OrganizeUserMessage(
                title: "Nothing Was Moved",
                message: "\(error.localizedDescription) Your queue is unchanged."
            )
        }
    }

    func browseQuery(scopeAssetIDs: Set<String>? = nil, scopeKey: String = "all") -> BrowseQuery {
        BrowseQuery(
            revision: presentationRevision,
            contentRevision: browseContentRevision,
            scopeKey: scopeKey,
            // Production scopes are resolved from the worker-owned recommendation
            // snapshot. Do not keep a recommendation-sized UI Set alive across the
            // asynchronous browse request.
            scopeAssetIDs: nil,
            configuration: browseConfiguration
        )
    }

    /// Executes filtering, sorting, and grouping on the worker actor. `nil` means the
    /// query was cancelled or superseded and callers should retain their prior result.
    func browseSections(for query: BrowseQuery) async -> [OrganizeBrowseSection]? {
        browseRequestSequence &+= 1
        let request = BrowseQuery(
            revision: query.revision,
            contentRevision: query.contentRevision,
            sequence: browseRequestSequence,
            scopeKey: query.scopeKey,
            scopeAssetIDs: nil,
            configuration: query.configuration
        )
        do {
            let result = try await worker.browse(request)
            guard result.query == request,
                  query.revision == presentationRevision,
                  query.contentRevision == browseContentRevision,
                  query.configuration == browseConfiguration else { return nil }
            return result.sections
        } catch {
            return nil
        }
    }

    func activeMetric(for asset: OrganizeAssetPresentation) -> String {
        switch browseConfiguration.sort {
        case .creationDate: asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Capture date unavailable"
        case .modificationDate: asset.modificationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Modified date unavailable"
        case .addedDate: asset.addedDate?.formatted(date: .abbreviated, time: .omitted) ?? "Date added unavailable"
        case .filename: asset.originalFilename
        case .knownSize: asset.knownBytes.map(Self.byteString) ?? "Size pending"
        case .resolution: String(format: "%.1f MP", asset.megapixels)
        case .duration: asset.durationMilliseconds.map(Self.durationString) ?? "Not a video"
        case .albumCount: "\(asset.albumCount) album\(asset.albumCount == 1 ? "" : "s")"
        case .reviewState:
            (reviewedAssetOverrides[asset.id] ?? asset.isReviewed) ? "Reviewed" : "Unreviewed"
        }
    }

    func reviewDecisionCount(_ choice: OrganizeReviewChoice) -> Int {
        reviewDecisionAssetIDs[choice]?.count ?? 0
    }

    func reviewDecisionIDs(_ choice: OrganizeReviewChoice) -> [String] {
        reviewDecisionAssetIDs[choice] ?? []
    }

    func deletedHistoryQuery(searchText: String) -> OrganizeDeletedHistoryQuery {
        OrganizeDeletedHistoryQuery(revision: presentationRevision, searchText: searchText)
    }

    func deletedBatches(for query: OrganizeDeletedHistoryQuery) async -> [OrganizeDeletedBatchPresentation]? {
        deletedHistoryRequestSequence &+= 1
        let request = OrganizeDeletedHistoryQuery(
            revision: query.revision,
            sequence: deletedHistoryRequestSequence,
            searchText: query.searchText
        )
        let source = deletedBatches
        defer { PresentationStorageRetirement.retire(consume source) }
        do {
            let result = try await worker.deletedHistory(request, batches: source)
            guard result.query == request, query.revision == presentationRevision else { return nil }
            return result.batches
        } catch {
            return nil
        }
    }

    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func durationString(_ milliseconds: Int) -> String {
        let totalSeconds = max(milliseconds / 1_000, 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func persistReview(
        session: OrganizeReviewSessionPresentation,
        action: OrganizeReviewActionPresentation
    ) {
        guard let callback = callbacks.persistReviewChoice else { return }
        let sessionID = session.id
        let resultingCursor = session.currentIndex
        let isComplete = session.isComplete
        enqueueReviewPersistence {
            await callback(sessionID, action, resultingCursor, isComplete)
        }
    }

    private func enqueueReviewPersistence(
        _ operation: consuming @escaping @MainActor @Sendable () async -> Void
    ) {
        let preceding = reviewPersistenceTask
        let task = Task { [preceding = consume preceding, operation = consume operation] in
            await preceding?.value
            await operation()
            PresentationStorageRetirement.retire(consume preceding)
            PresentationStorageRetirement.retire(consume operation)
        }
        reviewPersistenceTask = task
    }

    private func persistQueue(_ delta: consuming OrganizeQueuePersistenceDelta) {
        let precedingTask = queuePersistenceTask
        if let callback = callbacks.persistQueueDelta {
            let task = Task { [
                callback,
                precedingTask = consume precedingTask,
                delta = consume delta
            ] in
                // Intent-sized deltas preserve write order without retaining aliases to
                // the complete live queue while SQLite or another write is suspended.
                await precedingTask?.value
                await callback(delta)
                PresentationStorageRetirement.retire(consume precedingTask)
                PresentationStorageRetirement.retire(consume delta)
            }
            queuePersistenceTask = task
            return
        }

        // Source compatibility for integrations that have not adopted deltas. The
        // production coordinator installs `persistQueueDelta`; only this fallback owns
        // a complete snapshot across the callback.
        guard let callback = callbacks.persistQueue else {
            PresentationStorageRetirement.retire(consume delta)
            return
        }
        let storage = QueuePersistenceStorage(
            assetIDs: queuedAssetIDs,
            recommendations: queuedRecommendationKinds
        )
        let task = Task { [
            callback,
            precedingTask = consume precedingTask,
            storage = consume storage,
            delta = consume delta
        ] in
            // Queue snapshots must reach durable storage in the same order in which
            // the user created them. Independent tasks could otherwise let an older,
            // slower write overwrite a newer selection.
            await precedingTask?.value
            await callback(storage.assetIDs, storage.recommendations)
            PresentationStorageRetirement.retire(consume precedingTask)
            PresentationStorageRetirement.retire(consume storage)
            PresentationStorageRetirement.retire(consume delta)
        }
        queuePersistenceTask = task
    }

    private func persistProtectedAlbum(
        _ delta: consuming OrganizeProtectedAlbumPersistenceDelta
    ) {
        let deltaCallback = callbacks.persistProtectedAlbumDelta
        let compatibilityCallback = callbacks.persistProtectedAlbums
        guard deltaCallback != nil || compatibilityCallback != nil else {
            protectedAlbumPersistenceCompletedGeneration = delta.generation
            PresentationStorageRetirement.retire(consume delta)
            return
        }

        let precedingTask = protectedAlbumPersistenceTask
        // Never capture the complete set in production. This value is populated only
        // for the compatibility callback and can be removed with that legacy API.
        let compatibilityIDs = deltaCallback == nil ? protectedAlbumIDs : nil
        let task = Task { [
            weak self,
            deltaCallback,
            compatibilityCallback,
            precedingTask = consume precedingTask,
            compatibilityIDs,
            delta = consume delta
        ] in
            await precedingTask?.value
            guard let self else {
                PresentationStorageRetirement.retire(consume precedingTask)
                PresentationStorageRetirement.retire(consume compatibilityIDs)
                PresentationStorageRetirement.retire(consume delta)
                return
            }

            self.protectedAlbumPersistenceExecutingGeneration = delta.generation
            if let deltaCallback {
                await deltaCallback(delta)
            } else if let compatibilityCallback, let compatibilityIDs {
                await compatibilityCallback(compatibilityIDs)
            }
            self.finishProtectedAlbumPersistence(generation: delta.generation)
            PresentationStorageRetirement.retire(consume precedingTask)
            PresentationStorageRetirement.retire(consume compatibilityIDs)
            PresentationStorageRetirement.retire(consume delta)
        }
        protectedAlbumPersistenceTask = task
    }

    private func finishProtectedAlbumPersistence(generation: UInt64) {
        protectedAlbumPersistenceCompletedGeneration = max(
            protectedAlbumPersistenceCompletedGeneration,
            generation
        )
        if protectedAlbumPersistenceExecutingGeneration == generation {
            protectedAlbumPersistenceExecutingGeneration = nil
        }
        if protectedAlbumPersistenceGeneration == generation {
            let previous = protectedAlbumPersistenceTask
            protectedAlbumPersistenceTask = nil
            if let previous { PresentationStorageRetirement.retire(consume previous) }
        }
    }

    private func removeQueueRecordsFromPresentation(
        _ records: consuming [OrganizeDeletedItemPresentation]
    ) async {
        _ = await enqueuePresentationMutation(.removeQueueRecords(records))
    }

    private func removeQueueAssetIDsFromPresentation(
        _ assetIDs: consuming [String],
        additionalAssetIDs: consuming [String]
    ) async {
        _ = await enqueuePresentationMutation(
            .removeQueueAssets(
                assetIDs: assetIDs,
                additionalAssetIDs: additionalAssetIDs
            )
        )
    }

    private func applyQueuePresentation(_ result: consuming OrganizeQueueSelectionResult) {
        let previous = currentQueuePresentationStorage()
        queuedAssetIDs = result.queuedAssetIDs
        queuedAssets = result.queuedAssets
        queuedAssetIndexByID = result.queuedAssetIndexByID
        queuedAssetIDsInOrder = result.queuedAssetIDsInOrder
        queueKnownBytes = result.queueKnownBytes
        queuedRecommendationKinds = result.recommendationKinds
        PresentationStorageRetirement.retire(consume previous)
        // `result` is only a fixed-size shell around buffers now installed in the
        // UI and retained canonically by the worker. Let that shell release here so
        // it cannot force copy-on-write during the next worker mutation.
    }

    private func enqueuePresentationMutation(
        _ intent: consuming PresentationMutationIntent
    ) async -> PresentationMutationOutcome {
        let preceding = presentationMutationTask
        let generation = presentationMutationGeneration
        let worker = worker
        let outcome = PresentationMutationOutcomeBox()
        let task = Task { @MainActor [
            weak self,
            worker,
            preceding = consume preceding,
            intent = consume intent,
            outcome
        ] in
            await preceding?.value
            if let self,
               !Task.isCancelled,
                generation == self.presentationMutationGeneration {
                await self.performPresentationMutation(
                    copy intent,
                    worker: worker,
                    generation: generation,
                    outcome: outcome
                )
            }
            PresentationStorageRetirement.retire(consume preceding)
            // Captured values are borrowed within an escaping task closure. Give
            // retirement an explicitly owned alias; its detached lifetime ensures
            // releasing the capture itself on MainActor is constant-time.
            let retirementIntent = intent
            PresentationStorageRetirement.retire(consume retirementIntent)
        }
        presentationMutationTask = task
        await task.value
        return outcome.value
    }

    private func performPresentationMutation(
        _ intent: borrowing PresentationMutationIntent,
        worker: OrganizeWorker,
        generation: UInt64,
        outcome: PresentationMutationOutcomeBox
    ) async {
        do {
            switch copy intent {
            case let .selection(mutation):
                let result = await worker.mutateSelection(mutation)
                guard acceptsPresentationMutation(generation) else {
                    PresentationStorageRetirement.retire(consume result)
                    return
                }
                replaceSelection(with: result.selectedAssetIDs)

            case let .beginReview(recommendationKind):
                let session = await worker.beginReview(recommendationKind: recommendationKind)
                guard acceptsPresentationMutation(generation) else {
                    PresentationStorageRetirement.retire(consume session)
                    return
                }
                guard let session else { return }
                installReviewSession(session)

            case let .reviewChoice(request):
                let result = try await worker.applyReviewChoice(request)
                guard acceptsPresentationMutation(generation) else {
                    PresentationStorageRetirement.retire(consume result)
                    return
                }
                guard let result else {
                    outcome.value = .reviewAccepted(false)
                    return
                }
                applyReviewMutation(result, isUndo: false)
                outcome.value = .reviewAccepted(true)

            case let .undoReview(sessionID):
                let result = try await worker.undoReviewChoice(sessionID: sessionID)
                guard acceptsPresentationMutation(generation) else {
                    PresentationStorageRetirement.retire(consume result)
                    return
                }
                guard let result else { return }
                applyReviewMutation(result, isUndo: true)

            case let .queue(assetIDs, allowProtected, recommendationKind):
                let result = try await worker.queueSelection(
                    requestedIDs: assetIDs,
                    allowProtected: allowProtected,
                    recommendationKind: recommendationKind
                )
                guard acceptsPresentationMutation(generation) else {
                    PresentationStorageRetirement.retire(consume result)
                    return
                }
                if !result.protectedAssets.isEmpty, !allowProtected {
                    outcome.value = .protectedAssets(result.protectedAssets)
                    return
                }
                applyQueuePresentation(result)
                persistQueue(
                    .upsert(
                        assetIDs: assetIDs,
                        recommendationKind: recommendationKind,
                        allowProtected: allowProtected
                    )
                )

            case let .removeQueueAssets(assetIDs, additionalAssetIDs):
                let result = try await worker.removeQueueAssets(
                    assetIDs: assetIDs,
                    additionalAssetIDs: additionalAssetIDs
                )
                guard acceptsPresentationMutation(generation) else {
                    PresentationStorageRetirement.retire(consume result)
                    return
                }
                applyQueuePresentation(result)

            case let .removeQueueRecords(records):
                let result = try await worker.removeQueueRecords(records)
                guard acceptsPresentationMutation(generation) else {
                    PresentationStorageRetirement.retire(consume result)
                    return
                }
                applyQueuePresentation(result)

            case let .keepQueuedAsset(assetID):
                let result = try await worker.markQueuedAssetReviewedAndRemove(assetID: assetID)
                guard acceptsPresentationMutation(generation) else {
                    PresentationStorageRetirement.retire(consume result)
                    return
                }
                reviewedAssetOverrides[result.assetID] = result.isReviewed
                applyQueuePresentation(result.queue)
                invalidateBrowseContent()

            case let .setAlbumProtection(albumID, isProtected):
                protectedAlbumPersistenceGeneration &+= 1
                let delta = OrganizeProtectedAlbumPersistenceDelta(
                    generation: protectedAlbumPersistenceGeneration,
                    albumID: albumID,
                    isProtected: isProtected
                )
                let result = await worker.protectedAlbumPresentationMutation(delta)
                // The user intent remains durable even if a concurrent library
                // snapshot supersedes this particular UI response.
                persistProtectedAlbum(delta)
                guard acceptsPresentationMutation(generation) else {
                    PresentationStorageRetirement.retire(consume result)
                    return
                }
                let previous = protectedAlbumIDs
                protectedAlbumIDs = result.protectedAlbumIDs
                if !previous.isEmpty {
                    PresentationStorageRetirement.retire(consume previous)
                }
            }
        } catch is CancellationError {
            // A newer library generation owns the canonical presentation now.
        } catch {
            userMessage = OrganizeUserMessage(
                title: "Organizer Update Failed",
                message: error.localizedDescription
            )
        }
    }

    private func acceptsPresentationMutation(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == presentationMutationGeneration
    }

    /// Every public queue, review, or protection intent advances this scalar before
    /// any suspension. While a destructive batch is preparing, the attempted
    /// mutation is rejected but still invalidates that batch's lease.
    private func beginDeletionSensitiveMutation() -> Bool {
        deletionIntentGeneration &+= 1
        return !isMovingToRecentlyDeleted
    }

    private func activeDeletionIntentValidator() -> OrganizeDeletionIntentValidator? {
        guard isMovingToRecentlyDeleted else { return nil }
        let generation = deletionIntentGeneration
        return { [weak self] in
            guard let self else { return false }
            return self.isMovingToRecentlyDeleted
                && self.deletionIntentGeneration == generation
        }
    }

    private func installReviewSession(
        _ session: consuming OrganizeReviewSessionPresentation
    ) {
        let previous = ReviewPresentationStorage(
            session: activeReviewSession,
            decisionAssetIDs: reviewDecisionAssetIDs,
            decisionAssetIndexByID: reviewDecisionAssetIndexByID
        )
        activeReviewSession = session
        reviewDecisionAssetIDs = [:]
        reviewDecisionAssetIndexByID = [:]
        PresentationStorageRetirement.retire(consume previous)
        if let callback = callbacks.persistReviewSession, let snapshot = activeReviewSession {
            enqueueReviewPersistence { await callback(snapshot) }
        }
    }

    private func applyReviewMutation(
        _ result: consuming OrganizeReviewPresentationMutationResult,
        isUndo: Bool
    ) {
        let session = result.session
        let action = result.action
        let assetID = result.assetID
        let isReviewed = result.isReviewed
        let queue = result.queue
        let decisionAssetIDs = result.reviewDecisionAssetIDs
        let decisionAssetIndexByID = result.reviewDecisionAssetIndexByID
        let previous = ReviewPresentationStorage(
            session: activeReviewSession,
            decisionAssetIDs: reviewDecisionAssetIDs,
            decisionAssetIndexByID: reviewDecisionAssetIndexByID
        )

        activeReviewSession = session
        reviewDecisionAssetIDs = decisionAssetIDs
        reviewDecisionAssetIndexByID = decisionAssetIndexByID
        reviewedAssetOverrides[assetID] = isReviewed
        applyQueuePresentation(queue)
        invalidateBrowseContent()
        PresentationStorageRetirement.retire(consume previous)

        if isUndo {
            if let callback = callbacks.persistReviewUndo {
                enqueueReviewPersistence {
                    await callback(session.id, action, session.currentIndex)
                }
            }
        } else {
            persistReview(session: session, action: action)
        }
    }

    private func invalidatePresentationMutations() {
        presentationMutationGeneration &+= 1
        let previous = presentationMutationTask
        previous?.cancel()
        presentationMutationTask = nil
        if let previous { PresentationStorageRetirement.retire(consume previous) }
    }

    private func invalidateBrowseContent() {
        browseContentRevision &+= 1
    }

    private func currentPresentationStorage(
        includeProtectedAlbumIDs: Bool = true
    ) -> PresentationStorage {
        PresentationStorage(
            assets: assets,
            assetIndexByID: assetIndexByID,
            albums: albums,
            primaryBreakdown: primaryBreakdown,
            secondaryBreakdown: secondaryBreakdown,
            reviewRecommendations: reviewRecommendations,
            organizeRecommendations: organizeRecommendations,
            selectedAssetIDs: selectedAssetIDs,
            queuedAssetIDs: queuedAssetIDs,
            queuedAssets: queuedAssets,
            queuedAssetIndexByID: queuedAssetIndexByID,
            queuedAssetIDsInOrder: queuedAssetIDsInOrder,
            queuedRecommendationKinds: queuedRecommendationKinds,
            protectedAlbumIDs: includeProtectedAlbumIDs ? protectedAlbumIDs : [],
            activeReviewSession: activeReviewSession,
            duplicateGroups: duplicateGroups,
            deletedBatches: deletedBatches,
            availableFormats: availableFormats,
            reviewDecisionAssetIDs: reviewDecisionAssetIDs,
            reviewDecisionAssetIndexByID: reviewDecisionAssetIndexByID
        )
    }

    private func currentQueuePresentationStorage() -> QueuePresentationStorage {
        QueuePresentationStorage(
            queuedAssetIDs: queuedAssetIDs,
            queuedAssets: queuedAssets,
            queuedAssetIndexByID: queuedAssetIndexByID,
            queuedAssetIDsInOrder: queuedAssetIDsInOrder,
            recommendationKinds: queuedRecommendationKinds
        )
    }

    private func cancelAndRetireFallbackPresentationTask() {
        let previous = fallbackPresentationTask
        previous?.cancel()
        fallbackPresentationTask = nil
        if let previous { PresentationStorageRetirement.retire(consume previous) }
    }

    private func reportLibraryPresentationError(_ message: String) {
        userMessage = OrganizeUserMessage(
            title: "Library Presentation Unavailable",
            message: message
        )
    }
}
