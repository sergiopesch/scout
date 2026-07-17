import AppKit
import CryptoKit
import Foundation

struct ScoutContextPack: Codable, Sendable {
    let schemaVersion: Int
    let contentSHA256: String
    let body: Body
    let approval: ApprovalBinding?

    struct Body: Codable, Sendable {
        let contextPackID: String
        let sessionID: String
        let revision: Int
        let generatedAt: String
        let approvedAt: String?
        let journalHeadSHA256: String?
        let previousContextPackSHA256: String?
        let organization: String
        let objective: String
        let graphStateSHA256: String
        let entities: [Entity]
        let relationships: [Relationship]
        let claims: [Claim]
        let openQuestions: [Question]
        let quickWins: [Opportunity]
        let selectedPOC: SelectedPOC?
        let nonGoals: [NonGoal]
        let constraints: [Constraint]
        let acceptanceCriteria: [AcceptanceCriterion]
        let successMeasures: [SuccessMeasure]
        let redactionManifest: RedactionManifest

        private enum CodingKeys: String, CodingKey {
            case contextPackID
            case sessionID
            case revision
            case generatedAt
            case approvedAt
            case journalHeadSHA256
            case previousContextPackSHA256
            case organization
            case objective
            case graphStateSHA256
            case entities
            case relationships
            case claims
            case openQuestions
            case quickWins
            case selectedPOC
            case nonGoals
            case constraints
            case acceptanceCriteria
            case successMeasures
            case redactionManifest
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(contextPackID, forKey: .contextPackID)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(revision, forKey: .revision)
            try container.encode(generatedAt, forKey: .generatedAt)
            try container.encodeIfPresent(approvedAt, forKey: .approvedAt)
            try container.encodeIfPresent(journalHeadSHA256, forKey: .journalHeadSHA256)
            try container.encodeIfPresent(previousContextPackSHA256, forKey: .previousContextPackSHA256)
            try container.encode(organization, forKey: .organization)
            try container.encode(objective, forKey: .objective)
            try container.encode(graphStateSHA256, forKey: .graphStateSHA256)
            try container.encode(entities, forKey: .entities)
            try container.encode(relationships, forKey: .relationships)
            try container.encode(claims, forKey: .claims)
            try container.encode(openQuestions, forKey: .openQuestions)
            try container.encode(quickWins, forKey: .quickWins)
            try container.encode(selectedPOC, forKey: .selectedPOC)
            try container.encode(nonGoals, forKey: .nonGoals)
            try container.encode(constraints, forKey: .constraints)
            try container.encode(acceptanceCriteria, forKey: .acceptanceCriteria)
            try container.encode(successMeasures, forKey: .successMeasures)
            try container.encode(redactionManifest, forKey: .redactionManifest)
        }
    }

    struct Entity: Codable, Sendable {
        let id: String
        let kind: String
        let title: String
        let detail: String
        let trust: String
        let confidenceBasisPoints: Int
    }

    struct Relationship: Codable, Sendable {
        let id: String
        let sourceID: String
        let targetID: String
        let predicate: String
        let epistemicMode: String
        let confidenceBasisPoints: Int
        let needsValidation: Bool
        let supportingClaimIDs: [String]
        let sourceEvidenceIDs: [String]
    }

    struct Claim: Codable, Sendable {
        let id: String
        let title: String
        let detail: String
        let epistemicMode: String
        let confidenceBasisPoints: Int
        let needsValidation: Bool
        let relatedEntityID: String?
        let evidence: Evidence
    }

    struct Evidence: Codable, Sendable {
        let id: String
        let sourceEvidenceIDs: [String]
        let speaker: String
        let timestamp: String
        let excerpt: String
    }

    struct Question: Codable, Sendable {
        let id: String
        let priority: String
        let topic: String
        let question: String
        let rationale: String
    }

    struct Opportunity: Codable, Sendable {
        let id: String
        let title: String
        let detail: String
        let impact: Int
        let effort: Int
        let readiness: Int
        let timeToValue: String
        let evidenceCount: Int
        let supportingClaimIDs: [String]
    }

