import Foundation
@testable import Scout
import XCTest

final class DiarizationClientTests: XCTestCase {
    func testAcceptsOrderedSegmentsBoundedByExactSubmittedPCM() async throws {
        let transport = DiarizationStubTransport(response: response(
            duration: 1,
            segments: [
                segment(id: "s0", start: 0, end: 0.4),
                segment(id: "s1", start: 0.4, end: 1),
            ]
        ))
        let client = DiarizationClient(configuration: configuration, transport: transport)

        let proposal = try await client.refine(pcm16: oneSecondPCM)

        XCTAssertEqual(proposal.duration, 1)
        XCTAssertEqual(proposal.segments.map(\.id), ["s0", "s1"])
        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://scout.example.test/v1/transcriptions/diarize")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    }

    func testRejectsSegmentBeyondExactPCMDuration() async {
        let client = client(response: response(
            duration: 1,
            segments: [segment(id: "s0", start: 0, end: 1.001)]
        ))

        await assertClientError(.invalidResponse) {
            try await client.refine(pcm16: self.oneSecondPCM)
        }
    }

    func testRejectsOverlappingOrUnorderedSegments() async {
        let client = client(response: response(
            duration: 1,
            segments: [
                segment(id: "s0", start: 0, end: 0.7),
                segment(id: "s1", start: 0.6, end: 0.9),
            ]
        ))

        await assertClientError(.invalidResponse) {
            try await client.refine(pcm16: self.oneSecondPCM)
        }
    }

    func testRejectsDuplicateSegmentIdentifiers() async {
        let client = client(response: response(
            duration: 1,
            segments: [
                segment(id: "same", start: 0, end: 0.4),
                segment(id: "same", start: 0.4, end: 0.9),
            ]
        ))

        await assertClientError(.invalidResponse) {
            try await client.refine(pcm16: self.oneSecondPCM)
        }
    }

    func testRejectsUnboundedSegmentCount() async {
        let segments = (0 ... 512).map { index in
            segment(id: "s\(index)", start: 0, end: 0)
        }
        let client = client(response: response(duration: 1, segments: segments))

        await assertClientError(.invalidResponse) {
            try await client.refine(pcm16: self.oneSecondPCM)
        }
    }

    func testRejectsOddLengthPCMBeforeNetwork() async {
        let transport = DiarizationStubTransport(response: Data())
        let client = DiarizationClient(configuration: configuration, transport: transport)

        await assertClientError(.invalidAudio) {
            try await client.refine(pcm16: Data(repeating: 0, count: 3))
        }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRejectsOversizedResponse() async {
        let transport = DiarizationStubTransport(response: Data(repeating: 0, count: 2 * 1024 * 1024 + 1))
        let client = DiarizationClient(configuration: configuration, transport: transport)

        await assertClientError(.invalidResponse) {
            try await client.refine(pcm16: self.oneSecondPCM)
        }
    }

    private let token = String(repeating: "t", count: 64)

    private var configuration: BridgeConfiguration {
        BridgeConfiguration(
            baseURL: URL(string: "https://scout.example.test")!,
            authenticationToken: token
        )
    }

    private var oneSecondPCM: Data {
        Data(repeating: 0, count: 24_000 * MemoryLayout<Int16>.size)
    }

    private func client(response: Data) -> DiarizationClient {
        DiarizationClient(
            configuration: configuration,
            transport: DiarizationStubTransport(response: response)
        )
    }

    private func response(duration: Double, segments: [String]) -> Data {
        Data(
            """
            {
              "revision_kind": "diarization_proposal",
              "model_call": {"model": "gpt-4o-transcribe-diarize"},
              "transcription": {
                "task": "transcribe",
                "duration": \(duration),
                "text": "A speaker described the current state.",
                "segments": [\(segments.joined(separator: ","))]
              }
            }
            """.utf8
        )
    }

    private func segment(id: String, start: Double, end: Double) -> String {
        """
        {"id":"\(id)","start":\(start),"end":\(end),"speaker":"speaker_0","text":"Observed speech."}
        """
    }

    private func assertClientError(
        _ expected: DiarizationClient.ClientError,
        operation: () async throws -> DiarizationProposal,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected diarization to fail", file: file, line: line)
        } catch let error as DiarizationClient.ClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
        }
    }
}

private actor DiarizationStubTransport: DiarizationTransport {
    private let response: DiarizationHTTPResponse
    private var capturedRequests: [URLRequest] = []

    init(response: Data, statusCode: Int? = 200) {
        self.response = .init(data: response, statusCode: statusCode)
    }

    func data(for request: URLRequest) async throws -> DiarizationHTTPResponse {
        capturedRequests.append(request)
        return response
    }

    func requests() -> [URLRequest] {
        capturedRequests
    }
}
