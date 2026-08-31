import Foundation

typealias LibraryIndexSnapshot = PhotoLibrarySnapshot

enum LibrarySnapshotSource: Equatable, Sendable {
    case fresh
    case cached
    case fallback
}

struct LibraryIndexResult: Sendable {
    let generation: UInt64
    let requestedRevision: UInt64
    let snapshot: PhotoLibrarySnapshot
    let source: LibrarySnapshotSource
    let refreshErrorDescription: String?
}

struct PhotoLibraryIndexChanges: Sendable {
    let upsertedAssets: [PhotoAsset]
    let deletedAssetIDs: Set<String>
    let upsertedAlbums: [PhotoAlbum]
    let deletedAlbumIDs: Set<String>
    /// Non-nil for limited access. Objects outside the currently visible scope
    /// are removed in the same transaction as the journal delta.
    let accessibleAssetIDs: Set<String>?
    let changeTokenData: Data?
    let authorizationScopeFingerprint: String?

    init(
        upsertedAssets: [PhotoAsset],
        deletedAssetIDs: Set<String>,
        upsertedAlbums: [PhotoAlbum],
        deletedAlbumIDs: Set<String>,
        accessibleAssetIDs: Set<String>?,
        changeTokenData: Data?,
        authorizationScopeFingerprint: String? = nil
    ) {
        self.upsertedAssets = upsertedAssets
        self.deletedAssetIDs = deletedAssetIDs
        self.upsertedAlbums = upsertedAlbums
        self.deletedAlbumIDs = deletedAlbumIDs
        self.accessibleAssetIDs = accessibleAssetIDs
        self.changeTokenData = changeTokenData
        self.authorizationScopeFingerprint = authorizationScopeFingerprint
    }

    var hasObjectChanges: Bool {
        !upsertedAssets.isEmpty || !deletedAssetIDs.isEmpty
            || !upsertedAlbums.isEmpty || !deletedAlbumIDs.isEmpty
    }

    static func unchanged(tokenData: Data?, accessibleAssetIDs: Set<String>? = nil) -> Self {
        Self(
            upsertedAssets: [],
            deletedAssetIDs: [],
            upsertedAlbums: [],
            deletedAlbumIDs: [],
            accessibleAssetIDs: accessibleAssetIDs,
            changeTokenData: tokenData,
            authorizationScopeFingerprint: nil
        )
    }
}

enum PhotoLibraryChangeLoadResult: Sendable {
    case changes(PhotoLibraryIndexChanges)
    case rebuild(PhotoLibrarySnapshot)
}

protocol PhotoLibraryChangeLoading: Sendable {
    func loadChanges(
        since changeTokenData: Data?,
        revision: UInt64,
        authorization: PhotoAuthorizationState,
        knownAssetIDs: Set<String>
    ) async throws -> PhotoLibraryChangeLoadResult
    func currentAuthorizationScopeFingerprint(
        authorization: PhotoAuthorizationState
    ) async throws -> String?
}

protocol PhotoLibraryIndexPersisting: Sendable {
    func cachedPhotoLibrarySnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState,
        scopeFingerprint: String?
    ) async throws -> PhotoLibrarySnapshot?
    func replaceCachedPhotoLibrarySnapshot(
        _ snapshot: PhotoLibrarySnapshot,
        authorization: PhotoAuthorizationState
    ) async throws
    func applyPhotoLibraryChanges(
        _ changes: PhotoLibraryIndexChanges,
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot
    func advanceCachedPhotoLibraryChangeToken(_ changeTokenData: Data?) async throws
}

protocol LibrarySnapshotLoading: Sendable {
    func cachedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot?
    func refreshedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot
}

struct PersistentLibrarySnapshotLoader: LibrarySnapshotLoading {
    let store: any PhotoLibraryIndexPersisting
    let changeLoader: any PhotoLibraryChangeLoading

    func cachedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot? {
        let scopeFingerprint = try await changeLoader.currentAuthorizationScopeFingerprint(
            authorization: authorization
        )
        return try await store.cachedPhotoLibrarySnapshot(
            revision: revision,
            authorization: authorization,
            scopeFingerprint: scopeFingerprint
        )
    }

