import CryptoKit
import Foundation
import Security

enum PairingPayloadError: LocalizedError, Equatable {
    case malformed
    case unsupportedVersion
    case nonPrivateAddress
    case invalidPort
    case invalidToken
    case invalidCertificateFingerprint

    var errorDescription: String? {
        switch self {
        case .malformed: "This is not an MB Photos receiver QR code."
        case .unsupportedVersion: "The Windows receiver uses an unsupported protocol version."
        case .nonPrivateAddress: "The receiver must use a private local-network IPv4 address."
        case .invalidPort: "The receiver advertised an invalid network port."
        case .invalidToken: "The one-time pairing code is invalid. Start the receiver again."
        case .invalidCertificateFingerprint: "The receiver certificate fingerprint is invalid."
        }
    }
}

struct PairingPayload: Equatable, Sendable {
    let protocolVersion: Int
    let host: String
    let port: Int
    let token: String
    let certificateSHA256: String

    var baseURL: URL { URL(string: "https://\(host):\(port)")! }

    init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "mbphotos",
              components.host?.lowercased() == "pair",
              components.path.isEmpty,
              let items = components.queryItems
        else { throw PairingPayloadError.malformed }
        let grouped = Dictionary(grouping: items, by: \.name)
        guard ["v", "host", "port", "token", "cert"].allSatisfy({ grouped[$0]?.count == 1 }),
              grouped.keys.allSatisfy({ ["v", "host", "port", "token", "cert"].contains($0) }),
              let versionString = grouped["v"]?.first?.value,
              let version = Int(versionString),
              let host = grouped["host"]?.first?.value,
              let portString = grouped["port"]?.first?.value,
              let port = Int(portString),
              let token = grouped["token"]?.first?.value,
              let fingerprint = grouped["cert"]?.first?.value
        else { throw PairingPayloadError.malformed }
        guard version == ExportConstants.protocolVersion else { throw PairingPayloadError.unsupportedVersion }
        guard Self.isPrivateIPv4(host) else { throw PairingPayloadError.nonPrivateAddress }
        guard (1...65_535).contains(port) else { throw PairingPayloadError.invalidPort }
        guard token.count == 43, Self.decodeBase64URL(token)?.count == 32 else {
            throw PairingPayloadError.invalidToken
        }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard fingerprint.count == 64,
              fingerprint.unicodeScalars.allSatisfy(hex.contains)
        else { throw PairingPayloadError.invalidCertificateFingerprint }
        self.protocolVersion = version
        self.host = host
        self.port = port
        self.token = token
        self.certificateSHA256 = fingerprint
    }

    init(string: String) throws {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PairingPayloadError.malformed
        }
        try self.init(url: url)
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let a = Int(pieces[0]), let b = Int(pieces[1]),
              let c = Int(pieces[2]), let d = Int(pieces[3]),
              [a, b, c, d].allSatisfy({ (0...255).contains($0) })
        else { return false }
        return a == 10
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        return Data(base64Encoded: base64)
    }
}

struct ClientIdentity: Codable, Sendable {
    let name: String
    let version: String
    let instanceId: UUID
}

struct PairRequest: Codable, Sendable {
    let protocolVersion: Int
    let token: String
    let client: ClientIdentity
}

struct ReceiverCapabilities: Codable, Equatable, Sendable {
    let chunkSizeBytes: Int
    let maxRelativePathUtf16Units: Int
    let pathPolicyVersion: Int
    let hashAlgorithm: String
    let sequentialChunksRequired: Bool
    let supportedProfiles: [ExportProfileKind]
}

struct PairResponse: Codable, Sendable {
    let protocolVersion: Int
    let sessionToken: String
    let receiverRunId: UUID
    let destination: Destination
    let capabilities: ReceiverCapabilities
}

struct ChunkRange: Codable, Equatable, Sendable {
    let firstIndex: Int
    let lastIndexInclusive: Int
}

enum FileDecisionAction: String, Codable, Sendable {
    case upload
    case skip
    case resume
    case conflict
}

enum FileDecisionReason: String, Codable, Sendable {
    case new
    case verified
    case partial
    case changed
    case pathAdjusted
    case unresolvableConflict
}

