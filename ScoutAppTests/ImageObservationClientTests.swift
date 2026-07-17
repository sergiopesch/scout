import CryptoKit
import Foundation
@testable import Scout
import UniformTypeIdentifiers
import XCTest

final class ImageObservationClientTests: XCTestCase {
    func testPostsAuthenticatedBoundedMultipartAndDecodesProposal() async throws {
        let requestValue = try request()
        let transport = ImageObservationStubTransport(responseData: Data(validResponseJSON(for: requestValue).utf8))
        let client = ImageObservationClient(configuration: configuration, transport: transport)

        let result = try await client.observe(requestValue)

        XCTAssertEqual(result.proposal.schemaVersion, "1.0")
        XCTAssertEqual(result.proposal.entities.first?.kind, .system)
        XCTAssertEqual(result.proposal.relationships.first?.predicate, .writesTo)
        XCTAssertEqual(result.proposal.evidenceAssetSHA256, requestValue.image.assetSHA256)

        let requests = await transport.requests()
        let captured = try XCTUnwrap(requests.first)
        XCTAssertEqual(captured.url?.absoluteString, "https://scout.example.test/v1/images/observe")
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertFalse(try XCTUnwrap(captured.url?.absoluteString.contains(token)))
        let contentType = try XCTUnwrap(captured.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=ScoutImageBoundary-"))
        let body = try XCTUnwrap(captured.httpBody)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"session_id\""))
        XCTAssertTrue(bodyText.contains(requestValue.image.assetSHA256))
        XCTAssertTrue(bodyText.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(bodyText.contains("filename=\"evidence-\(requestValue.image.assetSHA256.prefix(12)).jpg\""))
        XCTAssertFalse(bodyText.contains("/Users/"))
        XCTAssertFalse(bodyText.contains(token))
    }

    func testFailsBeforeNetworkWhenDigestDoesNotMatchBytes() async throws {
        let transport = ImageObservationStubTransport(responseData: Data())
        let client = ImageObservationClient(configuration: configuration, transport: transport)
        let valid = try request()
        let invalid = ImageObservationRequest(
            sessionID: valid.sessionID,
            image: PreparedImageEvidence(
                normalizedJPEG: valid.image.normalizedJPEG,
                assetSHA256: String(repeating: "b", count: 64),
                pixelWidth: valid.image.pixelWidth,
                pixelHeight: valid.image.pixelHeight,
                sourceTypeIdentifier: valid.image.sourceTypeIdentifier
            )
        )

        await assertClientError(.invalidRequest(.assetDigestMismatch)) {
            try await client.observe(invalid)
        }
        let captured = await transport.requests()
        XCTAssertTrue(captured.isEmpty)
    }

    func testFailsClosedWhenResponseReferencesDifferentAsset() async throws {
        let validRequest = try request()
        let response = validResponseJSON(for: validRequest).replacingOccurrences(
            of: validRequest.image.assetSHA256,
            with: String(repeating: "c", count: 64)
        )
        let client = ImageObservationClient(
            configuration: configuration,
            transport: ImageObservationStubTransport(responseData: response)
        )

        await assertClientError(.invalidResponse(.evidenceDigestMismatch)) {
            try await client.observe(validRequest)
        }
    }

    func testFailsClosedOnUnknownStateBearingField() async throws {
        let validRequest = try request()
        let response = validResponseJSON(for: validRequest).replacingOccurrences(
            of: "\"proposal\":",
            with: "\"unexpected\":true,\"proposal\":"
        )
        let client = ImageObservationClient(
            configuration: configuration,
            transport: ImageObservationStubTransport(responseData: response)
        )

        await assertClientError(.invalidResponse(.schemaViolation)) {
            try await client.observe(validRequest)
        }
    }

    func testFailsClosedWhenRelationshipDoesNotResolve() async throws {
        let validRequest = try request()
        let response = validResponseJSON(for: validRequest).replacingOccurrences(
            of: "\"target_client_ref\": \"entity-orders\"",
            with: "\"target_client_ref\": \"entity-missing\""
        )
        let client = ImageObservationClient(
            configuration: configuration,
            transport: ImageObservationStubTransport(responseData: response)
        )

        await assertClientError(.invalidResponse(.invalidRelationshipReference)) {
            try await client.observe(validRequest)
        }
    }

    func testRequiresAuthenticationBeforeNetwork() async throws {
        let transport = ImageObservationStubTransport(responseData: Data())
        let client = ImageObservationClient(
            configuration: BridgeConfiguration(authenticationToken: nil),
            transport: transport
        )

        await assertClientError(.missingAuthentication) {
            try await client.observe(try self.request())
        }
        let captured = await transport.requests()
        XCTAssertTrue(captured.isEmpty)
    }

    private let token = String(repeating: "t", count: 64)

    private var configuration: BridgeConfiguration {
        BridgeConfiguration(
            baseURL: URL(string: "https://scout.example.test")!,
            authenticationToken: token
        )
    }

    private func request() throws -> ImageObservationRequest {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "scout-client-image-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try scoutTestImageData(width: 24, height: 16, type: .jpeg).write(to: url)
        let image = try ImageEvidenceImporter().prepareUserSelectedImage(at: url)
        return ImageObservationRequest(sessionID: "session-1", image: image)
    }

    private func validResponseJSON(for request: ImageObservationRequest) -> String {
        """
        {
          "proposal": {
            "schema_version": "1.0",
            "evidence_asset_sha256": "\(request.image.assetSHA256)",
            "entities": [
              {
                "client_ref": "entity-crm",
                "kind": "system",
                "name": "CRM",
                "detail": "Customer records",
                "basis": "visible",
                "confidence": 0.97,
                "rationale": "The labelled box is visible."
              },
              {
                "client_ref": "entity-orders",
                "kind": "data",
                "name": "Orders",
                "detail": null,
                "basis": "visible",
                "confidence": 0.9,
                "rationale": "The data store is visible."
              }
            ],
            "relationships": [{
              "client_ref": "relationship-1",
              "source_client_ref": "entity-crm",
              "predicate": "writes_to",
              "target_client_ref": "entity-orders",
              "basis": "visible",
              "confidence": 0.91,
              "rationale": "A directed arrow is visible."
            }],
            "notes": [{
              "client_ref": "note-1",
              "category": "architecture",
              "text": "A hand-drawn current-state architecture.",
              "basis": "visible",
              "confidence": 0.92
            }]
          },
          "model_call": {
            "response_id": "resp_image_test",
            "model": "gpt-test",
            "prompt_version": "image-observations-v1",
            "schema_version": "1.0",
            "input_asset_sha256": "\(request.image.assetSHA256)",
            "output_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          }
        }
        """
    }

    private func assertClientError(
        _ expected: ImageObservationClientError,
        operation: () async throws -> ImageObservationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected image observation to fail", file: file, line: line)
        } catch let error as ImageObservationClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
        }
    }
}

private actor ImageObservationStubTransport: ImageObservationTransport {
    private let response: ImageObservationHTTPResponse
    private var capturedRequests: [URLRequest] = []

    init(responseData: Data, statusCode: Int? = 200) {
        response = ImageObservationHTTPResponse(data: responseData, statusCode: statusCode)
    }

    init(responseData: String, statusCode: Int? = 200) {
        response = ImageObservationHTTPResponse(data: Data(responseData.utf8), statusCode: statusCode)
    }

    func data(for request: URLRequest) async throws -> ImageObservationHTTPResponse {
        capturedRequests.append(request)
        return response
    }

    func requests() -> [URLRequest] {
        capturedRequests
    }
}
