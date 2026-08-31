import Foundation
import XCTest
@testable import MBPhotos

final class CrashLogStoreTests: XCTestCase {
    func testDiagnosticPreviewLeavesSmallLogsUnchanged() {
        let preview = DiagnosticLogPreview.make(from: "first\nsecond\n", maximumCharacterCount: 64)

        XCTAssertEqual(preview.text, "first\nsecond\n")
        XCTAssertFalse(preview.isTruncated)
    }

    func testDiagnosticPreviewKeepsNewestCompleteLines() {
        let preview = DiagnosticLogPreview.make(
            from: "oldest line\nolder line\nnewest line\n",
            maximumCharacterCount: 22
        )

        XCTAssertTrue(preview.isTruncated)
        XCTAssertFalse(preview.text.contains("oldest line"))
        XCTAssertFalse(preview.text.contains("older line"))
        XCTAssertTrue(preview.text.contains("newest line"))
        XCTAssertTrue(preview.text.hasPrefix("[Earlier diagnostics omitted from this preview]\n"))
    }

    func testDiagnosticFileKeepsNewestEntryWhenItCompacts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DiagnosticLogFile(
            fileURL: directory.appendingPathComponent("diagnostics.log"),
            maximumByteCount: 256
        )

        try await file.append("[old] " + String(repeating: "x", count: 220) + "\n")
        try await file.append("[newest] export failed safely\n")

        let snapshot = await file.contents()
        XCTAssertLessThanOrEqual(snapshot.storedByteCount, 256)
        XCTAssertTrue(snapshot.text.contains("older diagnostics removed"))
        XCTAssertTrue(snapshot.text.contains("[newest] export failed safely"))
    }

    func testDiagnosticFileCanBeCleared() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DiagnosticLogFile(
            fileURL: directory.appendingPathComponent("diagnostics.log")
        )

        try await file.append("test entry\n")
        try await file.clear()

        let snapshot = await file.contents()
        XCTAssertEqual(snapshot.storedByteCount, 0)
        XCTAssertEqual(snapshot.text, "")
        XCTAssertNil(snapshot.persistenceError)
    }
}