struct FileDecision: Codable, Equatable, Sendable {
    let fileId: UUID
    let action: FileDecisionAction
    let acceptedRelativePath: String?
    let nextChunkIndex: Int
    let acknowledgedChunks: [ChunkRange]
    let reason: FileDecisionReason

    private enum CodingKeys: String, CodingKey {
        case fileId
        case action
        case acceptedRelativePath
        case nextChunkIndex
        case acknowledgedChunks
        case reason
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileId, forKey: .fileId)
        try container.encode(action, forKey: .action)
        if let acceptedRelativePath {
            try container.encode(acceptedRelativePath, forKey: .acceptedRelativePath)
        } else {
            try container.encodeNil(forKey: .acceptedRelativePath)
        }
        try container.encode(nextChunkIndex, forKey: .nextChunkIndex)
        try container.encode(acknowledgedChunks, forKey: .acknowledgedChunks)
        try container.encode(reason, forKey: .reason)
    }
}

struct JobPlan: Codable, Sendable {
    let protocolVersion: Int
    let jobId: UUID
    let destination: Destination
    let state: JobState
    let decisions: [FileDecision]
    let createdAt: Date
    let updatedAt: Date
}

struct FileCommitReceipt: Codable, Equatable, Sendable {
    let fileId: UUID
    let state: String
    let relativePath: String
    let byteCount: Int64
    let sha256: String
    let committedAt: Date
}

struct JobStatusResponse: Codable, Sendable {
    let protocolVersion: Int
    let jobId: UUID
    let destination: Destination
    let state: JobState
    let decisions: [FileDecision]
    let committedFiles: [FileCommitReceipt]
    let createdAt: Date
    let updatedAt: Date
    let report: CompletionReport?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case jobId
        case destination
        case state
        case decisions
        case committedFiles
        case createdAt
        case updatedAt
        case report
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(jobId, forKey: .jobId)
        try container.encode(destination, forKey: .destination)
        try container.encode(state, forKey: .state)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(committedFiles, forKey: .committedFiles)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        if let report {
            try container.encode(report, forKey: .report)
        } else {
            try container.encodeNil(forKey: .report)
        }
    }
}

struct ChunkReceipt: Codable, Equatable, Sendable {
    let jobId: UUID
    let fileId: UUID
    let chunkIndex: Int
    let startOffset: Int64
    let endOffsetExclusive: Int64
    let byteCount: Int
    let chunkSha256: String
    let nextChunkIndex: Int
    let receivedAt: Date
}

struct CommitFileRequest: Codable, Sendable {
    let byteCount: Int64
    let sha256: String
}

struct CompleteJobRequest: Codable, Equatable, Sendable {
    let completedAt: Date
    let failures: [CompletionFailure]

    init(completedAt: Date, failures: [CompletionFailure] = []) {
        self.completedAt = completedAt
        self.failures = failures
    }

    private enum CodingKeys: String, CodingKey {
        case completedAt
        case failures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        failures = try container.decodeIfPresent([CompletionFailure].self, forKey: .failures) ?? []
    }
}

enum AbandonReason: String, Codable, Sendable {
    case userDiscarded
    case sourceUnavailable
    case clientReset
}

struct AbandonJobRequest: Codable, Sendable {
    let reason: AbandonReason?
}

struct AbandonmentReceipt: Codable, Sendable {
    let jobId: UUID
    let state: String
    let removedPartialFiles: Int
    let abandonedAt: Date
}

struct APIErrorResponse: Codable, Sendable {
    let code: String
    let message: String
    let retryable: Bool
    let requestId: UUID?

    var knownCode: APIErrorCode? { APIErrorCode(rawValue: code) }
}

enum TransferError: LocalizedError, Sendable {
    case certificateMismatch
    case destinationMismatch(expected: UUID, actual: UUID)
    case receiverRejected(APIErrorResponse, statusCode: Int)
    case invalidResponse
    case incompatibleReceiver(String)
    case decisionConflict(String)
    case receiptMismatch
    case network(String)