    struct SelectedPOC: Codable, Sendable {
        let id: String
        let title: String
        let problem: String
        let scope: [String]
        let selectionState: String
        let epistemicMode: String
        let supportingClaimIDs: [String]
    }

    struct NonGoal: Codable, Sendable {
        let id: String
        let statement: String
        let rationale: String
    }

    struct Constraint: Codable, Sendable {
        let id: String
        let statement: String
        let category: String
        let epistemicMode: String
        let supportingClaimIDs: [String]
    }

    struct AcceptanceCriterion: Codable, Sendable {
        let id: String
        let statement: String
        let measure: String
        let target: String
        let supportingClaimIDs: [String]
    }

    struct SuccessMeasure: Codable, Sendable {
        let id: String
        let name: String
        let baseline: String
        let target: String
        let unit: String
        let supportingClaimIDs: [String]
    }

    struct RedactionManifest: Codable, Sendable {
        let containsRawAudio: Bool
        let containsRawTranscript: Bool
        let excludesPersonalDataByDefault: Bool
        let includedEvidenceForm: String
    }

    struct ApprovalBinding: Codable, Sendable {
        let algorithm: String
        let keyID: String
        let contextPackID: String
        let sessionID: String
        let revision: Int
        let journalHeadSHA256: String
        let contentSHA256: String
        let approvedScopeSHA256: String
        let approvedAt: String
        let tag: String
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case contentSHA256 = "content_sha256"
        case body
        case approval
    }
}

struct ContextPackHead: Codable, Equatable, Sendable {
    let contextPackID: String
    let revision: Int
    let contentSHA256: String
}

struct StagedContextPack: Identifiable, Sendable {
    var id: String { pack.body.contextPackID }

    let pack: ScoutContextPack
    let encodedPack: Data
    let approvedScopeSHA256: String
    let journalHeadSHA256: String
    let previousHead: ContextPackHead?
}

enum ContextPackExportError: LocalizedError, Equatable {
    case encodingFailed
    case immutableRevisionCollision
    case invalidRevision
    case handoffNotReady
    case missingJournalHead
    case approvalScopeChanged

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "Scout could not encode the context pack."
        case .immutableRevisionCollision: "A different immutable context pack already uses this identifier."
        case .invalidRevision: "Scout could not establish the next immutable context-pack revision."
        case .handoffNotReady: "Select a proof of value backed only by factual, validated evidence before approving a Codex handoff."
        case .missingJournalHead: "Scout must verify the canonical event-journal head before approving a Codex handoff."
        case .approvalScopeChanged: "The staged handoff no longer matches the exact bytes that were reviewed. Review and approve it again."
        }
    }
}

