import CryptoKit
import Foundation

enum MediaKind: String, Codable, CaseIterable, Sendable {
    case photo
    case video
}

enum AssetMediaSubtype: String, Codable, Hashable, Sendable {
    case livePhoto
    case panorama
    case screenshot
    case screenRecording
    case hdr
    case depthEffect
    case raw
    case spatialMedia
    case slowMotion
    case highFrameRate
    case timelapse
    case cinematic
}

enum PhotoResourceKind: String, Codable, Hashable, Sendable {
    case photo
    case video
    case audio
    case alternatePhoto
    case fullSizePhoto
    case fullSizeVideo
    case pairedVideo
    case fullSizePairedVideo
    case adjustmentData
    case adjustmentBasePhoto
    case adjustmentBasePairedVideo
    case adjustmentBaseVideo
    case photoProxy
    case unknown
}

struct PhotoResourceDescriptor: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: PhotoResourceKind
    /// Preserves the PhotoKit numeric resource type even when a newer iOS
    /// resource is not yet known to this build.
    let rawResourceType: Int?
    let originalFilename: String
    let uniformTypeIdentifier: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let estimatedByteCount: Int64?

    init(
        id: String,
        kind: PhotoResourceKind,
        rawResourceType: Int? = nil,
        originalFilename: String,
        uniformTypeIdentifier: String?,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        estimatedByteCount: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.rawResourceType = rawResourceType
        self.originalFilename = originalFilename
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.estimatedByteCount = estimatedByteCount
    }
}

struct AssetLocation: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double?
}

