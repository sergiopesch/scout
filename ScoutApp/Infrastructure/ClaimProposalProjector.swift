import CryptoKit
import Foundation

enum ClaimProposalProjectionError: Error, Equatable {
    case unsupportedSchemaVersion(String)
    case mismatchedEventBoundary(expected: Int, actual: Int)
    case duplicateUtteranceIdentifier(String)
    case invalidClaimReference(String)
    case invalidEntityName(String)
    case invalidConfidence(String)
    case missingEvidenceUtterance(String)
    case missingEvidenceIdentifier(String)
}

/// Evidence retained alongside a UI projection. The UI-domain types intentionally remain
/// lightweight; this record keeps their complete, immutable grounding available to the trust UI.
struct ProjectionEvidenceLink: Equatable, Sendable {
    let projectionID: String
    let projectedClaimIDs: [String]
    let clientReferences: [String]
    let evidenceUtteranceIDs: [String]
    let evidenceIDs: [String]
}

/// Provenance for one deduplicated claim projection, including the exact model-call boundary.
struct ClaimProjectionProvenance: Equatable, Sendable {
    let projectedClaimID: String
    let clientReferences: [String]
    let evidenceUtteranceIDs: [String]
    let evidenceIDs: [String]
    let rationales: [String]
    /// The exact, structured scalar supplied for the proposal object. This is domain data,
    /// not display text: the commit planner uses it to preserve literal claim semantics.
    let objectValue: String?
    let modelCall: ClaimModelCall

    init(
        projectedClaimID: String,
        clientReferences: [String],
        evidenceUtteranceIDs: [String],
        evidenceIDs: [String],
        rationales: [String],
        objectValue: String? = nil,
        modelCall: ClaimModelCall
    ) {
        self.projectedClaimID = projectedClaimID
        self.clientReferences = clientReferences
        self.evidenceUtteranceIDs = evidenceUtteranceIDs
        self.evidenceIDs = evidenceIDs
        self.rationales = rationales
        self.objectValue = objectValue
        self.modelCall = modelCall
    }
}

struct ClaimProposalProjection: Equatable, Sendable {
    let modelCall: ClaimModelCall
    let entities: [GraphEntity]
    let relationships: [GraphRelationship]
    let claims: [TrustClaim]
    let entityEvidence: [ProjectionEvidenceLink]
    let relationshipEvidence: [ProjectionEvidenceLink]
    let claimProvenance: [ClaimProjectionProvenance]
}

