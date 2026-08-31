@preconcurrency import Photos
import CryptoKit
import Foundation

/// Replays PhotoKit's persistent change journal away from the main actor. Token
/// expiry and unavailable change details deliberately become a full rebuild;
/// transient errors are thrown so the durable cache remains the UI fallback.
final class PhotoKitPersistentChangeLoader: PhotoLibraryChangeLoading, @unchecked Sendable {
    func loadChanges(
        since changeTokenData: Data?,
        revision: UInt64,
        authorization: PhotoAuthorizationState,
        knownAssetIDs: Set<String>
    ) async throws -> PhotoLibraryChangeLoadResult {
        let task = Task.detached(priority: .utility) {
            try Self.loadSynchronously(
                since: changeTokenData,
                revision: revision,
                authorization: authorization,
                knownAssetIDs: knownAssetIDs
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func currentAuthorizationScopeFingerprint(
        authorization: PhotoAuthorizationState
    ) async throws -> String? {
        guard authorization == .limited else { return nil }
        let task = Task.detached(priority: .utility) {
            let identifiers = try PhotoKitLibraryReader.accessibleAssetIdentifiers()
            try Task.checkCancellation()
            return try PhotoKitLibraryReader.scopeFingerprint(for: identifiers)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func loadSynchronously(
        since changeTokenData: Data?,
        revision: UInt64,
        authorization: PhotoAuthorizationState,
        knownAssetIDs: Set<String>
    ) throws -> PhotoLibraryChangeLoadResult {
        guard let changeTokenData,
              let token = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: PHPersistentChangeToken.self,
                  from: changeTokenData
              ) else {
            return .rebuild(
                try PhotoKitLibraryReader.fullSnapshot(
                    revision: revision,
                    authorization: authorization
                )
            )
        }

        let history: PHPersistentChangeFetchResult
        do {
            history = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
        } catch {
            if Self.requiresRebuild(error) {
                return .rebuild(
                    try PhotoKitLibraryReader.fullSnapshot(
                        revision: revision,
                        authorization: authorization
                    )
                )
            }
            throw error
        }

        var insertedOrUpdatedAssetIDs: Set<String> = []
        var deletedAssetIDs: Set<String> = []
        var insertedOrUpdatedAlbumIDs: Set<String> = []
        var deletedAlbumIDs: Set<String> = []
        var latestToken = token

        do {
            for change in history {
                try Task.checkCancellation()
                let assetDetails = try change.changeDetails(for: .asset)
                insertedOrUpdatedAssetIDs.formUnion(assetDetails.insertedLocalIdentifiers)
                insertedOrUpdatedAssetIDs.formUnion(assetDetails.updatedLocalIdentifiers)
                deletedAssetIDs.formUnion(assetDetails.deletedLocalIdentifiers)
                let albumDetails = try change.changeDetails(for: .assetCollection)
                insertedOrUpdatedAlbumIDs.formUnion(albumDetails.insertedLocalIdentifiers)
                insertedOrUpdatedAlbumIDs.formUnion(albumDetails.updatedLocalIdentifiers)
                deletedAlbumIDs.formUnion(albumDetails.deletedLocalIdentifiers)
                latestToken = change.changeToken
            }
        } catch {
            if Self.requiresRebuild(error) {
                return .rebuild(
                    try PhotoKitLibraryReader.fullSnapshot(
                        revision: revision,
                        authorization: authorization
                    )
                )
            }
            throw error
        }

        deletedAssetIDs.subtract(insertedOrUpdatedAssetIDs)
        deletedAlbumIDs.subtract(insertedOrUpdatedAlbumIDs)
        let assets = try PhotoKitLibraryReader.assets(identifiers: insertedOrUpdatedAssetIDs)
        deletedAssetIDs.formUnion(insertedOrUpdatedAssetIDs.subtracting(Set(assets.map(\.id))))
        let albums = try PhotoKitLibraryReader.albums(identifiers: insertedOrUpdatedAlbumIDs)
        deletedAlbumIDs.formUnion(insertedOrUpdatedAlbumIDs.subtracting(Set(albums.map(\.id))))

        let accessibleAssetIDs: Set<String>? = authorization == .limited
            ? try PhotoKitLibraryReader.accessibleAssetIdentifiers()
            : nil
        if let accessibleAssetIDs,
           !accessibleAssetIDs.subtracting(knownAssetIDs).isEmpty {
            // PhotoKit does not guarantee a persistent asset insertion for a
            // newly granted limited-library item. Rebuild so its metadata and
            // all album memberships appear atomically.
            return .rebuild(
                try PhotoKitLibraryReader.fullSnapshot(
                    revision: revision,
                    authorization: authorization
                )
            )
        }
        let scopeFingerprint: String?
        if let accessibleAssetIDs {
            scopeFingerprint = try PhotoKitLibraryReader.scopeFingerprint(for: accessibleAssetIDs)
        } else {
            scopeFingerprint = nil
        }
        let tokenData = try NSKeyedArchiver.archivedData(
            withRootObject: latestToken,
            requiringSecureCoding: true
        )
        return .changes(
            PhotoLibraryIndexChanges(
                upsertedAssets: assets,
                deletedAssetIDs: deletedAssetIDs,
                upsertedAlbums: albums,
                deletedAlbumIDs: deletedAlbumIDs,
                accessibleAssetIDs: accessibleAssetIDs,
                changeTokenData: tokenData,
                authorizationScopeFingerprint: scopeFingerprint
            )
        )
    }

    private static func requiresRebuild(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == PHPhotosErrorDomain && (error.code == 3_105 || error.code == 3_210)
    }
}

enum PhotoKitLibraryReader {
    nonisolated static func fullSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) throws -> PhotoLibrarySnapshot {
        let tokenData = try NSKeyedArchiver.archivedData(
            withRootObject: PHPhotoLibrary.shared().currentChangeToken,
            requiringSecureCoding: true
        )
        try Task.checkCancellation()
        let assets = try allAssets()
        try Task.checkCancellation()
        return PhotoLibrarySnapshot(
            revision: revision,
            assets: assets,
            albums: try allAlbums(),
            changeTokenData: tokenData,
            authorizationScopeFingerprint: authorization == .limited
                ? try scopeFingerprint(for: Set(assets.map(\.id)))
                : nil
        )
    }

    nonisolated static func allAssets() throws -> [PhotoAsset] {
        let options = PhotoKitFetchOptions.includingHiddenAssets()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PhotoAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, index, stop in
            if index.isMultiple(of: 128), Task.isCancelled {
                stop.pointee = true
                return
            }
            if let model = PhotoKitAssetMapper.model(from: asset) { assets.append(model) }
        }
        try Task.checkCancellation()
        return assets
    }

    nonisolated static func assets(identifiers: Set<String>) throws -> [PhotoAsset] {
        guard !identifiers.isEmpty else { return [] }
        var assets: [PhotoAsset] = []
        assets.reserveCapacity(identifiers.count)
        for batch in identifierBatches(identifiers) {
            try Task.checkCancellation()
            let result = PHAsset.fetchAssets(
                withLocalIdentifiers: batch,
                options: PhotoKitFetchOptions.includingHiddenAssets()
            )
            result.enumerateObjects { asset, index, stop in
                if index.isMultiple(of: 128), Task.isCancelled {
                    stop.pointee = true
                    return
                }
                if let model = PhotoKitAssetMapper.model(from: asset) { assets.append(model) }
            }
        }
        try Task.checkCancellation()
        return assets
    }

    nonisolated static func accessibleAssetIdentifiers() throws -> Set<String> {
        let result = PHAsset.fetchAssets(with: PhotoKitFetchOptions.includingHiddenAssets())
        var identifiers: Set<String> = []
        identifiers.reserveCapacity(result.count)
        result.enumerateObjects { asset, index, stop in
            if index.isMultiple(of: 256), Task.isCancelled {
                stop.pointee = true
                return
            }
            identifiers.insert(asset.localIdentifier)
        }
        try Task.checkCancellation()
        return identifiers
    }

    nonisolated static func scopeFingerprint(for identifiers: Set<String>) throws -> String {
        var hasher = SHA256()
        let separator = Data([0])
        for (index, identifier) in identifiers.sorted().enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            hasher.update(data: Data(identifier.utf8))
            hasher.update(data: separator)
        }
        return hasher.finalize().hexString
    }

    nonisolated static func allAlbums() throws -> [PhotoAlbum] {
        try mapAlbums(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))
    }

