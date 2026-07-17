import Foundation

/// Read-only input to Scout's conservative opportunity ranking. Scores are transparent heuristics,
/// not truth or ROI forecasts; every output must retain at least one supporting claim.
struct QuickWinSnapshot {
    let entities: [GraphEntity]
    let relationships: [GraphRelationship]
    let claims: [TrustClaim]

    @MainActor
    init(workspace: ScoutWorkspace) {
        entities = workspace.entities
        relationships = workspace.relationships
        claims = workspace.claims
    }

    init(entities: [GraphEntity], relationships: [GraphRelationship], claims: [TrustClaim]) {
        self.entities = entities
        self.relationships = relationships
        self.claims = claims
    }
}

struct QuickWinEngine {
    static let maximumCount = 3

    func rank(_ snapshot: QuickWinSnapshot) -> [QuickWin] {
        let supportedClaims = snapshot.claims.filter {
            !$0.evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !supportedClaims.isEmpty else { return [] }

        var candidates: [RankedQuickWin] = []
        if let batch = batchHandoffCandidate(snapshot, supportedClaims: supportedClaims) {
            candidates.append(batch)
        }
        if let friction = frictionCandidate(snapshot, supportedClaims: supportedClaims) {
            candidates.append(friction)
        }
        if let view = readOnlyViewCandidate(snapshot, supportedClaims: supportedClaims) {
            candidates.append(view)
        }

        var unique: [String: RankedQuickWin] = [:]
        for candidate in candidates {
            unique[candidate.win.id] = candidate
        }
        return unique.values.sorted {
            ($0.score, $0.win.id) > ($1.score, $1.win.id)
        }.prefix(Self.maximumCount).map(\.win)
    }

    private func batchHandoffCandidate(
        _ snapshot: QuickWinSnapshot,
        supportedClaims: [TrustClaim]
    ) -> RankedQuickWin? {
        let terms = ["nightly", "batch", "csv", "export", "reconcile"]
        let matching = supportedClaims.filter { claim in
            let text = "\(claim.title) \(claim.detail) \(claim.evidenceQuote)".lowercased()
            return terms.contains(where: text.contains)
        }
        guard !matching.isEmpty,
              snapshot.entities.contains(where: { $0.kind == .system || $0.kind == .data })
        else { return nil }

        return candidate(
            rule: "batch-handoff-sentinel",
            title: "Batch handoff sentinel",
            detail: "Observe the evidenced batch exchange and alert its owner when an expected handoff is missing or anomalous.",
            impact: 4,
            effort: 1,
            readiness: readiness(for: matching),
            timeToValue: "3–5 days",
            claims: matching
        )
    }

    private func frictionCandidate(
        _ snapshot: QuickWinSnapshot,
        supportedClaims: [TrustClaim]
    ) -> RankedQuickWin? {
        let frictions = snapshot.entities.filter { $0.kind == .friction }
        guard let friction = frictions.sorted(by: { $0.id < $1.id }).first else { return nil }
        let related = supportedClaims.filter { claim in
            claim.relatedEntityID == friction.id
                || claim.title.localizedCaseInsensitiveContains(friction.title)
                || claim.detail.localizedCaseInsensitiveContains(friction.title)
        }
        guard !related.isEmpty else { return nil }

        return candidate(
            rule: "friction-\(friction.id)",
            title: "Reduce \(friction.title.lowercased())",
            detail: "Timebox a reversible intervention around this evidenced friction, then measure wait time and rework before expanding scope.",
            impact: 5,
            effort: 2,
            readiness: readiness(for: related),
            timeToValue: "1–2 weeks",
            claims: related
        )
    }

    private func readOnlyViewCandidate(
        _ snapshot: QuickWinSnapshot,
        supportedClaims: [TrustClaim]
    ) -> RankedQuickWin? {
        let systemCount = snapshot.entities.filter { $0.kind == .system }.count
        guard systemCount >= 2,
              snapshot.entities.contains(where: { $0.kind == .process }),
              snapshot.relationships.contains(where: { relationship in
                  let endpoints = Set([relationship.sourceID, relationship.targetID])
                  return snapshot.entities.filter { endpoints.contains($0.id) && $0.kind == .system }.count >= 1
              })
        else { return nil }

        let related = Array(supportedClaims.sorted { $0.id < $1.id }.prefix(5))
        return candidate(
            rule: "read-only-operational-view",
            title: "Read-only operational view",
            detail: "Unify the evidenced status signals in a grounded operator view while keeping every system of record read-only.",
            impact: 4,
            effort: 2,
            readiness: readiness(for: related),
            timeToValue: "2–3 weeks",
            claims: related
        )
    }

    private func candidate(
        rule: String,
        title: String,
        detail: String,
        impact: Int,
        effort: Int,
        readiness: Int,
        timeToValue: String,
        claims: [TrustClaim]
    ) -> RankedQuickWin {
        let claimIDs = Array(Set(claims.map(\.id))).sorted()
        let id = ScoutStableContentIdentity.identifier(
            prefix: "win",
            canonical: ScoutStableContentIdentity.canonical(["quick-win-v1", rule])
        )
        let win = QuickWin(
            id: id,
            title: title,
            detail: detail,
            impact: impact,
            effort: effort,
            readiness: readiness,
            timeToValue: timeToValue,
            evidenceCount: claimIDs.count,
            supportingClaimIDs: claimIDs
        )
        return RankedQuickWin(win: win, score: impact * 4 + readiness * 3 - effort * 2)
    }

    private func readiness(for claims: [TrustClaim]) -> Int {
        let grounded = claims.filter { $0.provenance == .heard || $0.provenance == .validated }.count
        let validated = claims.filter { !$0.needsValidation }.count
        let ratio = Double(grounded + validated) / Double(max(1, claims.count * 2))
        return min(5, max(1, Int((ratio * 5).rounded())))
    }
}

private struct RankedQuickWin {
    let win: QuickWin
    let score: Int
}
