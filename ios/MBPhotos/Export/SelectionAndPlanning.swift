import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum SelectionError: LocalizedError, Equatable {
    case noAssets
    case invalidDateRange
    case noAlbums

    var errorDescription: String? {
        switch self {
        case .noAssets: "This selection contains no accessible photos or videos."
        case .invalidDateRange: "The end date must not be earlier than the start date."
        case .noAlbums: "Choose at least one album."
        }
    }
}

enum ExportPlanningError: LocalizedError, Equatable {
    case noExportableResources(String)
    case tooManyAssets(actual: Int, limit: Int)
    case legacyJobRequiresReplanning

    var errorDescription: String? {
        switch self {
        case let .noExportableResources(assetID):
            "An accessible item has no authoritative PhotoKit resource (\(assetID)). Refresh the library and try again."
        case let .tooManyAssets(actual, limit):
            "This selection contains \(actual) items, but a Portable Master Library transfer supports at most \(limit) items. Split the selection into smaller transfers."
        case .legacyJobRequiresReplanning:
            "This paused transfer uses the previous backup format. Leave it untouched and create a fresh Portable Master Library transfer."
        }
    }
}

struct SelectionService: Sendable {
    func freeze(
        source: SelectionSource,
        assets: [PhotoAsset],
        albums: [PhotoAlbum],
        previouslyExportedRevisions: [String: String] = [:],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> FrozenSelection {
        let selected: [PhotoAsset]
        switch source {
        case .allAccessible:
            selected = assets
        case .newOrChanged:
            // The Windows destination ledger is authoritative. Every accessible
            // candidate must be reconciled so a deleted or externally changed PC
            // file is restored even when the source asset itself is unchanged.
            // The receiver returns `skip` for verified, unchanged renditions.
            _ = previouslyExportedRevisions
            selected = assets
        case let .dateRange(start, end):
            guard start <= end else { throw SelectionError.invalidDateRange }
            selected = try assets.filter {
                try Task.checkCancellation()
                guard let creationDate = $0.creationDate else { return false }
                return creationDate >= start && creationDate <= end
            }
        case let .albums(ids):
            guard !ids.isEmpty else { throw SelectionError.noAlbums }
            var assetIDs: Set<String> = []
            for album in albums where ids.contains(album.id) {
                try Task.checkCancellation()
                assetIDs.formUnion(album.assetIDs)
            }
            selected = try assets.filter {
                try Task.checkCancellation()
                return assetIDs.contains($0.id)
            }
        case let .manual(ids):
            selected = try assets.filter {
                try Task.checkCancellation()
                return ids.contains($0.id)
            }
        case let .custom(assetIDs, albumIDs):
            var selectedIDs = assetIDs
            for album in albums where albumIDs.contains(album.id) {
                try Task.checkCancellation()
                selectedIDs.formUnion(album.assetIDs)
            }
            selected = try assets.filter {
                try Task.checkCancellation()
                return selectedIDs.contains($0.id)
            }
        }

        guard !selected.isEmpty else { throw SelectionError.noAssets }
        try Task.checkCancellation()
        let sorted = selected.sorted {
            switch ($0.creationDate, $1.creationDate) {
            case let (lhs?, rhs?):
                lhs == rhs ? $0.id < $1.id : lhs < rhs
            case (_?, nil):
                true
            case (nil, _?):
                false
            case (nil, nil):
                $0.id < $1.id
            }
        }
        try Task.checkCancellation()
        let albumIDs: [String]
        switch source {
        case let .albums(ids), let .custom(_, ids):
            albumIDs = ids.sorted()
        default:
            albumIDs = []
        }
        return FrozenSelection(
            source: source,
            assets: sorted,
            selectedAlbumIDs: albumIDs,
            createdAt: now,
            sourceTimeZone: timeZone.identifier
        )
    }
}

enum ResourceDisposition: Equatable, Sendable {
    case original(PhotoResourceKind)
    case renderedEdit
    case adjustment
    case proxy
    case auxiliary
}

enum ResourceClassifier {
    static func classify(_ kind: PhotoResourceKind) -> ResourceDisposition {
        switch kind {
        case .photo, .video, .audio, .alternatePhoto, .pairedVideo:
            .original(kind)
        case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo:
            .renderedEdit
        case .adjustmentData, .adjustmentBasePhoto, .adjustmentBasePairedVideo, .adjustmentBaseVideo:
            .adjustment
        case .photoProxy:
            .proxy
        case .unknown:
            .auxiliary
        }
    }

    static func authoritativeResources(in asset: PhotoAsset) -> [PhotoResourceDescriptor] {
        asset.resources
            .filter { $0.kind != .photoProxy }
            .sorted { $0.id < $1.id }
    }

    static func masterResource(in asset: PhotoAsset) -> PhotoResourceDescriptor? {
        let resources = authoritativeResources(in: asset)
        switch (asset.mediaKind, asset.isEdited) {
        case (.photo, true):
            return resources.first { $0.kind == .fullSizePhoto }
        case (.photo, false):
            return resources.first { $0.kind == .photo }
        case (.video, true):
            return resources.first { $0.kind == .fullSizeVideo }
        case (.video, false):
            return resources.first { $0.kind == .video }
        }
    }
}

enum WindowsPathSanitizer {
    private static let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    ]

    static func component(_ input: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*")
        let normalized = input.precomposedStringWithCanonicalMapping
        let scalars = normalized.unicodeScalars.map {
            invalid.contains($0) || $0.value <= 0x1f ? "_" : String($0)
        }.joined()
        var output = scalars
        while output.last == " " || output.last == "." { output.removeLast() }
        if output.isEmpty || output == "." || output == ".." { output = "_" }
        let base = output.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.uppercased() ?? output.uppercased()
        if reservedNames.contains(base) { output = "_\(output)" }
        return output
    }