    nonisolated static func albums(identifiers: Set<String>) throws -> [PhotoAlbum] {
        guard !identifiers.isEmpty else { return [] }
        var albums: [PhotoAlbum] = []
        for batch in identifierBatches(identifiers) {
            try Task.checkCancellation()
            albums.append(
                contentsOf: try mapAlbums(
                    PHAssetCollection.fetchAssetCollections(
                        withLocalIdentifiers: batch,
                        options: nil
                    )
                )
            )
        }
        return albums.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    nonisolated private static func identifierBatches(
        _ identifiers: Set<String>,
        maximumCount: Int = 500
    ) -> [[String]] {
        var batches: [[String]] = []
        batches.reserveCapacity((identifiers.count + maximumCount - 1) / maximumCount)
        var batch: [String] = []
        batch.reserveCapacity(maximumCount)
        for identifier in identifiers {
            batch.append(identifier)
            if batch.count == maximumCount {
                batches.append(batch)
                batch = []
                batch.reserveCapacity(maximumCount)
            }
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    nonisolated private static func mapAlbums(
        _ result: PHFetchResult<PHAssetCollection>
    ) throws -> [PhotoAlbum] {
        var albums: [PhotoAlbum] = []
        albums.reserveCapacity(result.count)
        result.enumerateObjects { collection, collectionIndex, collectionStop in
            if collectionIndex.isMultiple(of: 32), Task.isCancelled {
                collectionStop.pointee = true
                return
            }
            guard let title = collection.localizedTitle, !title.isEmpty else { return }
            let assetResult = PHAsset.fetchAssets(
                in: collection,
                options: PhotoKitFetchOptions.includingHiddenAssets()
            )
            var identifiers: [String] = []
            identifiers.reserveCapacity(assetResult.count)
            assetResult.enumerateObjects { asset, assetIndex, assetStop in
                if assetIndex.isMultiple(of: 256), Task.isCancelled {
                    assetStop.pointee = true
                    return
                }
                identifiers.append(asset.localIdentifier)
            }
            albums.append(
                PhotoAlbum(
                    id: collection.localIdentifier,
                    title: title,
                    parentID: nil,
                    assetIDs: identifiers
                )
            )
        }
        try Task.checkCancellation()
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
