@testable import MBPhotos
import XCTest

final class PathAndPairingTests: XCTestCase {
    func testWindowsSanitizationPolicy() {
        XCTAssertEqual(WindowsPathSanitizer.component("CON.txt"), "_CON.txt")
        XCTAssertEqual(WindowsPathSanitizer.component("two<>bad?.jpg "), "two__bad_.jpg")
        XCTAssertEqual(WindowsPathSanitizer.component("..."), "_")
        XCTAssertEqual(WindowsPathSanitizer.component(" Cafe\u{301}.jpg"), " Café.jpg")
    }

    func testCaseInsensitiveCollisionHasStableSuffix() throws {
        var paths: Set<String> = []
        let firstID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let first = try WindowsPathSanitizer.uniqueRelativePath(
            directory: "Photos/2026",
            filename: "IMG.JPG",
            fileID: firstID,
            occupiedLowercasePaths: &paths
        )
        let second = try WindowsPathSanitizer.uniqueRelativePath(
            directory: "Photos/2026",
            filename: "img.jpg",
            fileID: secondID,
            occupiedLowercasePaths: &paths
        )
        XCTAssertEqual(first, "Photos/2026/IMG.JPG")
        XCTAssertEqual(second, "Photos/2026/img~22222222.jpg")
    }

    func testPathUsesAtMost239UTF16Units() throws {
        var paths: Set<String> = []
        let id = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let result = try WindowsPathSanitizer.uniqueRelativePath(
            directory: "Photos/2026/2026-08/2026-08-24",
            filename: String(repeating: "😀", count: 200) + ".jpg",
            fileID: id,
            occupiedLowercasePaths: &paths
        )
        XCTAssertLessThanOrEqual(result.utf16.count, 239)
        XCTAssertTrue(result.hasSuffix("~33333333.jpg"))
    }

    func testPairingPayloadAcceptsPrivateIPv4AndStrictCredentials() throws {
        let token = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq"
        let fingerprint = String(repeating: "a", count: 64)
        let payload = try PairingPayload(
            string: "mbphotos://pair?v=1&host=192.168.1.4&port=49152&token=\(token)&cert=\(fingerprint)"
        )
        XCTAssertEqual(payload.host, "192.168.1.4")
        XCTAssertEqual(payload.port, 49_152)
    }

    func testPairingRejectsPublicOrPlaintextLookingAddress() {
        let token = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq"
        let fingerprint = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try PairingPayload(
            string: "mbphotos://pair?v=1&host=8.8.8.8&port=443&token=\(token)&cert=\(fingerprint)"
        ))
    }

    func testStableIDsMeetUUIDVersionAndVariantContract() {
        let id = StableID.make(namespace: "file", value: "fixture")
        let parts = id.uuidString.lowercased().split(separator: "-")
        XCTAssertEqual(parts[2].first, "5")
        XCTAssertTrue("89ab".contains(parts[3].first!))
    }
}
