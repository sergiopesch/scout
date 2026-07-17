import Foundation

/// A read-only snapshot for deterministic discovery-gap analysis.
struct DiscoveryGapSnapshot {
    let entities: [GraphEntity]
    let relationships: [GraphRelationship]
    let claims: [TrustClaim]
    let existingQuestions: [DiscoveryQuestion]

    @MainActor
    init(workspace: ScoutWorkspace) {
        entities = workspace.entities
        relationships = workspace.relationships
        claims = workspace.claims
        existingQuestions = workspace.questions
    }

    init(
        entities: [GraphEntity],
        relationships: [GraphRelationship],
        claims: [TrustClaim],
        existingQuestions: [DiscoveryQuestion] = []
    ) {
        self.entities = entities
        self.relationships = relationships
        self.claims = claims
        self.existingQuestions = existingQuestions
    }
}

/// Derives bounded next-best discovery questions without changing graph or trust state.
struct DiscoveryGapEngine {
    static let defaultMaximumQuestionCount = 6
    static let hardMaximumQuestionCount = 8

    @MainActor
    func derive(
        from workspace: ScoutWorkspace,
        maximumCount: Int = Self.defaultMaximumQuestionCount
    ) -> [DiscoveryQuestion] {
        derive(from: DiscoveryGapSnapshot(workspace: workspace), maximumCount: maximumCount)
    }