/// A deterministic adapter from validated model proposals into Scout's read-only UI projection.
///
/// The projector does not commit events or mutate a workspace. Model-provided identifiers are kept
/// only as provenance; every UI identifier is derived from canonical semantic content.
struct ClaimProposalProjector {
    func project(
        _ result: ClaimExtractionResult,
        for request: ClaimExtractionRequest,
        speakerNamesByID: [String: String] = [:]
    ) throws -> ClaimProposalProjection {
        guard result.proposal.schemaVersion == "1.0" else {
            throw ClaimProposalProjectionError.unsupportedSchemaVersion(result.proposal.schemaVersion)
        }
        guard result.modelCall.inputEventBoundary == request.eventBoundary else {
            throw ClaimProposalProjectionError.mismatchedEventBoundary(
                expected: request.eventBoundary,
                actual: result.modelCall.inputEventBoundary
            )
        }

        let utterances = try indexedUtterances(request.utterances)
        var entityAccumulators: [String: EntityAccumulator] = [:]
        var relationshipAccumulators: [String: RelationshipAccumulator] = [:]
        var claimAccumulators: [String: ClaimAccumulator] = [:]

        for proposal in result.proposal.claims {
            let clientReference = proposal.clientReference
            guard !clientReference.isEmpty else {
                throw ClaimProposalProjectionError.invalidClaimReference(clientReference)
            }
            guard proposal.confidence.isFinite, (0 ... 1).contains(proposal.confidence) else {
                throw ClaimProposalProjectionError.invalidConfidence(clientReference)
            }

            let subject = try entityDescriptor(kind: proposal.subject.kind, name: proposal.subject.name)
            let object = try entityDescriptor(kind: proposal.object.kind, name: proposal.object.name)
            let evidence = try resolvedEvidence(
                proposal.evidenceUtteranceIDs,
                from: utterances,
                clientReference: clientReference
            )
            let claimKey = ScoutStableContentIdentity.canonical([
                "claim-v1",
                subject.semanticKey,
                proposal.predicate.rawValue,
                object.semanticKey,
                proposal.object.value.map {
                    "literal:\(ScoutStableContentIdentity.normalized($0))"
                } ?? "entity-object",
                proposal.epistemicStatus.rawValue,
            ])
            let claimID = ScoutStableContentIdentity.identifier(prefix: "claim", canonical: claimKey)
            let relationshipKey = ScoutStableContentIdentity.canonical([
                "relationship-v1",
                subject.semanticKey,
                proposal.predicate.rawValue,
                object.semanticKey,
            ])
            let relationshipID = ScoutStableContentIdentity.identifier(
                prefix: "relationship",
                canonical: relationshipKey
            )

            entityAccumulators[subject.semanticKey, default: EntityAccumulator(descriptor: subject)]
                .include(
                    displayName: subject.displayName,
                    proposal: proposal,
                    projectedClaimID: claimID,
                    evidence: evidence
                )
            entityAccumulators[object.semanticKey, default: EntityAccumulator(descriptor: object)]
                .include(
                    displayName: object.displayName,
                    proposal: proposal,
                    projectedClaimID: claimID,
                    evidence: evidence
                )

            relationshipAccumulators[relationshipKey, default: RelationshipAccumulator(
                id: relationshipID,
                sourceKey: subject.semanticKey,
                targetKey: object.semanticKey,
                predicate: proposal.predicate,
                sourceKind: subject.kind,
                targetKind: object.kind
            )].include(
                proposal: proposal,
                projectedClaimID: claimID,
                evidence: evidence
            )

            claimAccumulators[claimKey, default: ClaimAccumulator(
                id: claimID,
                subject: subject,
                object: object,
                predicate: proposal.predicate,
                epistemicStatus: proposal.epistemicStatus,
                objectValue: proposal.object.value
            )].include(proposal: proposal, evidence: evidence)
        }

        let entitiesByKey = entityAccumulators.mapValues { accumulator in
            accumulator.makeEntity()
        }
        let entities = entitiesByKey.values.sorted { $0.id < $1.id }

        let relationships: [GraphRelationship] = relationshipAccumulators.values.compactMap { accumulator -> GraphRelationship? in
            guard let source = entitiesByKey[accumulator.sourceKey],
                  let target = entitiesByKey[accumulator.targetKey]
            else { return nil }
            return accumulator.makeRelationship(sourceID: source.id, targetID: target.id)
        }.sorted { $0.id < $1.id }

        let claims = claimAccumulators.values.map { accumulator in
            accumulator.makeClaim(
                utterances: utterances,
                speakerNamesByID: speakerNamesByID,
                relatedEntityID: entitiesByKey[accumulator.subject.semanticKey]?.id
            )
        }.sorted { $0.id < $1.id }

        let entityEvidence: [ProjectionEvidenceLink] = entityAccumulators.compactMap { element -> ProjectionEvidenceLink? in
            let (key, accumulator) = element
            guard let entity = entitiesByKey[key] else { return nil }
            return accumulator.makeEvidenceLink(projectionID: entity.id)
        }.sorted { $0.projectionID < $1.projectionID }

        let relationshipEvidence = relationshipAccumulators.values.map {
            $0.makeEvidenceLink()
        }.sorted { $0.projectionID < $1.projectionID }

        let claimProvenance = claimAccumulators.values.map {
            $0.makeProvenance(modelCall: result.modelCall)
        }.sorted { $0.projectedClaimID < $1.projectedClaimID }

        return ClaimProposalProjection(
            modelCall: result.modelCall,
            entities: entities,
            relationships: relationships,
            claims: claims,
            entityEvidence: entityEvidence,
            relationshipEvidence: relationshipEvidence,
            claimProvenance: claimProvenance
        )
    }

    private func indexedUtterances(
        _ values: [ClaimExtractionUtterance]
    ) throws -> [String: ClaimExtractionUtterance] {
        var result: [String: ClaimExtractionUtterance] = [:]
        for utterance in values {
            guard result[utterance.utteranceID] == nil else {
                throw ClaimProposalProjectionError.duplicateUtteranceIdentifier(utterance.utteranceID)
            }
            guard !utterance.evidenceID.isEmpty else {
                throw ClaimProposalProjectionError.missingEvidenceIdentifier(utterance.utteranceID)
            }
            result[utterance.utteranceID] = utterance
        }
        return result
    }

