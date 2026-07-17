import Foundation

enum ClaimUtteranceSource: String, Codable, CaseIterable, Sendable {
    case realtime
    case diarizationRevision = "diarization_revision"
    case manual
}

struct ClaimExtractionUtterance: Encodable, Equatable, Sendable {
    let utteranceID: String
    let evidenceID: String
    let speakerID: String?
    let text: String
    let startMilliseconds: Int
    let endMilliseconds: Int
    let source: ClaimUtteranceSource

    enum CodingKeys: String, CodingKey {
        case utteranceID = "utterance_id"
        case evidenceID = "evidence_id"
        case speakerID = "speaker_id"
        case text
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(utteranceID, forKey: .utteranceID)
        try container.encode(evidenceID, forKey: .evidenceID)
        if let speakerID {
            try container.encode(speakerID, forKey: .speakerID)
        } else {
            try container.encodeNil(forKey: .speakerID)
        }
        try container.encode(text, forKey: .text)
        try container.encode(startMilliseconds, forKey: .startMilliseconds)
        try container.encode(endMilliseconds, forKey: .endMilliseconds)
        try container.encode(source, forKey: .source)
    }
}

struct ClaimExtractionRequest: Encodable, Equatable, Sendable {
    let sessionID: String
    let eventBoundary: Int
    let utterances: [ClaimExtractionUtterance]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case eventBoundary = "event_boundary"
        case utterances
    }
}

enum ClaimEntityKind: String, Decodable, CaseIterable, Sendable {
    case person
    case team
    case system
    case data
    case process
    case policy
    case goal
    case constraint
    case metric
    case action
    case value
    case externalParty = "external_party"
    case unknown
}

enum ClaimRelationshipPredicate: String, Decodable, CaseIterable, Sendable {
    case uses
    case owns
    case stores
    case readsFrom = "reads_from"
    case writesTo = "writes_to"
    case dependsOn = "depends_on"
    case handsOffTo = "hands_off_to"
    case governedBy = "governed_by"
    case constrainedBy = "constrained_by"
    case aimsTo = "aims_to"
    case measures
    case causes
    case blocks
    case enables
    case performs
    case requires
    case relatesTo = "relates_to"
}

enum ClaimEpistemicStatus: String, Decodable, CaseIterable, Sendable {
    case heard
    case inferred
}

struct ClaimProposalEntity: Decodable, Equatable, Sendable {
    let kind: ClaimEntityKind
    let name: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case name
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ClaimEntityKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
    }
}

struct ClaimProposalObject: Decodable, Equatable, Sendable {
    let kind: ClaimEntityKind
    let name: String
    let value: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case name
        case value
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.value) else {
            throw DecodingError.keyNotFound(
                CodingKeys.value,
                .init(codingPath: decoder.codingPath, debugDescription: "Required nullable value is missing")
            )
        }
        kind = try container.decode(ClaimEntityKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decodeIfPresent(String.self, forKey: .value)
    }
}

struct ProposedClaim: Decodable, Equatable, Sendable {
    let clientReference: String
    let subject: ClaimProposalEntity
    let predicate: ClaimRelationshipPredicate
    let object: ClaimProposalObject
    let epistemicStatus: ClaimEpistemicStatus
    let confidence: Double
    let evidenceUtteranceIDs: [String]
    let rationale: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case clientReference = "client_ref"
        case subject
        case predicate
        case object
        case epistemicStatus = "epistemic_status"
        case confidence
        case evidenceUtteranceIDs = "evidence_utterance_ids"
        case rationale
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientReference = try container.decode(String.self, forKey: .clientReference)
        subject = try container.decode(ClaimProposalEntity.self, forKey: .subject)
        predicate = try container.decode(ClaimRelationshipPredicate.self, forKey: .predicate)
        object = try container.decode(ClaimProposalObject.self, forKey: .object)
        epistemicStatus = try container.decode(ClaimEpistemicStatus.self, forKey: .epistemicStatus)
        confidence = try container.decode(Double.self, forKey: .confidence)
        evidenceUtteranceIDs = try container.decode([String].self, forKey: .evidenceUtteranceIDs)
        rationale = try container.decode(String.self, forKey: .rationale)
    }
}