struct PhotoAsset: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let mediaKind: MediaKind
    let mediaSubtypes: Set<AssetMediaSubtype>
    let creationDate: Date?
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let durationMilliseconds: Int?
    let location: AssetLocation?
    let isFavorite: Bool
    let isEdited: Bool
    let resources: [PhotoResourceDescriptor]
    let isHidden: Bool
    let addedDate: Date?
    let burstIdentifier: String?
    let representsBurst: Bool
    /// Precomputed once when the immutable model is created/decoded. Large
    /// libraries read this value in many filters and dictionaries; hashing the
    /// resource manifest on every access turns otherwise-linear passes into a
    /// substantial CPU cost.
    let sourceRevision: String
    /// Stable identity for analysis results. Unlike `sourceRevision`, this value
    /// intentionally excludes export renderer/profile versions: changing how an
    /// export is produced must not invalidate exact sizes and hashes calculated
    /// from the unchanged PhotoKit resource manifest.
    let analysisRevision: String

    init(
        id: String,
        mediaKind: MediaKind,
        mediaSubtypes: Set<AssetMediaSubtype>,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        durationMilliseconds: Int?,
        location: AssetLocation?,
        isFavorite: Bool,
        isEdited: Bool,
        resources: [PhotoResourceDescriptor],
        isHidden: Bool = false,
        addedDate: Date? = nil,
        burstIdentifier: String? = nil,
        representsBurst: Bool = false,
        sourceRevision: String? = nil,
        analysisRevision: String? = nil
    ) {
        self.id = id
        self.mediaKind = mediaKind
        self.mediaSubtypes = mediaSubtypes
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationMilliseconds = durationMilliseconds
        self.location = location
        self.isFavorite = isFavorite
        self.isEdited = isEdited
        self.resources = resources
        self.isHidden = isHidden
        self.addedDate = addedDate
        self.burstIdentifier = burstIdentifier
        self.representsBurst = representsBurst
        self.sourceRevision = sourceRevision ?? Self.makeSourceRevision(
            id: id,
            modificationDate: modificationDate,
            mediaKind: mediaKind,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            durationMilliseconds: durationMilliseconds,
            mediaSubtypes: mediaSubtypes,
            resources: resources,
            isEdited: isEdited
        )
        self.analysisRevision = analysisRevision ?? Self.makeAnalysisRevision(
            id: id,
            modificationDate: modificationDate,
            mediaKind: mediaKind,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            durationMilliseconds: durationMilliseconds,
            mediaSubtypes: mediaSubtypes,
            resources: resources,
            isEdited: isEdited
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case mediaKind
        case mediaSubtypes
        case creationDate
        case modificationDate
        case pixelWidth
        case pixelHeight
        case durationMilliseconds
        case location
        case isFavorite
        case isEdited
        case resources
        case isHidden
        case addedDate
        case burstIdentifier
        case representsBurst
        case sourceRevision
        case analysisRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            mediaKind: try container.decode(MediaKind.self, forKey: .mediaKind),
            mediaSubtypes: try container.decode(Set<AssetMediaSubtype>.self, forKey: .mediaSubtypes),
            creationDate: try container.decodeIfPresent(Date.self, forKey: .creationDate),
            modificationDate: try container.decodeIfPresent(Date.self, forKey: .modificationDate),
            pixelWidth: try container.decode(Int.self, forKey: .pixelWidth),
            pixelHeight: try container.decode(Int.self, forKey: .pixelHeight),
            durationMilliseconds: try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds),
            location: try container.decodeIfPresent(AssetLocation.self, forKey: .location),
            isFavorite: try container.decode(Bool.self, forKey: .isFavorite),
            isEdited: try container.decode(Bool.self, forKey: .isEdited),
            resources: try container.decode([PhotoResourceDescriptor].self, forKey: .resources),
            isHidden: try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false,
            addedDate: try container.decodeIfPresent(Date.self, forKey: .addedDate),
            burstIdentifier: try container.decodeIfPresent(String.self, forKey: .burstIdentifier),
            representsBurst: try container.decodeIfPresent(Bool.self, forKey: .representsBurst) ?? false,
            sourceRevision: try container.decodeIfPresent(String.self, forKey: .sourceRevision),
            analysisRevision: try container.decodeIfPresent(String.self, forKey: .analysisRevision)
        )
    }

    private static func makeSourceRevision(
        id: String,
        modificationDate: Date?,
        mediaKind: MediaKind,
        pixelWidth: Int,
        pixelHeight: Int,
        durationMilliseconds: Int?,
        mediaSubtypes: Set<AssetMediaSubtype>,
        resources: [PhotoResourceDescriptor],
        isEdited: Bool
    ) -> String {
        let resourcePart = resources
            .sorted { $0.id < $1.id }
            .map { "\($0.kind.rawValue)|\($0.originalFilename)|\($0.uniformTypeIdentifier ?? "")|\($0.estimatedByteCount.map(String.init) ?? "")" }
            .joined(separator: ";")
        let parts = [
            id,
            modificationDate.map(WireDate.string) ?? "",
            mediaKind.rawValue,
            String(pixelWidth),
            String(pixelHeight),
            String(durationMilliseconds ?? 0),
            mediaSubtypes.map(\.rawValue).sorted().joined(separator: ","),
            resourcePart,
            ExportConstants.profileVersion.description,
            String(isEdited)
        ]
        return SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).hexString
    }

    private static func makeAnalysisRevision(
        id: String,
        modificationDate: Date?,
        mediaKind: MediaKind,
        pixelWidth: Int,
        pixelHeight: Int,
        durationMilliseconds: Int?,
        mediaSubtypes: Set<AssetMediaSubtype>,
        resources: [PhotoResourceDescriptor],
        isEdited: Bool
    ) -> String {
        let resourcePart = resources
            .sorted { $0.id < $1.id }
            .map { "\($0.kind.rawValue)|\($0.originalFilename)|\($0.uniformTypeIdentifier ?? "")|\($0.estimatedByteCount.map(String.init) ?? "")" }
            .joined(separator: ";")
        let parts = [
            "analysis-v1",
            id,
            modificationDate.map(WireDate.string) ?? "",
            mediaKind.rawValue,
            String(pixelWidth),
            String(pixelHeight),
            String(durationMilliseconds ?? 0),
            mediaSubtypes.map(\.rawValue).sorted().joined(separator: ","),
            resourcePart,
            String(isEdited)
        ]
        return SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).hexString
    }
}

struct ResourceFingerprint: Codable, Hashable, Sendable {
    let kind: PhotoResourceKind
    let byteCount: Int64
    let sha256: String
}

struct AssetFingerprint: Codable, Hashable, Sendable {
    let assetID: String
    let sourceRevision: String
    let resources: [ResourceFingerprint]
    let analyzedAt: Date