    static func uniqueRelativePath(
        directory: String,
        filename: String,
        fileID: UUID,
        occupiedLowercasePaths: inout Set<String>
    ) throws -> String {
        var safeName = component(filename)
        var candidate = "\(directory)/\(safeName)"
        if occupiedLowercasePaths.contains(candidate.lowercased()) {
            safeName = addingSuffix("~\(fileID.uuidString.lowercased().prefix(8))", to: safeName)
            candidate = "\(directory)/\(safeName)"
            guard !occupiedLowercasePaths.contains(candidate.lowercased()) else {
                throw WindowsPathError.pathConflict
            }
        }
        if candidate.utf16.count > ExportConstants.maximumRelativePathLength {
            candidate = try shortenedRelativePath(candidate, fileID: fileID)
        }
        guard validateRelativePath(candidate), !occupiedLowercasePaths.contains(candidate.lowercased()) else {
            throw WindowsPathError.pathConflict
        }
        occupiedLowercasePaths.insert(candidate.lowercased())
        return candidate
    }

    static func validateRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf16.count <= ExportConstants.maximumRelativePathLength,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\")
        else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        return segments.allSatisfy {
            component($0).unicodeScalars.elementsEqual($0.unicodeScalars)
        }
    }

    static func shortenedRelativePath(_ path: String, fileID: UUID) throws -> String {
        guard path.utf16.count > ExportConstants.maximumRelativePathLength else { return path }
        guard let slash = path.lastIndex(of: "/") else { throw WindowsPathError.pathConflict }
        let directory = String(path[...slash])
        let filename = String(path[path.index(after: slash)...])
        let value = filename as NSString
        let ext = value.pathExtension
        let extensionPart = ext.isEmpty ? "" : ".\(ext)"
        let suffix = "~\(fileID.uuidString.lowercased().prefix(8))"
        let availableStemUnits = ExportConstants.maximumRelativePathLength
            - directory.utf16.count
            - suffix.utf16.count
            - extensionPart.utf16.count
        guard availableStemUnits >= 1 else { throw WindowsPathError.pathConflict }

        var scalars = Array(value.deletingPathExtension.unicodeScalars)
        while String(String.UnicodeScalarView(scalars)).utf16.count > availableStemUnits {
            guard scalars.count > 1 else { throw WindowsPathError.pathConflict }
            scalars.removeLast()
        }
        let stem = String(String.UnicodeScalarView(scalars))
        let result = "\(directory)\(stem)\(suffix)\(extensionPart)"
        guard result.utf16.count <= ExportConstants.maximumRelativePathLength else {
            throw WindowsPathError.pathConflict
        }
        return result
    }

    private static func addingSuffix(_ suffix: String, to filename: String) -> String {
        let value = filename as NSString
        let ext = value.pathExtension
        let base = value.deletingPathExtension
        return ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
    }

}

enum WindowsPathError: LocalizedError, Equatable {
    case pathConflict

    var errorDescription: String? { "A Windows-safe path could not be created." }
}

struct PreflightSummary: Equatable, Sendable {
    let assetCount: Int
    let masterFileCount: Int
    let archiveFileCount: Int
    let thumbnailFileCount: Int
    let missingMasterCount: Int
    let estimatedKnownBytes: Int64
    let unknownByteCount: Int
    var warnings: [String]
    var destinationFreeBytes: Int64? = nil
    var unchangedFileCount = 0
    var resumableFileCount = 0
    var changedFileCount = 0
    var conflictFileCount = 0

    func reconciled(with remotePlan: JobPlan) -> PreflightSummary {
        var result = self
        result.destinationFreeBytes = remotePlan.destination.freeBytes
        result.unchangedFileCount = remotePlan.decisions.filter { $0.action == .skip }.count
        result.resumableFileCount = remotePlan.decisions.filter { $0.action == .resume }.count
        result.changedFileCount = remotePlan.decisions.filter { $0.reason == .changed }.count
        result.conflictFileCount = remotePlan.decisions.filter { $0.action == .conflict }.count
        if result.conflictFileCount > 0 {
            result.warnings.append(
                "\(result.conflictFileCount) destination path conflict(s) will be reported without overwriting existing files."
            )
        }
        if result.estimatedKnownBytes > remotePlan.destination.freeBytes {
            result.warnings.append("The known source size exceeds the destination’s currently available space.")
        }
        return result
    }
}

struct PlannedExport: Sendable {
    let job: ExportJob
    let sourceResourcesByFileID: [UUID: PhotoResourceDescriptor]
    let sourceAssetIDsByFileID: [UUID: String]
    let preflight: PreflightSummary
}

/// One action-sized mutation for the preflight worker's private selection
/// mirror. The presentation model keeps its own Sets for constant-time SwiftUI
/// reads, but never lends those copy-on-write buffers to an asynchronous task.
enum PreflightSelectionDelta: Equatable, Sendable {
    case asset(revision: UInt64, id: String, isSelected: Bool)
    case assets(revision: UInt64, ids: [String], isSelected: Bool)
    case album(revision: UInt64, id: String, isSelected: Bool)
    case albums(revision: UInt64, ids: [String], isSelected: Bool)
    case clear(revision: UInt64)

    var revision: UInt64 {
        switch self {
        case let .asset(revision, _, _),
             let .assets(revision, _, _),
             let .album(revision, _, _),
             let .albums(revision, _, _),
             let .clear(revision):
            revision
        }
    }
}

