import Combine
import Foundation
import MetricKit
import UIKit

enum CrashLogLevel: String, Sendable {
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case crash = "CRASH"
}

struct CrashLogSnapshot: Sendable {
    let text: String
    let storedByteCount: Int
    let persistenceError: String?
}

/// A bounded, append-only log file. File access lives off the main actor so
/// diagnostics never make navigation or photo browsing wait for disk I/O.
actor DiagnosticLogFile {
    let fileURL: URL
    let maximumByteCount: Int

    init(fileURL: URL, maximumByteCount: Int = 1_048_576) {
        self.fileURL = fileURL
        self.maximumByteCount = maximumByteCount
    }

    func append(_ entry: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let entryData = Data(entry.utf8)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try entryData.write(to: fileURL, options: .atomic)
            try applyFileProtection()
            return
        }

        let existingSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if existingSize + entryData.count > maximumByteCount {
            try compact(existingData: Data(contentsOf: fileURL), incomingData: entryData)
            try applyFileProtection()
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: entryData)
    }

    func contents() -> CrashLogSnapshot {
        do {
            let data = try Data(contentsOf: fileURL)
            return CrashLogSnapshot(
                text: String(decoding: data, as: UTF8.self),
                storedByteCount: data.count,
                persistenceError: nil
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return CrashLogSnapshot(text: "", storedByteCount: 0, persistenceError: nil)
        } catch {
            return CrashLogSnapshot(
                text: "",
                storedByteCount: 0,
                persistenceError: error.localizedDescription
            )
        }
    }

    func clear() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func compact(existingData: Data, incomingData: Data) throws {
        let marker = Data("\n[older diagnostics removed to keep this log bounded]\n".utf8)
        let availableForExisting = max(
            maximumByteCount - marker.count - min(incomingData.count, maximumByteCount),
            0
        )
        var retained = Data(existingData.suffix(availableForExisting))
        if let firstNewline = retained.firstIndex(of: UInt8(ascii: "\n")) {
            retained = Data(retained[retained.index(after: firstNewline)...])
        }

        var replacement = marker
        replacement.append(retained)
        replacement.append(incomingData.suffix(max(maximumByteCount - replacement.count, 0)))
        try replacement.write(to: fileURL, options: .atomic)
    }

    private func applyFileProtection() throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }
}

private struct DeliveredCrashReport: Sendable {
    let signature: String
    let timestamp: Date
    let json: String
}

/// Owns the user-visible diagnostic log and subscribes to Apple's crash
/// diagnostics. MetricKit reports may arrive on a later app launch, so reports
/// are persisted and de-duplicated before being displayed.
@MainActor
final class CrashLogStore: NSObject, ObservableObject {
    static let shared = CrashLogStore()

    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var lastUpdatedAt: Date?

    private static let processedSignaturesKey = "diagnostics.processed-metrickit-crashes.v1"
    private static let maximumProcessedSignatures = 64

    private let file: DiagnosticLogFile
    private var writeTask: Task<Void, Never>?
    private var processedSignatures: [String]

    override init() {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        file = DiagnosticLogFile(
            fileURL: baseDirectory
                .appendingPathComponent("Diagnostics", isDirectory: true)
                .appendingPathComponent("mb-photos-diagnostics.log")
        )
        processedSignatures = UserDefaults.standard.stringArray(
            forKey: Self.processedSignaturesKey
        ) ?? []
        super.init()

        MXMetricManager.shared.add(self)
        record(
            .info,
            category: "Session",
            message: "MB Photos launched",
            metadata: Self.currentContext()
        )
        ingest(Self.crashReports(from: MXMetricManager.shared.pastDiagnosticPayloads))
    }