    var knownByteCount: Int64 {
        resources.reduce(into: 0) { total, resource in
            let (sum, overflow) = total.addingReportingOverflow(resource.byteCount)
            total = overflow ? .max : sum
        }
    }

    /// Exact-duplicate identity for the complete resource manifest. Filenames and
    /// PhotoKit identifiers are intentionally excluded: only type, bytes, and content
    /// identify an exact copy. Sorting preserves repeated companion resources while
    /// making the key independent of PhotoKit's resource enumeration order.
    var exactDuplicateKey: String {
        let canonicalManifest = resources
            .map { resource in
                let hash = resource.sha256.lowercased()
                return "\(resource.kind.rawValue.utf8.count):\(resource.kind.rawValue)"
                    + "|\(resource.byteCount)"
                    + "|\(hash.utf8.count):\(hash)"
            }
            .sorted()
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonicalManifest.utf8)).hexString
    }
}

struct PhotoAlbum: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let parentID: String?
    let assetIDs: [String]
}

enum PhotoAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized
}

enum SelectionSource: Equatable, Sendable {
    case allAccessible
    case newOrChanged
    case dateRange(start: Date, end: Date)
    case albums(Set<String>)
    case manual(Set<String>)
    /// A quick-selection export can combine individually chosen assets with
    /// whole albums. The wire protocol still describes this as a manual
    /// selection while preserving the selected album identifiers as metadata.
    case custom(assetIDs: Set<String>, albumIDs: Set<String>)

    var kind: SelectionKind {
        switch self {
        case .allAccessible: .allAccessible
        case .newOrChanged: .newOrChanged
        case .dateRange: .dateRange
        case .albums: .albums
        case .manual, .custom: .manual
        }
    }
}

enum SelectionKind: String, Codable, CaseIterable, Sendable {
    case allAccessible
    case newOrChanged
    case dateRange
    case albums
    case manual

    var label: String {
        switch self {
        case .allAccessible: "All accessible"
        case .newOrChanged: "New or changed"
        case .dateRange: "Date range"
        case .albums: "Albums"
        case .manual: "Choose photos"
        }
    }
}

struct FrozenSelection: Sendable, Equatable {
    let source: SelectionSource
    let assets: [PhotoAsset]
    let selectedAlbumIDs: [String]
    let createdAt: Date
    let sourceTimeZone: String
}

enum ExportProfileKind: String, Codable, CaseIterable, Sendable {
    case portableLibrary
    // Decoding-only legacy values keep v1 history visible. New planning and
    // receiver capability checks accept only `portableLibrary`.
    case preserveOriginals
    case originalsAndCurrentJpegs

    static var allCases: [ExportProfileKind] { [.portableLibrary] }

    var label: String {
        switch self {
        case .portableLibrary: "Portable Master Library"
        case .preserveOriginals: "Legacy originals"
        case .originalsAndCurrentJpegs: "Legacy originals + JPEGs"
        }
    }
}

struct ExportProfile: Codable, Equatable, Sendable {
    let kind: ExportProfileKind
    let profileVersion: Int

    init(kind: ExportProfileKind = .portableLibrary) {
        self.kind = kind
        self.profileVersion = ExportConstants.profileVersion
    }
}

enum StorageArea: String, Codable, Hashable, Sendable {
    case master
    case libraryData
}

enum RepresentationRole: String, Codable, Hashable, Sendable {
    case masterCurrent
    case rootOriginal
    case currentLiveMotion
    case originalLiveMotion
    case adjustmentBase
    case adjustmentRecipe
    case alternateOriginal
    case auxiliary
}

enum Criticality: String, Codable, Sendable {
    case masterRequired
    case archiveRequired
    case optional
}

enum Provenance: String, Codable, Sendable {
    case exactPhotoKitResource
    case generatedThumbnail
}

enum ResourceAvailability: String, Codable, Sendable {
    case available
    case sourceUnavailable
    case transferFailed
    case missing
    case tampered
    case superseded
}

struct Destination: Codable, Equatable, Sendable {
    let destinationId: UUID
    let displayName: String
    let createdAt: Date
    let freeBytes: Int64
    let pathPolicyVersion: Int
    let destinationFormatVersion: Int
}

