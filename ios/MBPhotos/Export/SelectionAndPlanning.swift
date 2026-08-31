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
    case noOriginalResources(String)

    var errorDescription: String? {
        switch self {
        case let .noOriginalResources(assetID):
            "An accessible item has no exportable original resource (\(assetID)). Refresh the library and try again."
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
        if case let .albums(ids) = source {
            albumIDs = ids.sorted()
        } else {
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
    case unsupported
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
            .unsupported
        }
    }

    static func originalResources(in asset: PhotoAsset) -> [PhotoResourceDescriptor] {
        asset.resources
            .filter {
                if case .original = classify($0.kind) { return true }
                return false
            }
            .sorted { $0.id < $1.id }
    }

    static func needsCurrentJPEG(_ asset: PhotoAsset) -> Bool {
        guard asset.mediaKind == .photo else { return false }
        if asset.isEdited { return true }
        let original = originalResources(in: asset).first { $0.kind == .photo }
            ?? originalResources(in: asset).first
        guard let uti = original?.uniformTypeIdentifier?.lowercased() else { return true }
        let compatible = ["public.jpeg", "public.jpg", "public.png", "com.compuserve.gif"]
        return !compatible.contains(uti)
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
    let originalFileCount: Int
    let generatedJPEGCount: Int
    let estimatedKnownBytes: Int64
    let unknownByteCount: Int
    let editedVideoCount: Int
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
    case album(revision: UInt64, id: String, isSelected: Bool)

    var revision: UInt64 {
        switch self {
        case let .asset(revision, _, _), let .album(revision, _, _): revision
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
        case let .album(_, id, isSelected):
            if isSelected { selectedAlbumIDs.insert(id) }
            else { selectedAlbumIDs.remove(id) }
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
        case .manual: .manual(selectedAssetIDs)
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
    func plan(
        selection: FrozenSelection,
        albums: [PhotoAlbum],
        profile: ExportProfile,
        jobID: UUID = UUID()
    ) throws -> PlannedExport {
        var occupied: Set<String> = []
        var sourceResources: [UUID: PhotoResourceDescriptor] = [:]
        var sourceAssets: [UUID: String] = [:]
        var exportAssets: [ExportAsset] = []
        var originalCount = 0
        var jpegCount = 0
        var knownBytes: Int64 = 0
        var unknownBytes = 0
        var editedVideoCount = 0

        let calendar = Calendar(identifier: .gregorian)
        for asset in selection.assets {
            try Task.checkCancellation()
            let assetID = StableID.make(namespace: "asset", value: asset.id)
            let originals = ResourceClassifier.originalResources(in: asset)
            guard !originals.isEmpty else {
                throw ExportPlanningError.noOriginalResources(asset.id)
            }
            var files: [ExportFile] = []
            let directory = Self.directory(for: asset.creationDate, calendar: calendar, timeZoneID: selection.sourceTimeZone)

            for resource in originals {
                let fileID = StableID.make(
                    namespace: "file",
                    value: "\(asset.id)|\(asset.sourceRevision)|original|\(resource.id)"
                )
                let relativePath = try WindowsPathSanitizer.uniqueRelativePath(
                    directory: directory,
                    filename: resource.originalFilename,
                    fileID: fileID,
                    occupiedLowercasePaths: &occupied
                )
                let file = ExportFile(
                    fileId: fileID,
                    assetId: assetID,
                    kind: .originalResource,
                    resourceType: resource.kind,
                    originalFilename: resource.originalFilename,
                    proposedRelativePath: relativePath,
                    byteCount: resource.estimatedByteCount,
                    sha256: nil,
                    sourceRevision: asset.sourceRevision,
                    captureDate: asset.creationDate,
                    contentType: resource.uniformTypeIdentifier
                        .flatMap(UTType.init)
                        .flatMap(\.preferredMIMEType)
                )
                files.append(file)
                sourceResources[fileID] = resource
                sourceAssets[fileID] = asset.id
                originalCount += 1
                if let bytes = resource.estimatedByteCount { knownBytes += bytes } else { unknownBytes += 1 }
            }

            if profile.kind == .originalsAndCurrentJpegs, ResourceClassifier.needsCurrentJPEG(asset) {
                let sourceBase = originals.first?.originalFilename ?? "Photo"
                let base = (sourceBase as NSString).deletingPathExtension
                let fileID = StableID.make(
                    namespace: "file",
                    value: "\(asset.id)|\(asset.sourceRevision)|currentJPEG|\(ExportConstants.jpegRendererVersion)|\(profile.preserveLocation)"
                )
                let relativePath = try WindowsPathSanitizer.uniqueRelativePath(
                    directory: directory,
                    filename: "\(base)__current.jpg",
                    fileID: fileID,
                    occupiedLowercasePaths: &occupied
                )
                files.append(
                    ExportFile(
                        fileId: fileID,
                        assetId: assetID,
                        kind: .currentJpeg,
                        resourceType: .photo,
                        originalFilename: sourceBase,
                        proposedRelativePath: relativePath,
                        byteCount: nil,
                        sha256: nil,
                        sourceRevision: asset.sourceRevision,
                        captureDate: asset.creationDate,
                        contentType: "image/jpeg"
                    )
                )
                sourceAssets[fileID] = asset.id
                jpegCount += 1
                unknownBytes += 1
            }
            if asset.mediaKind == .video, asset.isEdited { editedVideoCount += 1 }

            exportAssets.append(
                ExportAsset(
                    assetId: assetID,
                    sourceLocalIdentifier: asset.id,
                    sourceRevision: asset.sourceRevision,
                    mediaType: asset.mediaKind,
                    mediaSubtypes: asset.mediaSubtypes.sorted { $0.rawValue < $1.rawValue },
                    creationDate: asset.creationDate,
                    modificationDate: asset.modificationDate,
                    location: profile.preserveLocation ? asset.location : nil,
                    isEdited: asset.isEdited,
                    recoveryFingerprint: RecoveryFingerprint(
                        captureDate: asset.creationDate,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        durationMilliseconds: asset.durationMilliseconds,
                        mediaType: asset.mediaKind,
                        originalFilenames: originals.map(\.originalFilename),
                        resourceByteCounts: originals.map(\.estimatedByteCount)
                    ),
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
        warnings.append("iCloud-only status and exact byte size are determined as each original is prepared.")
        if editedVideoCount > 0 {
            warnings.append("\(editedVideoCount) edited video(s) will export original resources only; current edited playback is not rendered in this version.")
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
                originalFileCount: originalCount,
                generatedJPEGCount: jpegCount,
                estimatedKnownBytes: knownBytes,
                unknownByteCount: unknownBytes,
                editedVideoCount: editedVideoCount,
                warnings: warnings
            )
        )
    }

    func rehydrate(job: ExportJob, assets: [PhotoAsset]) throws -> PlannedExport {
        try Task.checkCancellation()
        let currentByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var resourcesByFile: [UUID: PhotoResourceDescriptor] = [:]
        var sourceAssetsByFile: [UUID: String] = [:]
        for exportAsset in job.assets {
            try Task.checkCancellation()
            guard let current = currentByID[exportAsset.sourceLocalIdentifier],
                  current.sourceRevision == exportAsset.sourceRevision else { continue }
            let resourcesByStableID = Dictionary(uniqueKeysWithValues: current.resources.map { resource in
                let fileID = StableID.make(
                    namespace: "file",
                    value: "\(current.id)|\(current.sourceRevision)|original|\(resource.id)"
                )
                return (fileID, resource)
            })
            for file in exportAsset.files {
                sourceAssetsByFile[file.fileId] = current.id
                if file.kind == .originalResource, let resource = resourcesByStableID[file.fileId] {
                    resourcesByFile[file.fileId] = resource
                }
            }
        }
        let originals = job.files.filter { $0.kind == .originalResource }
        let jpegs = job.files.filter { $0.kind == .currentJpeg }
        var warnings = ["This is a frozen resume. Sources changed or removed since planning will be reported, never substituted."]
        if job.assets.contains(where: { $0.mediaType == .video && $0.isEdited }) {
            warnings.append("Edited video playback is not rendered; original video resources are preserved.")
        }
        return PlannedExport(
            job: job,
            sourceResourcesByFileID: resourcesByFile,
            sourceAssetIDsByFileID: sourceAssetsByFile,
            preflight: PreflightSummary(
                assetCount: job.assets.count,
                originalFileCount: originals.count,
                generatedJPEGCount: jpegs.count,
                estimatedKnownBytes: job.files.compactMap(\.byteCount).reduce(0, +),
                unknownByteCount: job.files.filter { $0.byteCount == nil }.count,
                editedVideoCount: job.assets.filter { $0.mediaType == .video && $0.isEdited }.count,
                warnings: warnings
            )
        )
    }

    private static func directory(for date: Date?, calendar: Calendar, timeZoneID: String) -> String {
        guard let date else { return "Photos/Undated" }
        var calendar = calendar
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        let day = String(format: "%02d", parts.day ?? 0)
        return "Photos/\(year)/\(year)-\(month)/\(year)-\(month)-\(day)"
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
