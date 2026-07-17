import Foundation
import ScoutCore

enum ClaimProjectionCommitPlanningError: Error, Equatable, Sendable {
    case invalidBoundaryIntegrity(EventID)
    case boundarySessionMismatch(expected: SessionID, actual: SessionID)
    case boundarySequenceMismatch(expected: Int, actual: UInt64)
    case boundaryNotCommitted(EventID)
    case boundaryHashMismatch(EventID)
    case invalidProjectionRecord(kind: String, id: String)
    case missingProjectionRecord(kind: String, id: String)
    case missingEvidence(EvidenceID)
    case invalidCoreValue(String)
    case conflictingModelReceipt(ModelCallReceiptID)
    case conflictingModelResponse(String)
    case stateTransitionRejected(String)
}

struct ClaimProjectionPlannedEvent: Equatable, Sendable {
    let id: EventID
    let payload: ScoutEventPayload
}

/// An atomic, deterministic proposal for crossing from a validated UI projection into ScoutCore.
///
/// The model-call receipt is deliberately separate because it must be committed before every
/// derived payload. `derivedEvents` are always ordered entities, claims, then relationships.
struct ClaimProjectionCommitPlan: Equatable, Sendable {
    let modelCallEventID: EventID
    let modelCallReceipt: ModelCallReceipt
    let shouldRecordModelCall: Bool
    let derivedEvents: [ClaimProjectionPlannedEvent]

    var isNoOp: Bool {
        !shouldRecordModelCall && derivedEvents.isEmpty
    }
}