    var errorDescription: String? {
        switch self {
        case .certificateMismatch: "The receiver identity did not match the scanned QR code. Nothing was sent."
        case let .destinationMismatch(_, actual):
            "This frozen job belongs to a different Windows backup. Open that backup folder to resume it (connected destination: \(actual.uuidString.lowercased()))."
        case let .receiverRejected(error, _): error.message
        case .invalidResponse: "The Windows receiver returned an unreadable response."
        case let .incompatibleReceiver(reason): "This receiver is incompatible: \(reason)"
        case let .decisionConflict(path): "The receiver could not safely create \(path)."
        case .receiptMismatch: "The receiver acknowledged different data than was sent."
        case let .network(message): "The transfer connection was lost: \(message)"
        }
    }

    var retryable: Bool {
        switch self {
        case let .receiverRejected(error, _): error.retryable
        case .network: true
        default: false
        }
    }
}

final class PinnedTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let expectedHost: String
    private let expectedFingerprint: String
    private let lock = NSLock()
    private var rejectedPin = false

    init(expectedHost: String, expectedFingerprint: String) {
        self.expectedHost = expectedHost
        self.expectedFingerprint = expectedFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard challenge.protectionSpace.host == expectedHost,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first
        else {
            markPinRejected()
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).hexString
        guard fingerprint == expectedFingerprint else {
            markPinRejected()
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func consumePinRejection() -> Bool {
        lock.lock()
        let result = rejectedPin
        rejectedPin = false
        lock.unlock()
        return result
    }

    private func markPinRejected() {
        lock.lock()
        rejectedPin = true
        lock.unlock()
    }
}

actor TransferClient {
    private let payload: PairingPayload
    private let tlsDelegate: PinnedTLSDelegate
    private let session: URLSession
    private let encoder = WireCoders.encoder()
    private let decoder = WireCoders.decoder()
    private var bearerToken: String?

    init(payload: PairingPayload) {
        self.payload = payload
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 1
        let delegate = PinnedTLSDelegate(
            expectedHost: payload.host,
            expectedFingerprint: payload.certificateSHA256
        )
        self.tlsDelegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func pair(instanceID: UUID, appVersion: String) async throws -> PairResponse {
        let body = PairRequest(
            protocolVersion: ExportConstants.protocolVersion,
            token: payload.token,
            client: ClientIdentity(
                name: "MB Photos for iOS",
                version: appVersion,
                instanceId: instanceID
            )
        )
        let response: PairResponse = try await sendJSON(path: "/v1/pair", method: "POST", body: body, authenticated: false)
        guard response.protocolVersion == ExportConstants.protocolVersion else {
            throw TransferError.incompatibleReceiver("protocol version")
        }
        let capabilities = response.capabilities
        guard capabilities.chunkSizeBytes == ExportConstants.chunkSize,
              capabilities.maxRelativePathUtf16Units == ExportConstants.maximumRelativePathLength,
              capabilities.pathPolicyVersion == ExportConstants.pathPolicyVersion,
              capabilities.hashAlgorithm == "sha256",
              capabilities.sequentialChunksRequired
        else { throw TransferError.incompatibleReceiver("transfer or path capabilities") }
        bearerToken = response.sessionToken
        return response
    }

    func createOrReconcileJob(_ job: ExportJob) async throws -> JobPlan {
        let plan: JobPlan = try await sendJSON(path: "/v1/jobs", method: "POST", body: job)
        guard plan.protocolVersion == ExportConstants.protocolVersion, plan.jobId == job.jobId else {
            throw TransferError.invalidResponse
        }
        return plan
    }

    func jobStatus(jobID: UUID) async throws -> JobStatusResponse {
        try await send(path: "/v1/jobs/\(jobID.uuidString.lowercased())", method: "GET", body: nil)
    }

    func uploadFile(
        jobID: UUID,
        fileID: UUID,
        localURL: URL,
        digest: FileDigest,
        startingChunkIndex: Int,
        progress: @escaping @Sendable (_ acknowledgedBytes: Int64) -> Void
    ) async throws -> Int {
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        guard startingChunkIndex >= 0,
              Int64(startingChunkIndex) <= Int64.max / Int64(ExportConstants.chunkSize)
        else { throw TransferError.receiptMismatch }
        var index = startingChunkIndex
        var offset = Int64(index) * Int64(ExportConstants.chunkSize)
        guard offset <= digest.byteCount else { throw TransferError.receiptMismatch }
        try handle.seek(toOffset: UInt64(offset))
        progress(offset)

        while offset < digest.byteCount {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: ExportConstants.chunkSize) ?? Data()
            guard !data.isEmpty else { throw TransferError.invalidResponse }
            let chunkHash = SHA256.hash(data: data).hexString
            var request = try makeRequest(
                path: "/v1/jobs/\(jobID.uuidString.lowercased())/files/\(fileID.uuidString.lowercased())/chunks/\(index)",
                method: "PUT",
                authenticated: true
            )
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(chunkHash, forHTTPHeaderField: "X-Chunk-SHA256")
            request.setValue(
                "bytes \(offset)-\(offset + Int64(data.count) - 1)/\(digest.byteCount)",
                forHTTPHeaderField: "Content-Range"
            )
            let receipt: ChunkReceipt = try await perform(request, body: data)
            guard receipt.jobId == jobID,
                  receipt.fileId == fileID,
                  receipt.chunkIndex == index,
                  receipt.startOffset == offset,
                  receipt.endOffsetExclusive == offset + Int64(data.count),
                  receipt.byteCount == data.count,
                  receipt.chunkSha256 == chunkHash,
                  receipt.nextChunkIndex == index + 1
            else { throw TransferError.receiptMismatch }
            index = receipt.nextChunkIndex
            offset = receipt.endOffsetExclusive
            progress(offset)
        }
        return index
    }

    func commitFile(jobID: UUID, fileID: UUID, digest: FileDigest) async throws -> FileCommitReceipt {
        let body = CommitFileRequest(byteCount: digest.byteCount, sha256: digest.sha256)
        let receipt: FileCommitReceipt = try await sendJSON(
            path: "/v1/jobs/\(jobID.uuidString.lowercased())/files/\(fileID.uuidString.lowercased())/commit",
            method: "POST",
            body: body
        )
        guard receipt.fileId == fileID,
              receipt.state == "committed",
              receipt.byteCount == digest.byteCount,
              receipt.sha256 == digest.sha256
        else { throw TransferError.receiptMismatch }
        return receipt
    }

    func completeJob(
        jobID: UUID,
        failures: [CompletionFailure] = [],
        at date: Date = Date()
    ) async throws -> CompletionReport {
        try await sendJSON(
            path: "/v1/jobs/\(jobID.uuidString.lowercased())/complete",
            method: "POST",
            body: CompleteJobRequest(completedAt: date, failures: failures)
        )
    }

    func abandonJob(jobID: UUID, reason: AbandonReason) async throws -> AbandonmentReceipt {
        try await sendJSON(
            path: "/v1/jobs/\(jobID.uuidString.lowercased())/abandon",
            method: "POST",
            body: AbandonJobRequest(reason: reason)
        )
    }

    private func sendJSON<Request: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Request,
        authenticated: Bool = true
    ) async throws -> Response {
        try await send(path: path, method: method, body: try encoder.encode(body), authenticated: authenticated)
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: Data?,
        authenticated: Bool = true
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: method, authenticated: authenticated)
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return try await perform(request, body: body)
    }

    private func makeRequest(path: String, method: String, authenticated: Bool) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: payload.baseURL)?.absoluteURL else {
            throw TransferError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        if authenticated {
            guard let bearerToken else {
                throw TransferError.incompatibleReceiver("pairing session is missing")
            }
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest, body: Data?) async throws -> Response {
        do {
            var request = request
            request.httpBody = body
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TransferError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                if let apiError = try? decoder.decode(APIErrorResponse.self, from: data) {
                    throw TransferError.receiverRejected(apiError, statusCode: http.statusCode)
                }
                throw TransferError.invalidResponse
            }
            do { return try decoder.decode(Response.self, from: data) }
            catch { throw TransferError.invalidResponse }
        } catch let error as TransferError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if tlsDelegate.consumePinRejection() {
                throw TransferError.certificateMismatch
            }
            throw TransferError.network(error.localizedDescription)
        }
    }
}
