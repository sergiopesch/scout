import Foundation
import ScoutCore

enum ImageObservationProjectionError: Error, Equatable, Sendable {
    case invalidCoreValue(String)
}

/// Deterministically turns a validated provider result into canonical evidence-layer proposals.
/// It does not append events and cannot mutate graph state.
struct ImageObservationProjector {
    func project(
        _ result: ImageObservationResult,
        sessionID: String,
        evidenceID: EvidenceID,
        modelCallReceiptID: ModelCallReceiptID
    ) throws -> [ScoutCore.VisualObservation] {
        let entityNames = Dictionary(
            uniqueKeysWithValues: result.proposal.entities.map { ($0.clientReference, $0.name) }
        )
        var observations: [ScoutCore.VisualObservation] = []

        for entity in result.proposal.entities {
            observations.append(try makeObservation(
                sessionID: sessionID,
                clientReference: entity.clientReference,
                evidenceID: evidenceID,
                modelCallReceiptID: modelCallReceiptID,
                kind: .entity,
                title: entity.name,
                detail: entity.detail ?? entity.rationale,
                basis: entity.basis,
                confidence: entity.confidence
            ))
        }

        for relationship in result.proposal.relationships {
            let source = entityNames[relationship.sourceClientReference]
                ?? relationship.sourceClientReference
            let target = entityNames[relationship.targetClientReference]
                ?? relationship.targetClientReference
            observations.append(try makeObservation(
                sessionID: sessionID,
                clientReference: relationship.clientReference,
                evidenceID: evidenceID,
                modelCallReceiptID: modelCallReceiptID,
                kind: .relationship,
                title: "\(source) → \(target)",
                detail: "\(Self.humanized(relationship.predicate.rawValue)): \(relationship.rationale)",
                basis: relationship.basis,
                confidence: relationship.confidence
            ))
        }

        for note in result.proposal.notes {
            observations.append(try makeObservation(
                sessionID: sessionID,
                clientReference: note.clientReference,
                evidenceID: evidenceID,
                modelCallReceiptID: modelCallReceiptID,
                kind: .note,
                title: Self.humanized(note.category.rawValue),
                detail: note.text,
                basis: note.basis,
                confidence: note.confidence
            ))
        }
        return observations.sorted { $0.id < $1.id }
    }

    private func makeObservation(
        sessionID: String,
        clientReference: String,
        evidenceID: EvidenceID,
        modelCallReceiptID: ModelCallReceiptID,
        kind: ScoutCore.VisualObservationKind,
        title: String,
        detail: String,
        basis: ImageObservationBasis,
        confidence: Double
    ) throws -> ScoutCore.VisualObservation {
        do {
            let canonical = ScoutStableContentIdentity.canonical([
                "visual-observation-v1",
                sessionID,
                evidenceID.rawValue,
                modelCallReceiptID.rawValue,
                kind.rawValue,
                clientReference,
            ])
            return ScoutCore.VisualObservation(
                id: try VisualObservationID(validating: ScoutStableContentIdentity.identifier(
                    prefix: "visual-observation",
                    canonical: canonical
                )),
                evidenceID: evidenceID,
                modelCallReceiptID: modelCallReceiptID,
                kind: kind,
                title: try NonEmptyString(validating: title),
                detail: try NonEmptyString(validating: detail),
                basis: basis == .visible ? .visible : .inferred,
                confidence: try Confidence(
                    basisPoints: Int((confidence * 10_000).rounded(.toNearestOrAwayFromZero))
                )
            )
        } catch {
            throw ImageObservationProjectionError.invalidCoreValue(String(reflecting: error))
        }
    }

    private static func humanized(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

enum VisualObservationUIProjector {
    static func card(_ observation: ScoutCore.VisualObservation) -> VisualEvidenceProposalCard {
        let kind: VisualEvidenceProposalKind = switch observation.kind {
        case .entity: .entity
        case .relationship: .relationship
        case .note: .note
        }
        let reviewStatus: VisualEvidenceReviewStatus = switch observation.status {
        case .proposed: .proposed
        case .confirmed: .confirmed
        case .rejected: .rejected
        }
        return VisualEvidenceProposalCard(
            id: observation.id.rawValue,
            kind: kind,
            title: observation.title.rawValue,
            detail: observation.detail.rawValue,
            basis: observation.basis == .visible ? .visible : .inferred,
            confidence: Double(observation.confidence.basisPoints) / 10_000,
            reviewStatus: reviewStatus
        )
    }
}