@MainActor
struct ContextPackExporter {
    private let encoder: JSONEncoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func makePack(
        from workspace: ScoutWorkspace,
        approved: Bool,
        revision requestedRevision: Int? = nil,
        journalHeadSHA256: String? = nil,
        previousContextPackSHA256: String? = nil,
        now: Date = .now
    ) throws -> ScoutContextPack {
        if approved,
           (workspace.captureState == .listening || !workspace.selectedPOCHasBuildReadyEvidence) {
            throw ContextPackExportError.handoffNotReady
        }
        let generatedAt = now.ISO8601Format(.iso8601)
        if approved, !Self.isSHA256(journalHeadSHA256) {
            throw ContextPackExportError.missingJournalHead
        }
        let selectedPOC = Self.selectedPOC(from: workspace)
        if approved, selectedPOC == nil {
            throw ContextPackExportError.handoffNotReady
        }
        let selectedClaimIDs = Set(selectedPOC?.supportingClaimIDs ?? [])
        let scopedClaims = approved
            ? workspace.claims.filter { selectedClaimIDs.contains($0.id) }
            : workspace.claims
        let includedClaimIDs = Set(scopedClaims.map(\.id))
        if approved, includedClaimIDs != selectedClaimIDs {
            throw ContextPackExportError.handoffNotReady
        }

        func sourceEvidenceIDs(for claimID: String) -> [String] {
            workspace.claimEvidenceIDsByID[claimID]
                ?? workspace.claimProvenanceByID[claimID]?.evidenceIDs
                ?? ["evidence-\(claimID)"]
        }

        let allClaimIDs = Set(workspace.claims.map(\.id))
        let relationshipInputs: [(
            relationship: GraphRelationship,
            supportingClaimIDs: [String],
            sourceEvidenceIDs: [String]
        )] = workspace.relationships.compactMap { relationship in
            let projectedSupport = workspace.projectionEvidenceByID[relationship.id]?.projectedClaimIDs ?? []
            let support = Set(relationship.supportingClaimIDs + projectedSupport)
                .intersection(allClaimIDs)
                .sorted()
            guard !support.isEmpty else { return nil }
            if approved, !Set(support).isSubset(of: selectedClaimIDs) {
                return nil
            }
            let evidence = Set(support.flatMap(sourceEvidenceIDs(for:))).sorted()
            guard !evidence.isEmpty else { return nil }
            return (relationship, support, evidence)
        }

        let workspaceEntityIDs = Set(workspace.entities.map(\.id))
        let scopedEntityIDs: Set<String>
        if approved {
            let claimEntityIDs = Set(scopedClaims.compactMap(\.relatedEntityID))
            let relationshipEntityIDs = Set(relationshipInputs.flatMap {
                [$0.relationship.sourceID, $0.relationship.targetID]
            })
            scopedEntityIDs = claimEntityIDs.union(relationshipEntityIDs)
            guard scopedEntityIDs.isSubset(of: workspaceEntityIDs) else {
                throw ContextPackExportError.handoffNotReady
            }
        } else {
            scopedEntityIDs = workspaceEntityIDs
        }

        let entities = workspace.entities.filter { scopedEntityIDs.contains($0.id) }.map {
            ScoutContextPack.Entity(
                id: $0.id,
                kind: $0.kind.rawValue.lowercased(),
                title: $0.title,
                detail: $0.subtitle,
                trust: Self.epistemicMode($0.provenance),
                confidenceBasisPoints: Self.basisPoints($0.confidence)
            )
        }
        let relationships = relationshipInputs.compactMap { input -> ScoutContextPack.Relationship? in
            let relationship = input.relationship
            guard scopedEntityIDs.contains(relationship.sourceID),
                  scopedEntityIDs.contains(relationship.targetID)
            else { return nil }
            return ScoutContextPack.Relationship(
                id: relationship.id,
                sourceID: relationship.sourceID,
                targetID: relationship.targetID,
                predicate: relationship.label,
                epistemicMode: Self.epistemicMode(relationship.provenance),
                confidenceBasisPoints: Self.basisPoints(relationship.confidence),
                needsValidation: relationship.needsValidation,
                supportingClaimIDs: input.supportingClaimIDs,
                sourceEvidenceIDs: input.sourceEvidenceIDs
            )
        }
        let graphHash = try Self.sha256(of: encoder.encode(GraphDigest(entities: entities, relationships: relationships)))
        let revision = requestedRevision ?? Self.nextRevision(for: workspace.activeEvidenceSessionID)
        guard revision > 0 else { throw ContextPackExportError.invalidRevision }
        let packID = "\(workspace.activeEvidenceSessionID)-r\(revision)-\(UUID().uuidString.lowercased())"

        let body = ScoutContextPack.Body(
            contextPackID: packID,
            sessionID: workspace.activeEvidenceSessionID,
            revision: revision,
            generatedAt: generatedAt,
            approvedAt: approved ? generatedAt : nil,
            journalHeadSHA256: approved ? journalHeadSHA256 : nil,
            previousContextPackSHA256: approved ? previousContextPackSHA256 : nil,
            organization: workspace.selectedSession.organization,
            objective: approved ? selectedPOC?.problem ?? Self.objective(from: workspace) : Self.objective(from: workspace),
            graphStateSHA256: graphHash,
            entities: entities,
            relationships: relationships,
            claims: scopedClaims.map {
                .init(
                    id: $0.id,
                    title: $0.title,
                    detail: $0.detail,
                    epistemicMode: Self.epistemicMode($0.provenance),
                    confidenceBasisPoints: Self.basisPoints($0.confidence),
                    needsValidation: $0.needsValidation,
                    relatedEntityID: $0.relatedEntityID,
                    evidence: .init(
                        id: "evidence-link-\($0.id)",
                        sourceEvidenceIDs: workspace.claimEvidenceIDsByID[$0.id]
                            ?? workspace.claimProvenanceByID[$0.id]?.evidenceIDs
                            ?? ["evidence-\($0.id)"],
                        speaker: $0.speakerName,
                        timestamp: $0.timestamp,
                        excerpt: Self.boundedEvidenceExcerpt($0.evidenceQuote)
                    )
                )
            },
            openQuestions: (approved ? [] : workspace.questions.filter { !$0.isAsked }).map {
                .init(id: $0.id, priority: $0.priority.rawValue.lowercased(), topic: $0.topic, question: $0.text, rationale: $0.rationale)
            },
            quickWins: (approved ? workspace.selectedPOCQuickWin.map { [$0] } ?? [] : workspace.quickWins).map {
                .init(
                    id: $0.id,
                    title: $0.title,
                    detail: $0.detail,
                    impact: $0.impact,
                    effort: $0.effort,
                    readiness: $0.readiness,
                    timeToValue: $0.timeToValue,
                    evidenceCount: $0.evidenceCount,
                    supportingClaimIDs: $0.supportingClaimIDs
                )
            },
            selectedPOC: selectedPOC,
            nonGoals: Self.nonGoals,
            constraints: Self.constraints(from: workspace).filter {
                Set($0.supportingClaimIDs).isSubset(of: includedClaimIDs)
            },
            acceptanceCriteria: Self.acceptanceCriteria(from: workspace).filter {
                Set($0.supportingClaimIDs).isSubset(of: includedClaimIDs)
            },
            successMeasures: [],
            redactionManifest: .init(
                containsRawAudio: false,
                containsRawTranscript: false,
                excludesPersonalDataByDefault: true,
                includedEvidenceForm: "minimal attributed excerpts"
            )
        )

        let bodyData = try encoder.encode(body)
        return ScoutContextPack(
            schemaVersion: 1,
            contentSHA256: Self.sha256(of: bodyData),
            body: body,
            approval: nil
        )
    }