    private func resolvedEvidence(
        _ identifiers: [String],
        from utterances: [String: ClaimExtractionUtterance],
        clientReference: String
    ) throws -> [ClaimExtractionUtterance] {
        guard !identifiers.isEmpty else {
            throw ClaimProposalProjectionError.invalidClaimReference(clientReference)
        }
        var seen: Set<String> = []
        return try identifiers.map { identifier in
            guard seen.insert(identifier).inserted else {
                throw ClaimProposalProjectionError.invalidClaimReference(clientReference)
            }
            guard let utterance = utterances[identifier] else {
                throw ClaimProposalProjectionError.missingEvidenceUtterance(identifier)
            }
            return utterance
        }.sorted {
            ($0.startMilliseconds, $0.utteranceID) < ($1.startMilliseconds, $1.utteranceID)
        }
    }

    private func entityDescriptor(
        kind: ClaimEntityKind,
        name: String
    ) throws -> EntityDescriptor {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name else {
            throw ClaimProposalProjectionError.invalidEntityName(name)
        }
        return EntityDescriptor(kind: kind, displayName: name)
    }
}

private struct EntityDescriptor {
    let kind: ClaimEntityKind
    let displayName: String

    var semanticKey: String {
        ScoutStableContentIdentity.canonical([
            "entity-v1",
            kind.rawValue,
            ScoutStableContentIdentity.normalized(displayName),
        ])
    }
}

private struct EntityAccumulator {
    let descriptor: EntityDescriptor
    private(set) var displayNames: Set<String> = []
    private(set) var confidence: Double = 0
    private(set) var statuses: Set<ClaimEpistemicStatus> = []
    private(set) var claimIDs: Set<String> = []
    private(set) var clientReferences: Set<String> = []
    private(set) var utteranceIDs: Set<String> = []
    private(set) var evidenceIDs: Set<String> = []

    init(descriptor: EntityDescriptor) {
        self.descriptor = descriptor
        displayNames.insert(descriptor.displayName)
    }

    mutating func include(
        displayName: String,
        proposal: ProposedClaim,
        projectedClaimID: String,
        evidence: [ClaimExtractionUtterance]
    ) {
        displayNames.insert(displayName)
        confidence = max(confidence, proposal.confidence)
        statuses.insert(proposal.epistemicStatus)
        claimIDs.insert(projectedClaimID)
        clientReferences.insert(proposal.clientReference)
        utteranceIDs.formUnion(evidence.map(\.utteranceID))
        evidenceIDs.formUnion(evidence.map(\.evidenceID))
    }

    func makeEntity() -> GraphEntity {
        let title = displayNames.sorted().first ?? descriptor.displayName
        let entityID = ScoutStableContentIdentity.identifier(
            prefix: "entity",
            canonical: descriptor.semanticKey
        )
        let kind = descriptor.kind.uiKind
        let point = ScoutStableContentIdentity.layoutPoint(for: descriptor.semanticKey, kind: kind)
        return GraphEntity(
            id: entityID,
            title: title,
            subtitle: descriptor.kind.uiSubtitle,
            kind: kind,
            x: point.x,
            y: point.y,
            // A provider classification is provenance about the proposal, not authority to
            // promote model output into customer-confirmed graph state.
            provenance: .proposed,
            confidence: confidence
        )
    }

    func makeEvidenceLink(projectionID: String) -> ProjectionEvidenceLink {
        ProjectionEvidenceLink(
            projectionID: projectionID,
            projectedClaimIDs: claimIDs.sorted(),
            clientReferences: clientReferences.sorted(),
            evidenceUtteranceIDs: utteranceIDs.sorted(),
            evidenceIDs: evidenceIDs.sorted()
        )
    }
}

private struct RelationshipAccumulator {
    let id: String
    let sourceKey: String
    let targetKey: String
    let predicate: ClaimRelationshipPredicate
    let sourceKind: ClaimEntityKind
    let targetKind: ClaimEntityKind
    private(set) var confidence: Double = 0
    private(set) var claimIDs: Set<String> = []
    private(set) var clientReferences: Set<String> = []
    private(set) var utteranceIDs: Set<String> = []
    private(set) var evidenceIDs: Set<String> = []