struct RecoveryFingerprint: Codable, Equatable, Sendable {
    let captureDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let durationMilliseconds: Int?
    let mediaType: MediaKind
    let originalFilenames: [String]
    let resourceByteCounts: [Int64?]

    private enum CodingKeys: String, CodingKey {
        case captureDate
        case pixelWidth
        case pixelHeight
        case durationMilliseconds
        case mediaType
        case originalFilenames
        case resourceByteCounts
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let captureDate {
            try container.encode(captureDate, forKey: .captureDate)
        } else {
            try container.encodeNil(forKey: .captureDate)
        }
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        if let durationMilliseconds {
            try container.encode(durationMilliseconds, forKey: .durationMilliseconds)
        } else {
            try container.encodeNil(forKey: .durationMilliseconds)
        }
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(originalFilenames, forKey: .originalFilenames)
        try container.encode(resourceByteCounts, forKey: .resourceByteCounts)
    }
}

struct ExportFile: Codable, Identifiable, Equatable, Sendable {
    let fileId: UUID
    let assetId: UUID
    let contentRevision: String
    let storageArea: StorageArea
    let roles: [RepresentationRole]
    let criticality: Criticality
    let provenance: Provenance
    let photoKitResourceType: PhotoResourceKind?
    let photoKitResourceTypeRaw: Int?
    let originalFilename: String
    let proposedRelativePath: String
    let uniformTypeIdentifier: String?
    let contentType: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let durationMilliseconds: Int?
    var byteCount: Int64?
    var sha256: String?
    let captureDate: Date?
    let availability: ResourceAvailability

    var id: UUID { fileId }
    /// The local ledger predates protocol v2's per-file terminology. Keep the
    /// internal alias until its storage column is migrated; it is not encoded.
    var sourceRevision: String { contentRevision }

    private enum CodingKeys: String, CodingKey {
        case fileId
        case assetId
        case contentRevision
        case storageArea
        case roles
        case criticality
        case provenance
        case photoKitResourceType
        case photoKitResourceTypeRaw
        case originalFilename
        case proposedRelativePath
        case uniformTypeIdentifier
        case contentType
        case pixelWidth
        case pixelHeight
        case durationMilliseconds
        case byteCount
        case sha256
        case captureDate
        case availability
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileId, forKey: .fileId)
        try container.encode(assetId, forKey: .assetId)
        try container.encode(contentRevision, forKey: .contentRevision)
        try container.encode(storageArea, forKey: .storageArea)
        try container.encode(roles, forKey: .roles)
        try container.encode(criticality, forKey: .criticality)
        try container.encode(provenance, forKey: .provenance)
        if let photoKitResourceType {
            try container.encode(photoKitResourceType, forKey: .photoKitResourceType)
        } else {
            try container.encodeNil(forKey: .photoKitResourceType)
        }
        if let photoKitResourceTypeRaw {
            try container.encode(photoKitResourceTypeRaw, forKey: .photoKitResourceTypeRaw)
        } else {
            try container.encodeNil(forKey: .photoKitResourceTypeRaw)
        }
        try container.encode(originalFilename, forKey: .originalFilename)
        try container.encode(proposedRelativePath, forKey: .proposedRelativePath)
        if let uniformTypeIdentifier {
            try container.encode(uniformTypeIdentifier, forKey: .uniformTypeIdentifier)
        } else {
            try container.encodeNil(forKey: .uniformTypeIdentifier)
        }
        if let contentType {
            try container.encode(contentType, forKey: .contentType)
        } else {
            try container.encodeNil(forKey: .contentType)
        }
        if let pixelWidth {
            try container.encode(pixelWidth, forKey: .pixelWidth)
        } else {
            try container.encodeNil(forKey: .pixelWidth)
        }
        if let pixelHeight {
            try container.encode(pixelHeight, forKey: .pixelHeight)
        } else {
            try container.encodeNil(forKey: .pixelHeight)
        }
        if let durationMilliseconds {
            try container.encode(durationMilliseconds, forKey: .durationMilliseconds)
        } else {
            try container.encodeNil(forKey: .durationMilliseconds)
        }
        if let byteCount {
            try container.encode(byteCount, forKey: .byteCount)
        } else {
            try container.encodeNil(forKey: .byteCount)
        }
        if let sha256 {
            try container.encode(sha256, forKey: .sha256)
        } else {
            try container.encodeNil(forKey: .sha256)
        }
        if let captureDate {
            try container.encode(captureDate, forKey: .captureDate)
        } else {
            try container.encodeNil(forKey: .captureDate)
        }
        try container.encode(availability, forKey: .availability)
    }
}

