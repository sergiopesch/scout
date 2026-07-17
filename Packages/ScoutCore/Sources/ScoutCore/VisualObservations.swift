import Foundation

/// Visual observations are a separate evidence-layer projection. They never imply graph state.
public enum VisualObservationKind: String, Codable, CaseIterable, Sendable, CanonicalRepresentable {
    case entity
    case relationship
    case note

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

public enum VisualObservationBasis: String, Codable, CaseIterable, Sendable, CanonicalRepresentable {
    case visible
    case inferred

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

public enum VisualObservationStatus: String, Codable, CaseIterable, Sendable, CanonicalRepresentable {
    case proposed
    case confirmed
    case rejected

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

public enum VisualObservationDisposition: String, Codable, CaseIterable, Sendable, CanonicalRepresentable {
    case confirmed
    case rejected

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

/// The current native app has no authenticated reviewer identity. This value records the honest
/// authority boundary: a person explicitly acted in the local Scout review surface.
public enum VisualObservationReviewer: String, Codable, CaseIterable, Sendable, CanonicalRepresentable {
    case localOperator

    public var canonicalValue: CanonicalValue { .string(rawValue) }
}

public struct VisualObservation: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let id: VisualObservationID
    public let evidenceID: EvidenceID
    public let modelCallReceiptID: ModelCallReceiptID
    public let kind: VisualObservationKind
    public let title: NonEmptyString
    public let detail: NonEmptyString
    public let basis: VisualObservationBasis
    public let confidence: Confidence
    public let status: VisualObservationStatus

    public init(
        id: VisualObservationID,
        evidenceID: EvidenceID,
        modelCallReceiptID: ModelCallReceiptID,
        kind: VisualObservationKind,
        title: NonEmptyString,
        detail: NonEmptyString,
        basis: VisualObservationBasis,
        confidence: Confidence,
        status: VisualObservationStatus = .proposed
    ) {
        self.id = id
        self.evidenceID = evidenceID
        self.modelCallReceiptID = modelCallReceiptID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.basis = basis
        self.confidence = confidence
        self.status = status
    }

    func reviewed(_ disposition: VisualObservationDisposition) -> VisualObservation {
        VisualObservation(
            id: id,
            evidenceID: evidenceID,
            modelCallReceiptID: modelCallReceiptID,
            kind: kind,
            title: title,
            detail: detail,
            basis: basis,
            confidence: confidence,
            status: disposition == .confirmed ? .confirmed : .rejected
        )
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "id": id.canonicalValue,
            "evidenceID": evidenceID.canonicalValue,
            "modelCallReceiptID": modelCallReceiptID.canonicalValue,
            "kind": kind.canonicalValue,
            "title": title.canonicalValue,
            "detail": detail.canonicalValue,
            "basis": basis.canonicalValue,
            "confidence": confidence.canonicalValue,
            "status": status.canonicalValue,
        ])
    }
}

public struct VisualObservationReviewed: Codable, Equatable, Sendable, CanonicalRepresentable {
    public let observationID: VisualObservationID
    public let disposition: VisualObservationDisposition
    public let reviewer: VisualObservationReviewer

    public init(
        observationID: VisualObservationID,
        disposition: VisualObservationDisposition,
        reviewer: VisualObservationReviewer = .localOperator
    ) {
        self.observationID = observationID
        self.disposition = disposition
        self.reviewer = reviewer
    }

    public var canonicalValue: CanonicalValue {
        .object([
            "observationID": observationID.canonicalValue,
            "disposition": disposition.canonicalValue,
            "reviewer": reviewer.canonicalValue,
        ])
    }
}
