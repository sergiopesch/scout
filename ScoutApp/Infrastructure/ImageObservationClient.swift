import CryptoKit
import Foundation

enum ImageObservationBasis: String, Decodable, CaseIterable, Sendable {
    case visible
    case inferred
}

enum ImageObservationNoteCategory: String, Decodable, CaseIterable, Sendable {
    case label
    case processStep = "process_step"
    case architecture
    case annotation
    case uncertainty
    case other
}

struct ImageObservationEntity: Decodable, Equatable, Sendable {
    let clientReference: String
    let kind: ClaimEntityKind
    let name: String
    let detail: String?
    let basis: ImageObservationBasis
    let confidence: Double
    let rationale: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case clientReference = "client_ref"
        case kind
        case name
        case detail
        case basis
        case confidence
        case rationale
    }

    init(from decoder: Decoder) throws {
        try imageRejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.detail) else {
            throw DecodingError.keyNotFound(
                CodingKeys.detail,
                .init(codingPath: decoder.codingPath, debugDescription: "Required nullable detail is missing")
            )
        }
        clientReference = try container.decode(String.self, forKey: .clientReference)
        kind = try container.decode(ClaimEntityKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        basis = try container.decode(ImageObservationBasis.self, forKey: .basis)
        confidence = try container.decode(Double.self, forKey: .confidence)
        rationale = try container.decode(String.self, forKey: .rationale)
    }
}

struct ImageObservationRelationship: Decodable, Equatable, Sendable {
    let clientReference: String
    let sourceClientReference: String
    let predicate: ClaimRelationshipPredicate
    let targetClientReference: String
    let basis: ImageObservationBasis
    let confidence: Double
    let rationale: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case clientReference = "client_ref"
        case sourceClientReference = "source_client_ref"
        case predicate
        case targetClientReference = "target_client_ref"
        case basis
        case confidence
        case rationale
    }

    init(from decoder: Decoder) throws {
        try imageRejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientReference = try container.decode(String.self, forKey: .clientReference)
        sourceClientReference = try container.decode(String.self, forKey: .sourceClientReference)
        predicate = try container.decode(ClaimRelationshipPredicate.self, forKey: .predicate)
        targetClientReference = try container.decode(String.self, forKey: .targetClientReference)
        basis = try container.decode(ImageObservationBasis.self, forKey: .basis)
        confidence = try container.decode(Double.self, forKey: .confidence)
        rationale = try container.decode(String.self, forKey: .rationale)
    }
}

struct ImageObservationNote: Decodable, Equatable, Sendable {
    let clientReference: String
    let category: ImageObservationNoteCategory
    let text: String
    let basis: ImageObservationBasis
    let confidence: Double

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case clientReference = "client_ref"
        case category
        case text
        case basis
        case confidence
    }

    init(from decoder: Decoder) throws {
        try imageRejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientReference = try container.decode(String.self, forKey: .clientReference)
        category = try container.decode(ImageObservationNoteCategory.self, forKey: .category)
        text = try container.decode(String.self, forKey: .text)
        basis = try container.decode(ImageObservationBasis.self, forKey: .basis)
        confidence = try container.decode(Double.self, forKey: .confidence)
    }
}

struct ImageObservationProposal: Decodable, Equatable, Sendable {
    let schemaVersion: String
    let evidenceAssetSHA256: String
    let entities: [ImageObservationEntity]
    let relationships: [ImageObservationRelationship]
    let notes: [ImageObservationNote]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case evidenceAssetSHA256 = "evidence_asset_sha256"
        case entities
        case relationships
        case notes
    }

    init(from decoder: Decoder) throws {
        try imageRejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        evidenceAssetSHA256 = try container.decode(String.self, forKey: .evidenceAssetSHA256)
        entities = try container.decode([ImageObservationEntity].self, forKey: .entities)
        relationships = try container.decode([ImageObservationRelationship].self, forKey: .relationships)
        notes = try container.decode([ImageObservationNote].self, forKey: .notes)
    }
}

