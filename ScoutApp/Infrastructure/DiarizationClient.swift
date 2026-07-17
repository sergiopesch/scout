import Foundation

struct DiarizationProposal: Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        let id: String
        let start: Double
        let end: Double
        let speaker: String
        let text: String
    }

    let model: String
    /// Exact duration derived from the submitted PCM, never trusted from the
    /// remote response.
    let duration: Double
    let text: String
    let segments: [Segment]
}

struct DiarizationHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int?
}

protocol DiarizationTransport: Sendable {
    func data(for request: URLRequest) async throws -> DiarizationHTTPResponse
}

struct URLSessionDiarizationTransport: DiarizationTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> DiarizationHTTPResponse {
        let (data, response) = try await session.data(for: request)
        return .init(
            data: data,
            statusCode: (response as? HTTPURLResponse)?.statusCode
        )
    }
}

actor DiarizationClient {
    enum ClientError: LocalizedError, Equatable, Sendable {
        case missingAuthentication
        case invalidAudio
        case transportFailure
        case invalidHTTPResponse
        case rejected(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAuthentication: "Scout Bridge authentication is not configured. Launch Scout with `make run`."
            case .invalidAudio: "The finalized audio turn is empty, malformed, or too large to refine."
            case .transportFailure: "Scout could not reach the speaker-refinement bridge."
            case .invalidHTTPResponse: "Scout Bridge returned a non-HTTP speaker-refinement response."
            case let .rejected(status): "Speaker refinement was rejected by Scout Bridge (HTTP \(status))."
            case .invalidResponse: "Scout Bridge returned an invalid speaker refinement."
            }
        }
    }

    private struct ResponseEnvelope: Decodable {
        let revisionKind: String
        let modelCall: ModelCall
        let transcription: Transcription

        struct ModelCall: Decodable { let model: String }
        struct Transcription: Decodable {
            let task: String
            let duration: Double
            let text: String
            let segments: [DiarizationProposal.Segment]
        }
    }

    private static let sampleRate = 24_000
    private static let bytesPerSample = MemoryLayout<Int16>.size
    private static let maximumAudioBytes = sampleRate * bytesPerSample * 60
    private static let maximumResponseBytes = 2 * 1024 * 1024
    private static let maximumSegments = 512
    private static let maximumSegmentTextBytes = 16 * 1024
    private static let maximumCombinedTextBytes = 256 * 1024
    private static let maximumIdentifierBytes = 128
    private static let timeEpsilon = 0.000_001

    private let configuration: BridgeConfiguration
    private let transport: any DiarizationTransport
    private let decoder: JSONDecoder

    init(
        configuration: BridgeConfiguration = .fromEnvironment(),
        transport: any DiarizationTransport = URLSessionDiarizationTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func refine(pcm16: Data, language: String? = "en") async throws -> DiarizationProposal {
        guard configuration.authenticationToken != nil else { throw ClientError.missingAuthentication }
        guard !pcm16.isEmpty,
              pcm16.count <= Self.maximumAudioBytes,
              pcm16.count.isMultiple(of: Self.bytesPerSample)
        else { throw ClientError.invalidAudio }

        let sampleCount = pcm16.count / Self.bytesPerSample
        guard sampleCount > 0 else { throw ClientError.invalidAudio }
        let exactDuration = Double(sampleCount) / Double(Self.sampleRate)
        guard exactDuration.isFinite, exactDuration > 0 else { throw ClientError.invalidAudio }

        let boundary = "ScoutBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let endpoint = configuration.baseURL.appending(path: "v1/transcriptions/diarize")
        var request = try await configuration.authorizedRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 70
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.multipartBody(
            wav: try Self.waveData(pcm16: pcm16),
            boundary: boundary,
            language: language
        )

        let response: DiarizationHTTPResponse
        do {
            response = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClientError.transportFailure
        }
        guard let statusCode = response.statusCode else { throw ClientError.invalidHTTPResponse }
        guard statusCode == 200 else { throw ClientError.rejected(statusCode) }
        guard response.data.count <= Self.maximumResponseBytes,
              let decoded = try? decoder.decode(ResponseEnvelope.self, from: response.data),
              Self.isValid(decoded, exactDuration: exactDuration)
        else { throw ClientError.invalidResponse }

        // A tiny binary-floating-point epsilon is accepted at the transport
        // boundary and then clamped away. Downstream code only sees segments
        // within the exact submitted PCM duration.
        let boundedSegments = decoded.transcription.segments.map { segment in
            DiarizationProposal.Segment(
                id: segment.id,
                start: min(segment.start, exactDuration),
                end: min(segment.end, exactDuration),
                speaker: segment.speaker,
                text: segment.text
            )
        }
        return DiarizationProposal(
            model: decoded.modelCall.model,
            duration: exactDuration,
            text: decoded.transcription.text,
            segments: boundedSegments
        )
    }

    private static func isValid(_ decoded: ResponseEnvelope, exactDuration: Double) -> Bool {
        guard decoded.revisionKind == "diarization_proposal",
              decoded.transcription.task == "transcribe",
              decoded.transcription.duration.isFinite,
              decoded.transcription.duration >= 0,
              abs(decoded.transcription.duration - exactDuration) <= max(0.05, exactDuration * 0.01),
              !decoded.modelCall.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.modelCall.model.utf8.count <= maximumIdentifierBytes,
              decoded.transcription.text.utf8.count <= maximumCombinedTextBytes,
              decoded.transcription.segments.count <= maximumSegments
        else { return false }

        var priorEnd = 0.0
        var identifiers = Set<String>()
        var combinedTextBytes = 0
        for segment in decoded.transcription.segments {
            let identifier = segment.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty,
                  !speaker.isEmpty,
                  identifier.utf8.count <= maximumIdentifierBytes,
                  speaker.utf8.count <= maximumIdentifierBytes,
                  identifiers.insert(identifier).inserted,
                  segment.start.isFinite,
                  segment.end.isFinite,
                  segment.start >= 0,
                  segment.end >= segment.start,
                  segment.start + timeEpsilon >= priorEnd,
                  segment.end <= exactDuration + timeEpsilon,
                  segment.text.utf8.count <= maximumSegmentTextBytes
            else { return false }

            let (newTotal, overflow) = combinedTextBytes.addingReportingOverflow(segment.text.utf8.count)
            guard !overflow, newTotal <= maximumCombinedTextBytes else { return false }
            combinedTextBytes = newTotal
            priorEnd = segment.end
        }
        return true
    }

    private static func multipartBody(wav: Data, boundary: String, language: String?) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }

        if let language {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"chunking_strategy\"\r\n\r\n")
        append("auto\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"turn.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func waveData(pcm16: Data) throws -> Data {
        guard let riffSize = UInt32(exactly: 36 + pcm16.count),
              let dataSize = UInt32(exactly: pcm16.count)
        else { throw ClientError.invalidAudio }

        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.appendLittleEndian(riffSize)
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(UInt32(sampleRate * bytesPerSample))
        wav.appendLittleEndian(UInt16(bytesPerSample))
        wav.appendLittleEndian(UInt16(16))
        wav.append(Data("data".utf8))
        wav.appendLittleEndian(dataSize)
        wav.append(pcm16)
        return wav
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
