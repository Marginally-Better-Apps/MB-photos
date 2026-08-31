@preconcurrency import Photos
import CryptoKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct PhotoLibrarySnapshot: Sendable {
    let revision: UInt64
    let assets: [PhotoAsset]
    let albums: [PhotoAlbum]
    let changeTokenData: Data?
    let authorizationScopeFingerprint: String?

    init(
        revision: UInt64 = 0,
        assets: [PhotoAsset],
        albums: [PhotoAlbum],
        changeTokenData: Data?,
        authorizationScopeFingerprint: String? = nil
    ) {
        self.revision = revision
        self.assets = assets
        self.albums = albums
        self.changeTokenData = changeTokenData
        self.authorizationScopeFingerprint = authorizationScopeFingerprint
    }
}

@MainActor
protocol PhotoCatalogProviding: AnyObject {
    var catalogRevision: UInt64 { get }
    func authorizationState() -> PhotoAuthorizationState
    func requestAuthorization() async -> PhotoAuthorizationState
    func fetchSnapshot(revision: UInt64) async throws -> PhotoLibrarySnapshot
    func thumbnail(assetID: String, size: CGSize, scale: CGFloat) async -> UIImage?
    func presentLimitedLibraryPicker(from viewController: UIViewController)
}

@MainActor
final class PhotoKitCatalog: NSObject, ObservableObject, PhotoCatalogProviding {
    @Published private(set) var catalogRevision: UInt64 = 0
    private let thumbnailPipeline: PhotoThumbnailPipeline

    override init() {
        thumbnailPipeline = PhotoThumbnailPipeline(client: PhotoKitThumbnailRequestClient())
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    init(thumbnailPipeline: PhotoThumbnailPipeline) {
        self.thumbnailPipeline = thumbnailPipeline
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    func authorizationState() -> PhotoAuthorizationState {
        Self.mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoAuthorizationState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return Self.mapAuthorization(status)
    }

    func fetchSnapshot(revision: UInt64) async throws -> PhotoLibrarySnapshot {
        let authorization = authorizationState()
        return try await Task.detached(priority: .userInitiated) {
            try PhotoKitLibraryReader.fullSnapshot(
                revision: revision,
                authorization: authorization
            )
        }.value
    }

    func thumbnail(assetID: String, size: CGSize, scale: CGFloat) async -> UIImage? {
        await thumbnail(
            assetID: assetID,
            size: size,
            scale: scale,
            allowsNetworkAccess: false
        )
    }

    func thumbnail(
        assetID: String,
        size: CGSize,
        scale: CGFloat,
        allowsNetworkAccess: Bool
    ) async -> UIImage? {
        let key = PhotoThumbnailKey(
            assetID: assetID,
            revision: catalogRevision,
            pixelWidth: max(Int((size.width * scale).rounded(.up)), 1),
            pixelHeight: max(Int((size.height * scale).rounded(.up)), 1),
            allowsNetworkAccess: allowsNetworkAccess
        )
        guard let decoded = await thumbnailPipeline.decodedThumbnail(for: key, scale: scale),
              !Task.isCancelled else {
            return nil
        }
        // Fetching, resizing, encoding, request coalescing, cache eviction, and
        // eager pixel decoding all happen behind the actor boundary. Only the
        // final immutable presentation image is installed on the main actor.
        return decoded.image
    }

    func clearThumbnailCache() async {
        await thumbnailPipeline.removeAll()
    }

    func presentLimitedLibraryPicker(from viewController: UIViewController) {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController)
    }

    nonisolated private static func mapAuthorization(_ status: PHAuthorizationStatus) -> PhotoAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .limited: .limited
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

}

enum PhotoKitFetchOptions {
    nonisolated static func includingHiddenAssets() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return options
    }
}

enum PhotoKitAssetMapper {
    nonisolated static func model(from asset: PHAsset) -> PhotoAsset? {
        guard asset.mediaType == .image || asset.mediaType == .video else { return nil }
        let resources = PhotoKitResourceCatalog.descriptors(
            assetID: asset.localIdentifier,
            resources: PHAssetResource.assetResources(for: asset)
        )
        let edited = asset.hasAdjustments || resources.contains {
            [.adjustmentData, .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo].contains($0.kind)
        }
        var mediaSubtypes = mapSubtypes(asset.mediaSubtypes)
        if resources.contains(where: { descriptor in
            guard let identifier = descriptor.uniformTypeIdentifier,
                  let type = UTType(identifier) else { return false }
            return type.conforms(to: .rawImage)
        }) {
            mediaSubtypes.insert(.raw)
        }

        let addedDate: Date?
        if #available(iOS 26.0, *) {
            addedDate = asset.addedDate
        } else {
            addedDate = nil
        }