    mutating func include(
        proposal: ProposedClaim,
        projectedClaimID: String,
        evidence: [ClaimExtractionUtterance]
    ) {
        confidence = max(confidence, proposal.confidence)
        claimIDs.insert(projectedClaimID)
        clientReferences.insert(proposal.clientReference)
        utteranceIDs.formUnion(evidence.map(\.utteranceID))
        evidenceIDs.formUnion(evidence.map(\.evidenceID))
    }

    func makeRelationship(sourceID: String, targetID: String) -> GraphRelationship {
        GraphRelationship(
            id: id,
            sourceID: sourceID,
            targetID: targetID,
            label: predicate.uiLabel,
            confidence: confidence,
            isFriction: predicate == .blocks
                || predicate == .constrainedBy
                || sourceKind == .constraint
                || targetKind == .constraint,
            provenance: .proposed,
            needsValidation: true,
            supportingClaimIDs: claimIDs.sorted(),
            evidenceIDs: evidenceIDs.sorted()
        )
    }

    func makeEvidenceLink() -> ProjectionEvidenceLink {
        ProjectionEvidenceLink(
            projectionID: id,
            projectedClaimIDs: claimIDs.sorted(),
            clientReferences: clientReferences.sorted(),
            evidenceUtteranceIDs: utteranceIDs.sorted(),
            evidenceIDs: evidenceIDs.sorted()
        )
    }
}

private struct ClaimAccumulator {
    let id: String
    let subject: EntityDescriptor
    let object: EntityDescriptor
    let predicate: ClaimRelationshipPredicate
    let epistemicStatus: ClaimEpistemicStatus
    private(set) var objectValues: Set<String>
    private(set) var subjectDisplayNames: Set<String>
    private(set) var objectDisplayNames: Set<String>
    private(set) var confidence: Double = 0
    private(set) var clientReferences: Set<String> = []
    private(set) var rationales: Set<String> = []
    private(set) var utteranceIDs: Set<String> = []
    private(set) var evidenceIDs: Set<String> = []

    init(
        id: String,
        subject: EntityDescriptor,
        object: EntityDescriptor,
        predicate: ClaimRelationshipPredicate,
        epistemicStatus: ClaimEpistemicStatus,
        objectValue: String?
    ) {
        self.id = id
        self.subject = subject
        self.object = object
        self.predicate = predicate
        self.epistemicStatus = epistemicStatus
        objectValues = objectValue.map { Set([$0]) } ?? []
        subjectDisplayNames = [subject.displayName]
        objectDisplayNames = [object.displayName]
    }

    mutating func include(proposal: ProposedClaim, evidence: [ClaimExtractionUtterance]) {
        subjectDisplayNames.insert(proposal.subject.name)
        objectDisplayNames.insert(proposal.object.name)
        confidence = max(confidence, proposal.confidence)
        clientReferences.insert(proposal.clientReference)
        rationales.insert(proposal.rationale)
        utteranceIDs.formUnion(evidence.map(\.utteranceID))
        evidenceIDs.formUnion(evidence.map(\.evidenceID))
        if let objectValue = proposal.object.value {
            objectValues.insert(objectValue)
        }
    }

    /// All values in one accumulator have the same normalized semantic identity. Selecting the
    /// bytewise-first observed literal makes replay independent of proposal ordering while still
    /// retaining an exact model-supplied value rather than reconstructing it from display text.
    private var objectValue: String? {
        objectValues.sorted().first
    }