struct ImageObservationModelCall: Decodable, Equatable, Sendable {
    let responseID: String
    let model: String
    let promptVersion: String
    let schemaVersion: String
    let inputAssetSHA256: String
    let outputSHA256: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case responseID = "response_id"
        case model
        case promptVersion = "prompt_version"
        case schemaVersion = "schema_version"
        case inputAssetSHA256 = "input_asset_sha256"
        case outputSHA256 = "output_sha256"
    }

    init(from decoder: Decoder) throws {
        try imageRejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        responseID = try container.decode(String.self, forKey: .responseID)
        model = try container.decode(String.self, forKey: .model)
        promptVersion = try container.decode(String.self, forKey: .promptVersion)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        inputAssetSHA256 = try container.decode(String.self, forKey: .inputAssetSHA256)
        outputSHA256 = try container.decode(String.self, forKey: .outputSHA256)
    }
}

struct ImageObservationResult: Decodable, Equatable, Sendable {
    let proposal: ImageObservationProposal
    let modelCall: ImageObservationModelCall

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case proposal
        case modelCall = "model_call"
    }

    init(from decoder: Decoder) throws {
        try imageRejectUnknownKeys(in: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proposal = try container.decode(ImageObservationProposal.self, forKey: .proposal)
        modelCall = try container.decode(ImageObservationModelCall.self, forKey: .modelCall)
    }
}

struct ImageObservationRequest: Equatable, Sendable {
    let sessionID: String
    let image: PreparedImageEvidence
}

enum ImageObservationContractViolation: Equatable, Sendable {
    case invalidSessionIdentifier
    case invalidAssetDigest
    case assetDigestMismatch
    case invalidImageBytes
    case invalidDimensions
    case schemaViolation
    case unsupportedSchemaVersion
    case evidenceDigestMismatch
    case tooManyProposals
    case invalidClientReference
    case duplicateClientReference
    case invalidEntity
    case invalidRelationshipReference
    case invalidNote
    case invalidConfidence
    case invalidModelMetadata
    case responseTooLarge
}

enum ImageObservationClientError: Error, LocalizedError, Equatable, Sendable {
    case missingAuthentication
    case invalidRequest(ImageObservationContractViolation)
    case transportFailure
    case invalidHTTPResponse
    case rejected(statusCode: Int)
    case invalidResponse(ImageObservationContractViolation)

    var errorDescription: String? {
        switch self {
        case .missingAuthentication:
            "Scout Bridge authentication is not configured. Launch Scout with `make run`."
        case .invalidRequest:
            "The image observation request does not satisfy Scout's evidence contract."
        case .transportFailure:
            "Scout could not reach the image observation bridge."
        case .invalidHTTPResponse:
            "Scout Bridge returned a non-HTTP image response."
        case let .rejected(statusCode):
            "Image observation was rejected by Scout Bridge (HTTP \(statusCode))."
        case .invalidResponse:
            "Scout Bridge returned an image proposal that failed closed validation."
        }
    }
}

struct ImageObservationHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int?
}

protocol ImageObservationTransport: Sendable {
    func data(for request: URLRequest) async throws -> ImageObservationHTTPResponse
}

struct URLSessionImageObservationTransport: ImageObservationTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> ImageObservationHTTPResponse {
        let (data, response) = try await session.data(for: request)
        return ImageObservationHTTPResponse(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode)
    }
}