    func refreshedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot {
        let scopeFingerprint = try await changeLoader.currentAuthorizationScopeFingerprint(
            authorization: authorization
        )
        var current = try await store.cachedPhotoLibrarySnapshot(
            revision: revision,
            authorization: authorization,
            scopeFingerprint: scopeFingerprint
        )
        // A rebuild snapshots a token *before* enumeration. Always replay from
        // that token before publishing so inserts/deletes that occur during the
        // enumeration window cannot be lost. Repeat deltas until one journal
        // read has no object changes; the bound prevents starvation under a
        // continuously mutating library, and the observer schedules the rest.
        for _ in 0..<8 {
            try Task.checkCancellation()
            let update = try await changeLoader.loadChanges(
                since: current?.changeTokenData,
                revision: revision,
                authorization: authorization,
                knownAssetIDs: Set(current?.assets.map(\.id) ?? [])
            )
            switch update {
            case let .rebuild(snapshot):
                try Task.checkCancellation()
                try await store.replaceCachedPhotoLibrarySnapshot(
                    snapshot,
                    authorization: authorization
                )
                current = snapshot
            case let .changes(changes):
                try Task.checkCancellation()
                if let current,
                   !changes.hasObjectChanges,
                   Self.hasSameAuthorizationScope(
                       current: current,
                       changes: changes,
                       authorization: authorization
                   ) {
                    // An empty journal page only advances the durable token.
                    // Reusing the immutable in-memory arrays avoids decoding
                    // and sorting the entire GRDB index a second time.
                    try await store.advanceCachedPhotoLibraryChangeToken(
                        changes.changeTokenData
                    )
                    return PhotoLibrarySnapshot(
                        revision: revision,
                        assets: current.assets,
                        albums: current.albums,
                        changeTokenData: changes.changeTokenData,
                        authorizationScopeFingerprint: current.authorizationScopeFingerprint
                    )
                }
                current = try await store.applyPhotoLibraryChanges(
                    changes,
                    revision: revision,
                    authorization: authorization
                )
                if !changes.hasObjectChanges, let current { return current }
            }
        }
        guard let current else {
            throw LedgerError.open("PhotoKit did not produce a library snapshot.")
        }
        return current
    }

    private static func hasSameAuthorizationScope(
        current: PhotoLibrarySnapshot,
        changes: PhotoLibraryIndexChanges,
        authorization: PhotoAuthorizationState
    ) -> Bool {
        guard authorization == .limited else { return true }
        return current.authorizationScopeFingerprint
            == changes.authorizationScopeFingerprint
    }
}

private struct ClosureLibrarySnapshotLoader: LibrarySnapshotLoading {
    let loader: @Sendable (UInt64) async throws -> PhotoLibrarySnapshot

    func cachedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot? { nil }

    func refreshedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot {
        try await loader(revision)
    }
}