    func record(
        _ level: CrashLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        enqueue(Self.renderedEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            metadata: metadata
        ))
    }

    func record(error: any Error, category: String, message: String? = nil) {
        let nsError = error as NSError
        record(
            .error,
            category: category,
            message: message ?? nsError.localizedDescription,
            metadata: [
                "errorDomain": nsError.domain,
                "errorCode": String(nsError.code)
            ]
        )
    }

    func snapshot() async -> CrashLogSnapshot {
        await writeTask?.value
        let stored = await file.contents()
        let header = Self.exportHeader(storedByteCount: stored.storedByteCount)
        return CrashLogSnapshot(
            text: header + (stored.text.isEmpty ? "No diagnostic events recorded.\n" : stored.text),
            storedByteCount: stored.storedByteCount,
            persistenceError: stored.persistenceError
        )
    }

    func clear() {
        let previous = writeTask
        writeTask = Task { @MainActor [weak self, file, previous = consume previous] in
            await previous?.value
            do {
                try await file.clear()
            } catch {
                guard let self else { return }
                self.enqueue(Self.renderedEntry(
                    timestamp: Date(),
                    level: .error,
                    category: "Diagnostics",
                    message: "The diagnostic log could not be cleared",
                    metadata: ["reason": error.localizedDescription]
                ))
                return
            }
            guard let self else { return }
            self.revision &+= 1
            self.lastUpdatedAt = Date()
            self.record(.info, category: "Diagnostics", message: "Diagnostic log cleared")
        }
    }

    private func ingest(_ reports: [DeliveredCrashReport]) {
        guard !reports.isEmpty else { return }
        var known = Set(processedSignatures)
        var changed = false

        for report in reports where !known.contains(report.signature) {
            known.insert(report.signature)
            processedSignatures.append(report.signature)
            changed = true
            enqueue(Self.renderedCrashReport(report))
        }

        if changed {
            processedSignatures = Array(processedSignatures.suffix(Self.maximumProcessedSignatures))
            UserDefaults.standard.set(processedSignatures, forKey: Self.processedSignaturesKey)
        }
    }

    private func enqueue(_ entry: String) {
        let previous = writeTask
        writeTask = Task { @MainActor [weak self, file, previous = consume previous] in
            await previous?.value
            try? await file.append(entry)
            guard let self else { return }
            self.revision &+= 1
            self.lastUpdatedAt = Date()
        }
    }

    private static func renderedEntry(
        timestamp: Date,
        level: CrashLogLevel,
        category: String,
        message: String,
        metadata: [String: String]
    ) -> String {
        let normalizedMessage = message
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
        let details = metadata
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { " \($0.key)=\(singleLine($0.value))" }
            .joined()
        return "[\(timestamp.ISO8601Format())] [\(level.rawValue)] [\(singleLine(category))] \(normalizedMessage)\(details)\n"
    }

    private static func renderedCrashReport(_ report: DeliveredCrashReport) -> String {
        """

        [\(report.timestamp.ISO8601Format())] [CRASH] [MetricKit] iOS delivered a crash report from an earlier session
        --- BEGIN APPLE CRASH DIAGNOSTIC ---
        \(report.json)
        --- END APPLE CRASH DIAGNOSTIC ---

        """
    }

    private static func exportHeader(storedByteCount: Int) -> String {
        let context = currentContext()
        let detailLines = context
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        return """
        MB Photos Diagnostics
        Generated: \(Date().ISO8601Format())
        Stored log size: \(ByteCountFormatter.string(fromByteCount: Int64(storedByteCount), countStyle: .file))
        \(detailLines)
        ------------------------------------------------------------------------

        """
    }

    private static func currentContext() -> [String: String] {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let process = ProcessInfo.processInfo
        return [
            "app": "MB Photos \(version) (\(build))",
            "device": UIDevice.current.model,
            "locale": Locale.current.identifier,
            "lowPowerMode": process.isLowPowerModeEnabled ? "true" : "false",
            "memory": ByteCountFormatter.string(fromByteCount: Int64(process.physicalMemory), countStyle: .memory),
            "os": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "thermalState": String(process.thermalState.rawValue),
            "timeZone": TimeZone.current.identifier
        ]
    }

    private nonisolated static func crashReports(
        from payloads: [MXDiagnosticPayload]
    ) -> [DeliveredCrashReport] {
        payloads.flatMap { payload in
            (payload.crashDiagnostics ?? []).map { crash in
                let data = crash.jsonRepresentation()
                let json: String
                if let object = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(
                       withJSONObject: object,
                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                   ) {
                    json = String(decoding: pretty, as: UTF8.self)
                } else {
                    json = String(decoding: data, as: UTF8.self)
                }
                return DeliveredCrashReport(
                    signature: stableSignature(for: data),
                    timestamp: payload.timeStampEnd,
                    json: json
                )
            }
        }
    }

    private nonisolated static func stableSignature(for data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

extension CrashLogStore: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = Self.crashReports(from: payloads)
        Task { @MainActor [weak self, reports] in
            self?.ingest(reports)
        }
    }
}
