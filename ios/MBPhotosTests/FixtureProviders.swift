@testable import MBPhotos
import Foundation
import UIKit

@MainActor
final class FixturePhotoCatalog: PhotoCatalogProviding {
    var catalogRevision: UInt64 = 0
    var state: PhotoAuthorizationState = .authorized
    var snapshot: PhotoLibrarySnapshot

    init(assets: [PhotoAsset], albums: [PhotoAlbum] = []) {
        snapshot = PhotoLibrarySnapshot(assets: assets, albums: albums, changeTokenData: nil)
    }

    func authorizationState() -> PhotoAuthorizationState { state }
    func requestAuthorization() async -> PhotoAuthorizationState { state }
    func fetchSnapshot(revision: UInt64) async throws -> PhotoLibrarySnapshot {
        PhotoLibrarySnapshot(
            revision: revision,
            assets: snapshot.assets,
            albums: snapshot.albums,
            changeTokenData: snapshot.changeTokenData
        )
    }
    func thumbnail(assetID: String, size: CGSize, scale: CGFloat) async -> UIImage? { nil }
    func presentLimitedLibraryPicker(from viewController: UIViewController) {}
}

actor FixtureOriginalProvider: PhotoResourceMaterializing {
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }

    func materializeResource(
        assetID: String,
        descriptor: PhotoResourceDescriptor,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: outputURL)
        progress(1)
    }
}

actor FixtureJPEGRenderer: ThumbnailRendering {
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }

    func renderThumbnail(
        assetID: String,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: outputURL)
        progress(1)
    }
}

enum FixtureFactory {
    static func asset(
        id: String = "asset-1",
        filename: String = "IMG_0001.HEIC",
        uti: String = "public.heic",
        creationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        modified: Date? = nil,
        location: AssetLocation? = nil,
        resourceKind: PhotoResourceKind = .photo,
        edited: Bool = false
    ) -> PhotoAsset {
        PhotoAsset(
            id: id,
            mediaKind: .photo,
            mediaSubtypes: [],
            creationDate: creationDate,
            modificationDate: modified,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            durationMilliseconds: nil,
            location: location,
            isFavorite: false,
            isEdited: edited,
            resources: [
                PhotoResourceDescriptor(
                    id: "\(id)#0#1#\(filename)",
                    kind: resourceKind,
                    originalFilename: filename,
                    uniformTypeIdentifier: uti
                )
            ]
        )
    }
}