    func stageApprovedPack(
        from workspace: ScoutWorkspace,
        currentHead: ContextPackHead?,
        journalHeadSHA256: String,
        now: Date = .now
    ) throws -> StagedContextPack {
        let revision: Int
        if let currentHead {
            guard currentHead.revision < Int.max else {
                throw ContextPackExportError.invalidRevision
            }
            revision = currentHead.revision + 1
        } else {
            revision = 1
        }
        let pack = try makePack(
            from: workspace,
            approved: true,
            revision: revision,
            journalHeadSHA256: journalHeadSHA256,
            previousContextPackSHA256: currentHead?.contentSHA256,
            now: now
        )
        let encoded = try encode(pack)
        let staged = StagedContextPack(
            pack: pack,
            encodedPack: encoded,
            approvedScopeSHA256: pack.contentSHA256,
            journalHeadSHA256: journalHeadSHA256,
            previousHead: currentHead
        )
        try validate(staged)
        return staged
    }

    func validate(_ staged: StagedContextPack) throws {
        let finalBytes = try encode(staged.pack)
        let bodyHash = Self.sha256(of: try encoder.encode(staged.pack.body))
        guard staged.pack.approval == nil,
              finalBytes == staged.encodedPack,
              staged.pack.contentSHA256 == staged.approvedScopeSHA256,
              bodyHash == staged.approvedScopeSHA256,
              staged.pack.body.journalHeadSHA256 == staged.journalHeadSHA256,
              staged.pack.body.previousContextPackSHA256 == staged.previousHead?.contentSHA256
        else {
            throw ContextPackExportError.approvalScopeChanged
        }
    }

    func encode(_ pack: ScoutContextPack) throws -> Data {
        try encoder.encode(pack)
    }

