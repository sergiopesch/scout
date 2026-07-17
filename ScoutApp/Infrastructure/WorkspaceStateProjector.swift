import Foundation
import ScoutCore

/// One deterministic, read-only projection of the canonical event-reduced state into the native
/// cockpit. The event log remains truth; this value can be discarded and rebuilt at any time.
struct WorkspaceReplayProjection {
    let sessionID: String
    let title: String
    let participantCount: Int
    let captureState: CaptureState
    let elapsedSeconds: Int
    let transcript: [TranscriptUtterance]
    let entities: [GraphEntity]
    let relationships: [GraphRelationship]
    let claims: [TrustClaim]
    let projectionEvidenceByID: [String: ProjectionEvidenceLink]
    let claimEvidenceIDsByID: [String: [String]]
    let visualEvidenceAsset: VisualEvidenceAssetSummary?
    let visualEvidenceProposals: [VisualEvidenceProposalCard]
}

struct WorkspaceStateProjector {
    func project(_ state: ScoutState) -> WorkspaceReplayProjection? {
        guard let session = state.session else { return nil }
        let coreEntities = state.graph.entities.values
            .filter { if case .active = $0.lifecycle { true } else { false } }
            .sorted { $0.id < $1.id }
        let positions = positions(for: coreEntities.map(\.id.rawValue))
        let speakers = Dictionary(uniqueKeysWithValues: state.speakers.values.map {
            ($0.id, speaker($0))
        })

        let transcript = state.utterances.values.sorted {
            ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
        }.compactMap { utterance -> TranscriptUtterance? in
            guard let speaker = speakers[utterance.speakerID] else { return nil }
            return TranscriptUtterance(
                id: utterance.id.rawValue,
                speaker: speaker,
                secondsFromStart: seconds(
                    from: session.startedAt,
                    to: utterance.startedAt
                ),
                text: utterance.text.rawValue,
                provenance: .heard,
                confidence: Double(utterance.transcriptionConfidence.basisPoints) / 10_000,
                isFinal: true
            )
        }

        let entities = coreEntities.map { entity in
            let position = positions[entity.id.rawValue] ?? (x: 0.5, y: 0.5)
            return GraphEntity(
                id: entity.id.rawValue,
                title: entity.canonicalName.rawValue,
                subtitle: subtitle(for: entity),
                kind: kind(entity.kind),
                x: position.x,
                y: position.y,
                provenance: provenance(entity.trust),
                confidence: confidence(entity.trust),
            )
        }
        let entityKinds = Dictionary(uniqueKeysWithValues: coreEntities.map { ($0.id, $0.kind) })

        let relationships = state.graph.relationships.values.sorted { $0.id < $1.id }.compactMap {
            relationship -> GraphRelationship? in
            guard entityKinds[relationship.sourceID] != nil,
                  entityKinds[relationship.targetID] != nil
            else { return nil }
            return GraphRelationship(
                id: relationship.id.rawValue,
                sourceID: relationship.sourceID.rawValue,
                targetID: relationship.targetID.rawValue,
                label: relationship.label?.rawValue ?? relationshipLabel(relationship.kind),
                confidence: confidence(relationship.trust),
                isFriction: isFriction(relationship.kind),
                provenance: provenance(relationship.trust),
                needsValidation: relationship.trust.validationStatus != .validated,
                supportingClaimIDs: relationship.claimIDs.map(\.rawValue),
                evidenceIDs: relationship.evidenceIDs.map(\.rawValue)
            )
        }

        let activeClaims = state.claims.values.filter {
            $0.status != .superseded && $0.status != .rejected
        }.sorted { $0.id < $1.id }
        let claims = activeClaims.map { claim in
            let evidence = claim.evidenceIDs.compactMap { state.evidence[$0] }
            let latestEvidence = evidence.max { $0.capturedAt < $1.capturedAt }
            let relatedEntityID: String? = switch claim.subject {
            case let .entity(id): id.rawValue
            case .session: nil
            }
            let speakerName = claim.assertedBy
                .flatMap { speakers[$0]?.name }
                ?? "Scout"
            return TrustClaim(
                id: claim.id.rawValue,
                title: claimTitle(claim, state: state),
                detail: claim.trust.rationale?.rawValue ?? "Evidence-linked claim.",
                provenance: claim.status == .accepted ? .validated : provenance(claim.trust),
                confidence: confidence(claim.trust),
                evidenceQuote: latestEvidence?.excerpt?.rawValue ?? "Evidence retained in Scout.",
                speakerName: speakerName,
                timestamp: latestEvidence.map {
                    timestamp(from: session.startedAt, to: $0.capturedAt)
                } ?? "00:00",
                relatedEntityID: relatedEntityID,
                needsValidation: claim.status != .accepted
                    || claim.trust.validationStatus != .validated,
            )
        }

        var evidenceByProjectionID: [String: ProjectionEvidenceLink] = [:]
        for entity in coreEntities {
            evidenceByProjectionID[entity.id.rawValue] = ProjectionEvidenceLink(
                projectionID: entity.id.rawValue,
                projectedClaimIDs: [],
                clientReferences: [],
                evidenceUtteranceIDs: utteranceIDs(entity.evidenceIDs, state: state),
                evidenceIDs: entity.evidenceIDs.map(\.rawValue)
            )
        }
        for relationship in state.graph.relationships.values {
            evidenceByProjectionID[relationship.id.rawValue] = ProjectionEvidenceLink(
                projectionID: relationship.id.rawValue,
                projectedClaimIDs: relationship.claimIDs.map(\.rawValue),
                clientReferences: [],
                evidenceUtteranceIDs: utteranceIDs(relationship.evidenceIDs, state: state),
                evidenceIDs: relationship.evidenceIDs.map(\.rawValue)
            )
        }

        let elapsedEnd = session.endedAt
            ?? state.utterances.values.map(\.endedAt).max()
            ?? session.startedAt
        let visualProjection = visualEvidence(from: state)
        return WorkspaceReplayProjection(
            sessionID: state.sessionID.rawValue,
            title: session.title.rawValue,
            participantCount: state.speakers.count,
            captureState: session.status == .ended ? .complete : .paused,
            elapsedSeconds: seconds(from: session.startedAt, to: elapsedEnd),
            transcript: transcript,
            entities: entities,
            relationships: relationships,
            claims: claims,
            projectionEvidenceByID: evidenceByProjectionID,
            claimEvidenceIDsByID: Dictionary(uniqueKeysWithValues: activeClaims.map {
                ($0.id.rawValue, $0.evidenceIDs.map(\.rawValue))
            }),
            visualEvidenceAsset: visualProjection.asset,
            visualEvidenceProposals: visualProjection.proposals
        )
    }

