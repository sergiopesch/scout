import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageEvidenceLimits: Equatable, Sendable {
    static let production = ImageEvidenceLimits(
        maximumSourceBytes: 16 * 1024 * 1024,
        maximumSourceDimension: 12_000,
        maximumSourcePixels: 24_000_000,
        maximumDecodedBytes: 96 * 1024 * 1024,
        maximumOutputDimension: 4_096,
        maximumOutputPixels: 16_777_216,
        maximumOutputBytes: 8 * 1024 * 1024
    )

    let maximumSourceBytes: Int
    let maximumSourceDimension: Int
    let maximumSourcePixels: Int
    let maximumDecodedBytes: Int
    let maximumOutputDimension: Int
    let maximumOutputPixels: Int
    let maximumOutputBytes: Int
}

struct PreparedImageEvidence: Equatable, Sendable {
    let normalizedJPEG: Data
    let assetSHA256: String
    let pixelWidth: Int
    let pixelHeight: Int
    let sourceTypeIdentifier: String

    var mimeType: String { "image/jpeg" }
    var byteCount: Int { normalizedJPEG.count }
}

enum ImageEvidenceImportError: Error, LocalizedError, Equatable, Sendable {
    case invalidLimits
    case invalidResource
    case symbolicLinkNotAccepted
    case unreadableResource
    case sourceTooLarge
    case unsupportedFormat
    case multipleFramesNotAccepted
    case invalidDimensions
    case decompressionBoundExceeded
    case decodeFailed
    case normalizationFailed
    case normalizedImageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidLimits:
            "Scout's image safety limits are invalid."
        case .invalidResource:
            "Select a regular local image file."
        case .symbolicLinkNotAccepted:
            "Scout does not import image aliases or symbolic links."
        case .unreadableResource:
            "Scout could not securely read the selected image."
        case .sourceTooLarge:
            "The selected image exceeds Scout's source byte limit."
        case .unsupportedFormat:
            "Scout accepts JPEG, PNG, HEIC, or HEIF source images."
        case .multipleFramesNotAccepted:
            "Scout accepts one still image at a time."
        case .invalidDimensions:
            "The selected image has invalid or excessive dimensions."
        case .decompressionBoundExceeded:
            "The selected image would exceed Scout's safe decode limit."
        case .decodeFailed:
            "The selected image could not be decoded safely."
        case .normalizationFailed:
            "Scout could not normalize the selected image."
        case .normalizedImageTooLarge:
            "The normalized image still exceeds Scout's upload limit."
        }
    }
}

/// Imports one explicitly user-selected local image into a bounded, metadata-free evidence artifact.
/// The returned JPEG is the only byte sequence that may be uploaded or hashed into later observations.
struct ImageEvidenceImporter: Sendable {
    private static let acceptedSourceTypes: Set<String> = [
        UTType.jpeg.identifier,
        UTType.png.identifier,
        "public.heic",
        "public.heif",
    ]

    private let limits: ImageEvidenceLimits

    init(limits: ImageEvidenceLimits = .production) {
        self.limits = limits
    }

    func prepareUserSelectedImage(at url: URL) throws -> PreparedImageEvidence {
        guard valid(limits) else { throw ImageEvidenceImportError.invalidLimits }
        guard url.isFileURL else { throw ImageEvidenceImportError.invalidResource }

        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ImageEvidenceImportError.invalidResource }
            guard values.isSymbolicLink != true else { throw ImageEvidenceImportError.symbolicLinkNotAccepted }
            if let declaredSize = values.fileSize, declaredSize > limits.maximumSourceBytes {
                throw ImageEvidenceImportError.sourceTooLarge
            }

