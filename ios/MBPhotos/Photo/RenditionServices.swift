@preconcurrency import Photos
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum RenditionError: LocalizedError {
    case assetUnavailable(String)
    case resourceUnavailable(String)
    case imageDecodeFailed
    case imageEncodeFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .assetUnavailable(id): "The photo or video is no longer accessible (\(id))."
        case let .resourceUnavailable(name): "The original resource is no longer available (\(name))."
        case .imageDecodeFailed: "The current photo could not be decoded."
        case .imageEncodeFailed: "The Windows-compatible JPEG could not be encoded."
        case .cancelled: "Preparation was paused."
        }
    }
}

protocol PhotoResourceMaterializing: Sendable {
    func materializeResource(
        assetID: String,
        descriptor: PhotoResourceDescriptor,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

protocol ThumbnailRendering: Sendable {
    func renderThumbnail(
        assetID: String,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

actor PhotoKitRenditionProvider: PhotoResourceMaterializing {
    func materializeResource(
        assetID: String,
        descriptor: PhotoResourceDescriptor,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        guard let asset = fetchResult.firstObject else { throw RenditionError.assetUnavailable(assetID) }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = PhotoKitResourceCatalog.resource(
            descriptorID: descriptor.id,
            assetID: assetID,
            resources: resources
        ) else {
            throw RenditionError.resourceUnavailable(descriptor.originalFilename)
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value in progress(value) }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(
                    for: resource,
                    toFile: outputURL,
                    options: options
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            // PhotoKit's write API does not expose a request ID to cancel. The completed
            // staging file is ignored until a resumed job validates and transfers it.
        }
        try Task.checkCancellation()
        progress(1)
    }
}

actor PhotoKitThumbnailRenderer: ThumbnailRendering {
    private let imageManager = PHImageManager.default()

    func renderThumbnail(
        assetID: String,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetID],
            options: PhotoKitFetchOptions.includingHiddenAssets()
        )
        guard let asset = fetchResult.firstObject else { throw RenditionError.assetUnavailable(assetID) }
        progress(0.05)
        let data: Data
        let orientation: CGImagePropertyOrientation
        if asset.mediaType == .video {
            data = try await requestCurrentPosterJPEG(for: asset, progress: progress)
            orientation = .up
        } else {
            (data, orientation) = try await requestCurrentImageData(for: asset, progress: progress)
        }
        try Task.checkCancellation()
        progress(0.75)
        try Self.encodeSRGBJPEG(
            sourceData: data,
            orientation: orientation,
            outputURL: outputURL,
            preserveLocation: false,
            maximumPixelDimension: ExportConstants.thumbnailMaximumPixelDimension
        )
        progress(1)
    }

    private func requestCurrentImageData(
        for asset: PHAsset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, CGImagePropertyOrientation) {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in
            progress(0.05 + value * 0.65)
        }

        let cancellation = PhotoImageRequestCancellation(manager: imageManager)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = ThrowingImageContinuationBox(continuation)
                let requestID = imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, orientation, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        box.resume(throwing: RenditionError.cancelled)
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        box.resume(throwing: error)
                    } else if let data {
                        box.resume(returning: (data, orientation))
                    } else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                        box.resume(throwing: RenditionError.imageDecodeFailed)
                    }
                }
                cancellation.setRequestID(requestID)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func requestCurrentPosterJPEG(
        for asset: PHAsset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in
            progress(0.05 + value * 0.65)
        }

        let cancellation = PhotoImageRequestCancellation(manager: imageManager)
        let target = CGSize(
            width: ExportConstants.thumbnailMaximumPixelDimension,
            height: ExportConstants.thumbnailMaximumPixelDimension
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = ThrowingDataContinuationBox(continuation)
                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: target,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        box.resume(throwing: RenditionError.cancelled)
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        box.resume(throwing: error)
                    } else if let image,
                              (info?[PHImageResultIsDegradedKey] as? Bool) != true,
                              let data = image.jpegData(
                                compressionQuality: ExportConstants.thumbnailJPEGQuality
                              ) {
                        box.resume(returning: data)
                    } else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                        box.resume(throwing: RenditionError.imageDecodeFailed)
                    }
                }
                cancellation.setRequestID(requestID)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func encodeSRGBJPEG(
        sourceData: Data,
        orientation: CGImagePropertyOrientation,
        outputURL: URL,
        preserveLocation: Bool,
        authoritativeLocation: AssetLocation? = nil,
        maximumPixelDimension: Int? = nil
    ) throws {
        guard let imageSource = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let ciImage = CIImage(
                data: sourceData,
                options: [.applyOrientationProperty: false]
              ) else {
            throw RenditionError.imageDecodeFailed
        }
        let oriented = ciImage.oriented(forExifOrientation: Int32(orientation.rawValue))
        let rendered: CIImage
        if let maximumPixelDimension,
           maximumPixelDimension > 0,
           max(oriented.extent.width, oriented.extent.height) > CGFloat(maximumPixelDimension) {
            let scale = CGFloat(maximumPixelDimension) / max(oriented.extent.width, oriented.extent.height)
            rendered = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            rendered = oriented
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ])
        guard let cgImage = context.createCGImage(
            rendered,
            from: rendered.extent.integral,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw RenditionError.imageDecodeFailed
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw RenditionError.imageEncodeFailed
        }
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let properties = JPEGMetadataPolicy.outputProperties(
            source: sourceProperties,
            preserveLocation: preserveLocation,
            authoritativeLocation: authoritativeLocation
        )
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RenditionError.imageEncodeFailed
        }
    }
}