    func save(_ pack: ScoutContextPack) throws -> URL {
        let data = try encode(pack)
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appending(path: "Scout", directoryHint: .isDirectory)
            .appending(path: "ContextPacks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let destination = directory.appending(path: "\(pack.body.contextPackID).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else {
                throw ContextPackExportError.immutableRevisionCollision
            }
            return destination
        }
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    func copyToPasteboard(_ pack: ScoutContextPack) throws {
        let data = try encode(pack)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ContextPackExportError.encodingFailed
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyHandoffPromptToPasteboard(_ pack: ScoutContextPack) {
        let prompt = "Use $scout-build with Scout session \(pack.body.sessionID) and approved context pack \(pack.body.contextPackID). Begin by validating the evidence boundary, then propose a build manifest before editing code."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    private static func basisPoints(_ value: Double) -> Int {
        min(10_000, max(0, Int((value * 10_000).rounded())))
    }

    /// Keeps each excerpt well inside the gateway contract while retaining a stable, human-readable
    /// source fragment. Full transcript text remains in the encrypted event log, never the pack.
    private static func boundedEvidenceExcerpt(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Evidence available in Scout; excerpt withheld." : trimmed
        let limit = 1_200
        guard fallback.count > limit else { return fallback }
        return String(fallback.prefix(limit - 1)) + "…"
    }

    private static func objective(from workspace: ScoutWorkspace) -> String {
        if let goal = workspace.entities
            .filter({ $0.kind == .goal })
            .sorted(by: { ($0.confidence, $0.id) > ($1.confidence, $1.id) })
            .first
        {
            return goal.subtitle.isEmpty ? goal.title : "\(goal.title) — \(goal.subtitle)"
        }
        return workspace.selectedSession.summary
    }

    private static func epistemicMode(_ kind: EvidenceKind) -> String {
        switch kind {
        case .heard: "heard"
        case .inferred: "inferred"
        case .proposed: "suggested"
        case .validated: "confirmed"
        }
    }

    private static func selectedPOC(from workspace: ScoutWorkspace) -> ScoutContextPack.SelectedPOC? {
        guard let win = workspace.selectedPOCQuickWin else { return nil }
        let includedClaims = Set(workspace.claims.map(\.id))
        let support = win.supportingClaimIDs.filter(includedClaims.contains).sorted()
        guard !support.isEmpty else { return nil }
        return .init(
            id: "poc-\(win.id)",
            title: win.title,
            problem: win.detail,
            scope: [
                "Build a read-only, reversible proof of value",
                "Use only the evidence-linked inputs named in this context pack",
                "Measure the agreed outcome before expanding scope",
            ],
            selectionState: "selected_for_poc",
            epistemicMode: "suggested",
            supportingClaimIDs: support
        )
    }

    private static let nonGoals: [ScoutContextPack.NonGoal] = [
        .init(id: "non-goal-production-writes", statement: "No writes to production systems of record.", rationale: "The first proof of value must remain read-only and reversible."),
        .init(id: "non-goal-external-actions", statement: "No automated external communication or irreversible operational action.", rationale: "A named human remains accountable during the POC."),
        .init(id: "non-goal-raw-evidence", statement: "No raw audio, unrestricted transcripts, image bytes, or credentials in build context.", rationale: "Codex receives the minimum evidence-linked context required to build.")
    ]

    private static func constraints(from workspace: ScoutWorkspace) -> [ScoutContextPack.Constraint] {
        guard let win = workspace.selectedPOCQuickWin else { return [] }
        let claimsByID = Dictionary(uniqueKeysWithValues: workspace.claims.map { ($0.id, $0) })
        let support = win.supportingClaimIDs.filter { id in
            guard let claim = claimsByID[id] else { return false }
            return !claim.needsValidation
                && (claim.provenance == .heard || claim.provenance == .validated)
        }.sorted()
        guard !support.isEmpty else { return [] }
        return [.init(
            id: "constraint-read-only-\(win.id)",
            statement: "The selected POC must not mutate a production system of record.",
            category: "system_mutation",
            epistemicMode: "suggested",
            supportingClaimIDs: support
        )]
    }

    private static func acceptanceCriteria(from workspace: ScoutWorkspace) -> [ScoutContextPack.AcceptanceCriterion] {
        guard let win = workspace.selectedPOCQuickWin else { return [] }
        let included = Set(workspace.claims.filter {
            !$0.needsValidation && ($0.provenance == .heard || $0.provenance == .validated)
        }.map(\.id))
        let support = win.supportingClaimIDs.filter(included.contains).sorted()
        guard !support.isEmpty else { return [] }
        return [.init(
            id: "accept-read-only-\(win.id)",
            statement: "Complete the selected POC without mutating a production system of record.",
            measure: "Production write operations",
            target: "0",
            supportingClaimIDs: support
        )]
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy {
            ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
        }
    }

    private static func nextRevision(for sessionID: String) -> Int {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Scout", directoryHint: .isDirectory)
            .appending(path: "ContextPacks", directoryHint: .isDirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 1 }

        struct StoredEnvelope: Decodable {
            struct StoredBody: Decodable {
                let sessionID: String
                let revision: Int
            }
            let body: StoredBody
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let highest = files.lazy
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(StoredEnvelope.self, from: $0) }
            .filter { $0.body.sessionID == sessionID }
            .map(\.body.revision)
            .max() ?? 0
        return highest + 1
    }

    private struct GraphDigest: Codable {
        let entities: [ScoutContextPack.Entity]
        let relationships: [ScoutContextPack.Relationship]
    }
}

actor ScoutBridgeClient {
    enum BridgeError: LocalizedError {
        case missingAuthentication
        case missingApprovalAuthentication
        case rejected(Int)
        case invalidResponse
        case revisionOverflow

        var errorDescription: String? {
            switch self {
            case .missingAuthentication: "Scout Bridge authentication is not configured. Launch Scout with `make run`."
            case .missingApprovalAuthentication: "Scout approval authentication is unavailable. Relaunch Scout with `make run` before approving a handoff."
            case .rejected: "Scout Bridge rejected the context pack."
            case .invalidResponse: "Scout Bridge returned an invalid context-pack head."
            case .revisionOverflow: "The context-pack revision limit was reached."
            }
        }
    }

    private let configuration: BridgeConfiguration
    private let session: URLSession

    init(configuration: BridgeConfiguration = .fromEnvironment(), session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func currentHead(for sessionID: String) async throws -> ContextPackHead? {
        guard configuration.authenticationToken != nil else { throw BridgeError.missingAuthentication }
        var components = URLComponents(
            url: configuration.baseURL.appending(path: "v1/context-packs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "session_id", value: sessionID),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let endpoint = components?.url else { throw BridgeError.invalidResponse }
        var request = try await configuration.authorizedRequest(url: endpoint, session: session)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeError.rejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let page = try JSONDecoder.scout.decode(ContextPackHeadPage.self, from: data)
        if let current = page.currentHead, current.revision == Int.max {
            throw BridgeError.revisionOverflow
        }
        return page.currentHead
    }

    func approveAndStore(_ staged: StagedContextPack) async throws -> ScoutContextPack {
        guard configuration.authenticationToken != nil else { throw BridgeError.missingAuthentication }
        guard let approvalToken = configuration.approvalToken else {
            throw BridgeError.missingApprovalAuthentication
        }
        let endpoint = configuration.baseURL.appending(path: "v1/context-packs/approve")
        var request = try await configuration.authorizedRequest(url: endpoint, session: session)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(approvalToken, forHTTPHeaderField: "X-Scout-Approval-Token")
        request.httpBody = staged.encodedPack
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        // A conflict means the immutable identifier already names different content.
        // Only the server's verified create/idempotent-success responses are safe to accept.
        guard let http = response as? HTTPURLResponse, [200, 201].contains(http.statusCode) else {
            throw BridgeError.rejected((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let envelope = try JSONDecoder.scout.decode(ApprovalResponse.self, from: data)
        guard envelope.contextPack.contentSHA256 == staged.approvedScopeSHA256,
              envelope.contextPack.body.contextPackID == staged.pack.body.contextPackID,
              envelope.contextPack.approval?.contentSHA256 == staged.approvedScopeSHA256
        else { throw BridgeError.invalidResponse }
        return envelope.contextPack
    }

    private struct ContextPackHeadPage: Decodable {
        let currentHead: ContextPackHead?
    }

    private struct ApprovalResponse: Decodable {
        let contextPack: ScoutContextPack
    }
}

private extension JSONEncoder {
    static var scout: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

private extension JSONDecoder {
    static var scout: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