            let sourceBytes = try readBoundedFile(at: url)
            return try normalize(sourceBytes)
        } catch let error as ImageEvidenceImportError {
            throw error
        } catch {
            throw ImageEvidenceImportError.unreadableResource
        }
    }

    private func readBoundedFile(at url: URL) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ImageEvidenceImportError.unreadableResource
        }
        defer { try? handle.close() }

        let bytes: Data
        do {
            bytes = try handle.read(upToCount: limits.maximumSourceBytes + 1) ?? Data()
        } catch {
            throw ImageEvidenceImportError.unreadableResource
        }
        guard !bytes.isEmpty else { throw ImageEvidenceImportError.invalidResource }
        guard bytes.count <= limits.maximumSourceBytes else { throw ImageEvidenceImportError.sourceTooLarge }
        return bytes
    }

    private func normalize(_ sourceBytes: Data) throws -> PreparedImageEvidence {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(sourceBytes as CFData, sourceOptions),
              let sourceType = CGImageSourceGetType(source) as String?
        else { throw ImageEvidenceImportError.decodeFailed }

        guard Self.acceptedSourceTypes.contains(sourceType) else {
            throw ImageEvidenceImportError.unsupportedFormat
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ImageEvidenceImportError.multipleFramesNotAccepted
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw ImageEvidenceImportError.invalidDimensions }

        guard sourceWidth > 0, sourceHeight > 0,
              sourceWidth <= limits.maximumSourceDimension,
              sourceHeight <= limits.maximumSourceDimension,
              let sourcePixels = safeProduct(sourceWidth, sourceHeight),
              sourcePixels <= limits.maximumSourcePixels
        else { throw ImageEvidenceImportError.invalidDimensions }
        guard let decodedBytes = safeProduct(sourcePixels, 4), decodedBytes <= limits.maximumDecodedBytes else {
            throw ImageEvidenceImportError.decompressionBoundExceeded
        }

        let initialTarget = min(limits.maximumOutputDimension, max(sourceWidth, sourceHeight))
        var targetDimension = initialTarget
        let qualities: [Double] = [0.92, 0.84, 0.76]

        while targetDimension >= 512 || targetDimension == initialTarget {
            guard let normalizedImage = createNormalizedImage(source: source, targetDimension: targetDimension) else {
                throw ImageEvidenceImportError.decodeFailed
            }
            guard normalizedImage.width > 0, normalizedImage.height > 0,
                  normalizedImage.width <= limits.maximumOutputDimension,
                  normalizedImage.height <= limits.maximumOutputDimension,
                  let outputPixels = safeProduct(normalizedImage.width, normalizedImage.height),
                  outputPixels <= limits.maximumOutputPixels
            else { throw ImageEvidenceImportError.decompressionBoundExceeded }

            for quality in qualities {
                guard let encoded = encodeJPEG(normalizedImage, quality: quality) else {
                    throw ImageEvidenceImportError.normalizationFailed
                }
                if encoded.count <= limits.maximumOutputBytes {
                    return PreparedImageEvidence(
                        normalizedJPEG: encoded,
                        assetSHA256: Self.sha256(encoded),
                        pixelWidth: normalizedImage.width,
                        pixelHeight: normalizedImage.height,
                        sourceTypeIdentifier: sourceType
                    )
                }
            }

            if targetDimension <= 512 { break }
            targetDimension = max(512, Int((Double(targetDimension) * 0.8).rounded(.down)))
        }
        throw ImageEvidenceImportError.normalizedImageTooLarge
    }

    private func createNormalizedImage(source: CGImageSource, targetDimension: Int) -> CGImage? {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: thumbnail.width,
            height: thumbnail.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        context.interpolationQuality = .high
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        return context.makeImage()
    }

    private func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return stripPrivateJPEGMetadata(output as Data)
    }

    /// ImageIO may synthesize an EXIF dictionary containing only pixel dimensions even when no
    /// source metadata is supplied. Remove all application-private and comment segments from the
    /// encoded byte stream so the bytes Scout hashes and uploads are genuinely metadata-free.
    /// APP0/JFIF is retained because it describes JPEG interchange, not source provenance.
    private func stripPrivateJPEGMetadata(_ jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return nil }

        var sanitized = Data(bytes[0 ... 1])
        var offset = 2
        while offset < bytes.count {
            let markerStart = offset
            guard bytes[offset] == 0xff else { return nil }
            while offset < bytes.count, bytes[offset] == 0xff {
                offset += 1
            }
            guard offset < bytes.count else { return nil }
            let marker = bytes[offset]
            offset += 1

            if marker == 0xda { // Start of scan: compressed entropy data runs through EOI.
                sanitized.append(contentsOf: bytes[markerStart...])
                return sanitized
            }
            if marker == 0xd9 { // End of image before a scan is malformed, but preserve parsing.
                sanitized.append(contentsOf: bytes[markerStart ..< offset])
                return offset == bytes.count ? sanitized : nil
            }
            if marker == 0x01 || (0xd0 ... 0xd7).contains(marker) {
                sanitized.append(contentsOf: bytes[markerStart ..< offset])
                continue
            }

            guard offset + 1 < bytes.count else { return nil }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard length >= 2 else { return nil }
            let segmentEnd = offset + length
            guard segmentEnd <= bytes.count else { return nil }

            let containsPrivateMetadata = (0xe1 ... 0xef).contains(marker) || marker == 0xfe
            if !containsPrivateMetadata {
                sanitized.append(contentsOf: bytes[markerStart ..< segmentEnd])
            }
            offset = segmentEnd
        }
        return nil
    }

    private func safeProduct(_ left: Int, _ right: Int) -> Int? {
        let (value, overflow) = left.multipliedReportingOverflow(by: right)
        return overflow ? nil : value
    }

    private func valid(_ limits: ImageEvidenceLimits) -> Bool {
        limits.maximumSourceBytes > 0
            && limits.maximumSourceDimension > 0
            && limits.maximumSourcePixels > 0
            && limits.maximumDecodedBytes > 0
            && limits.maximumOutputDimension > 0
            && limits.maximumOutputDimension <= limits.maximumSourceDimension
            && limits.maximumOutputPixels > 0
            && limits.maximumOutputBytes > 0
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
