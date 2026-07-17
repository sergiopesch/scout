import Foundation
@testable import Scout
import XCTest

final class ClaimExtractionClientTests: XCTestCase {
    func testPostsAuthenticatedContractAndDecodesEvidenceLinkedProposal() async throws {
        let transport = ClaimExtractionStubTransport(responseData: validResponseData())
        let client = ClaimExtractionClient(
            configuration: configuration,
            transport: transport
        )

        let result = try await client.extract(validRequest())

        XCTAssertEqual(result.proposal.schemaVersion, "1.0")
        XCTAssertEqual(result.proposal.claims.first?.predicate, .stores)
        XCTAssertEqual(result.proposal.claims.first?.epistemicStatus, .heard)
        XCTAssertEqual(result.modelCall.inputEventBoundary, 42)
        let claim = try XCTUnwrap(result.proposal.claims.first)
        XCTAssertEqual(result.evidenceIDs(for: claim, in: validRequest()), ["evidence-1"])

        let capturedRequests = await transport.requests()
        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://scout.example.test/v1/claims/extract")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString.contains(token)))

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["session_id"] as? String, "session-1")
        XCTAssertEqual(json["event_boundary"] as? Int, 42)
        let utterance = try XCTUnwrap((json["utterances"] as? [[String: Any]])?.first)
        XCTAssertEqual(utterance["utterance_id"] as? String, "utterance-1")
        XCTAssertEqual(utterance["evidence_id"] as? String, "evidence-1")
        XCTAssertTrue(utterance["speaker_id"] is NSNull)
        XCTAssertEqual(utterance["source"] as? String, "realtime")
    }

    func testRejectsInvalidUtteranceRangeBeforeNetworkIO() async {
        let transport = ClaimExtractionStubTransport(responseData: validResponseData())
        let client = ClaimExtractionClient(configuration: configuration, transport: transport)
        let invalid = ClaimExtractionRequest(
            sessionID: "session-1",
            eventBoundary: 42,
            utterances: [
                ClaimExtractionUtterance(
                    utteranceID: "utterance-1",
                    evidenceID: "evidence-1",
                    speakerID: nil,
                    text: "Inventory lives in NetSuite.",
                    startMilliseconds: 500,
                    endMilliseconds: 499,
                    source: .realtime
                ),
            ]
        )

        await assertClientError(
            .invalidRequest(.invalidUtteranceRange),
            from: { try await client.extract(invalid) }
        )
        let capturedRequests = await transport.requests()
        XCTAssertTrue(capturedRequests.isEmpty)
    }

    func testFailsClosedWhenProposalReferencesUnknownUtterance() async {
        let response = validResponseJSON().replacingOccurrences(
            of: "\"evidence_utterance_ids\": [\"utterance-1\"]",
            with: "\"evidence_utterance_ids\": [\"utterance-not-provided\"]"
        )
        let client = ClaimExtractionClient(
            configuration: configuration,
            transport: ClaimExtractionStubTransport(responseData: response)
        )

        await assertClientError(
            .invalidResponse(.invalidEvidenceReferences),
            from: { try await client.extract(self.validRequest()) }
        )
    }

    func testFailsClosedOnResponseRangeViolation() async {
        let response = validResponseJSON().replacingOccurrences(of: "\"confidence\": 0.98", with: "\"confidence\": 1.01")
        let client = ClaimExtractionClient(
            configuration: configuration,
            transport: ClaimExtractionStubTransport(responseData: response)
        )

        await assertClientError(
            .invalidResponse(.invalidConfidence),
            from: { try await client.extract(self.validRequest()) }
        )
    }

    func testFailsClosedOnUnknownSchemaMember() async {
        let response = validResponseJSON().replacingOccurrences(
            of: "\"proposal\":",
            with: "\"unexpected\":true,\"proposal\":"
        )
        let client = ClaimExtractionClient(
            configuration: configuration,
            transport: ClaimExtractionStubTransport(responseData: response)
        )

        await assertClientError(
            .invalidResponse(.schemaViolation),
            from: { try await client.extract(self.validRequest()) }
        )
    }

    func testFailsClosedWhenGatewayBoundaryDoesNotMatchInput() async {
        let response = validResponseJSON().replacingOccurrences(
            of: "\"input_event_boundary\": 42",
            with: "\"input_event_boundary\": 43"
        )
        let client = ClaimExtractionClient(
            configuration: configuration,
            transport: ClaimExtractionStubTransport(responseData: response)
        )

        await assertClientError(
            .invalidResponse(.mismatchedEventBoundary),
            from: { try await client.extract(self.validRequest()) }
        )
    }

    func testRequiresGatewayAuthenticationBeforeNetworkIO() async {
        let transport = ClaimExtractionStubTransport(responseData: validResponseData())
        let client = ClaimExtractionClient(
            configuration: BridgeConfiguration(authenticationToken: nil),
            transport: transport
        )

        await assertClientError(.missingAuthentication, from: { try await client.extract(self.validRequest()) })
        let capturedRequests = await transport.requests()
        XCTAssertTrue(capturedRequests.isEmpty)
    }

    func testDecodesScalarObjectValueWithoutNormalizingTheLiteral() async throws {
        let response = validResponseJSON().replacingOccurrences(
            of: "\"value\": null",
            with: "\"value\": \" 97.5% in Q4 \""
        )
        let client = ClaimExtractionClient(
            configuration: configuration,
            transport: ClaimExtractionStubTransport(responseData: response)
        )

        let result = try await client.extract(validRequest())

        XCTAssertEqual(result.proposal.claims.first?.object.value, " 97.5% in Q4 ")
    }

    private let token = String(repeating: "t", count: 64)

    private var configuration: BridgeConfiguration {
        BridgeConfiguration(
            baseURL: URL(string: "https://scout.example.test")!,
            authenticationToken: token
        )
    }

    private func validRequest() -> ClaimExtractionRequest {
        ClaimExtractionRequest(
            sessionID: "session-1",
            eventBoundary: 42,
            utterances: [
                ClaimExtractionUtterance(
                    utteranceID: "utterance-1",
                    evidenceID: "evidence-1",
                    speakerID: nil,
                    text: "Inventory lives in NetSuite.",
                    startMilliseconds: 100,
                    endMilliseconds: 2000,
                    source: .realtime
                ),
            ]
        )
    }

    private func validResponseData() -> Data {
        Data(
            """
            {
              "proposal": {
                "schema_version": "1.0",
                "claims": [{
                  "client_ref": "claim-1",
                  "subject": {"kind": "system", "name": "NetSuite"},
                  "predicate": "stores",
                  "object": {"kind": "data", "name": "Inventory", "value": null},
                  "epistemic_status": "heard",
                  "confidence": 0.98,
                  "evidence_utterance_ids": ["utterance-1"],
                  "rationale": "The customer stated this directly."
                }],
                "unresolved_terms": []
              },
              "model_call": {
                "response_id": "resp_test",
                "model": "gpt-test",
                "prompt_version": "claims-v1",
                "schema_version": "1.0",
                "input_event_boundary": 42,
                "output_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              }
            }
            """.utf8
        )
    }

    private func validResponseJSON() -> String {
        String(decoding: validResponseData(), as: UTF8.self)
    }

    private func assertClientError(
        _ expected: ClaimExtractionClientError,
        from operation: () async throws -> ClaimExtractionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected claim extraction to fail", file: file, line: line)
        } catch let error as ClaimExtractionClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
        }
    }
}

private actor ClaimExtractionStubTransport: ClaimExtractionTransport {
    private let response: ClaimExtractionHTTPResponse
    private var capturedRequests: [URLRequest] = []

    init(responseData: Data, statusCode: Int? = 200) {
        response = ClaimExtractionHTTPResponse(data: responseData, statusCode: statusCode)
    }

    init(responseData: String, statusCode: Int? = 200) {
        response = ClaimExtractionHTTPResponse(data: Data(responseData.utf8), statusCode: statusCode)
    }

    func data(for request: URLRequest) async throws -> ClaimExtractionHTTPResponse {
        capturedRequests.append(request)
        return response
    }

    func requests() -> [URLRequest] {
        capturedRequests
    }
}