/// Scalar, revision-tagged input for one preflight generation. Manual and album
/// identifiers deliberately do not appear here; `PreflightWorker` freezes them
/// from its independently owned selection mirror.
struct PreflightRequest: Equatable, Sendable {
    let revision: UInt64
    let selectionRevision: UInt64
    let libraryRevision: UInt64
    let kind: SelectionKind
    let rangeStart: Date
    let rangeEnd: Date
    let profile: ExportProfile
}

/// Performs all selection freezing and export-plan construction away from the
/// main actor.  The presentation layer passes immutable library snapshots in
/// and receives one immutable plan back.
protocol PreflightWorking: Sendable {
    func applySelectionDelta(_ delta: PreflightSelectionDelta) async

    func plan(
        request: PreflightRequest,
        assets: [PhotoAsset],
        albums: [PhotoAlbum]
    ) async throws -> PlannedExport

    func rehydrate(job: ExportJob, assets: [PhotoAsset]) async throws -> PlannedExport
}

actor PreflightWorker: PreflightWorking {
    private let selectionService: SelectionService
    private let planner: ExportPlanner
    private var selectedAssetIDs: Set<String> = []
    private var selectedAlbumIDs: Set<String> = []
    private var selectionRevision: UInt64 = 0
    private var latestPlanningRevision: UInt64 = 0
    private var latestLibraryRevision: UInt64 = 0

    init(
        selectionService: SelectionService = SelectionService(),
        planner: ExportPlanner = ExportPlanner()
    ) {
        self.selectionService = selectionService
        self.planner = planner
    }

    func applySelectionDelta(_ delta: PreflightSelectionDelta) {
        // Deltas are serialized by AppModel before they reach this actor. Reject
        // duplicate, stale, or gapped delivery rather than corrupting the mirror;
        // a request carrying the unmatched revision will then be rejected too.
        guard delta.revision == selectionRevision &+ 1 else { return }
        switch delta {
        case let .asset(_, id, isSelected):
            if isSelected { selectedAssetIDs.insert(id) }
            else { selectedAssetIDs.remove(id) }
        case let .assets(_, ids, isSelected):
            if isSelected { selectedAssetIDs.formUnion(ids) }
            else { selectedAssetIDs.subtract(ids) }
        case let .album(_, id, isSelected):
            if isSelected { selectedAlbumIDs.insert(id) }
            else { selectedAlbumIDs.remove(id) }
        case let .albums(_, ids, isSelected):
            if isSelected { selectedAlbumIDs.formUnion(ids) }
            else { selectedAlbumIDs.subtract(ids) }
        case .clear:
            selectedAssetIDs.removeAll(keepingCapacity: false)
            selectedAlbumIDs.removeAll(keepingCapacity: false)
        }
        selectionRevision = delta.revision
    }

    func plan(
        request: PreflightRequest,
        assets: [PhotoAsset],
        albums: [PhotoAlbum]
    ) throws -> PlannedExport {
        try Task.checkCancellation()
        guard request.revision > latestPlanningRevision,
              request.selectionRevision == selectionRevision,
              request.libraryRevision >= latestLibraryRevision else {
            throw CancellationError()
        }
        latestPlanningRevision = request.revision
        latestLibraryRevision = request.libraryRevision
        let source: SelectionSource = switch request.kind {
        case .allAccessible: .allAccessible
        case .newOrChanged: .newOrChanged
        case .dateRange: .dateRange(start: request.rangeStart, end: request.rangeEnd)
        case .albums: .albums(selectedAlbumIDs)
        case .manual: .custom(assetIDs: selectedAssetIDs, albumIDs: selectedAlbumIDs)
        }
        let frozen = try selectionService.freeze(
            source: source,
            assets: assets,
            albums: albums
        )
        try Task.checkCancellation()
        return try planner.plan(
            selection: frozen,
            albums: albums,
            profile: request.profile
        )
    }

    func rehydrate(job: ExportJob, assets: [PhotoAsset]) throws -> PlannedExport {
        try planner.rehydrate(job: job, assets: assets)
    }
}

struct ExportPlanner: Sendable {
    static let maximumAssetsPerJob = 100_000

    static func validateAssetCount(_ count: Int) throws {
        guard count <= maximumAssetsPerJob else {
            throw ExportPlanningError.tooManyAssets(
                actual: count,
                limit: maximumAssetsPerJob
            )
        }
    }