/// Pure authority for converting a validated model projection into a reducer-safe commit plan.
///
/// This type performs no I/O and has no clock or randomness. It validates the exact model input
/// boundary, resolves every evidence identifier against committed state, derives stable IDs, and
/// dry-runs the complete plan through `ScoutGraphReducer` before returning it.
struct ClaimProjectionCommitPlanner {
    func plan(
        _ projection: ClaimProposalProjection,
        inputBoundary boundaryEvent: ScoutEventEnvelope,
        currentState state: ScoutState
    ) throws -> ClaimProjectionCommitPlan {
        try validateBoundary(boundaryEvent, modelCall: projection.modelCall, state: state)

        let receipt = try makeReceipt(for: projection.modelCall, boundaryEvent: boundaryEvent)
        let modelCallEventID = try eventID(
            prefix: "event-model-call",
            canonical: receipt.canonicalValue
        )

        if let existing = state.modelCallReceipts[receipt.id] {
            guard existing == receipt else {
                throw ClaimProjectionCommitPlanningError.conflictingModelReceipt(receipt.id)
            }
            return ClaimProjectionCommitPlan(
                modelCallEventID: modelCallEventID,
                modelCallReceipt: receipt,
                shouldRecordModelCall: false,
                derivedEvents: []
            )
        }

        if let existing = state.modelCallReceipts.values.first(where: {
            $0.provider.rawValue == "openai"
                && $0.providerResponseID.rawValue == projection.modelCall.responseID
        }) {
            guard hasSameProviderResponse(existing, receipt) else {
                throw ClaimProjectionCommitPlanningError.conflictingModelResponse(
                    projection.modelCall.responseID
                )
            }
            return ClaimProjectionCommitPlan(
                modelCallEventID: modelCallEventID,
                modelCallReceipt: receipt,
                shouldRecordModelCall: false,
                derivedEvents: []
            )
        }

        let entityEvidence = try uniqueEvidenceLinks(
            projection.entityEvidence,
            kind: "entity",
            state: state
        )
        let relationshipEvidence = try uniqueEvidenceLinks(
            projection.relationshipEvidence,
            kind: "relationship",
            state: state
        )
        let claimProvenance = try uniqueClaimProvenance(projection.claimProvenance, state: state)

        let projectedEntityIDs = Set(projection.entities.map(\.id))
        guard projectedEntityIDs.count == projection.entities.count else {
            throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                kind: "entity",
                id: "duplicate"
            )
        }
        guard Set(entityEvidence.keys) == projectedEntityIDs else {
            throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                kind: "entity-evidence",
                id: "coverage"
            )
        }

        var derived: [ClaimProjectionPlannedEvent] = []
        var coreEntitiesByProjectionID: [String: ScoutCore.GraphEntity] = [:]

        for entity in projection.entities.sorted(by: { $0.id < $1.id }) {
            guard let evidence = entityEvidence[entity.id] else {
                throw ClaimProjectionCommitPlanningError.missingProjectionRecord(
                    kind: "entity-evidence",
                    id: entity.id
                )
            }
            let coreEntity = try makeEntity(entity, evidence: evidence)
            coreEntitiesByProjectionID[entity.id] = coreEntity
            let payload = ScoutEventPayload.entityUpserted(coreEntity)
            try derived.append(ClaimProjectionPlannedEvent(
                id: derivedEventID(receipt: receipt, payload: payload),
                payload: payload
            ))
        }

        let projectedClaimIDs = Set(projection.claims.map(\.id))
        guard projectedClaimIDs.count == projection.claims.count,
              Set(claimProvenance.keys) == projectedClaimIDs
        else {
            throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                kind: "claim",
                id: "coverage"
            )
        }

        let relationshipByClaimID = try indexRelationshipsByClaimID(
            projection.relationships,
            evidenceByRelationshipID: relationshipEvidence,
            projectedClaimIDs: projectedClaimIDs,
            projectedEntityIDs: projectedEntityIDs
        )

        var committedClaimIDByProjectionID: [String: ClaimID] = [:]
        var committedClaimStatusByProjectionID: [String: ClaimStatus] = [:]

        for projectedClaim in projection.claims.sorted(by: { $0.id < $1.id }) {
            guard let provenance = claimProvenance[projectedClaim.id] else {
                throw ClaimProjectionCommitPlanningError.missingProjectionRecord(
                    kind: "claim-provenance",
                    id: projectedClaim.id
                )
            }
            guard provenance.modelCall == projection.modelCall else {
                throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                    kind: "claim-model-call",
                    id: projectedClaim.id
                )
            }
            guard let relationship = relationshipByClaimID[projectedClaim.id],
                  let subject = coreEntitiesByProjectionID[relationship.sourceID],
                  let object = coreEntitiesByProjectionID[relationship.targetID]
            else {
                throw ClaimProjectionCommitPlanningError.missingProjectionRecord(
                    kind: "claim-relationship",
                    id: projectedClaim.id
                )
            }

            let predicate = try corePredicate(for: relationship.label).claim
            let subjectValue = ClaimSubject.entity(subject.id)
            // A scalar object is the factual value of the claim. The object entity remains the
            // target of the graph relationship, so architecture projection and claim semantics
            // are both retained without deriving domain data from UI display strings.
            let objectValue: ClaimObject = if let literal = provenance.objectValue {
                .value(.text(literal))
            } else {
                .entity(object.id)
            }
            let evidenceIDs = try evidenceIdentifiers(provenance.evidenceIDs, state: state)
            let revisionID = try claimRevisionID(
                projectedClaimID: projectedClaim.id,
                object: objectValue,
                evidenceIDs: evidenceIDs
            )

            let semanticMatches = state.claims.values.filter {
                $0.subject == subjectValue
                    && $0.predicate == predicate
                    && $0.object == objectValue
                    && !isSuperseded($0.status)
            }

            if let existingExact = semanticMatches.first(where: {
                Set($0.evidenceIDs) == Set(evidenceIDs)
            }) {
                committedClaimIDByProjectionID[projectedClaim.id] = existingExact.id
                committedClaimStatusByProjectionID[projectedClaim.id] = existingExact.status
                continue
            }

            let supersededID = supersedablePriorClaim(
                among: semanticMatches,
                newEvidenceIDs: evidenceIDs,
                state: state
            )?.id
            let coreClaim = try ScoutCore.Claim(
                id: revisionID,
                subject: subjectValue,
                predicate: predicate,
                object: objectValue,
                assertedBy: assertedSpeaker(for: evidenceIDs, state: state),
                evidenceIDs: evidenceIDs,
                trust: trust(
                    provenance: .proposed,
                    confidence: projectedClaim.confidence,
                    needsValidation: true,
                    rationale: provenance.rationales
                ),
                status: .proposed,
                supersedes: supersededID
            )
            let payload = ScoutEventPayload.claimProposed(coreClaim)
            try derived.append(ClaimProjectionPlannedEvent(
                id: derivedEventID(receipt: receipt, payload: payload),
                payload: payload
            ))
            committedClaimIDByProjectionID[projectedClaim.id] = coreClaim.id
            committedClaimStatusByProjectionID[projectedClaim.id] = coreClaim.status
        }

        let projectedRelationshipIDs = Set(projection.relationships.map(\.id))
        guard projectedRelationshipIDs.count == projection.relationships.count,
              Set(relationshipEvidence.keys) == projectedRelationshipIDs
        else {
            throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                kind: "relationship",
                id: "coverage"
            )
        }

        for relationship in projection.relationships.sorted(by: { $0.id < $1.id }) {
            guard let source = coreEntitiesByProjectionID[relationship.sourceID],
                  let target = coreEntitiesByProjectionID[relationship.targetID],
                  let evidence = relationshipEvidence[relationship.id]
            else {
                throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                    kind: "relationship",
                    id: relationship.id
                )
            }
            let claimIDs = evidence.projectedClaimIDs.compactMap { projectionID -> ClaimID? in
                guard committedClaimStatusByProjectionID[projectionID] != .rejected else {
                    return nil
                }
                return committedClaimIDByProjectionID[projectionID]
            }.sorted()
            guard !claimIDs.isEmpty else {
                // A previously rejected claim must not silently recreate a graph edge.
                continue
            }
            guard claimIDs.count == Set(claimIDs).count else {
                throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                    kind: "relationship-claim",
                    id: relationship.id
                )
            }
            let mapped = try corePredicate(for: relationship.label)
            let coreRelationship = try ScoutCore.GraphRelationship(
                id: RelationshipID(validating: relationship.id),
                sourceID: source.id,
                targetID: target.id,
                kind: mapped.relationship,
                label: NonEmptyString(validating: relationship.label),
                claimIDs: claimIDs,
                evidenceIDs: evidenceIdentifiers(evidence.evidenceIDs, state: state),
                trust: trust(
                    provenance: .proposed,
                    confidence: relationship.confidence,
                    needsValidation: true,
                    rationale: ["Evidence-linked relationship proposed by claim extraction."]
                )
            )
            let payload = ScoutEventPayload.relationshipUpserted(coreRelationship)
            try derived.append(ClaimProjectionPlannedEvent(
                id: derivedEventID(receipt: receipt, payload: payload),
                payload: payload
            ))
        }

        let commitPlan = ClaimProjectionCommitPlan(
            modelCallEventID: modelCallEventID,
            modelCallReceipt: receipt,
            shouldRecordModelCall: true,
            derivedEvents: derived
        )
        try validateAtomically(commitPlan, boundaryEvent: boundaryEvent, state: state)
        return commitPlan
    }

    private func validateBoundary(
        _ event: ScoutEventEnvelope,
        modelCall: ClaimModelCall,
        state: ScoutState
    ) throws {
        guard event.hasValidIntegrity else {
            throw ClaimProjectionCommitPlanningError.invalidBoundaryIntegrity(event.id)
        }
        guard event.sessionID == state.sessionID else {
            throw ClaimProjectionCommitPlanningError.boundarySessionMismatch(
                expected: state.sessionID,
                actual: event.sessionID
            )
        }
        guard modelCall.inputEventBoundary > 0,
              UInt64(modelCall.inputEventBoundary) == event.sequence.rawValue
        else {
            throw ClaimProjectionCommitPlanningError.boundarySequenceMismatch(
                expected: modelCall.inputEventBoundary,
                actual: event.sequence.rawValue
            )
        }
        guard let committed = state.eventBoundaries[event.id] else {
            throw ClaimProjectionCommitPlanningError.boundaryNotCommitted(event.id)
        }
        guard committed == ModelInputEventBoundary(event) else {
            throw ClaimProjectionCommitPlanningError.boundaryHashMismatch(event.id)
        }
    }

    private func makeReceipt(
        for modelCall: ClaimModelCall,
        boundaryEvent: ScoutEventEnvelope
    ) throws -> ModelCallReceipt {
        do {
            let receiptCanonical = ScoutStableContentIdentity.canonical([
                "model-call-receipt-v1",
                "openai",
                modelCall.responseID,
                ModelCallPurpose.claimExtraction.rawValue,
                boundaryEvent.id.rawValue,
                String(boundaryEvent.sequence.rawValue),
                boundaryEvent.integrityHash.rawValue,
                modelCall.promptVersion,
                modelCall.schemaVersion,
                modelCall.model,
                modelCall.outputSHA256,
            ])
            return try ModelCallReceipt(
                id: ModelCallReceiptID(
                    validating: ScoutStableContentIdentity.identifier(
                        prefix: "model-call",
                        canonical: receiptCanonical
                    )
                ),
                provider: NonEmptyString(validating: "openai"),
                providerResponseID: NonEmptyString(validating: modelCall.responseID),
                purpose: .claimExtraction,
                inputBoundary: ModelInputEventBoundary(boundaryEvent),
                promptVersion: NonEmptyString(validating: modelCall.promptVersion),
                outputSchemaVersion: NonEmptyString(validating: modelCall.schemaVersion),
                model: NonEmptyString(validating: modelCall.model),
                outputHash: SHA256Digest(validating: modelCall.outputSHA256)
            )
        } catch {
            throw ClaimProjectionCommitPlanningError.invalidCoreValue(String(reflecting: error))
        }
    }

    private func uniqueEvidenceLinks(
        _ links: [ProjectionEvidenceLink],
        kind: String,
        state: ScoutState
    ) throws -> [String: ProjectionEvidenceLink] {
        var result: [String: ProjectionEvidenceLink] = [:]
        for link in links {
            guard result[link.projectionID] == nil else {
                throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                    kind: "\(kind)-evidence",
                    id: link.projectionID
                )
            }
            _ = try evidenceIdentifiers(link.evidenceIDs, state: state)
            result[link.projectionID] = link
        }
        return result
    }

    private func uniqueClaimProvenance(
        _ values: [ClaimProjectionProvenance],
        state: ScoutState
    ) throws -> [String: ClaimProjectionProvenance] {
        var result: [String: ClaimProjectionProvenance] = [:]
        for value in values {
            guard result[value.projectedClaimID] == nil else {
                throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                    kind: "claim-provenance",
                    id: value.projectedClaimID
                )
            }
            _ = try evidenceIdentifiers(value.evidenceIDs, state: state)
            result[value.projectedClaimID] = value
        }
        return result
    }

    private func indexRelationshipsByClaimID(
        _ relationships: [GraphRelationship],
        evidenceByRelationshipID: [String: ProjectionEvidenceLink],
        projectedClaimIDs: Set<String>,
        projectedEntityIDs: Set<String>
    ) throws -> [String: GraphRelationship] {
        var result: [String: GraphRelationship] = [:]
        for relationship in relationships {
            guard projectedEntityIDs.contains(relationship.sourceID),
                  projectedEntityIDs.contains(relationship.targetID),
                  let evidence = evidenceByRelationshipID[relationship.id],
                  !evidence.projectedClaimIDs.isEmpty
            else {
                throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                    kind: "relationship",
                    id: relationship.id
                )
            }
            for claimID in evidence.projectedClaimIDs {
                guard projectedClaimIDs.contains(claimID), result[claimID] == nil else {
                    throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                        kind: "claim-relationship",
                        id: claimID
                    )
                }
                result[claimID] = relationship
            }
        }
        guard Set(result.keys) == projectedClaimIDs else {
            throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                kind: "claim-relationship",
                id: "coverage"
            )
        }
        return result
    }

    private func evidenceIdentifiers(
        _ values: [String],
        state: ScoutState
    ) throws -> [EvidenceID] {
        guard !values.isEmpty, values.count == Set(values).count else {
            throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                kind: "evidence",
                id: values.joined(separator: ",")
            )
        }
        return try values.sorted().map { rawValue in
            let id: EvidenceID
            do {
                id = try EvidenceID(validating: rawValue)
            } catch {
                throw ClaimProjectionCommitPlanningError.invalidCoreValue(rawValue)
            }
            guard state.evidence[id] != nil else {
                throw ClaimProjectionCommitPlanningError.missingEvidence(id)
            }
            return id
        }
    }

    private func makeEntity(
        _ entity: GraphEntity,
        evidence: ProjectionEvidenceLink
    ) throws -> ScoutCore.GraphEntity {
        do {
            return try ScoutCore.GraphEntity(
                id: EntityID(validating: entity.id),
                kind: coreKind(for: entity.kind),
                canonicalName: NonEmptyString(validating: entity.title),
                evidenceIDs: evidence.evidenceIDs.sorted().map(EvidenceID.init(validating:)),
                trust: trust(
                    provenance: .proposed,
                    confidence: entity.confidence,
                    needsValidation: true,
                    rationale: ["Entity proposed from immutable evidence."]
                )
            )
        } catch let error as ClaimProjectionCommitPlanningError {
            throw error
        } catch {
            throw ClaimProjectionCommitPlanningError.invalidCoreValue(String(reflecting: error))
        }
    }

    private func coreKind(for kind: GraphEntityKind) -> PrimitiveKind {
        switch kind {
        case .person: .person
        case .system: .system
        case .data: .dataAsset
        case .process: .process
        case .goal: .goal
        case .policy: .policy
        case .friction: .constraint
        case .action: .action
        }
    }

    private func corePredicate(
        for label: String
    ) throws -> (claim: ClaimPredicate, relationship: RelationshipKind) {
        func customClaim(_ value: String) throws -> ClaimPredicate {
            try .custom(NonEmptyString(validating: value))
        }
        func customRelationship(_ value: String) throws -> RelationshipKind {
            try .custom(NonEmptyString(validating: value))
        }

        return switch label {
        case "uses": (.uses, .uses)
        case "owns": (.owns, .owns)
        case "stores": (.storesDataIn, .stores)
        case "reads from": (.consumes, .consumes)
        case "writes to": (.produces, .produces)
        case "depends on": (.dependsOn, .dependsOn)
        case "hands off to": (.precedes, .precedes)
        case "governed by": try (customClaim("governedBy"), customRelationship("governedBy"))
        case "constrained by": try (
                customClaim("constrainedBy"),
                customRelationship("constrainedBy")
            )
        case "aims to": (.targets, .targets)
        case "measures": (.measures, .measures)
        case "causes": (.triggers, .triggers)
        case "blocks": (.blocks, .blocks)
        case "enables": try (customClaim("enables"), customRelationship("enables"))
        case "performs": try (.participatesIn, customRelationship("performs"))
        case "requires": (.dependsOn, .dependsOn)
        case "relates to": try (customClaim("relatesTo"), customRelationship("relatesTo"))
        default:
            throw ClaimProjectionCommitPlanningError.invalidProjectionRecord(
                kind: "relationship-predicate",
                id: label
            )
        }
    }

    private func trust(
        provenance: EvidenceKind,
        confidence: Double,
        needsValidation: Bool,
        rationale: [String]
    ) throws -> TrustAssessment {
        guard confidence.isFinite, (0 ... 1).contains(confidence) else {
            throw ClaimProjectionCommitPlanningError.invalidCoreValue("confidence")
        }
        let origin: TrustOrigin = switch provenance {
        case .heard: .heard
        case .inferred: .inferred
        case .proposed: .suggested
        case .validated: .confirmed
        }
        let validationStatus: ValidationStatus = switch provenance {
        case .validated: .validated
        default: needsValidation ? .needsValidation : .unreviewed
        }
        let joinedRationale = rationale
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: " | ")
        return try TrustAssessment(
            origin: origin,
            confidence: Confidence(basisPoints: Int((confidence * 10000).rounded())),
            validationStatus: validationStatus,
            rationale: joinedRationale.isEmpty ? nil : NonEmptyString(validating: joinedRationale)
        )
    }

    private func conservativeProvenance(_ values: [EvidenceKind]) -> EvidenceKind {
        if values.contains(.proposed) {
            return .proposed
        }
        if values.contains(.inferred) {
            return .inferred
        }
        if values.allSatisfy({ $0 == .validated }) {
            return .validated
        }
        return .heard
    }

    private func assertedSpeaker(
        for evidenceIDs: [EvidenceID],
        state: ScoutState
    ) -> SpeakerID? {
        let speakerIDs = Set(evidenceIDs.compactMap { evidenceID -> SpeakerID? in
            guard let evidence = state.evidence[evidenceID],
                  case let .utterance(utteranceID) = evidence.source
            else { return nil }
            return state.utterances[utteranceID]?.speakerID
        })
        return speakerIDs.count == 1 ? speakerIDs.first : nil
    }

    private func claimRevisionID(
        projectedClaimID: String,
        object: ClaimObject,
        evidenceIDs: [EvidenceID]
    ) throws -> ClaimID {
        let canonical = ScoutStableContentIdentity.canonical(
            [
                "claim-revision-v2",
                projectedClaimID,
                CanonicalJSON.string(object.canonicalValue),
            ] + evidenceIDs.map(\.rawValue).sorted()
        )
        return try ClaimID(
            validating: ScoutStableContentIdentity.identifier(
                prefix: "\(projectedClaimID)-revision",
                canonical: canonical
            )
        )
    }

    private func supersedablePriorClaim(
        among values: [ScoutCore.Claim],
        newEvidenceIDs: [EvidenceID],
        state: ScoutState
    ) -> ScoutCore.Claim? {
        let newestNewEvidence = newEvidenceIDs.compactMap { state.evidence[$0]?.capturedAt }.max()
        return values.filter { claim in
            guard isUnreviewedProposal(claim),
                  Set(claim.evidenceIDs) != Set(newEvidenceIDs),
                  let newestNewEvidence
            else { return false }
            let newestPriorEvidence = claim.evidenceIDs.compactMap {
                state.evidence[$0]?.capturedAt
            }.max()
            return newestPriorEvidence.map { newestNewEvidence > $0 } ?? true
        }.sorted { lhs, rhs in
            let lhsTime = lhs.evidenceIDs.compactMap { state.evidence[$0]?.capturedAt }.max()
            let rhsTime = rhs.evidenceIDs.compactMap { state.evidence[$0]?.capturedAt }.max()
            if lhsTime != rhsTime {
                return (lhsTime ?? .init(millisecondsSinceUnixEpoch: 0)) > (rhsTime ?? .init(millisecondsSinceUnixEpoch: 0))
            }
            return lhs.id < rhs.id
        }.first
    }

    private func isUnreviewedProposal(_ claim: ScoutCore.Claim) -> Bool {
        guard claim.status == .proposed else { return false }
        return switch claim.trust.validationStatus {
        case .unreviewed, .needsValidation: true
        case .validated, .disputed, .rejected: false
        }
    }

    private func isSuperseded(_ status: ClaimStatus) -> Bool {
        status == .superseded
    }

    private func derivedEventID(
        receipt: ModelCallReceipt,
        payload: ScoutEventPayload
    ) throws -> EventID {
        let canonical = ScoutStableContentIdentity.canonical([
            "derived-event-v1",
            receipt.id.rawValue,
            payload.kind,
            CanonicalJSON.string(payload.canonicalValue),
        ])
        return try eventID(prefix: "event-derived", canonical: .string(canonical))
    }

    private func eventID(prefix: String, canonical: CanonicalValue) throws -> EventID {
        try EventID(
            validating: ScoutStableContentIdentity.identifier(
                prefix: prefix,
                canonical: CanonicalJSON.string(canonical)
            )
        )
    }

    private func hasSameProviderResponse(
        _ lhs: ModelCallReceipt,
        _ rhs: ModelCallReceipt
    ) -> Bool {
        lhs.provider == rhs.provider
            && lhs.providerResponseID == rhs.providerResponseID
            && lhs.purpose == rhs.purpose
            && lhs.inputBoundary == rhs.inputBoundary
            && lhs.promptVersion == rhs.promptVersion
            && lhs.outputSchemaVersion == rhs.outputSchemaVersion
            && lhs.model == rhs.model
            && lhs.outputHash == rhs.outputHash
            && lhs.metadata == rhs.metadata
    }

    private func validateAtomically(
        _ plan: ClaimProjectionCommitPlan,
        boundaryEvent: ScoutEventEnvelope,
        state: ScoutState
    ) throws {
        guard let lastSequence = state.lastSequence else {
            throw ClaimProjectionCommitPlanningError.stateTransitionRejected("missing-sequence")
        }
        do {
            var next = state
            var chain = try EventChainBuilder(
                sessionID: state.sessionID,
                nextSequence: lastSequence.successor(),
                previousHash: state.lastEventHash
            )
            let actor = try EventActor.model(ModelIdentity(
                provider: NonEmptyString(validating: "openai"),
                model: NonEmptyString(validating: plan.modelCallReceipt.model.rawValue),
                operationVersion: NonEmptyString(validating: plan.modelCallReceipt.promptVersion.rawValue)
            ))
            let timestamp = boundaryEvent.recordedAt

            let receiptEvent = try chain.seal(
                id: plan.modelCallEventID,
                occurredAt: timestamp,
                recordedAt: timestamp,
                actor: actor,
                causationID: boundaryEvent.id,
                payload: .modelCallRecorded(plan.modelCallReceipt)
            )
            next = try ScoutGraphReducer.reduce(next, event: receiptEvent)

            for planned in plan.derivedEvents {
                let event = try chain.seal(
                    id: planned.id,
                    occurredAt: timestamp,
                    recordedAt: timestamp,
                    actor: actor,
                    correlationID: plan.modelCallEventID,
                    causationID: plan.modelCallEventID,
                    payload: planned.payload
                )
                next = try ScoutGraphReducer.reduce(next, event: event)
            }
            _ = next
        } catch let error as ClaimProjectionCommitPlanningError {
            throw error
        } catch {
            throw ClaimProjectionCommitPlanningError.stateTransitionRejected(
                String(reflecting: error)
            )
        }
    }
}
