import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@testable import Scout
import UniformTypeIdentifiers
import XCTest

final class ImageEvidenceImporterTests: XCTestCase {
    func testNormalizesOrientationStripsMetadataAndHashesExactJPEGBytes() throws {
        let url = temporaryURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try scoutTestImageData(width: 32, height: 16, type: .jpeg, orientation: 6).write(to: url)

        let prepared = try ImageEvidenceImporter().prepareUserSelectedImage(at: url)

        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(prepared.sourceTypeIdentifier, UTType.jpeg.identifier)
        XCTAssertEqual(prepared.pixelWidth, 16)
        XCTAssertEqual(prepared.pixelHeight, 32)
        XCTAssertEqual(prepared.assetSHA256, sha256(prepared.normalizedJPEG))
        XCTAssertLessThanOrEqual(prepared.byteCount, ImageEvidenceLimits.production.maximumOutputBytes)
        XCTAssertFalse(containsPrivateJPEGMetadata(prepared.normalizedJPEG))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.normalizedJPEG as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        XCTAssertNil(properties[kCGImagePropertyExifDictionary])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    func testRejectsSourceBeforeReadingPastByteLimit() throws {
        let url = temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try scoutTestImageData(width: 8, height: 8, type: .png)
        try data.write(to: url)
        let importer = ImageEvidenceImporter(limits: limits(maximumSourceBytes: data.count - 1))

        XCTAssertThrowsError(try importer.prepareUserSelectedImage(at: url)) { error in
            XCTAssertEqual(error as? ImageEvidenceImportError, .sourceTooLarge)
        }
    }

    func testRejectsPixelCountBeforeDecode() throws {
        let url = temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        try scoutTestImageData(width: 8, height: 8, type: .png).write(to: url)
        let importer = ImageEvidenceImporter(limits: limits(maximumSourcePixels: 63))

        XCTAssertThrowsError(try importer.prepareUserSelectedImage(at: url)) { error in
            XCTAssertEqual(error as? ImageEvidenceImportError, .invalidDimensions)
        }
    }

    func testRejectsUnapprovedImageContainer() throws {
        let url = temporaryURL(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try scoutTestImageData(width: 8, height: 8, type: .gif).write(to: url)

        XCTAssertThrowsError(try ImageEvidenceImporter().prepareUserSelectedImage(at: url)) { error in
            XCTAssertEqual(error as? ImageEvidenceImportError, .unsupportedFormat)
        }
    }

    private func temporaryURL(extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "scout-image-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }

    private func limits(
        maximumSourceBytes: Int = 1024 * 1024,
        maximumSourcePixels: Int = 1_000_000
    ) -> ImageEvidenceLimits {
        ImageEvidenceLimits(
            maximumSourceBytes: maximumSourceBytes,
            maximumSourceDimension: 2_000,
            maximumSourcePixels: maximumSourcePixels,
            maximumDecodedBytes: 4_000_000,
            maximumOutputDimension: 1_024,
            maximumOutputPixels: 1_000_000,
            maximumOutputBytes: 512 * 1024
        )
    }
}

func scoutTestImageData(
    width: Int,
    height: Int,
    type: UTType,
    orientation: Int = 1
) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation,
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImagePropertyExifDictionary: ["UserComment": "must be stripped"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func containsPrivateJPEGMetadata(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return true }
    var offset = 2
    while offset + 4 <= bytes.count {
        guard bytes[offset] == 0xff else { return true }
        let marker = bytes[offset + 1]
        if marker == 0xda { return false }
        let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        guard length >= 2, offset + 2 + length <= bytes.count else { return true }
        if (0xe1 ... 0xef).contains(marker) || marker == 0xfe { return true }
        offset += 2 + length
    }
    return true
}