actor ImageObservationClient {
    fileprivate static let maximumImageBytes = 8 * 1024 * 1024
    fileprivate static let maximumDimension = 4_096
    fileprivate static let maximumPixels = 16_777_216
    private static let maximumResponseBytes = 2 * 1024 * 1024

    private let configuration: BridgeConfiguration
    private let transport: any ImageObservationTransport
    private let decoder = JSONDecoder()

    init(
        configuration: BridgeConfiguration = .fromEnvironment(),
        transport: any ImageObservationTransport = URLSessionImageObservationTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    func observe(_ request: ImageObservationRequest) async throws -> ImageObservationResult {
        guard configuration.authenticationToken != nil else {
            throw ImageObservationClientError.missingAuthentication
        }
        if let violation = ImageObservationContract.validate(request) {
            throw ImageObservationClientError.invalidRequest(violation)
        }

        let boundary = "ScoutImageBoundary-\(UUID().uuidString)"
        let body = Self.multipartBody(for: request, boundary: boundary)
        let endpoint = configuration.baseURL.appending(path: "v1/images/observe")
        var urlRequest = try await configuration.authorizedRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 70
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = body

        let response: ImageObservationHTTPResponse
        do {
            response = try await transport.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImageObservationClientError.transportFailure
        }

        guard let statusCode = response.statusCode else {
            throw ImageObservationClientError.invalidHTTPResponse
        }
        guard statusCode == 200 else {
            throw ImageObservationClientError.rejected(statusCode: statusCode)
        }
        guard response.data.count <= Self.maximumResponseBytes else {
            throw ImageObservationClientError.invalidResponse(.responseTooLarge)
        }

        let result: ImageObservationResult
        do {
            result = try decoder.decode(ImageObservationResult.self, from: response.data)
        } catch {
            throw ImageObservationClientError.invalidResponse(.schemaViolation)
        }
        if let violation = ImageObservationContract.validate(result, against: request) {
            throw ImageObservationClientError.invalidResponse(violation)
        }
        return result
    }

    private static func multipartBody(for request: ImageObservationRequest, boundary: String) -> Data {
        var body = Data()
        appendField(name: "session_id", value: request.sessionID, boundary: boundary, to: &body)
        appendField(name: "asset_sha256", value: request.image.assetSHA256, boundary: boundary, to: &body)
        appendField(name: "pixel_width", value: String(request.image.pixelWidth), boundary: boundary, to: &body)
        appendField(name: "pixel_height", value: String(request.image.pixelHeight), boundary: boundary, to: &body)

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"evidence-\(request.image.assetSHA256.prefix(12)).jpg\"\r\n".utf8
        ))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(request.image.normalizedJPEG)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func appendField(name: String, value: String, boundary: String, to body: inout Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }
}

private enum ImageObservationContract {
    static func validate(_ request: ImageObservationRequest) -> ImageObservationContractViolation? {
        guard isIdentifier(request.sessionID) else { return .invalidSessionIdentifier }
        guard isSHA256(request.image.assetSHA256) else { return .invalidAssetDigest }
        guard sha256(request.image.normalizedJPEG) == request.image.assetSHA256 else { return .assetDigestMismatch }
        guard !request.image.normalizedJPEG.isEmpty,
              request.image.normalizedJPEG.count <= ImageObservationClient.maximumImageBytes,
              request.image.mimeType == "image/jpeg",
              request.image.normalizedJPEG.starts(with: Data([0xff, 0xd8])),
              request.image.normalizedJPEG.suffix(2).elementsEqual(Data([0xff, 0xd9]))
        else { return .invalidImageBytes }
        guard request.image.pixelWidth > 0,
              request.image.pixelHeight > 0,
              request.image.pixelWidth <= ImageObservationClient.maximumDimension,
              request.image.pixelHeight <= ImageObservationClient.maximumDimension,
              let pixels = safeProduct(request.image.pixelWidth, request.image.pixelHeight),
              pixels <= ImageObservationClient.maximumPixels
        else { return .invalidDimensions }
        return nil
    }

