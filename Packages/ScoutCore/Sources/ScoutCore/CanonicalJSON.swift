import CryptoKit
import Foundation

/// A deliberately small JSON value set used for stable hashes.
///
/// Floating-point numbers are intentionally absent. Domain values that need a
/// fraction use ``ExactDecimal`` so their byte representation is unambiguous.
public indirect enum CanonicalValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case string(String)
    case array([CanonicalValue])
    case object([String: CanonicalValue])
}

public protocol CanonicalRepresentable: Sendable {
    var canonicalValue: CanonicalValue { get }
}

public enum CanonicalJSON {
    /// Encodes objects with lexicographically sorted keys, UTF-8 strings, and
    /// minimal JSON escaping. The implementation is intentionally independent
    /// of Foundation's JSON encoder.
    public static func encode(_ value: CanonicalValue) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(256)
        append(value, to: &bytes)
        return Data(bytes)
    }

    public static func string(_ value: CanonicalValue) -> String {
        String(decoding: encode(value), as: UTF8.self)
    }

    private static func append(_ value: CanonicalValue, to bytes: inout [UInt8]) {
        switch value {
        case .null:
            bytes.append(contentsOf: "null".utf8)
        case let .bool(value):
            bytes.append(contentsOf: (value ? "true" : "false").utf8)
        case let .integer(value):
            bytes.append(contentsOf: String(value).utf8)
        case let .unsigned(value):
            bytes.append(contentsOf: String(value).utf8)
        case let .string(value):
            appendEscaped(value, to: &bytes)
        case let .array(values):
            bytes.append(ascii: "[")
            for (index, element) in values.enumerated() {
                if index > 0 { bytes.append(ascii: ",") }
                append(element, to: &bytes)
            }
            bytes.append(ascii: "]")
        case let .object(object):
            bytes.append(ascii: "{")
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 { bytes.append(ascii: ",") }
                appendEscaped(key, to: &bytes)
                bytes.append(ascii: ":")
                // `key` came from this dictionary, so the value always exists.
                append(object[key]!, to: &bytes)
            }
            bytes.append(ascii: "}")
        }
    }

    private static func appendEscaped(_ value: String, to bytes: inout [UInt8]) {
        bytes.append(ascii: "\"")
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                bytes.append(contentsOf: "\\\"".utf8)
            case 0x5C:
                bytes.append(contentsOf: "\\\\".utf8)
            case 0x08:
                bytes.append(contentsOf: "\\b".utf8)
            case 0x09:
                bytes.append(contentsOf: "\\t".utf8)
            case 0x0A:
                bytes.append(contentsOf: "\\n".utf8)
            case 0x0C:
                bytes.append(contentsOf: "\\f".utf8)
            case 0x0D:
                bytes.append(contentsOf: "\\r".utf8)
            case 0x00 ... 0x1F:
                let hex = String(format: "\\u%04x", scalar.value)
                bytes.append(contentsOf: hex.utf8)
            default:
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        bytes.append(ascii: "\"")
    }
}

private extension Array where Element == UInt8 {
    mutating func append(ascii character: Character) {
        append(String(character).utf8.first!)
    }
}

public enum DigestValidationError: Error, Equatable, Sendable {
    case invalidSHA256(String)
}

/// A validated, lowercase SHA-256 digest.
public struct SHA256Digest: Codable, Hashable, Comparable, Sendable, CanonicalRepresentable {
    public let rawValue: String

    public init(validating rawValue: String) throws {
        guard rawValue.count == 64,
              rawValue.unicodeScalars.allSatisfy({
                  (0x30 ... 0x39).contains($0.value) || (0x61 ... 0x66).contains($0.value)
              })
        else {
            throw DigestValidationError.invalidSHA256(rawValue)
        }
        self.rawValue = rawValue
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public static func hash(_ data: Data) -> SHA256Digest {
        let bytes = SHA256.hash(data: data)
        return SHA256Digest(unchecked: bytes.map { String(format: "%02x", $0) }.joined())
    }

    public static func hash(_ value: CanonicalValue) -> SHA256Digest {
        hash(CanonicalJSON.encode(value))
    }

    public static func < (lhs: SHA256Digest, rhs: SHA256Digest) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var canonicalValue: CanonicalValue { .string(rawValue) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Optional where Wrapped: CanonicalRepresentable {
    var canonicalValue: CanonicalValue {
        switch self {
        case let .some(value): value.canonicalValue
        case .none: .null
        }
    }
}

extension Optional where Wrapped == String {
    var canonicalStringValue: CanonicalValue {
        map(CanonicalValue.string) ?? .null
    }
}