        return PhotoAsset(
            id: asset.localIdentifier,
            mediaKind: asset.mediaType == .video ? .video : .photo,
            mediaSubtypes: mediaSubtypes,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            durationMilliseconds: asset.mediaType == .video ? Int(asset.duration * 1_000) : nil,
            location: asset.location.map {
                AssetLocation(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    altitudeMeters: $0.verticalAccuracy >= 0 ? $0.altitude : nil
                )
            },
            isFavorite: asset.isFavorite,
            isEdited: edited,
            resources: resources,
            isHidden: asset.isHidden,
            addedDate: addedDate,
            burstIdentifier: asset.burstIdentifier,
            representsBurst: asset.representsBurst
        )
    }

    nonisolated static func mapSubtypes(_ subtypes: PHAssetMediaSubtype) -> Set<AssetMediaSubtype> {
        var result: Set<AssetMediaSubtype> = []
        if subtypes.contains(.photoLive) { result.insert(.livePhoto) }
        if subtypes.contains(.photoPanorama) { result.insert(.panorama) }
        if subtypes.contains(.photoScreenshot) { result.insert(.screenshot) }
        if subtypes.contains(.videoScreenRecording) { result.insert(.screenRecording) }
        if subtypes.contains(.photoHDR) { result.insert(.hdr) }
        if subtypes.contains(.photoDepthEffect) { result.insert(.depthEffect) }
        if subtypes.contains(.spatialMedia) { result.insert(.spatialMedia) }
        if subtypes.contains(.videoCinematic) { result.insert(.cinematic) }
        if subtypes.contains(.videoHighFrameRate) {
            result.insert(.highFrameRate)
            result.insert(.slowMotion)
        }
        if subtypes.contains(.videoTimelapse) { result.insert(.timelapse) }
        return result
    }
}

enum PhotoKitResourceCatalog {
    private struct KeyedResource {
        let index: Int
        let key: String
        let resource: PHAssetResource
    }

    nonisolated static func descriptors(
        assetID: String,
        resources: [PHAssetResource]
    ) -> [PhotoResourceDescriptor] {
        entries(assetID: assetID, resources: resources).map(\.descriptor)
    }

    nonisolated static func resource(
        descriptorID: String,
        assetID: String,
        resources: [PHAssetResource]
    ) -> PHAssetResource? {
        entries(assetID: assetID, resources: resources)
            .first { $0.descriptor.id == descriptorID }?
            .resource
    }

    nonisolated private static func entries(
        assetID: String,
        resources: [PHAssetResource]
    ) -> [(descriptor: PhotoResourceDescriptor, resource: PHAssetResource)] {
        var keyed: [KeyedResource] = []
        keyed.reserveCapacity(resources.count)
        for (index, resource) in resources.enumerated() {
            let type = String(resource.type.rawValue)
            let filename = resource.originalFilename
            let uniformTypeIdentifier = resource.uniformTypeIdentifier
            let separator = "\u{1f}"
            let key = type + separator + filename + separator + uniformTypeIdentifier
            keyed.append(KeyedResource(index: index, key: key, resource: resource))
        }
        keyed.sort { lhs, rhs in
            lhs.key == rhs.key ? lhs.index < rhs.index : lhs.key < rhs.key
        }

        var occurrences: [String: Int] = [:]
        var result: [(descriptor: PhotoResourceDescriptor, resource: PHAssetResource)] = []
        result.reserveCapacity(keyed.count)
        for entry in keyed {
            let occurrence = occurrences[entry.key, default: 0]
            occurrences[entry.key] = occurrence + 1
            let keyHash = SHA256.hash(data: Data(entry.key.utf8)).hexString
            result.append((
                PhotoResourceDescriptor(
                    id: "\(assetID)#\(keyHash)#\(occurrence)",
                    kind: mapResourceKind(entry.resource.type),
                    originalFilename: entry.resource.originalFilename,
                    uniformTypeIdentifier: entry.resource.uniformTypeIdentifier
                ),
                entry.resource
            ))
        }
        return result
    }

    nonisolated private static func mapResourceKind(_ type: PHAssetResourceType) -> PhotoResourceKind {
        switch type {
        case .photo: .photo
        case .video: .video
        case .audio: .audio
        case .alternatePhoto: .alternatePhoto
        case .fullSizePhoto: .fullSizePhoto
        case .fullSizeVideo: .fullSizeVideo
        case .adjustmentData: .adjustmentData
        case .adjustmentBasePhoto: .adjustmentBasePhoto
        case .pairedVideo: .pairedVideo
        case .fullSizePairedVideo: .fullSizePairedVideo
        case .adjustmentBasePairedVideo: .adjustmentBasePairedVideo
        case .adjustmentBaseVideo: .adjustmentBaseVideo
        case .photoProxy: .photoProxy
        @unknown default: .unknown
        }
    }
}

extension PhotoKitCatalog: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.catalogRevision &+= 1
        }
    }
}