    static func validate(
        _ result: ImageObservationResult,
        against request: ImageObservationRequest
    ) -> ImageObservationContractViolation? {
        guard result.proposal.schemaVersion == "1.0" else { return .unsupportedSchemaVersion }
        guard result.proposal.evidenceAssetSHA256 == request.image.assetSHA256,
              result.modelCall.inputAssetSHA256 == request.image.assetSHA256
        else { return .evidenceDigestMismatch }
        guard result.proposal.entities.count <= 100,
              result.proposal.relationships.count <= 150,
              result.proposal.notes.count <= 100
        else { return .tooManyProposals }

        let entityReferences = result.proposal.entities.map(\.clientReference)
        guard Set(entityReferences).count == entityReferences.count else { return .duplicateClientReference }
        let knownEntities = Set(entityReferences)

        for entity in result.proposal.entities {
            guard isClientReference(entity.clientReference) else { return .invalidClientReference }
            guard isTrimmedText(entity.name, maximum: 240),
                  entity.detail.map({ isTrimmedText($0, maximum: 1_000) }) ?? true,
                  isTrimmedText(entity.rationale, maximum: 1_000)
            else { return .invalidEntity }
            guard validConfidence(entity.confidence) else { return .invalidConfidence }
        }

        let relationshipReferences = result.proposal.relationships.map(\.clientReference)
        guard Set(relationshipReferences).count == relationshipReferences.count else {
            return .duplicateClientReference
        }
        for relationship in result.proposal.relationships {
            guard isClientReference(relationship.clientReference),
                  isClientReference(relationship.sourceClientReference),
                  isClientReference(relationship.targetClientReference)
            else { return .invalidClientReference }
            guard knownEntities.contains(relationship.sourceClientReference),
                  knownEntities.contains(relationship.targetClientReference)
            else { return .invalidRelationshipReference }
            guard isTrimmedText(relationship.rationale, maximum: 1_000) else { return .invalidEntity }
            guard validConfidence(relationship.confidence) else { return .invalidConfidence }
        }

        let noteReferences = result.proposal.notes.map(\.clientReference)
        guard Set(noteReferences).count == noteReferences.count else { return .duplicateClientReference }
        for note in result.proposal.notes {
            guard isClientReference(note.clientReference) else { return .invalidClientReference }
            guard isTrimmedText(note.text, maximum: 2_000) else { return .invalidNote }
            guard validConfidence(note.confidence) else { return .invalidConfidence }
        }

        guard result.modelCall.promptVersion == "image-observations-v1",
              result.modelCall.schemaVersion == "1.0",
              !result.modelCall.responseID.isEmpty,
              !result.modelCall.model.isEmpty,
              isSHA256(result.modelCall.outputSHA256)
        else { return .invalidModelMetadata }
        return nil
    }

    private static func validConfidence(_ value: Double) -> Bool {
        value.isFinite && (0 ... 1).contains(value)
    }

    private static func isTrimmedText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf16.count <= maximum
    }

    private static func isIdentifier(_ value: String) -> Bool {
        isASCIIIdentifier(value, maximum: 128, punctuation: [".", "_", ":", "-"])
    }

    private static func isClientReference(_ value: String) -> Bool {
        isASCIIIdentifier(value, maximum: 64, punctuation: [".", "_", "-"])
    }

    private static func isASCIIIdentifier(
        _ value: String,
        maximum: Int,
        punctuation: Set<Character>
    ) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximum,
              value.unicodeScalars.count == value.utf8.count,
              let first = value.first,
              first.imageIsASCIIAlphaNumeric
        else { return false }
        return value.dropFirst().allSatisfy { $0.imageIsASCIIAlphaNumeric || punctuation.contains($0) }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    private static func safeProduct(_ left: Int, _ right: Int) -> Int? {
        let (value, overflow) = left.multipliedReportingOverflow(by: right)
        return overflow ? nil : value
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Character {
    var imageIsASCIIAlphaNumeric: Bool {
        guard let byte = asciiValue else { return false }
        return (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }
}

private struct ImageAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

private func imageRejectUnknownKeys<Keys: CodingKey & CaseIterable>(
    in decoder: Decoder,
    known _: Keys.Type
) throws where Keys.AllCases: Collection {
    let container = try decoder.container(keyedBy: ImageAnyCodingKey.self)
    let allowed = Set(Keys.allCases.map(\.stringValue))
    let unknown = Set(container.allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unexpected image proposal member")
        )
    }
}
