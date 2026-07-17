import Foundation
import Testing
@testable import ScoutCore

@Suite("Canonical encoding and value primitives")
struct CanonicalAndPrimitiveTests {
    @Test("Canonical JSON sorts object keys and escapes deterministically")
    func canonicalJSON() {
        let first = CanonicalValue.object([
            "z": .integer(-4),
            "a": .string("line\n\"quoted\""),
            "m": .array([.bool(true), .null]),
        ])
        let second = CanonicalValue.object([
            "m": .array([.bool(true), .null]),
            "a": .string("line\n\"quoted\""),
            "z": .integer(-4),
        ])

        #expect(CanonicalJSON.string(first) == "{\"a\":\"line\\n\\\"quoted\\\"\",\"m\":[true,null],\"z\":-4}")
        #expect(CanonicalJSON.encode(first) == CanonicalJSON.encode(second))
        #expect(SHA256Digest.hash(first) == SHA256Digest.hash(second))
    }

    @Test("SHA-256 matches the published abc test vector")
    func sha256Vector() throws {
        let digest = SHA256Digest.hash(Data("abc".utf8))
        let expected = try SHA256Digest(
            validating: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(digest == expected)
    }

    @Test("Digest validation rejects uppercase and malformed values")
    func digestValidation() {
        do {
            _ = try SHA256Digest(validating: String(repeating: "A", count: 64))
            Issue.record("Expected uppercase digest to be rejected")
        } catch let error as DigestValidationError {
            #expect(error == .invalidSHA256(String(repeating: "A", count: 64)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Typed IDs are single-value Codable and cannot cross types")
    func typedIdentifiers() throws {
        let session: SessionID = testID("session-1")
        let encoded = try JSONEncoder().encode(session)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"session-1\"")
        #expect(try JSONDecoder().decode(SessionID.self, from: encoded) == session)

        let malformed = Data("\" session-1\"".utf8)
        do {
            _ = try JSONDecoder().decode(SessionID.self, from: malformed)
            Issue.record("Expected malformed ID to fail decoding")
        } catch let error as PrimitiveValidationError {
            #expect(error == .invalidIdentifier(" session-1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Non-empty strings normalize boundary whitespace")
    func nonEmptyString() throws {
        #expect(try NonEmptyString(validating: "  Acme Retail \n").rawValue == "Acme Retail")
        do {
            _ = try NonEmptyString(validating: " \n ")
            Issue.record("Expected whitespace-only text to fail")
        } catch let error as PrimitiveValidationError {
            #expect(error == .emptyString)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Confidence accepts only 0 through 10,000 basis points")
    func confidenceBounds() throws {
        #expect(try Confidence(basisPoints: 0) == .none)
        #expect(try Confidence(basisPoints: 10_000) == .certain)
        for invalid in [-1, 10_001] {
            do {
                _ = try Confidence(basisPoints: invalid)
                Issue.record("Expected \(invalid) to fail")
            } catch let error as PrimitiveValidationError {
                #expect(error == .confidenceOutOfRange(invalid))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Exact decimals normalize without floating point")
    func exactDecimal() throws {
        let normalized = try ExactDecimal(coefficient: 12_340, scale: 3)
        #expect(normalized.coefficient == 1_234)
        #expect(normalized.scale == 2)
        #expect(normalized.canonicalString == "12.34")
        #expect(try ExactDecimal(coefficient: -5, scale: 2).canonicalString == "-0.05")
        #expect(try ExactDecimal(coefficient: 123, scale: 1) < ExactDecimal(coefficient: 124, scale: 1))
        #expect(try ExactDecimal(coefficient: 0, scale: 0) < ExactDecimal(coefficient: 1, scale: 2))
        #expect(try ExactDecimal(coefficient: -1, scale: 2) < ExactDecimal(coefficient: 0, scale: 0))
    }

    @Test("Sequences are one-based and overflow-safe")
    func sequences() throws {
        do {
            _ = try EventSequence(0)
            Issue.record("Expected zero sequence to fail")
        } catch let error as PrimitiveValidationError {
            #expect(error == .sequenceMustStartAtOne)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let maximum = try EventSequence(UInt64.max)
        do {
            _ = try maximum.successor()
            Issue.record("Expected sequence overflow")
        } catch let error as PrimitiveValidationError {
            #expect(error == .sequenceOverflow)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