    func plan(
        selection: FrozenSelection,
        albums: [PhotoAlbum],
        profile: ExportProfile,
        jobID: UUID = UUID()
    ) throws -> PlannedExport {
        try Self.validateAssetCount(selection.assets.count)
        var occupied: Set<String> = []
        var sourceResources: [UUID: PhotoResourceDescriptor] = [:]
        var sourceAssets: [UUID: String] = [:]
        var exportAssets: [ExportAsset] = []
        var masterCount = 0
        var archiveCount = 0
        var thumbnailCount = 0
        var missingMasterCount = 0
        var missingArchiveCount = 0
        var knownBytes: Int64 = 0
        var unknownBytes = 0

        let calendar = Calendar(identifier: .gregorian)
        for asset in selection.assets {
            try Task.checkCancellation()
            let assetID = StableID.make(namespace: "asset", value: asset.id)
            let resources = ResourceClassifier.authoritativeResources(in: asset)
            guard !resources.isEmpty else {
                throw ExportPlanningError.noExportableResources(asset.id)
            }
            let isLive = asset.mediaSubtypes.contains(.livePhoto)
                || resources.contains { $0.kind == .pairedVideo || $0.kind == .fullSizePairedVideo }
            var wireMediaSubtypes = asset.mediaSubtypes
            if isLive { wireMediaSubtypes.insert(.livePhoto) }
            let masterResource = ResourceClassifier.masterResource(in: asset)
            if masterResource == nil { missingMasterCount += 1 }
            var files: [ExportFile] = []
            let resourceFileIDs = Self.resourceFileIDs(
                assetID: asset.id,
                resources: resources
            )
            var unavailableMasterFileID: UUID?
            var unavailableOriginalFileID: UUID?
            var unavailableLiveFileIDs: [PhotoResourceKind: UUID] = [:]
            let masterDirectory = Self.masterDirectory(
                for: asset.creationDate,
                calendar: calendar,
                timeZoneID: selection.sourceTimeZone
            )

            for resource in resources {
                guard let fileID = resourceFileIDs[resource.id] else {
                    throw ExportPlanningError.noExportableResources(asset.id)
                }
                let isMaster = resource.id == masterResource?.id
                let roles = Self.roles(for: resource, asset: asset, isMaster: isMaster)
                let dimensions = Self.dimensions(for: resource, asset: asset)
                let storageArea: StorageArea = isMaster ? .master : .libraryData
                let relativePath: String
                if isMaster {
                    relativePath = try WindowsPathSanitizer.uniqueRelativePath(
                        directory: masterDirectory,
                        filename: resource.originalFilename,
                        fileID: fileID,
                        occupiedLowercasePaths: &occupied
                    )
                } else {
                    relativePath = Self.libraryResourcePath(
                        assetID: assetID,
                        fileID: fileID,
                        resource: resource
                    )
                }
                let file = ExportFile(
                    fileId: fileID,
                    assetId: assetID,
                    contentRevision: Self.contentRevision(for: resource, asset: asset),
                    storageArea: storageArea,
                    roles: roles,
                    criticality: Self.criticality(for: roles, isMaster: isMaster),
                    provenance: .exactPhotoKitResource,
                    photoKitResourceType: resource.kind,
                    photoKitResourceTypeRaw: resource.rawResourceType,
                    originalFilename: resource.originalFilename,
                    proposedRelativePath: relativePath,
                    uniformTypeIdentifier: resource.uniformTypeIdentifier,
                    contentType: resource.uniformTypeIdentifier
                        .flatMap(UTType.init)
                        .flatMap(\.preferredMIMEType),
                    pixelWidth: dimensions.width,
                    pixelHeight: dimensions.height,
                    durationMilliseconds: Self.duration(for: resource, asset: asset),
                    byteCount: resource.estimatedByteCount,
                    sha256: nil,
                    captureDate: asset.creationDate,
                    availability: .available
                )
                files.append(file)
                sourceResources[fileID] = resource
                sourceAssets[fileID] = asset.id
                if isMaster { masterCount += 1 } else { archiveCount += 1 }
                if let bytes = resource.estimatedByteCount { knownBytes += bytes } else { unknownBytes += 1 }
            }

            if masterResource == nil {
                let expectedKind: PhotoResourceKind = asset.mediaKind == .photo
                    ? (asset.isEdited ? .fullSizePhoto : .photo)
                    : (asset.isEdited ? .fullSizeVideo : .video)
                let placeholderID = StableID.make(
                    namespace: "file",
                    value: "\(asset.id)|unavailable-master|\(expectedKind.rawValue)"
                )
                let filenameSource = Self.primaryOriginal(in: resources) ?? resources[0]
                let dimensions = Self.dimensions(for: filenameSource, asset: asset)
                let relativePath = try WindowsPathSanitizer.uniqueRelativePath(
                    directory: masterDirectory,
                    filename: filenameSource.originalFilename,
                    fileID: placeholderID,
                    occupiedLowercasePaths: &occupied
                )
                files.append(
                    ExportFile(
                        fileId: placeholderID,
                        assetId: assetID,
                        contentRevision: Self.unavailableMasterRevision(
                            expectedKind: expectedKind,
                            asset: asset
                        ),
                        storageArea: .master,
                        roles: asset.isEdited
                            ? [.masterCurrent]
                            : [.masterCurrent, .rootOriginal],
                        criticality: .masterRequired,
                        provenance: .exactPhotoKitResource,
                        photoKitResourceType: expectedKind,
                        photoKitResourceTypeRaw: Self.rawResourceType(for: expectedKind),
                        originalFilename: filenameSource.originalFilename,
                        proposedRelativePath: relativePath,
                        uniformTypeIdentifier: filenameSource.uniformTypeIdentifier,
                        contentType: filenameSource.uniformTypeIdentifier
                            .flatMap(UTType.init)
                            .flatMap(\.preferredMIMEType),
                        pixelWidth: dimensions.width,
                        pixelHeight: dimensions.height,
                        durationMilliseconds: asset.mediaKind == .video
                            ? asset.durationMilliseconds
                            : nil,
                        byteCount: nil,
                        sha256: nil,
                        captureDate: asset.creationDate,
                        availability: .sourceUnavailable
                    )
                )
                unavailableMasterFileID = placeholderID
            }

            if asset.isEdited, Self.primaryOriginal(in: resources) == nil {
                let placeholder = Self.unavailableRootOriginalFile(
                    asset: asset,
                    assetID: assetID,
                    filenameSource: resources[0]
                )
                files.append(placeholder)
                unavailableOriginalFileID = placeholder.fileId
                missingArchiveCount += 1
            }

            if isLive {
                let expectedMotionResources: [(PhotoResourceKind, [RepresentationRole])]
                if asset.isEdited {
                    expectedMotionResources = [
                        (.pairedVideo, [.originalLiveMotion]),
                        (.fullSizePairedVideo, [.currentLiveMotion])
                    ]
                } else {
                    expectedMotionResources = [
                        (.pairedVideo, [.currentLiveMotion, .originalLiveMotion])
                    ]
                }
                for (expectedKind, roles) in expectedMotionResources
                where !resources.contains(where: { $0.kind == expectedKind }) {
                    let placeholder = Self.unavailableLiveMotionFile(
                        expectedKind: expectedKind,
                        roles: roles,
                        asset: asset,
                        assetID: assetID,
                        filenameSource: Self.primaryOriginal(in: resources) ?? resources[0]
                    )
                    files.append(placeholder)
                    unavailableLiveFileIDs[expectedKind] = placeholder.fileId
                    missingArchiveCount += 1
                }
            }

            let thumbnailID = StableID.make(namespace: "file", value: "\(asset.id)|current-thumbnail")
            let thumbnailDimensions = Self.thumbnailDimensions(for: asset)
            let thumbnailName = "\(((masterResource?.originalFilename ?? resources[0].originalFilename) as NSString).deletingPathExtension)__thumbnail.jpg"
            files.append(
                ExportFile(
                    fileId: thumbnailID,
                    assetId: assetID,
                    contentRevision: Self.thumbnailRevision(for: asset),
                    storageArea: .libraryData,
                    roles: [.auxiliary],
                    criticality: .optional,
                    provenance: .generatedThumbnail,
                    photoKitResourceType: nil,
                    photoKitResourceTypeRaw: nil,
                    originalFilename: thumbnailName,
                    proposedRelativePath: Self.thumbnailPath(assetID: assetID, fileID: thumbnailID),
                    uniformTypeIdentifier: UTType.jpeg.identifier,
                    contentType: "image/jpeg",
                    pixelWidth: thumbnailDimensions.width,
                    pixelHeight: thumbnailDimensions.height,
                    durationMilliseconds: nil,
                    byteCount: nil,
                    sha256: nil,
                    captureDate: asset.creationDate,
                    availability: .available
                )
            )
            sourceAssets[thumbnailID] = asset.id
            thumbnailCount += 1
            unknownBytes += 1

            let masterFileID = masterResource.flatMap { resourceFileIDs[$0.id] }
            let relationships: LivePhotoRelationships? = isLive
                ? LivePhotoRelationships(
                    currentStillFileId: masterFileID ?? unavailableMasterFileID,
                    currentMotionFileId: Self.fileID(
                        forFirstKind: asset.isEdited ? .fullSizePairedVideo : .pairedVideo,
                        resources: resources,
                        resourceFileIDs: resourceFileIDs
                    ) ?? unavailableLiveFileIDs[asset.isEdited ? .fullSizePairedVideo : .pairedVideo],
                    originalStillFileId: Self.fileID(
                        forFirstKind: .photo,
                        resources: resources,
                        resourceFileIDs: resourceFileIDs
                    ) ?? unavailableOriginalFileID ?? unavailableMasterFileID,
                    originalMotionFileId: Self.fileID(
                        forFirstKind: .pairedVideo,
                        resources: resources,
                        resourceFileIDs: resourceFileIDs
                    ) ?? unavailableLiveFileIDs[.pairedVideo]
                )
                : nil

            exportAssets.append(
                ExportAsset(
                    assetId: assetID,
                    sourceLocalIdentifier: asset.id,
                    sourceRevision: asset.sourceRevision,
                    mediaType: asset.mediaKind,
                    mediaSubtypes: wireMediaSubtypes.sorted { $0.rawValue < $1.rawValue },
                    creationDate: asset.creationDate,
                    modificationDate: asset.modificationDate,
                    location: asset.location,
                    isEdited: asset.isEdited,
                    recoveryFingerprint: Self.recoveryFingerprint(
                        for: asset,
                        resources: resources
                    ),
                    masterFileId: masterFileID,
                    livePhotoRelationships: relationships,
                    files: files
                )
            )
        }

        let memberships = try Self.memberships(for: exportAssets, albums: albums)
        let exportSelection = Self.wireSelection(selection)
        let job = ExportJob(
            protocolVersion: ExportConstants.protocolVersion,
            jobId: jobID,
            createdAt: selection.createdAt,
            sourceTimeZone: selection.sourceTimeZone,
            profile: profile,
            selection: exportSelection,
            assets: exportAssets,
            albumMemberships: memberships
        )
        var warnings: [String] = []
        warnings.append("iCloud-only status and exact byte size are determined as each PhotoKit resource is prepared.")
        if missingMasterCount > 0 {
            warnings.append(
                "\(missingMasterCount) item(s) have no exact current full-size resource. Their archive resources can transfer, but no generated fallback will be placed in Master."
            )
        }
        if missingArchiveCount > 0 {
            warnings.append(
                "\(missingArchiveCount) expected reversible archive resource(s) are unavailable. The current media can transfer, but the archive will be reported as incomplete."
            )
        }
        if selection.assets.contains(where: { $0.mediaKind == .video }) {
            warnings.append("HEVC and HDR video originals may require optional codecs on Windows.")
        }
        return PlannedExport(
            job: job,
            sourceResourcesByFileID: sourceResources,
            sourceAssetIDsByFileID: sourceAssets,
            preflight: PreflightSummary(
                assetCount: selection.assets.count,
                masterFileCount: masterCount,
                archiveFileCount: archiveCount,
                thumbnailFileCount: thumbnailCount,
                missingMasterCount: missingMasterCount,
                estimatedKnownBytes: knownBytes,
                unknownByteCount: unknownBytes,
                warnings: warnings
            )
        )
    }