    private func visualEvidence(
        from state: ScoutState
    ) -> (asset: VisualEvidenceAssetSummary?, proposals: [VisualEvidenceProposalCard]) {
        let receipts = state.modelCallReceipts.values
            .filter { $0.purpose == .whiteboardExtraction }
            .sorted {
                ($0.inputBoundary.sequence, $0.id) > ($1.inputBoundary.sequence, $1.id)
            }
        guard let receipt = receipts.first else { return (nil, []) }
        let observations = state.visualObservations.values
            .filter { $0.modelCallReceiptID == receipt.id }
            .sorted { $0.id < $1.id }
        guard let evidenceID = observations.first?.evidenceID else { return (nil, []) }

        let assetHash: String
        if case let .text(value)? = receipt.metadata["asset_sha256"] {
            assetHash = value
        } else if case let .image(locator)? = state.evidence[evidenceID]?.source {
            assetHash = locator.contentHash?.rawValue ?? "unknown"
        } else {
            assetHash = "unknown"
        }
        let width: Int
        if case let .integer(value)? = receipt.metadata["pixel_width"] {
            width = Int(clamping: value)
        } else {
            width = 0
        }
        let height: Int
        if case let .integer(value)? = receipt.metadata["pixel_height"] {
            height = Int(clamping: value)
        } else {
            height = 0
        }
        let byteCount: Int
        if case let .integer(value)? = receipt.metadata["byte_count"] {
            byteCount = Int(clamping: value)
        } else {
            byteCount = 0
        }
        return (
            VisualEvidenceAssetSummary(
                evidenceID: evidenceID.rawValue,
                assetSHA256: assetHash,
                pixelWidth: width,
                pixelHeight: height,
                byteCount: byteCount,
                model: receipt.model.rawValue,
                modelCallReceiptID: receipt.id.rawValue
            ),
            observations.map(VisualObservationUIProjector.card)
        )
    }

    private func speaker(_ value: ScoutCore.Speaker) -> Speaker {
        let name = value.displayName.rawValue
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        let tones: [SpeakerTone] = [.indigo, .teal, .coral, .gold]
        let index = value.id.rawValue.utf8.reduce(0) { ($0 + Int($1)) % tones.count }
        return Speaker(
            id: value.id.rawValue,
            name: name,
            role: value.role?.rawValue ?? "Role unconfirmed",
            initials: initials.isEmpty ? "?" : initials,
            tone: tones[index],
        )
    }

