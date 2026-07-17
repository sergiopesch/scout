import Foundation

public enum PrimitiveValidationError: Error, Equatable, Sendable {
    case emptyString
    case invalidIdentifier(String)
    case confidenceOutOfRange(Int)
    case sequenceMustStartAtOne
    case sequenceOverflow
    case decimalScaleTooLarge(UInt8)
}

/// A string that is trimmed once at the boundary and can never be empty.
public struct NonEmptyString: Codable, Hashable, Comparable, Sendable, CanonicalRepresentable {
    public let rawValue: String

    public init(validating value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PrimitiveValidationError.emptyString }
        rawValue = trimmed
    }

    public static func < (lhs: NonEmptyString, rhs: NonEmptyString) -> Bool {
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

/// Phantom-typed identifier. Different domain IDs cannot be accidentally mixed.
public struct ScoutID<Tag: Sendable>: Codable, Hashable, Comparable, Sendable, CanonicalRepresentable {
    public let rawValue: String

    public init(validating rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E })
        else {
            throw PrimitiveValidationError.invalidIdentifier(rawValue)
        }
        self.rawValue = rawValue
    }

    public static func random() -> ScoutID<Tag> {
        // UUID output is guaranteed to satisfy the identifier constraints.
        try! ScoutID<Tag>(validating: UUID().uuidString.lowercased())
    }

    public static func == (lhs: ScoutID<Tag>, rhs: ScoutID<Tag>) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }

    public static func < (lhs: ScoutID<Tag>, rhs: ScoutID<Tag>) -> Bool {
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

public enum SessionIDTag: Sendable {}
public enum EventIDTag: Sendable {}
public enum SpeakerIDTag: Sendable {}
public enum UtteranceIDTag: Sendable {}
public enum EvidenceIDTag: Sendable {}
public enum ClaimIDTag: Sendable {}
public enum EntityIDTag: Sendable {}
public enum RelationshipIDTag: Sendable {}
public enum AssetIDTag: Sendable {}
public enum ModelCallReceiptIDTag: Sendable {}
public enum VisualObservationIDTag: Sendable {}

public typealias SessionID = ScoutID<SessionIDTag>
public typealias EventID = ScoutID<EventIDTag>
public typealias SpeakerID = ScoutID<SpeakerIDTag>
public typealias UtteranceID = ScoutID<UtteranceIDTag>
public typealias EvidenceID = ScoutID<EvidenceIDTag>
public typealias ClaimID = ScoutID<ClaimIDTag>
public typealias EntityID = ScoutID<EntityIDTag>
public typealias RelationshipID = ScoutID<RelationshipIDTag>
public typealias AssetID = ScoutID<AssetIDTag>
public typealias ModelCallReceiptID = ScoutID<ModelCallReceiptIDTag>
public typealias VisualObservationID = ScoutID<VisualObservationIDTag>

/// Wall-clock time represented as an integer to avoid floating-point and date
/// formatting differences in event hashes.
public struct ScoutTimestamp: Codable, Hashable, Comparable, Sendable, CanonicalRepresentable {
    public let millisecondsSinceUnixEpoch: Int64

    public init(millisecondsSinceUnixEpoch: Int64) {
        self.millisecondsSinceUnixEpoch = millisecondsSinceUnixEpoch
    }

    public static func < (lhs: ScoutTimestamp, rhs: ScoutTimestamp) -> Bool {
        lhs.millisecondsSinceUnixEpoch < rhs.millisecondsSinceUnixEpoch
    }

    public var canonicalValue: CanonicalValue { .integer(millisecondsSinceUnixEpoch) }
}

public struct EventSequence: Codable, Hashable, Comparable, Sendable, CanonicalRepresentable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) throws {
        guard rawValue > 0 else { throw PrimitiveValidationError.sequenceMustStartAtOne }
        self.rawValue = rawValue
    }

    public func successor() throws -> EventSequence {
        guard rawValue < UInt64.max else { throw PrimitiveValidationError.sequenceOverflow }
        return try EventSequence(rawValue + 1)
    }

    public static func < (lhs: EventSequence, rhs: EventSequence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var canonicalValue: CanonicalValue { .unsigned(rawValue) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(UInt64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A fixed-point confidence score where 10,000 basis points equals 100%.
public struct Confidence: Codable, Hashable, Comparable, Sendable, CanonicalRepresentable {
    public let basisPoints: UInt16

    public init(basisPoints: Int) throws {
        guard (0 ... 10_000).contains(basisPoints) else {
            throw PrimitiveValidationError.confidenceOutOfRange(basisPoints)
        }
        self.basisPoints = UInt16(basisPoints)
    }

    public static let none = try! Confidence(basisPoints: 0)
    public static let certain = try! Confidence(basisPoints: 10_000)

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.basisPoints < rhs.basisPoints
    }

    public var canonicalValue: CanonicalValue { .unsigned(UInt64(basisPoints)) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(basisPoints: container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(basisPoints)
    }
}

/// Exact base-10 number represented by a coefficient and scale.
/// `12345, 2` means `123.45`. Trailing fractional zeros are normalized.
public struct ExactDecimal: Codable, Hashable, Comparable, Sendable, CanonicalRepresentable {
    public let coefficient: Int64
    public let scale: UInt8

    public init(coefficient: Int64, scale: UInt8) throws {
        guard scale <= 18 else { throw PrimitiveValidationError.decimalScaleTooLarge(scale) }

        var normalizedCoefficient = coefficient
        var normalizedScale = scale
        while normalizedScale > 0, normalizedCoefficient % 10 == 0 {
            normalizedCoefficient /= 10
            normalizedScale -= 1
        }
        self.coefficient = normalizedCoefficient
        self.scale = normalizedScale
    }

    public var canonicalString: String {
        guard scale > 0 else { return String(coefficient) }

        let signed = String(coefficient)
        let negative = signed.first == "-"
        var digits = negative ? String(signed.dropFirst()) : signed
        let requiredDigits = Int(scale) + 1
        if digits.count < requiredDigits {
            digits = String(repeating: "0", count: requiredDigits - digits.count) + digits
        }
        let split = digits.index(digits.endIndex, offsetBy: -Int(scale))
        let rendered = String(digits[..<split]) + "." + String(digits[split...])
        return negative ? "-" + rendered : rendered
    }

    public static func < (lhs: ExactDecimal, rhs: ExactDecimal) -> Bool {
        if lhs == rhs { return false }
        let lhsNegative = lhs.coefficient < 0
        let rhsNegative = rhs.coefficient < 0
        if lhsNegative != rhsNegative { return lhsNegative }

        let commonScale = max(lhs.scale, rhs.scale)
        let left = lhs.scaledMagnitude(to: commonScale)
        let right = rhs.scaledMagnitude(to: commonScale)
        let magnitudeComparison: ComparisonResult
        if left.count != right.count {
            magnitudeComparison = left.count < right.count ? .orderedAscending : .orderedDescending
        } else if left == right {
            magnitudeComparison = .orderedSame
        } else {
            magnitudeComparison = left < right ? .orderedAscending : .orderedDescending
        }
        return lhsNegative
            ? magnitudeComparison == .orderedDescending
            : magnitudeComparison == .orderedAscending
    }

    public var canonicalValue: CanonicalValue { .string(canonicalString) }

    private func scaledMagnitude(to targetScale: UInt8) -> String {
        let signed = String(coefficient)
        let magnitude = signed.first == "-" ? String(signed.dropFirst()) : signed
        let trimmed = magnitude.drop(while: { $0 == "0" })
        let significant = trimmed.isEmpty ? "0" : String(trimmed)
        if significant == "0" { return "0" }
        return significant + String(repeating: "0", count: Int(targetScale - scale))
    }

    private enum CodingKeys: String, CodingKey {
        case coefficient
        case scale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            coefficient: container.decode(Int64.self, forKey: .coefficient),
            scale: container.decode(UInt8.self, forKey: .scale)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(coefficient, forKey: .coefficient)
        try container.encode(scale, forKey: .scale)
    }
}

func normalizedUnique<T: Hashable & Comparable>(_ values: [T]) -> [T] {
    Array(Set(values)).sorted()
}