    func rehydrate(job: ExportJob, assets: [PhotoAsset]) throws -> PlannedExport {
        try Task.checkCancellation()
        guard job.protocolVersion == ExportConstants.protocolVersion,
              job.profile.kind == .portableLibrary,
              job.profile.profileVersion == ExportConstants.profileVersion else {
            throw ExportPlanningError.legacyJobRequiresReplanning
        }
        let currentByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var resourcesByFile: [UUID: PhotoResourceDescriptor] = [:]
        var sourceAssetsByFile: [UUID: String] = [:]
        for exportAsset in job.assets {
            try Task.checkCancellation()
            guard let current = currentByID[exportAsset.sourceLocalIdentifier],
                  current.sourceRevision == exportAsset.sourceRevision else { continue }
            let currentResources = ResourceClassifier.authoritativeResources(in: current)
            let currentFileIDs = Self.resourceFileIDs(
                assetID: current.id,
                resources: currentResources
            )
            let resourcesByStableID = Dictionary(uniqueKeysWithValues: currentResources.compactMap { resource in
                currentFileIDs[resource.id].map { ($0, resource) }
            })
            for file in exportAsset.files {
                if file.provenance == .exactPhotoKitResource,
                   let resource = resourcesByStableID[file.fileId] {
                    resourcesByFile[file.fileId] = resource
                    sourceAssetsByFile[file.fileId] = current.id
                } else if file.provenance == .generatedThumbnail {
                    sourceAssetsByFile[file.fileId] = current.id
                }
            }
        }
        var warnings = ["This is a frozen resume. Sources changed or removed since planning will be reported, never substituted."]
        let missingMasterCount = job.assets.filter { $0.masterFileId == nil }.count
        if missingMasterCount > 0 {
            warnings.append("\(missingMasterCount) item(s) have no exact current resource and will not receive a Master file.")
        }
        let missingArchiveCount = job.files.filter {
            $0.criticality == .archiveRequired && $0.availability == .sourceUnavailable
        }.count
        if missingArchiveCount > 0 {
            warnings.append("\(missingArchiveCount) expected reversible archive resource(s) remain unavailable in this frozen transfer.")
        }
        return PlannedExport(
            job: job,
            sourceResourcesByFileID: resourcesByFile,
            sourceAssetIDsByFileID: sourceAssetsByFile,
            preflight: PreflightSummary(
                assetCount: job.assets.count,
                masterFileCount: job.files.filter {
                    $0.storageArea == .master && $0.availability == .available
                }.count,
                archiveFileCount: job.files.filter {
                    $0.storageArea == .libraryData
                        && $0.provenance == .exactPhotoKitResource
                        && $0.availability == .available
                }.count,
                thumbnailFileCount: job.files.filter { $0.provenance == .generatedThumbnail }.count,
                missingMasterCount: missingMasterCount,
                estimatedKnownBytes: job.files.compactMap(\.byteCount).reduce(0, +),
                unknownByteCount: job.files.filter {
                    $0.availability == .available && $0.byteCount == nil
                }.count,
                warnings: warnings
            )
        )
    }