    func makeClaim(
        utterances: [String: ClaimExtractionUtterance],
        speakerNamesByID: [String: String],
        relatedEntityID: String?
    ) -> TrustClaim {
        let evidence = utteranceIDs.compactMap { utterances[$0] }.sorted {
            ($0.startMilliseconds, $0.utteranceID) < ($1.startMilliseconds, $1.utteranceID)
        }
        let speakers = Set(evidence.map { utterance -> String in
            guard let speakerID = utterance.speakerID else { return "Unresolved speaker" }
            return speakerNamesByID[speakerID] ?? speakerID
        }).sorted()
        let rationale = rationales.sorted().first ?? "Evidence-linked relationship."
        let valueDetail = objectValue.map { " Value: \($0)." } ?? ""
        let subjectName = subjectDisplayNames.sorted().first ?? subject.displayName
        let objectName = objectDisplayNames.sorted().first ?? object.displayName
        let statement = "\(subjectName) \(predicate.uiLabel) \(objectName)."

        return TrustClaim(
            id: id,
            title: "\(subjectName) \(predicate.uiLabel) \(objectName)",
            detail: "\(statement)\(valueDetail) \(rationale)",
            // `epistemicStatus` and confidence are model-owned hints retained in proposal
            // provenance. Only a deterministic Scout review event may assign factual authority.
            provenance: .proposed,
            confidence: confidence,
            evidenceQuote: evidence.map(\.text).joined(separator: " · "),
            speakerName: speakers.joined(separator: ", "),
            timestamp: evidence.first.map { Self.timestamp(milliseconds: $0.startMilliseconds) } ?? "00:00",
            relatedEntityID: relatedEntityID,
            needsValidation: true
        )
    }

    func makeProvenance(modelCall: ClaimModelCall) -> ClaimProjectionProvenance {
        ClaimProjectionProvenance(
            projectedClaimID: id,
            clientReferences: clientReferences.sorted(),
            evidenceUtteranceIDs: utteranceIDs.sorted(),
            evidenceIDs: evidenceIDs.sorted(),
            rationales: rationales.sorted(),
            objectValue: objectValue,
            modelCall: modelCall
        )
    }

    private static func timestamp(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension ClaimEntityKind {
    fileprivate var uiKind: GraphEntityKind {
        switch self {
        case .person, .team, .externalParty:
            .person
        case .system:
            .system
        case .data:
            .data
        case .process, .unknown:
            .process
        case .goal, .metric, .value:
            .goal
        case .policy:
            .policy
        case .constraint:
            .friction
        case .action:
            .action
        }
    }

    fileprivate var uiSubtitle: String {
        switch self {
        case .person: "Person"
        case .team: "Team"
        case .system: "System"
        case .data: "Data"
        case .process: "Process"
        case .policy: "Guardrail"
        case .goal: "Business goal"
        case .constraint: "Constraint"
        case .metric: "Success metric"
        case .action: "Action"
        case .value: "Value lever"
        case .externalParty: "External party"
        case .unknown: "Unresolved primitive"
        }
    }
}

extension ClaimRelationshipPredicate {
    fileprivate var uiLabel: String {
        switch self {
        case .uses: "uses"
        case .owns: "owns"
        case .stores: "stores"
        case .readsFrom: "reads from"
        case .writesTo: "writes to"
        case .dependsOn: "depends on"
        case .handsOffTo: "hands off to"
        case .governedBy: "governed by"
        case .constrainedBy: "constrained by"
        case .aimsTo: "aims to"
        case .measures: "measures"
        case .causes: "causes"
        case .blocks: "blocks"
        case .enables: "enables"
        case .performs: "performs"
        case .requires: "requires"
        case .relatesTo: "relates to"
        }
    }
}

enum ScoutStableContentIdentity {
    static func normalized(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func canonical(_ components: [String]) -> String {
        components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func identifier(prefix: String, canonical: String) -> String {
        "\(prefix)-\(hexDigest(canonical))"
    }

    static func layoutPoint(for canonical: String, kind: GraphEntityKind) -> (x: Double, y: Double) {
        let bytes = Array(SHA256.hash(data: Data(canonical.utf8)))
        let horizontal = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / Double(UInt16.max)
        let vertical = Double(UInt16(bytes[2]) << 8 | UInt16(bytes[3])) / Double(UInt16.max)
        let x = min(0.94, max(0.06, kind.layoutBand + (horizontal - 0.5) * 0.08))
        let y = 0.12 + vertical * 0.76
        return (x, y)
    }

    private static func hexDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension GraphEntityKind {
    var layoutBand: Double {
        switch self {
        case .person: 0.12
        case .system: 0.28
        case .data: 0.43
        case .process: 0.58
        case .friction: 0.70
        case .goal: 0.79
        case .policy: 0.87
        case .action: 0.91
        }
    }
}