struct LivePhotoRelationships: Codable, Equatable, Sendable {
    let currentStillFileId: UUID?
    let currentMotionFileId: UUID?
    let originalStillFileId: UUID?
    let originalMotionFileId: UUID?

    private enum CodingKeys: String, CodingKey {
        case currentStillFileId
        case currentMotionFileId
        case originalStillFileId
        case originalMotionFileId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try Self.encode(currentStillFileId, forKey: .currentStillFileId, into: &container)
        try Self.encode(currentMotionFileId, forKey: .currentMotionFileId, into: &container)
        try Self.encode(originalStillFileId, forKey: .originalStillFileId, into: &container)
        try Self.encode(originalMotionFileId, forKey: .originalMotionFileId, into: &container)
    }

    private static func encode(
        _ value: UUID?,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value { try container.encode(value, forKey: key) }
        else { try container.encodeNil(forKey: key) }
    }
}

struct ExportAsset: Codable, Identifiable, Equatable, Sendable {
    let assetId: UUID
    let sourceLocalIdentifier: String
    let sourceRevision: String
    let mediaType: MediaKind
    let mediaSubtypes: [AssetMediaSubtype]
    let creationDate: Date?
    let modificationDate: Date?
    let location: AssetLocation?
    let isEdited: Bool
    let recoveryFingerprint: RecoveryFingerprint
    let masterFileId: UUID?
    let livePhotoRelationships: LivePhotoRelationships?
    var files: [ExportFile]

    var id: UUID { assetId }

    private enum CodingKeys: String, CodingKey {
        case assetId
        case sourceLocalIdentifier
        case sourceRevision
        case mediaType
        case mediaSubtypes
        case creationDate
        case modificationDate
        case location
        case isEdited
        case recoveryFingerprint
        case masterFileId
        case livePhotoRelationships
        case files
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(assetId, forKey: .assetId)
        try container.encode(sourceLocalIdentifier, forKey: .sourceLocalIdentifier)
        try container.encode(sourceRevision, forKey: .sourceRevision)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(mediaSubtypes, forKey: .mediaSubtypes)
        if let creationDate {
            try container.encode(creationDate, forKey: .creationDate)
        } else {
            try container.encodeNil(forKey: .creationDate)
        }
        if let modificationDate {
            try container.encode(modificationDate, forKey: .modificationDate)
        } else {
            try container.encodeNil(forKey: .modificationDate)
        }
        try container.encodeIfPresent(location, forKey: .location)
        try container.encode(isEdited, forKey: .isEdited)
        try container.encode(recoveryFingerprint, forKey: .recoveryFingerprint)
        if let masterFileId {
            try container.encode(masterFileId, forKey: .masterFileId)
        } else {
            try container.encodeNil(forKey: .masterFileId)
        }
        if let livePhotoRelationships {
            try container.encode(livePhotoRelationships, forKey: .livePhotoRelationships)
        } else {
            try container.encodeNil(forKey: .livePhotoRelationships)
        }
        try container.encode(files, forKey: .files)
    }
}

struct AlbumMembership: Codable, Equatable, Sendable {
    let albumId: UUID
    let sourceAlbumIdentifier: String
    let albumTitle: String
    let parentAlbumId: UUID?
    let assetId: UUID

    private enum CodingKeys: String, CodingKey {
        case albumId
        case sourceAlbumIdentifier
        case albumTitle
        case parentAlbumId
        case assetId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(albumId, forKey: .albumId)
        try container.encode(sourceAlbumIdentifier, forKey: .sourceAlbumIdentifier)
        try container.encode(albumTitle, forKey: .albumTitle)
        if let parentAlbumId {
            try container.encode(parentAlbumId, forKey: .parentAlbumId)
        } else {
            try container.encodeNil(forKey: .parentAlbumId)
        }
        try container.encode(assetId, forKey: .assetId)
    }
}