    private static func masterDirectory(for date: Date?, calendar: Calendar, timeZoneID: String) -> String {
        guard let date else { return "Master/Undated" }
        var calendar = calendar
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        let day = String(format: "%02d", parts.day ?? 0)
        return "Master/\(year)/\(year)-\(month)/\(year)-\(month)-\(day)"
    }

    private static func resourceFileIDs(
        assetID: String,
        resources: [PhotoResourceDescriptor]
    ) -> [String: UUID] {
        var occurrences: [String: Int] = [:]
        var result: [String: UUID] = [:]
        result.reserveCapacity(resources.count)
        for resource in resources {
            let slotKind = resource.kind == .unknown
                ? "unknown-\(resource.rawResourceType.map(String.init) ?? "untyped")"
                : resource.kind.rawValue
            let occurrence = occurrences[slotKind, default: 0]
            occurrences[slotKind] = occurrence + 1
            result[resource.id] = StableID.make(
                namespace: "file",
                value: "\(assetID)|photoKit-slot|\(slotKind)|\(occurrence)"
            )
        }
        return result
    }

    private static func contentRevision(for resource: PhotoResourceDescriptor, asset: PhotoAsset) -> String {
        let mutableKinds: Set<PhotoResourceKind> = [
            .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo,
            .adjustmentData, .adjustmentBasePhoto, .adjustmentBasePairedVideo,
            .adjustmentBaseVideo, .unknown
        ]
        let parts = [
            "photo-kit-resource-v2",
            asset.id,
            resource.kind.rawValue,
            resource.rawResourceType.map(String.init) ?? "",
            resource.originalFilename,
            resource.uniformTypeIdentifier ?? "",
            resource.estimatedByteCount.map(String.init) ?? "",
            mutableKinds.contains(resource.kind) ? asset.sourceRevision : "immutable-original"
        ]
        return SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).hexString
    }

    private static func unavailableMasterRevision(
        expectedKind: PhotoResourceKind,
        asset: PhotoAsset
    ) -> String {
        SHA256.hash(data: Data(
            "unavailable-master-v2|\(asset.id)|\(expectedKind.rawValue)|\(asset.sourceRevision)".utf8
        )).hexString
    }

    private static func unavailableLiveMotionFile(
        expectedKind: PhotoResourceKind,
        roles: [RepresentationRole],
        asset: PhotoAsset,
        assetID: UUID,
        filenameSource: PhotoResourceDescriptor
    ) -> ExportFile {
        let fileID = StableID.make(
            namespace: "file",
            value: "\(asset.id)|unavailable-live-motion|\(expectedKind.rawValue)"
        )
        let stem = (filenameSource.originalFilename as NSString).deletingPathExtension
        let marker = expectedKind == .fullSizePairedVideo ? "_CURRENT" : ""
        let originalFilename = "\(stem)\(marker).MOV"
        return ExportFile(
            fileId: fileID,
            assetId: assetID,
            contentRevision: SHA256.hash(data: Data(
                "unavailable-live-motion-v2|\(asset.id)|\(expectedKind.rawValue)|\(asset.sourceRevision)".utf8
            )).hexString,
            storageArea: .libraryData,
            roles: roles.sorted { $0.rawValue < $1.rawValue },
            criticality: .archiveRequired,
            provenance: .exactPhotoKitResource,
            photoKitResourceType: expectedKind,
            photoKitResourceTypeRaw: rawResourceType(for: expectedKind),
            originalFilename: originalFilename,
            proposedRelativePath: "MB Photos Data/Resources/\(assetID.uuidString.lowercased())/\(fileID.uuidString.lowercased()).mov",
            uniformTypeIdentifier: UTType.quickTimeMovie.identifier,
            contentType: "video/quicktime",
            pixelWidth: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            pixelHeight: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
            durationMilliseconds: asset.durationMilliseconds,
            byteCount: nil,
            sha256: nil,
            captureDate: asset.creationDate,
            availability: .sourceUnavailable
        )
    }

    private static func unavailableRootOriginalFile(
        asset: PhotoAsset,
        assetID: UUID,
        filenameSource: PhotoResourceDescriptor
    ) -> ExportFile {
        let expectedKind: PhotoResourceKind = asset.mediaKind == .photo ? .photo : .video
        let fileID = StableID.make(
            namespace: "file",
            value: "\(asset.id)|unavailable-root-original|\(expectedKind.rawValue)"
        )
        let dimensions = dimensions(for: filenameSource, asset: asset)
        return ExportFile(
            fileId: fileID,
            assetId: assetID,
            contentRevision: SHA256.hash(data: Data(
                "unavailable-root-original-v2|\(asset.id)|\(expectedKind.rawValue)|\(asset.sourceRevision)".utf8
            )).hexString,
            storageArea: .libraryData,
            roles: [.rootOriginal],
            criticality: .archiveRequired,
            provenance: .exactPhotoKitResource,
            photoKitResourceType: expectedKind,
            photoKitResourceTypeRaw: rawResourceType(for: expectedKind),
            originalFilename: filenameSource.originalFilename,
            proposedRelativePath: libraryResourcePath(
                assetID: assetID,
                fileID: fileID,
                resource: filenameSource
            ),
            uniformTypeIdentifier: filenameSource.uniformTypeIdentifier,
            contentType: filenameSource.uniformTypeIdentifier
                .flatMap(UTType.init)
                .flatMap(\.preferredMIMEType),
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            durationMilliseconds: asset.mediaKind == .video ? asset.durationMilliseconds : nil,
            byteCount: nil,
            sha256: nil,
            captureDate: asset.creationDate,
            availability: .sourceUnavailable
        )
    }

    private static func thumbnailRevision(for asset: PhotoAsset) -> String {
        SHA256.hash(data: Data(
            "thumbnail|\(ExportConstants.thumbnailRendererVersion)|\(asset.sourceRevision)".utf8
        )).hexString
    }

    private static func primaryOriginal(
        in resources: [PhotoResourceDescriptor]
    ) -> PhotoResourceDescriptor? {
        resources.first { $0.kind == .photo || $0.kind == .video }
    }

    private static func rawResourceType(for kind: PhotoResourceKind) -> Int? {
        switch kind {
        case .photo: 1
        case .video: 2
        case .fullSizePhoto: 5
        case .fullSizeVideo: 6
        case .pairedVideo: 9
        case .fullSizePairedVideo: 10
        default: nil
        }
    }

    private static func recoveryFingerprint(
        for asset: PhotoAsset,
        resources: [PhotoResourceDescriptor]
    ) -> RecoveryFingerprint {
        let originals = resources.filter {
            roles(for: $0, asset: asset, isMaster: false).contains(.rootOriginal)
        }
        // Future PhotoKit resource layouts may not expose a type that this
        // build recognizes as the root original. Keep the recovery arrays
        // non-empty and aligned without pretending an auxiliary file has the
        // rootOriginal representation role.
        let fingerprintResources = originals.isEmpty ? resources : originals
        return RecoveryFingerprint(
            captureDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            durationMilliseconds: asset.durationMilliseconds,
            mediaType: asset.mediaKind,
            originalFilenames: fingerprintResources.map(\.originalFilename),
            resourceByteCounts: fingerprintResources.map(\.estimatedByteCount)
        )
    }

    private static func roles(
        for resource: PhotoResourceDescriptor,
        asset: PhotoAsset,
        isMaster: Bool
    ) -> [RepresentationRole] {
        var roles: Set<RepresentationRole> = []
        if isMaster { roles.insert(.masterCurrent) }
        switch resource.kind {
        case .photo, .video:
            roles.insert(.rootOriginal)
        case .alternatePhoto:
            roles.insert(.alternateOriginal)
        case .pairedVideo:
            roles.insert(.originalLiveMotion)
            if !asset.isEdited { roles.insert(.currentLiveMotion) }
        case .fullSizePairedVideo:
            roles.insert(.currentLiveMotion)
        case .adjustmentData:
            roles.insert(.adjustmentRecipe)
        case .adjustmentBasePhoto, .adjustmentBasePairedVideo, .adjustmentBaseVideo:
            roles.insert(.adjustmentBase)
        case .audio, .fullSizePhoto, .fullSizeVideo, .unknown:
            if !isMaster { roles.insert(.auxiliary) }
        case .photoProxy:
            break
        }
        return roles.sorted { $0.rawValue < $1.rawValue }
    }

    private static func criticality(for roles: [RepresentationRole], isMaster: Bool) -> Criticality {
        if isMaster { return .masterRequired }
        let archival: Set<RepresentationRole> = [
            .rootOriginal, .currentLiveMotion, .originalLiveMotion,
            .adjustmentBase, .adjustmentRecipe, .alternateOriginal
        ]
        return roles.contains(where: archival.contains) ? .archiveRequired : .optional
    }

    private static func duration(for resource: PhotoResourceDescriptor, asset: PhotoAsset) -> Int? {
        switch resource.kind {
        case .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo,
             .adjustmentBasePairedVideo, .adjustmentBaseVideo, .audio:
            asset.durationMilliseconds
        default:
            nil
        }
    }

    private static func dimensions(
        for resource: PhotoResourceDescriptor,
        asset: PhotoAsset
    ) -> (width: Int?, height: Int?) {
        switch resource.kind {
        case .photo, .alternatePhoto, .fullSizePhoto, .video, .fullSizeVideo,
             .pairedVideo, .fullSizePairedVideo, .adjustmentBasePhoto,
             .adjustmentBasePairedVideo, .adjustmentBaseVideo:
            return (
                resource.pixelWidth > 0 ? resource.pixelWidth : (asset.pixelWidth > 0 ? asset.pixelWidth : nil),
                resource.pixelHeight > 0 ? resource.pixelHeight : (asset.pixelHeight > 0 ? asset.pixelHeight : nil)
            )
        case .audio, .adjustmentData, .photoProxy, .unknown:
            return (
                resource.pixelWidth > 0 ? resource.pixelWidth : nil,
                resource.pixelHeight > 0 ? resource.pixelHeight : nil
            )
        }
    }

    private static func libraryResourcePath(
        assetID: UUID,
        fileID: UUID,
        resource: PhotoResourceDescriptor
    ) -> String {
        let filenameExtension = (resource.originalFilename as NSString).pathExtension
        let inferredExtension = resource.uniformTypeIdentifier
            .flatMap(UTType.init)
            .flatMap(\.preferredFilenameExtension)
        let safeExtension = WindowsPathSanitizer.component(
            filenameExtension.isEmpty ? (inferredExtension ?? "bin") : filenameExtension
        )
        return "MB Photos Data/Resources/\(assetID.uuidString.lowercased())/\(fileID.uuidString.lowercased()).\(safeExtension)"
    }

    private static func thumbnailPath(assetID: UUID, fileID: UUID) -> String {
        "MB Photos Data/Thumbnails/\(assetID.uuidString.lowercased())/\(fileID.uuidString.lowercased()).jpg"
    }

    private static func thumbnailDimensions(for asset: PhotoAsset) -> (width: Int?, height: Int?) {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return (nil, nil) }
        let maximum = Double(ExportConstants.thumbnailMaximumPixelDimension)
        let scale = min(1, maximum / Double(max(asset.pixelWidth, asset.pixelHeight)))
        return (
            max(1, Int((Double(asset.pixelWidth) * scale).rounded())),
            max(1, Int((Double(asset.pixelHeight) * scale).rounded()))
        )
    }

    private static func fileID(
        forFirstKind kind: PhotoResourceKind,
        resources: [PhotoResourceDescriptor],
        resourceFileIDs: [String: UUID]
    ) -> UUID? {
        resources.first { $0.kind == kind }.flatMap { resourceFileIDs[$0.id] }
    }

    private static func wireSelection(_ selection: FrozenSelection) -> ExportSelection {
        let dateRange: ExportSelection.DateRange?
        if case let .dateRange(start, end) = selection.source {
            dateRange = .init(start: start, end: end)
        } else {
            dateRange = nil
        }
        return ExportSelection(
            kind: selection.source.kind,
            assetCount: selection.assets.count,
            dateRange: dateRange,
            sourceAlbumIdentifiers: selection.selectedAlbumIDs.isEmpty ? nil : selection.selectedAlbumIDs
        )
    }

    private static func memberships(for assets: [ExportAsset], albums: [PhotoAlbum]) throws -> [AlbumMembership] {
        let assetBySourceID = Dictionary(uniqueKeysWithValues: assets.map { ($0.sourceLocalIdentifier, $0.assetId) })
        var result: [AlbumMembership] = []
        for album in albums {
            try Task.checkCancellation()
            let albumID = StableID.make(namespace: "album", value: album.id)
            let parentID = album.parentID.map { StableID.make(namespace: "album", value: $0) }
            for sourceAssetID in album.assetIDs {
                try Task.checkCancellation()
                guard let assetID = assetBySourceID[sourceAssetID] else { continue }
                result.append(AlbumMembership(
                    albumId: albumID,
                    sourceAlbumIdentifier: album.id,
                    albumTitle: album.title,
                    parentAlbumId: parentID,
                    assetId: assetID
                ))
            }
        }
        return result
    }
}
