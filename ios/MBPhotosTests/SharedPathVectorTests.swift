@testable import MBPhotos
import XCTest

final class SharedPathVectorTests: XCTestCase {
    func testCanonicalWindowsPathVectors() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "protocol/test-vectors/windows-paths.json"))
        let vectors = try JSONDecoder().decode(PathVectors.self, from: data)

        for vector in vectors.sanitizeFilename {
            XCTAssertEqual(
                WindowsPathSanitizer.component(vector.input),
                vector.expected,
                "sanitizeFilename: \(vector.id)"
            )
        }
        for vector in vectors.validateRelativePath {
            XCTAssertEqual(
                WindowsPathSanitizer.validateRelativePath(vector.resolvedPath),
                vector.valid,
                "validateRelativePath: \(vector.id)"
            )
        }
        for vector in vectors.shortenRelativePath {
            let fileID = try XCTUnwrap(UUID(uuidString: vector.fileId))
            if vector.error != nil {
                XCTAssertThrowsError(
                    try WindowsPathSanitizer.shortenedRelativePath(vector.resolvedPath, fileID: fileID),
                    "shortenRelativePath: \(vector.id)"
                )
            } else {
                XCTAssertEqual(
                    try WindowsPathSanitizer.shortenedRelativePath(vector.resolvedPath, fileID: fileID),
                    vector.resolvedExpectedPath,
                    "shortenRelativePath: \(vector.id)"
                )
            }
        }
        for vector in vectors.resolveCaseInsensitiveCollision {
            let fileID = try XCTUnwrap(UUID(uuidString: vector.fileId))
            let value = vector.proposedPath as NSString
            let directory = value.deletingLastPathComponent
            let filename = value.lastPathComponent
            var occupied = Set(vector.existingPaths.map { $0.lowercased() })
            if vector.error != nil {
                XCTAssertThrowsError(
                    try WindowsPathSanitizer.uniqueRelativePath(
                        directory: directory,
                        filename: filename,
                        fileID: fileID,
                        occupiedLowercasePaths: &occupied
                    ),
                    "resolveCaseInsensitiveCollision: \(vector.id)"
                )
            } else {
                XCTAssertEqual(
                    try WindowsPathSanitizer.uniqueRelativePath(
                        directory: directory,
                        filename: filename,
                        fileID: fileID,
                        occupiedLowercasePaths: &occupied
                    ),
                    vector.expectedPath,
                    "resolveCaseInsensitiveCollision: \(vector.id)"
                )
            }
        }
    }
}

private struct PathVectors: Decodable {
    let sanitizeFilename: [SanitizeVector]
    let validateRelativePath: [ValidateVector]
    let shortenRelativePath: [ShortenVector]
    let resolveCaseInsensitiveCollision: [CollisionVector]
}

private struct SanitizeVector: Decodable {
    let id: String
    let input: String
    let expected: String
}

private struct ValidateVector: Decodable {
    let id: String
    let path: String?
    let pathExpression: [ExpressionPart]?
    let valid: Bool

    var resolvedPath: String { path ?? pathExpression?.resolved ?? "" }
}

private struct ShortenVector: Decodable {
    let id: String
    let fileId: String
    let path: String?
    let pathExpression: [ExpressionPart]?
    let expectedPath: String?
    let expectedPathExpression: [ExpressionPart]?
    let error: String?

    var resolvedPath: String { path ?? pathExpression?.resolved ?? "" }
    var resolvedExpectedPath: String? { expectedPath ?? expectedPathExpression?.resolved }
}

private struct CollisionVector: Decodable {
    let id: String
    let fileId: String
    let proposedPath: String
    let existingPaths: [String]
    let expectedPath: String?
    let error: String?
}

private enum ExpressionPart: Decodable {
    case literal(String)
    case repeated(String, Int)

    private enum CodingKeys: String, CodingKey { case `repeat`, count }

    init(from decoder: Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            self = .literal(string)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .repeated(
            try container.decode(String.self, forKey: .repeat),
            try container.decode(Int.self, forKey: .count)
        )
    }

    var value: String {
        switch self {
        case let .literal(value): value
        case let .repeated(value, count): String(repeating: value, count: count)
        }
    }
}

private extension Array where Element == ExpressionPart {
    var resolved: String { map(\.value).joined() }
}