struct UnresolvedClaimTerm: Decodable, Equatable, Sendable {
    let term: String
    let evidenceUtteranceIDs: [String]
    let reason: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case term
        case evidenceUtteranceIDs = "evidence_utterance_ids"
        case reason
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        term = try container.decode(String.self, forKey: .term)
        evidenceUtteranceIDs = try container.decode([String].self, forKey: .evidenceUtteranceIDs)
        reason = try container.decode(String.self, forKey: .reason)
    }
}

struct ClaimProposalBatch: Decodable, Equatable, Sendable {
    let schemaVersion: String
    let claims: [ProposedClaim]
    let unresolvedTerms: [UnresolvedClaimTerm]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case claims
        case unresolvedTerms = "unresolved_terms"
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        claims = try container.decode([ProposedClaim].self, forKey: .claims)
        unresolvedTerms = try container.decode([UnresolvedClaimTerm].self, forKey: .unresolvedTerms)
    }
}

struct ClaimModelCall: Decodable, Equatable, Sendable {
    let responseID: String
    let model: String
    let promptVersion: String
    let schemaVersion: String
    let inputEventBoundary: Int
    let outputSHA256: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case responseID = "response_id"
        case model
        case promptVersion = "prompt_version"
        case schemaVersion = "schema_version"
        case inputEventBoundary = "input_event_boundary"
        case outputSHA256 = "output_sha256"
    }

    init(
        responseID: String,
        model: String,
        promptVersion: String,
        schemaVersion: String,
        inputEventBoundary: Int,
        outputSHA256: String
    ) {
        self.responseID = responseID
        self.model = model
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.inputEventBoundary = inputEventBoundary
        self.outputSHA256 = outputSHA256
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        responseID = try container.decode(String.self, forKey: .responseID)
        model = try container.decode(String.self, forKey: .model)
        promptVersion = try container.decode(String.self, forKey: .promptVersion)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        inputEventBoundary = try container.decode(Int.self, forKey: .inputEventBoundary)
        outputSHA256 = try container.decode(String.self, forKey: .outputSHA256)
    }
}

struct ClaimExtractionResult: Decodable, Equatable, Sendable {
    let proposal: ClaimProposalBatch
    let modelCall: ClaimModelCall

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case proposal
        case modelCall = "model_call"
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proposal = try container.decode(ClaimProposalBatch.self, forKey: .proposal)
        modelCall = try container.decode(ClaimModelCall.self, forKey: .modelCall)
    }

    func evidenceIDs(for claim: ProposedClaim, in request: ClaimExtractionRequest) -> [String] {
        let evidenceByUtterance = Dictionary(
            uniqueKeysWithValues: request.utterances.map { ($0.utteranceID, $0.evidenceID) }
        )
        return claim.evidenceUtteranceIDs.compactMap { evidenceByUtterance[$0] }
    }
}

enum ClaimContractViolation: Equatable, Sendable {
    case invalidIdentifier
    case invalidEventBoundary
    case invalidUtteranceCount
    case duplicateUtteranceIdentifier
    case invalidUtteranceText
    case combinedTextTooLarge
    case invalidUtteranceRange
    case schemaViolation
    case unsupportedSchemaVersion
    case tooManyClaims
    case tooManyUnresolvedTerms
    case invalidClientReference
    case invalidEntity
    case invalidConfidence
    case invalidEvidenceReferences
    case duplicateEvidenceReferences
    case invalidRationale
    case invalidUnresolvedTerm
    case invalidModelMetadata
    case mismatchedEventBoundary
    case responseTooLarge
}

enum ClaimExtractionClientError: Error, LocalizedError, Equatable, Sendable {
    case missingAuthentication
    case invalidRequest(ClaimContractViolation)
    case transportFailure
    case invalidHTTPResponse
    case rejected(statusCode: Int)
    case invalidResponse(ClaimContractViolation)