enum JPEGMetadataPolicy {
    static func outputProperties(
        source: [CFString: Any],
        preserveLocation: Bool,
        authoritativeLocation: AssetLocation? = nil
    ) -> [CFString: Any] {
        var properties = preserveLocation ? source : removingLocationMetadata(from: source)
        if preserveLocation, let authoritativeLocation {
            properties[kCGImagePropertyGPSDictionary] = gpsDictionary(authoritativeLocation)
        }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImageDestinationLossyCompressionQuality] = ExportConstants.thumbnailJPEGQuality
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        return properties
    }

    private static func removingLocationMetadata(from source: [CFString: Any]) -> [CFString: Any] {
        var result = source
        result.removeValue(forKey: kCGImagePropertyGPSDictionary)

        if var iptc = source[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            for key in [
                kCGImagePropertyIPTCCity,
                kCGImagePropertyIPTCSubLocation,
                kCGImagePropertyIPTCProvinceState,
                kCGImagePropertyIPTCCountryPrimaryLocationCode,
                kCGImagePropertyIPTCCountryPrimaryLocationName
            ] {
                iptc.removeValue(forKey: key)
            }
            if iptc.isEmpty {
                result.removeValue(forKey: kCGImagePropertyIPTCDictionary)
            } else {
                result[kCGImagePropertyIPTCDictionary] = iptc
            }
        }

        let xmpKey = "{XMP}" as CFString
        if let xmp = source[xmpKey] as? [CFString: Any] {
            let scrubbed = scrubbedXMP(xmp)
            if scrubbed.isEmpty {
                result.removeValue(forKey: xmpKey)
            } else {
                result[xmpKey] = scrubbed
            }
        }
        return result
    }

    private static func scrubbedXMP(_ source: [CFString: Any]) -> [CFString: Any] {
        let locationTerms = [
            "gps", "location", "latitude", "longitude", "altitude",
            "sublocation", "city", "province", "state", "country", "geotag"
        ]
        var result: [CFString: Any] = [:]
        for (key, value) in source {
            let normalizedKey = (key as String).lowercased()
            guard !locationTerms.contains(where: normalizedKey.contains) else { continue }
            if let nested = value as? [CFString: Any] {
                result[key] = scrubbedXMP(nested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func gpsDictionary(_ location: AssetLocation) -> [CFString: Any] {
        var gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(location.latitude),
            kCGImagePropertyGPSLatitudeRef: location.latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude: abs(location.longitude),
            kCGImagePropertyGPSLongitudeRef: location.longitude < 0 ? "W" : "E"
        ]
        if let altitude = location.altitudeMeters {
            gps[kCGImagePropertyGPSAltitude] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
        }
        return gps
    }
}

struct FileDigest: Equatable, Sendable {
    let byteCount: Int64
    let sha256: String

    static func compute(url: URL, bufferSize: Int = 1_024 * 1_024) throws -> FileDigest {
        precondition(bufferSize > 0)
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: bufferSize) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
            count += Int64(data.count)
        }
        try Task.checkCancellation()
        return FileDigest(byteCount: count, sha256: hash.finalize().hexString)
    }
}

private final class ThrowingImageContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, CGImagePropertyOrientation), Error>?

    init(_ continuation: CheckedContinuation<(Data, CGImagePropertyOrientation), Error>) {
        self.continuation = continuation
    }

    func resume(returning value: (Data, CGImagePropertyOrientation)) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<(Data, CGImagePropertyOrientation), Error>? {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        return current
    }
}

private final class ThrowingDataContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Data) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        return current
    }
}

private final class PhotoImageRequestCancellation: @unchecked Sendable {
    private let manager: PHImageManager
    private let lock = NSLock()
    private var requestID: PHImageRequestID?
    private var isCancelled = false

    init(manager: PHImageManager) {
        self.manager = manager
    }

    func setRequestID(_ requestID: PHImageRequestID) {
        lock.lock()
        self.requestID = requestID
        let cancelImmediately = isCancelled
        lock.unlock()
        if cancelImmediately { manager.cancelImageRequest(requestID) }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let requestID = requestID
        lock.unlock()
        if let requestID { manager.cancelImageRequest(requestID) }
    }
}