struct ExportSelection: Codable, Equatable, Sendable {
    struct DateRange: Codable, Equatable, Sendable {
        let start: Date
        let end: Date
    }

    let kind: SelectionKind
    let assetCount: Int
    let dateRange: DateRange?
    let sourceAlbumIdentifiers: [String]?
}

struct ExportJob: Codable, Identifiable, Equatable, Sendable {
    let protocolVersion: Int
    let jobId: UUID
    let createdAt: Date
    let sourceTimeZone: String
    let profile: ExportProfile
    let selection: ExportSelection
    var assets: [ExportAsset]
    let albumMemberships: [AlbumMembership]

    var id: UUID { jobId }
    var files: [ExportFile] { assets.flatMap(\.files) }
}

enum JobState: String, Codable, Sendable {
    case planned
    case transferring
    case paused
    case completed
    case completedWithFailures
    case abandoned
}

struct CompletionCounts: Codable, Equatable, Sendable {
    let assetsPlanned: Int
    let assetsPromoted: Int
    let assetsArchiveIncomplete: Int
    let filesPlanned: Int
    let filesCommitted: Int
    let filesSkipped: Int
    let filesFailed: Int
    let bytesTransferred: Int64
    let bytesCommitted: Int64
}

enum APIErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case authenticationRequired = "authentication_required"
    case authenticationInvalid = "authentication_invalid"
    case tokenExpired = "token_expired"
    case tokenConsumed = "token_consumed"
    case protocolMismatch = "protocol_mismatch"
    case jobNotFound = "job_not_found"
    case fileNotFound = "file_not_found"
    case jobConflict = "job_conflict"
    case fileConflict = "file_conflict"
    case chunkConflict = "chunk_conflict"
    case chunkOutOfOrder = "chunk_out_of_order"
    case diskFull = "disk_full"
    case pathConflict = "path_conflict"
    case unsafePath = "unsafe_path"
    case hashMismatch = "hash_mismatch"
    case unavailableSource = "unavailable_source"
    case masterConflict = "master_conflict"
    case archiveIncomplete = "archive_incomplete"
    case networkLoss = "network_loss"
    case changedDestination = "changed_destination"
    case destinationFormatMismatch = "destination_format_mismatch"
    case internalError = "internal_error"
}

struct CompletionFailure: Codable, Equatable, Sendable {
    let fileId: UUID
    let code: APIErrorCode
    let message: String
    let retryable: Bool
}

struct CompletionReport: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let jobId: UUID
    let destinationId: UUID
    let state: JobState
    let startedAt: Date
    let completedAt: Date
    let counts: CompletionCounts
    let failures: [CompletionFailure]
    let reportRelativePath: String
    let catalogGeneration: CatalogGeneration
}

struct CatalogGeneration: Codable, Equatable, Sendable {
    let generationId: UUID
    let catalogPointerRelativePath: String
    let assetsRelativePath: String
    let albumsRelativePath: String
}

enum ExportConstants {
    static let protocolVersion = 2
    static let profileVersion = 2
    static let pathPolicyVersion = 2
    static let destinationFormatVersion = 2
    static let catalogFormatVersion = 2
    static let thumbnailRendererVersion = "core-image-thumbnail-srgb-v1"
    static let thumbnailMaximumPixelDimension = 512
    static let thumbnailJPEGQuality = 0.82
    static let chunkSize = 8 * 1_024 * 1_024
    static let maximumRelativePathLength = 239
}

enum StableID {
    static func make(namespace: String, value: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace):\(value)".utf8)).hexString
        var bytes = Array(digest.prefix(32))
        bytes[12] = "5"
        let variant = Int(String(bytes[16]), radix: 16) ?? 0
        bytes[16] = Array("89ab")[variant & 3]
        let hex = String(bytes)
        let uuid = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuid)!
    }
}

enum WireDate {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: string)
    }
}

enum WireCoders {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(WireDate.string(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = WireDate.parse(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected RFC3339 date")
            }
            return date
        }
        return decoder
    }
}

extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