    var errorDescription: String? {
        switch self {
        case .missingAuthentication:
            "Scout Bridge authentication is not configured. Launch Scout with `make run`."
        case .invalidRequest:
            "The claim extraction request does not satisfy Scout's evidence contract."
        case .transportFailure:
            "Scout could not reach the claim extraction bridge."
        case .invalidHTTPResponse:
            "Scout Bridge returned a non-HTTP response."
        case let .rejected(statusCode):
            "Claim extraction was rejected by Scout Bridge (HTTP \(statusCode))."
        case .invalidResponse:
            "Scout Bridge returned a claim proposal that failed closed validation."
        }
    }
}

struct ClaimExtractionHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int?
}

protocol ClaimExtractionTransport: Sendable {
    func data(for request: URLRequest) async throws -> ClaimExtractionHTTPResponse
}

struct URLSessionClaimExtractionTransport: ClaimExtractionTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> ClaimExtractionHTTPResponse {
        let (data, response) = try await session.data(for: request)
        return ClaimExtractionHTTPResponse(
            data: data,
            statusCode: (response as? HTTPURLResponse)?.statusCode
        )
    }
}

actor ClaimExtractionClient {
    private static let maximumResponseBytes = 2 * 1024 * 1024

    private let configuration: BridgeConfiguration
    private let transport: any ClaimExtractionTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        configuration: BridgeConfiguration = .fromEnvironment(),
        transport: any ClaimExtractionTransport = URLSessionClaimExtractionTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func extract(_ request: ClaimExtractionRequest) async throws -> ClaimExtractionResult {
        guard configuration.authenticationToken != nil else {
            throw ClaimExtractionClientError.missingAuthentication
        }
        if let violation = ClaimContract.validate(request) {
            throw ClaimExtractionClientError.invalidRequest(violation)
        }

        let endpoint = configuration.baseURL.appending(path: "v1/claims/extract")
        var urlRequest = try await configuration.authorizedRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 70
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try encoder.encode(request)

        let response: ClaimExtractionHTTPResponse
        do {
            response = try await transport.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClaimExtractionClientError.transportFailure
        }

        guard let statusCode = response.statusCode else {
            throw ClaimExtractionClientError.invalidHTTPResponse
        }
        guard statusCode == 200 else {
            throw ClaimExtractionClientError.rejected(statusCode: statusCode)
        }
        guard response.data.count <= Self.maximumResponseBytes else {
            throw ClaimExtractionClientError.invalidResponse(.responseTooLarge)
        }

        let result: ClaimExtractionResult
        do {
            result = try decoder.decode(ClaimExtractionResult.self, from: response.data)
        } catch {
            throw ClaimExtractionClientError.invalidResponse(.schemaViolation)
        }
        if let violation = ClaimContract.validate(result, against: request) {
            throw ClaimExtractionClientError.invalidResponse(violation)
        }
        return result
    }
}

private enum ClaimContract {
    static func validate(_ request: ClaimExtractionRequest) -> ClaimContractViolation? {
        guard isIdentifier(request.sessionID) else { return .invalidIdentifier }
        guard request.eventBoundary >= 0 else { return .invalidEventBoundary }
        guard (1 ... 100).contains(request.utterances.count) else { return .invalidUtteranceCount }

        let utteranceIDs = request.utterances.map(\.utteranceID)
        guard Set(utteranceIDs).count == utteranceIDs.count else { return .duplicateUtteranceIdentifier }

        var totalCharacters = 0
        for utterance in request.utterances {
            guard isIdentifier(utterance.utteranceID),
                  isIdentifier(utterance.evidenceID),
                  utterance.speakerID.map(isIdentifier) ?? true
            else { return .invalidIdentifier }

            let trimmedText = trimmed(utterance.text)
            guard !trimmedText.isEmpty, utf16Count(trimmedText) <= 4000 else {
                return .invalidUtteranceText
            }
            totalCharacters += utf16Count(trimmedText)
            guard utterance.startMilliseconds >= 0,
                  utterance.endMilliseconds >= utterance.startMilliseconds
            else { return .invalidUtteranceRange }
        }
        guard totalCharacters <= 60000 else { return .combinedTextTooLarge }
        return nil
    }