    func derive(
        from snapshot: DiscoveryGapSnapshot,
        maximumCount: Int = Self.defaultMaximumQuestionCount
    ) -> [DiscoveryQuestion] {
        let limit = min(max(maximumCount, 0), Self.hardMaximumQuestionCount)
        guard limit > 0 else { return [] }

        let entities = snapshot.entities.sorted { $0.id < $1.id }
        let relationships = snapshot.relationships.sorted { $0.id < $1.id }
        let claims = snapshot.claims.sorted { $0.id < $1.id }
        var candidates: [GapCandidate] = []

        let goals = entities.filter { $0.kind == .goal }
        let processes = entities.filter { $0.kind == .process }
        let systems = entities.filter { $0.kind == .system }
        let data = entities.filter { $0.kind == .data }
        let people = entities.filter { $0.kind == .person }
        let policies = entities.filter { $0.kind == .policy }
        let frictions = entities.filter { $0.kind == .friction }
        let actions = entities.filter { $0.kind == .action }

        if goals.isEmpty {
            candidates.append(.init(
                rule: "missing-goal",
                priority: .critical,
                topic: "Business outcome",
                text: "What measurable business outcome would make this engagement successful?",
                rationale: "A shared outcome is required before architecture or POC scope can be evaluated."
            ))
        } else if !hasMeasurableGoalEvidence(goals: goals, claims: claims) {
            let goal = goals[0]
            candidates.append(.init(
                rule: "goal-baseline:\(goal.id)",
                priority: .high,
                topic: "Success metric",
                text: "How is “\(goal.title)” measured today, and what baseline should we use?",
                rationale: "A baseline and target turn the stated goal into a verifiable success criterion."
            ))
        }

        if !systems.isEmpty, processes.isEmpty {
            candidates.append(.init(
                rule: "missing-process",
                priority: .critical,
                topic: "Workflow",
                text: "Which end-to-end workflow connects these systems, including waits and handoffs?",
                rationale: "A system inventory without the operating flow cannot reveal the real bottleneck."
            ))
        }

        if !processes.isEmpty, systems.isEmpty {
            candidates.append(.init(
                rule: "missing-systems",
                priority: .high,
                topic: "System landscape",
                text: "Which systems support this workflow, and where is each system of record?",
                rationale: "The current process is present, but its technical dependencies are not yet grounded."
            ))
        }

        if (!systems.isEmpty || !processes.isEmpty), people.isEmpty {
            candidates.append(.init(
                rule: "missing-owner",
                priority: .high,
                topic: "Ownership",
                text: "Who owns this workflow operationally and who owns its technical systems?",
                rationale: "Named business and technical owners are needed for validation and acceptance."
            ))
        }

        if !data.isEmpty, policies.isEmpty {
            candidates.append(.init(
                rule: "missing-data-guardrail",
                priority: .critical,
                topic: "Data guardrail",
                text: "What data classifications, residency rules, or access controls constrain these data flows?",
                rationale: "Data is in scope, but no evidence-linked guardrail has been captured."
            ))
        }

        if let isolatedSystem = systems.first(where: { system in
            !relationships.contains { $0.sourceID == system.id || $0.targetID == system.id }
        }) {
            candidates.append(.init(
                rule: "isolated-system:\(isolatedSystem.id)",
                priority: .high,
                topic: "Integration",
                text: "What connects “\(isolatedSystem.title)” to the rest of the workflow, and how often does that exchange run?",
                rationale: "This system has no evidenced inbound or outbound relationship in the current model."
            ))
        }

        if let friction = frictions.first {
            candidates.append(.init(
                rule: "friction-volume:\(friction.id)",
                priority: .high,
                topic: "Volume",
                text: "How often does “\(friction.title)” occur, and how much time or rework does each occurrence create?",
                rationale: "Frequency and cost are required to rank this friction by potential value."
            ))
        }

        if let unvalidatedPolicy = policies.first(where: { policy in
            claims.contains { $0.relatedEntityID == policy.id && $0.needsValidation }
        }) {
            candidates.append(.init(
                rule: "validate-policy:\(unvalidatedPolicy.id)",
                priority: .critical,
                topic: "Guardrail validation",
                text: "Who can validate the exact scope and enforcement of “\(unvalidatedPolicy.title)”?",
                rationale: "A proposed solution must not rely on an unvalidated policy interpretation."
            ))
        }

        for claim in claims.filter({ $0.provenance == .inferred || $0.needsValidation }) {
            candidates.append(.init(
                rule: "validate-claim:\(claim.id)",
                priority: claim.provenance == .inferred ? .critical : .high,
                topic: "Evidence validation",
                text: "Can you confirm or correct this statement: “\(claim.title)”?",
                rationale: "This claim is \(claim.provenance.rawValue.lowercased()) or explicitly marked as needing validation."
            ))
        }

        if actions.isEmpty, !entities.isEmpty, !goals.isEmpty {
            candidates.append(.init(
                rule: "missing-next-action",
                priority: .explore,
                topic: "Safe first move",
                text: "What is the smallest reversible change that could test the most important value hypothesis?",
                rationale: "The model contains a goal but no agreed action or experiment yet."
            ))
        }

        let existingIDs = Set(snapshot.existingQuestions.map(\.id))
        let existingText = Set(snapshot.existingQuestions.map { ScoutStableContentIdentity.normalized($0.text) })
        var uniqueByID: [String: GapCandidate] = [:]
        for candidate in candidates {
            guard !existingIDs.contains(candidate.id),
                  !existingText.contains(ScoutStableContentIdentity.normalized(candidate.text))
            else { continue }
            uniqueByID[candidate.id] = candidate
        }

        return uniqueByID.values.sorted {
            ($0.priority.sortOrder, ScoutStableContentIdentity.normalized($0.topic), $0.id)
                < ($1.priority.sortOrder, ScoutStableContentIdentity.normalized($1.topic), $1.id)
        }.prefix(limit).map(\.question)
    }

    private func hasMeasurableGoalEvidence(goals: [GraphEntity], claims: [TrustClaim]) -> Bool {
        let goalIDs = Set(goals.map(\.id))
        return claims.contains { claim in
            guard let entityID = claim.relatedEntityID, goalIDs.contains(entityID) else { return false }
            return claim.title.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
                || claim.detail.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
        }
    }
}

private struct GapCandidate {
    let id: String
    let priority: QuestionPriority
    let topic: String
    let text: String
    let rationale: String

    init(
        rule: String,
        priority: QuestionPriority,
        topic: String,
        text: String,
        rationale: String
    ) {
        id = ScoutStableContentIdentity.identifier(
            prefix: "question",
            canonical: ScoutStableContentIdentity.canonical(["discovery-gap-v1", rule])
        )
        self.priority = priority
        self.topic = topic
        self.text = text
        self.rationale = rationale
    }

    var question: DiscoveryQuestion {
        DiscoveryQuestion(
            id: id,
            priority: priority,
            topic: topic,
            text: text,
            rationale: rationale,
            isAsked: false
        )
    }
}

private extension QuestionPriority {
    var sortOrder: Int {
        switch self {
        case .critical: 0
        case .high: 1
        case .explore: 2
        }
    }
}