    private func positions(for ids: [String]) -> [String: (x: Double, y: Double)] {
        guard !ids.isEmpty else { return [:] }
        let columns = min(4, max(1, Int(ceil(sqrt(Double(ids.count))))))
        let rows = max(1, Int(ceil(Double(ids.count) / Double(columns))))
        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            let column = index % columns
            let row = index / columns
            return (
                id,
                (
                    x: Double(column + 1) / Double(columns + 1),
                    y: Double(row + 1) / Double(rows + 1)
                )
            )
        })
    }

    private func kind(_ value: PrimitiveKind) -> GraphEntityKind {
        return switch value {
        case .person, .team, .organization: .person
        case .system, .capability: .system
        case .dataAsset: .data
        case .process: .process
        case .goal, .valueDriver, .metric: .goal
        case .policy, .regulation, .constraint: .policy
        case .temporalConstraint, .risk: .friction
        case .action: .action
        }
    }

    private func subtitle(for entity: ScoutCore.GraphEntity) -> String {
        if let detail = entity.attributes["detail"] ?? entity.attributes["description"] {
            return attribute(detail)
        }
        return displayName(entity.kind.rawValue)
    }

    private func attribute(_ value: AttributeValue) -> String {
        switch value {
        case let .text(value): value
        case let .integer(value): String(value)
        case let .boolean(value): value ? "Yes" : "No"
        case let .decimal(value): value.canonicalString
        case let .timestamp(value): String(value.millisecondsSinceUnixEpoch)
        case let .durationMilliseconds(value): "\(value) ms"
        case let .strings(values): values.joined(separator: ", ")
        }
    }

    private func provenance(_ trust: TrustAssessment) -> EvidenceKind {
        if trust.validationStatus == .validated { return .validated }
        return switch trust.origin {
        case .heard, .observed: EvidenceKind.heard
        case .inferred: EvidenceKind.inferred
        case .suggested: EvidenceKind.proposed
        case .confirmed, .corrected: EvidenceKind.validated
        }
    }

    private func confidence(_ trust: TrustAssessment) -> Double {
        Double(trust.confidence.basisPoints) / 10_000
    }

    private func claimTitle(_ claim: ScoutCore.Claim, state: ScoutState) -> String {
        let subject: String = switch claim.subject {
        case let .entity(id): state.graph.entities[id]?.canonicalName.rawValue ?? id.rawValue
        case .session: state.session?.title.rawValue ?? state.sessionID.rawValue
        }
        let object: String = switch claim.object {
        case let .entity(id): state.graph.entities[id]?.canonicalName.rawValue ?? id.rawValue
        case let .value(value): attribute(value)
        }
        return "\(subject) \(claimPredicate(claim.predicate)) \(object)"
    }

    private func claimPredicate(_ value: ClaimPredicate) -> String {
        return switch value {
        case .uses: "uses"
        case .storesDataIn: "stores data in"
        case .owns: "owns"
        case .participatesIn: "participates in"
        case .dependsOn: "depends on"
        case .governedBy: "is governed by"
        case .triggers: "triggers"
        case .blocks: "blocks"
        case .precedes: "precedes"
        case .measures: "measures"
        case .targets: "targets"
        case .produces: "produces"
        case .consumes: "consumes"
        case .hasPainPoint: "has pain point"
        case .hasGoal: "has goal"
        case let .custom(value): displayName(value.rawValue)
        }
    }

    private func relationshipLabel(_ value: RelationshipKind) -> String {
        return switch value {
        case .uses: "uses"
        case .stores: "stores"
        case .owns: "owns"
        case .dependsOn: "depends on"
        case .governs: "governs"
        case .triggers: "triggers"
        case .blocks: "blocks"
        case .precedes: "precedes"
        case .produces: "produces"
        case .consumes: "consumes"
        case .measures: "measures"
        case .targets: "targets"
        case let .custom(value): displayName(value.rawValue)
        }
    }

    private func isFriction(_ value: RelationshipKind) -> Bool {
        if case .blocks = value { return true }
        return false
    }

    private func utteranceIDs(_ evidenceIDs: [EvidenceID], state: ScoutState) -> [String] {
        evidenceIDs.compactMap { id in
            guard let evidence = state.evidence[id], case let .utterance(utteranceID) = evidence.source
            else { return nil }
            return utteranceID.rawValue
        }
    }

    private func seconds(from start: ScoutTimestamp, to end: ScoutTimestamp) -> Int {
        let difference = end.millisecondsSinceUnixEpoch.subtractingReportingOverflow(
            start.millisecondsSinceUnixEpoch
        )
        guard !difference.overflow, difference.partialValue > 0 else { return 0 }
        return Int(min(difference.partialValue / 1_000, Int64(Int.max)))
    }

    private func timestamp(from start: ScoutTimestamp, to end: ScoutTimestamp) -> String {
        let total = seconds(from: start, to: end)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func displayName(_ raw: String) -> String {
        raw.unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty {
                result.append(" ")
            }
            result.append(Character(String(scalar)))
        }.capitalized
    }
}