/// Serializes PhotoKit enumeration/change replay, collapses revision bursts into
/// the newest generation, and retains the last valid snapshot as a fallback.
actor LibraryIndexWorker {
    typealias Loader = @Sendable (_ revision: UInt64) async throws -> PhotoLibrarySnapshot

    private struct Request: Sendable {
        let generation: UInt64
        let revision: UInt64
        let authorization: PhotoAuthorizationState
        let force: Bool
    }

    private struct Waiter {
        let id: UUID
        let request: Request
        let continuation: CheckedContinuation<LibraryIndexResult, Error>
    }

    private let loader: any LibrarySnapshotLoading
    private var cachedSnapshot: PhotoLibrarySnapshot?
    private var cachedAuthorization: PhotoAuthorizationState?
    private var didLoadPersistentCache = false
    private var nextGeneration: UInt64 = 0
    private var newestRequest: Request?
    private var waiters: [Waiter] = []
    private var refreshTask: Task<Void, Never>?

    init(loader: @escaping Loader) {
        self.loader = ClosureLibrarySnapshotLoader(loader: loader)
    }

    init(loader: any LibrarySnapshotLoading) {
        self.loader = loader
    }

    /// Loads the durable index without asking PhotoKit to enumerate or replay.
    func loadCachedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState = .authorized
    ) async throws -> PhotoLibrarySnapshot? {
        if let cachedSnapshot, cachedAuthorization == authorization {
            if authorization != .limited {
                return Self.retag(cachedSnapshot, revision: revision)
            }
        }
        if cachedAuthorization != nil, cachedAuthorization != authorization {
            cachedSnapshot = nil
            cachedAuthorization = nil
            didLoadPersistentCache = false
        }
        guard !didLoadPersistentCache || authorization == .limited else { return nil }
        didLoadPersistentCache = true
        do {
            let stored = try await loader.cachedSnapshot(
                revision: revision,
                authorization: authorization
            )
            cachedSnapshot = stored
            cachedAuthorization = stored == nil ? nil : authorization
            return stored
        } catch {
            // A cancelled/transient GRDB read must not poison this worker for
            // the rest of the process. A later request may retry the cache.
            didLoadPersistentCache = false
            throw error
        }
    }

    func snapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState = .authorized,
        force: Bool = false
    ) async throws -> LibraryIndexResult {
        nextGeneration &+= 1
        let request = Request(
            generation: nextGeneration,
            revision: revision,
            authorization: authorization,
            force: force
        )

        // The durable cache API deliberately retags immutable storage with the
        // caller's presentation revision. For limited authorization we still
        // have to re-read it on every request to validate the current scope
        // fingerprint, but that retag must not make an older index appear
        // reconciled with a newer PhotoKit observer revision.
        let limitedRevisionRequiresReconciliation = authorization == .limited
            && cachedSnapshot?.revision != revision

        if cachedAuthorization != nil, cachedAuthorization != authorization {
            cachedSnapshot = nil
            cachedAuthorization = nil
            didLoadPersistentCache = false
        }
        if authorization == .limited {
            // Limited access can gain/revoke identifiers without changing the
            // authorization enum. Revalidate its scope fingerprint before any
            // in-memory return or fallback.
            _ = try await loadCachedSnapshot(revision: revision, authorization: authorization)
        } else if cachedSnapshot == nil, !didLoadPersistentCache {
            _ = try await loadCachedSnapshot(revision: revision, authorization: authorization)
        }
        if !force, !limitedRevisionRequiresReconciliation, let cachedSnapshot,
           cachedAuthorization == authorization,
           cachedSnapshot.revision == revision {
            return LibraryIndexResult(
                generation: request.generation,
                requestedRevision: revision,
                snapshot: cachedSnapshot,
                source: .cached,
                refreshErrorDescription: nil
            )
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                newestRequest = request
                waiters.append(
                    Waiter(id: waiterID, request: request, continuation: continuation)
                )
                guard refreshTask == nil else { return }
                refreshTask = Task { [weak self] in
                    await self?.runRefreshLoop()
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        if waiters.isEmpty {
            newestRequest = nil
            refreshTask?.cancel()
        } else {
            newestRequest = waiters.max(by: {
                $0.request.generation < $1.request.generation
            })?.request
        }
    }

    func clearCache() {
        cachedSnapshot = nil
        cachedAuthorization = nil
        didLoadPersistentCache = false
    }

    func cachedRevision() -> UInt64? { cachedSnapshot?.revision }

    private func runRefreshLoop() async {
        while let target = newestRequest {
            do {
                let snapshot = try await loader.refreshedSnapshot(
                    revision: target.revision,
                    authorization: target.authorization
                )
                try Task.checkCancellation()
                guard let newestRequest,
                      newestRequest.generation == target.generation,
                      newestRequest.authorization == target.authorization else { continue }
                cachedSnapshot = snapshot
                cachedAuthorization = target.authorization
                finishWaiters(with: snapshot, source: .fresh, errorDescription: nil)
                break
            } catch is CancellationError {
                // The last waiter can cancel this refresh, then a replacement
                // waiter can arrive while the cancelled loader is unwinding.
                // Only complete requests that belonged to the cancelled
                // generation; a newer generation must be restarted below.
                failWaiters(
                    throughGeneration: target.generation,
                    with: CancellationError()
                )
                break
            } catch {
                if let newestRequest, newestRequest.generation != target.generation { continue }
                if let cachedSnapshot, cachedAuthorization == target.authorization {
                    finishWaiters(
                        with: cachedSnapshot,
                        source: .fallback,
                        errorDescription: error.localizedDescription
                    )
                } else {
                    failWaiters(with: error)
                }
                break
            }
        }
        refreshTask = nil
        newestRequest = waiters.max(by: {
            $0.request.generation < $1.request.generation
        })?.request
        if newestRequest != nil {
            refreshTask = Task { [weak self] in await self?.runRefreshLoop() }
        }
    }

    private func finishWaiters(
        with snapshot: PhotoLibrarySnapshot,
        source: LibrarySnapshotSource,
        errorDescription: String?
    ) {
        let current = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in current {
            waiter.continuation.resume(
                returning: LibraryIndexResult(
                    generation: waiter.request.generation,
                    requestedRevision: waiter.request.revision,
                    snapshot: Self.retag(snapshot, revision: waiter.request.revision),
                    source: source,
                    refreshErrorDescription: errorDescription
                )
            )
        }
    }

    private func failWaiters(with error: Error) {
        let current = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in current { waiter.continuation.resume(throwing: error) }
    }

    private func failWaiters(throughGeneration generation: UInt64, with error: Error) {
        let failed = waiters.filter { $0.request.generation <= generation }
        waiters.removeAll { $0.request.generation <= generation }
        for waiter in failed { waiter.continuation.resume(throwing: error) }
    }

    /// An actor-isolated barrier used by concurrency tests to deterministically
    /// release a cancelled loader only after its replacement waiter is queued.
    func pendingWaiterCount() -> Int { waiters.count }

    private static func retag(_ snapshot: PhotoLibrarySnapshot, revision: UInt64) -> PhotoLibrarySnapshot {
        PhotoLibrarySnapshot(
            revision: revision,
            assets: snapshot.assets,
            albums: snapshot.albums,
            changeTokenData: snapshot.changeTokenData,
            authorizationScopeFingerprint: snapshot.authorizationScopeFingerprint
        )
    }
}