    static func validate(
        _ result: ClaimExtractionResult,
        against request: ClaimExtractionRequest
    ) -> ClaimContractViolation? {
        guard result.proposal.schemaVersion == "1.0" else { return .unsupportedSchemaVersion }
        guard result.proposal.claims.count <= 50 else { return .tooManyClaims }
        guard result.proposal.unresolvedTerms.count <= 25 else { return .tooManyUnresolvedTerms }

        let allowedEvidence = Set(request.utterances.map(\.utteranceID))
        for claim in result.proposal.claims {
            guard isClientReference(claim.clientReference) else { return .invalidClientReference }
            guard validEntity(claim.subject.kind, name: claim.subject.name),
                  validEntity(claim.object.kind, name: claim.object.name),
                  claim.object.value.map({ utf16Count($0) <= 4000 }) ?? true
            else { return .invalidEntity }
            guard claim.confidence.isFinite, (0 ... 1).contains(claim.confidence) else {
                return .invalidConfidence
            }
            guard (1 ... 8).contains(claim.evidenceUtteranceIDs.count),
                  claim.evidenceUtteranceIDs.allSatisfy(isIdentifier),
                  claim.evidenceUtteranceIDs.allSatisfy(allowedEvidence.contains)
            else { return .invalidEvidenceReferences }
            guard Set(claim.evidenceUtteranceIDs).count == claim.evidenceUtteranceIDs.count else {
                return .duplicateEvidenceReferences
            }
            guard isTrimmedText(claim.rationale, maximum: 1000) else { return .invalidRationale }
        }

        for unresolved in result.proposal.unresolvedTerms {
            guard isTrimmedText(unresolved.term, maximum: 240),
                  isTrimmedText(unresolved.reason, maximum: 500),
                  (1 ... 8).contains(unresolved.evidenceUtteranceIDs.count),
                  unresolved.evidenceUtteranceIDs.allSatisfy(isIdentifier),
                  unresolved.evidenceUtteranceIDs.allSatisfy(allowedEvidence.contains)
            else { return .invalidUnresolvedTerm }
        }

        guard result.modelCall.promptVersion == "claims-v1",
              result.modelCall.schemaVersion == "1.0",
              isLowercaseSHA256(result.modelCall.outputSHA256)
        else { return .invalidModelMetadata }
        guard result.modelCall.inputEventBoundary == request.eventBoundary else {
            return .mismatchedEventBoundary
        }
        return nil
    }

    private static func validEntity(_ kind: ClaimEntityKind, name: String) -> Bool {
        _ = kind
        return isTrimmedText(name, maximum: 240)
    }

    private static func isTrimmedText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value == trimmed(value) && utf16Count(value) <= maximum
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func utf16Count(_ value: String) -> Int {
        value.utf16.count
    }

    private static func isIdentifier(_ value: String) -> Bool {
        isASCIIIdentifier(value, maximum: 128, suffixPunctuation: [".", "_", ":", "-"])
    }

    private static func isClientReference(_ value: String) -> Bool {
        isASCIIIdentifier(value, maximum: 64, suffixPunctuation: [".", "_", "-"])
    }

    private static func isASCIIIdentifier(
        _ value: String,
        maximum: Int,
        suffixPunctuation: Set<Character>
    ) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximum, value.unicodeScalars.count == value.utf8.count,
              let first = value.first, first.isASCIIAlphaNumeric
        else { return false }
        return value.dropFirst().allSatisfy { $0.isASCIIAlphaNumeric || suffixPunctuation.contains($0) }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        guard let byte = asciiValue else { return false }
        return (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

private func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(
    in decoder: Decoder,
    known _: Keys.Type
) throws where Keys.AllCases: Collection {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let allowed = Set(Keys.allCases.map(\.stringValue))
    let unknown = Set(container.allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unexpected response member")
        )
    }
}
