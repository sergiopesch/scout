import Foundation
import Observation

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case discovery = "Live discovery"
    case evidence = "Evidence"
    case actionPack = "Action pack"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .discovery: "waveform.path.ecg"
        case .evidence: "checkmark.shield"
        case .actionPack: "shippingbox"
        }
    }
}

enum CaptureState: String {
    case idle
    case listening
    case paused
    case complete

    var label: String {
        switch self {
        case .idle: "Ready"
        case .listening: "Listening"
        case .paused: "Paused"
        case .complete: "Session complete"
        }
    }
}

enum AudioCaptureMode: String, CaseIterable, Identifiable {
    case roomMicrophone = "In-room microphone"
    case onlineMeeting = "Online meeting"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .roomMicrophone: "mic.fill"
        case .onlineMeeting: "macwindow.and.cursorarrow"
        }
    }

    var shortLabel: String {
        switch self {
        case .roomMicrophone: "Room"
        case .onlineMeeting: "Meeting"
        }
    }
}

enum SessionStatus: String, Hashable {
    case live
    case ready
    case archived
}

struct SessionSummary: Identifiable, Hashable {
    let id: String
    let organization: String
    let title: String
    let relativeDate: String
    let duration: String
    let participantCount: Int
    let status: SessionStatus
    let summary: String
}

enum SpeakerTone: String, Hashable {
    case indigo
    case teal
    case coral
    case gold
}

struct Speaker: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    let initials: String
    let tone: SpeakerTone
}

enum EvidenceKind: String, CaseIterable, Hashable, Sendable {
    case heard = "Heard"
    case inferred = "Inferred"
    case proposed = "Proposed"
    case validated = "Validated"

    var symbol: String {
        switch self {
        case .heard: "waveform"
        case .inferred: "sparkles"
        case .proposed: "lightbulb"
        case .validated: "checkmark.seal.fill"
        }
    }
}

struct TranscriptUtterance: Identifiable, Hashable {
    let id: String
    let speaker: Speaker
    let secondsFromStart: Int
    let text: String
    let provenance: EvidenceKind
    let confidence: Double
    let isFinal: Bool

    var timestamp: String {
        let minutes = secondsFromStart / 60
        let seconds = secondsFromStart % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

enum VisualEvidencePhase: String, Hashable, Sendable {
    case idle
    case preparing
    case persisted
    case analyzing
    case ready
    case failed

    var isWorking: Bool {
        self == .preparing || self == .persisted || self == .analyzing
    }
}

enum VisualEvidenceBasis: String, Hashable, Sendable {
    case visible = "Visible"
    case inferred = "Inferred"
}

enum VisualEvidenceProposalKind: String, Hashable, Sendable {
    case entity = "Entity"
    case relationship = "Relationship"
    case note = "Note"

    var symbol: String {
        switch self {
        case .entity: "square.on.circle"
        case .relationship: "arrow.triangle.branch"
        case .note: "note.text"
        }
    }
}

enum VisualEvidenceReviewStatus: String, Hashable, Sendable {
    case proposed
    case confirmed
    case rejected

    var label: String {
        switch self {
        case .proposed: "Needs validation"
        case .confirmed: "Confirmed"
        case .rejected: "Rejected"
        }
    }
}

struct VisualEvidenceAssetSummary: Hashable, Sendable {
    let evidenceID: String
    let assetSHA256: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let model: String?
    let modelCallReceiptID: String?
}

/// Read-only proposal cards. These never become graph state until a separate validation action
/// records canonical events; even visible labels remain proposed here.
struct VisualEvidenceProposalCard: Identifiable, Hashable, Sendable {
    let id: String
    let kind: VisualEvidenceProposalKind
    let title: String
    let detail: String
    let basis: VisualEvidenceBasis
    let confidence: Double
    let reviewStatus: VisualEvidenceReviewStatus

    init(
        id: String,
        kind: VisualEvidenceProposalKind,
        title: String,
        detail: String,
        basis: VisualEvidenceBasis,
        confidence: Double,
        reviewStatus: VisualEvidenceReviewStatus = .proposed
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.basis = basis
        self.confidence = confidence
        self.reviewStatus = reviewStatus
    }

    var needsValidation: Bool { reviewStatus == .proposed }
}

enum GraphEntityKind: String, CaseIterable, Hashable, Sendable {
    case person = "Person"
    case system = "System"
    case data = "Data"
    case process = "Process"
    case goal = "Goal"
    case policy = "Guardrail"
    case friction = "Friction"
    case action = "Action"

    var symbol: String {
        switch self {
        case .person: "person.fill"
        case .system: "server.rack"
        case .data: "cylinder.fill"
        case .process: "arrow.triangle.branch"
        case .goal: "scope"
        case .policy: "lock.shield.fill"
        case .friction: "exclamationmark.triangle.fill"
        case .action: "bolt.fill"
        }
    }
}

struct GraphEntity: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let kind: GraphEntityKind
    let x: Double
    let y: Double
    let provenance: EvidenceKind
    let confidence: Double
}

struct GraphRelationship: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let targetID: String
    let label: String
    let confidence: Double
    let isFriction: Bool
    let provenance: EvidenceKind
    let needsValidation: Bool
    let supportingClaimIDs: [String]
    let evidenceIDs: [String]

    init(
        id: String,
        sourceID: String,
        targetID: String,
        label: String,
        confidence: Double,
        isFriction: Bool,
        provenance: EvidenceKind = .proposed,
        needsValidation: Bool = true,
        supportingClaimIDs: [String] = [],
        evidenceIDs: [String] = []
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.label = label
        self.confidence = confidence
        self.isFriction = isFriction
        self.provenance = provenance
        self.needsValidation = needsValidation
        self.supportingClaimIDs = supportingClaimIDs
        self.evidenceIDs = evidenceIDs
    }
}

struct TrustClaim: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let provenance: EvidenceKind
    let confidence: Double
    let evidenceQuote: String
    let speakerName: String
    let timestamp: String
    let relatedEntityID: String?
    let needsValidation: Bool
}

enum QuestionPriority: String, Hashable {
    case critical = "Critical"
    case high = "High"
    case explore = "Explore"
}

struct DiscoveryQuestion: Identifiable, Hashable {
    let id: String
    let priority: QuestionPriority
    let topic: String
    let text: String
    let rationale: String
    var isAsked: Bool
}

struct QuickWin: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let impact: Int
    let effort: Int
    let readiness: Int
    let timeToValue: String
    let evidenceCount: Int
    let supportingClaimIDs: [String]

    init(
        id: String,
        title: String,
        detail: String,
        impact: Int,
        effort: Int,
        readiness: Int,
        timeToValue: String,
        evidenceCount: Int,
        supportingClaimIDs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.impact = impact
        self.effort = effort
        self.readiness = readiness
        self.timeToValue = timeToValue
        self.evidenceCount = evidenceCount
        self.supportingClaimIDs = supportingClaimIDs
    }
}

enum ArtifactReadiness: String, Hashable {
    case ready = "Ready"
    case review = "Review"
    case drafting = "Drafting"
}

struct ActionArtifact: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let readiness: ArtifactReadiness
}

@MainActor
@Observable
final class ScoutWorkspace {
    var selectedSessionID: String
    var activeEvidenceSessionID: String
    var destination: WorkspaceDestination = .discovery
    var captureState: CaptureState = .paused
    var selectedEntityID: String?
    var transcript: [TranscriptUtterance] = []
    var entities: [GraphEntity] = []
    var relationships: [GraphRelationship] = []
    var claims: [TrustClaim] = []
    var questions: [DiscoveryQuestion] = []
    var quickWins: [QuickWin] = []
    var artifacts: [ActionArtifact] = []
    var projectionEvidenceByID: [String: ProjectionEvidenceLink] = [:]
    var claimProvenanceByID: [String: ClaimProjectionProvenance] = [:]
    var claimEvidenceIDsByID: [String: [String]] = [:]
    var selectedPOCQuickWinID: String?
    var visualEvidencePhase: VisualEvidencePhase = .idle
    var visualEvidenceAsset: VisualEvidenceAssetSummary?
    var visualEvidenceProposals: [VisualEvidenceProposalCard] = []
    var visualEvidenceMessage: String?
    var visualEvidenceReviewError: String?
    var reviewingVisualObservationIDs: Set<String> = []
    var elapsedSeconds = 1_842
    var demoStep = 0
    var liveError: String?
    var audioCaptureMode: AudioCaptureMode = .roomMicrophone
    var systemAudioSources: [SystemAudioCaptureSource] = []
    var selectedSystemAudioSourceID: String?
    var isRefreshingAudioSources = false

    var sessions: [SessionSummary]

    @ObservationIgnored
    private var simulationTask: Task<Void, Never>?
    @ObservationIgnored
    var liveCaptureToggle: (() -> Void)?
    @ObservationIgnored
    var systemAudioRefresh: (() -> Void)?
    @ObservationIgnored
    var visualEvidenceImport: (() -> Void)?
    @ObservationIgnored
    var visualEvidenceReview: ((String, VisualEvidenceReviewStatus) -> Void)?
    @ObservationIgnored
    private var hasStartedLiveSession = false

    private let alex = Speaker(
        id: "speaker-alex",
        name: "Alex Morgan",
        role: "Forward Deployed Engineer",
        initials: "AM",
        tone: .indigo
    )
    private let maya = Speaker(
        id: "speaker-maya",
        name: "Maya Chen",
        role: "VP, Customer Operations",
        initials: "MC",
        tone: .teal
    )
    private let raj = Speaker(
        id: "speaker-raj",
        name: "Raj Patel",
        role: "Enterprise Architect",
        initials: "RP",
        tone: .coral
    )

    private static let demoSession = SessionSummary(
        id: "northstar-live",
        organization: "Northstar Retail",
        title: "Order intelligence discovery",
        relativeDate: "Live now",
        duration: "31 min",
        participantCount: 3,
        status: .live,
        summary: "Inventory accuracy, exception handling, and customer experience"
    )

    init(completed: Bool = false) {
        let initialSessions = [
            Self.demoSession,
            SessionSummary(
                id: "helix-ready",
                organization: "Helix Health",
                title: "Clinical intake workflow",
                relativeDate: "Yesterday",
                duration: "48 min",
                participantCount: 5,
                status: .ready,
                summary: "Action pack ready with two validated POC opportunities"
            ),
            SessionSummary(
                id: "atlas-archived",
                organization: "Atlas Manufacturing",
                title: "Service operations mapping",
                relativeDate: "12 Jul",
                duration: "56 min",
                participantCount: 4,
                status: .archived,
                summary: "Current-state service architecture and field handoffs"
            )
        ]
        sessions = initialSessions
        selectedSessionID = initialSessions[0].id
        activeEvidenceSessionID = initialSessions[0].id
        loadSeed()

        if completed {
            while demoStep < Self.totalDemoSteps {
                applyNextDemoStep()
            }
            captureState = .complete
        }
    }

    var selectedSession: SessionSummary {
        sessions.first(where: { $0.id == selectedSessionID }) ?? sessions[0]
    }

    var activeSessionSelected: Bool {
        selectedSessionID == sessions[0].id
    }

    var selectedEntity: GraphEntity? {
        entities.first(where: { $0.id == selectedEntityID })
    }

    var selectedClaim: TrustClaim? {
        if let selectedEntityID,
           let match = claims.last(where: { $0.relatedEntityID == selectedEntityID }) {
            return match
        }
        return claims.last
    }

    var selectedPOCQuickWin: QuickWin? {
        guard let selectedPOCQuickWinID else { return nil }
        return quickWins.first(where: { $0.id == selectedPOCQuickWinID })
    }

    /// A POC is eligible for explicit handoff review only when every referenced claim exists,
    /// comes from heard/validated evidence, and has no unresolved validation flag.
    var selectedPOCHasBuildReadyEvidence: Bool {
        guard let selectedPOCQuickWin, !selectedPOCQuickWin.supportingClaimIDs.isEmpty else {
            return false
        }
        let claimsByID = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0) })
        return selectedPOCQuickWin.supportingClaimIDs.allSatisfy { id in
            guard let claim = claimsByID[id] else { return false }
            return !claim.needsValidation
                && (claim.provenance == .heard || claim.provenance == .validated)
        }
    }

    var elapsedLabel: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var evidenceCoverage: Double {
        guard !entities.isEmpty else { return 0 }
        let grounded = entities.filter { $0.provenance == .heard || $0.provenance == .validated }.count
        return Double(grounded) / Double(entities.count)
    }

    var averageConfidence: Double {
        guard !claims.isEmpty else { return 0 }
        return claims.map(\.confidence).reduce(0, +) / Double(claims.count)
    }

    var unansweredQuestionCount: Int {
        questions.filter { !$0.isAsked }.count
    }

    var selectedSystemAudioSource: SystemAudioCaptureSource? {
        guard let selectedSystemAudioSourceID else { return nil }
        return systemAudioSources.first(where: { $0.id == selectedSystemAudioSourceID })
    }

    func startDemoIfNeeded() {
        guard activeSessionSelected, demoStep < Self.totalDemoSteps, simulationTask == nil else { return }
        captureState = .listening
        simulationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_100_000_000)
                guard !Task.isCancelled, let self else { return }
                self.elapsedSeconds += 4
                self.applyNextDemoStep()

                if self.demoStep >= Self.totalDemoSteps {
                    self.captureState = .complete
                    self.simulationTask = nil
                    return
                }
            }
        }
    }

    func pauseDemo() {
        simulationTask?.cancel()
        simulationTask = nil
        if captureState == .listening {
            captureState = .paused
        }
    }

    func toggleCapture() {
        if simulationTask != nil {
            pauseDemo()
            return
        }
        if let liveCaptureToggle {
            liveCaptureToggle()
            return
        }
        if captureState == .listening {
            pauseDemo()
        } else if demoStep < Self.totalDemoSteps {
            startDemoIfNeeded()
        }
    }

    func selectAudioMode(_ mode: AudioCaptureMode) {
        guard captureState != .listening else { return }
        audioCaptureMode = mode
        if mode == .onlineMeeting, systemAudioSources.isEmpty {
            systemAudioRefresh?()
        }
    }

    func refreshSystemAudioSources() {
        guard captureState != .listening else { return }
        systemAudioRefresh?()
    }

    func importVisualEvidence() {
        guard !visualEvidencePhase.isWorking else { return }
        visualEvidenceImport?()
    }

    func replayDemo() {
        pauseDemo()
        sessions[0] = Self.demoSession
        selectedSessionID = Self.demoSession.id
        loadSeed()
        startDemoIfNeeded()
    }

    /// Moves from the static, explicitly replayable product tour into a clean live session.
    /// Pausing and resuming the same session preserves everything already captured.
    func beginLiveSessionIfNeeded() {
        pauseDemo()
        guard !hasStartedLiveSession else { return }
        hasStartedLiveSession = true
        activeEvidenceSessionID = "session-\(UUID().uuidString.lowercased())"
        elapsedSeconds = 0
        transcript = []
        entities = []
        relationships = []
        claims = []
        questions = []
        quickWins = []
        artifacts = Self.draftingArtifacts
        projectionEvidenceByID = [:]
        claimProvenanceByID = [:]
        claimEvidenceIDsByID = [:]
        selectedPOCQuickWinID = nil
        resetVisualEvidence()
        selectedEntityID = nil
        liveError = nil
    }

    /// Applies a validated, deterministic projection. Stable content identifiers make retries
    /// idempotent while replacement allows later evidence to strengthen an existing item.
    func apply(_ projection: ClaimProposalProjection) {
        Self.upsert(projection.entities, into: &entities)
        Self.upsert(projection.relationships, into: &relationships)
        Self.upsert(projection.claims, into: &claims)

        for link in projection.entityEvidence + projection.relationshipEvidence {
            projectionEvidenceByID[link.projectionID] = link
        }
        for provenance in projection.claimProvenance {
            claimProvenanceByID[provenance.projectedClaimID] = provenance
            claimEvidenceIDsByID[provenance.projectedClaimID] = provenance.evidenceIDs
        }
        if selectedEntityID == nil {
            selectedEntityID = projection.entities.first?.id
        }
    }

    func refreshDerivedIntelligence() {
        let additions = DiscoveryGapEngine().derive(from: self)
        Self.upsert(additions, into: &questions)
        quickWins = QuickWinEngine().rank(QuickWinSnapshot(workspace: self))
        if let selectedPOCQuickWinID,
           !quickWins.contains(where: { $0.id == selectedPOCQuickWinID }) {
            self.selectedPOCQuickWinID = nil
        }
    }

    func beginVisualEvidenceImport() {
        visualEvidencePhase = .preparing
        visualEvidenceAsset = nil
        visualEvidenceProposals = []
        visualEvidenceReviewError = nil
        reviewingVisualObservationIDs = []
        visualEvidenceMessage = "Normalizing the selected image inside Scout's safety limits…"
    }

    func markVisualEvidencePersisted(_ receipt: LiveEventJournal.ImageEvidenceReceipt) {
        visualEvidencePhase = .persisted
        visualEvidenceAsset = VisualEvidenceAssetSummary(
            evidenceID: receipt.evidenceID.rawValue,
            assetSHA256: receipt.assetSHA256,
            pixelWidth: receipt.pixelWidth,
            pixelHeight: receipt.pixelHeight,
            byteCount: receipt.byteCount,
            model: nil,
            modelCallReceiptID: nil
        )
        visualEvidenceMessage = "Evidence committed. Asking the model for bounded observations…"
    }

    func markVisualEvidenceAnalyzing() {
        visualEvidencePhase = .analyzing
    }

    /// Applies only non-canonical proposal cards after the journal has committed both the image
    /// evidence and its provider receipt. Nothing here is treated as an accepted fact.
    func applyVisualEvidenceObservation(
        _ result: ImageObservationResult,
        evidence: LiveEventJournal.ImageEvidenceReceipt,
        observation: LiveEventJournal.ImageObservationReceipt
    ) {
        let cards = observation.observations.map(VisualObservationUIProjector.card)

        visualEvidenceAsset = VisualEvidenceAssetSummary(
            evidenceID: evidence.evidenceID.rawValue,
            assetSHA256: evidence.assetSHA256,
            pixelWidth: evidence.pixelWidth,
            pixelHeight: evidence.pixelHeight,
            byteCount: evidence.byteCount,
            model: result.modelCall.model,
            modelCallReceiptID: observation.modelCallReceiptID.rawValue
        )
        visualEvidenceProposals = cards
        visualEvidenceReviewError = nil
        reviewingVisualObservationIDs = []
        visualEvidencePhase = .ready
        visualEvidenceMessage = cards.isEmpty
            ? "No structured observations were proposed. The visual evidence remains durable."
            : "\(cards.count) model \(cards.count == 1 ? "proposal" : "proposals"). Every item needs human validation."
        destination = .evidence
    }

    func confirmVisualObservation(_ id: String) {
        reviewVisualObservation(id, disposition: .confirmed)
    }

    func rejectVisualObservation(_ id: String) {
        reviewVisualObservation(id, disposition: .rejected)
    }

    func setVisualObservationReviewInProgress(_ id: String, _ inProgress: Bool) {
        if inProgress {
            reviewingVisualObservationIDs.insert(id)
            visualEvidenceReviewError = nil
        } else {
            reviewingVisualObservationIDs.remove(id)
        }
    }

    func applyVisualObservationReview(_ id: String, status: VisualEvidenceReviewStatus) {
        guard let index = visualEvidenceProposals.firstIndex(where: { $0.id == id }) else { return }
        let existing = visualEvidenceProposals[index]
        visualEvidenceProposals[index] = VisualEvidenceProposalCard(
            id: existing.id,
            kind: existing.kind,
            title: existing.title,
            detail: existing.detail,
            basis: existing.basis,
            confidence: existing.confidence,
            reviewStatus: status
        )
        reviewingVisualObservationIDs.remove(id)
        visualEvidenceReviewError = nil
        refreshVisualEvidenceReviewSummary()
    }

    func failVisualObservationReview(_ id: String, message: String) {
        reviewingVisualObservationIDs.remove(id)
        visualEvidenceReviewError = "Review not saved. \(message)"
    }

    private func reviewVisualObservation(
        _ id: String,
        disposition: VisualEvidenceReviewStatus
    ) {
        guard disposition != .proposed,
              visualEvidenceProposals.first(where: { $0.id == id })?.reviewStatus == .proposed,
              !reviewingVisualObservationIDs.contains(id)
        else { return }
        visualEvidenceReview?(id, disposition)
    }

    private func refreshVisualEvidenceReviewSummary() {
        let confirmed = visualEvidenceProposals.filter { $0.reviewStatus == .confirmed }.count
        let rejected = visualEvidenceProposals.filter { $0.reviewStatus == .rejected }.count
        let proposed = visualEvidenceProposals.count - confirmed - rejected
        visualEvidenceMessage = "\(confirmed) confirmed · \(rejected) rejected · \(proposed) awaiting review. Confirmed observations remain evidence only."
    }

    func failVisualEvidenceImport(_ message: String, evidenceRetained: Bool) {
        visualEvidencePhase = .failed
        visualEvidenceProposals = []
        visualEvidenceMessage = evidenceRetained
            ? "Evidence retained; no model proposal was applied. \(message)"
            : message
        visualEvidenceReviewError = nil
        reviewingVisualObservationIDs = []
        destination = .evidence
    }

    func selectEntity(_ id: String) {
        selectedEntityID = id
    }

    func markQuestionAsked(_ id: String) {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[index].isAsked.toggle()
    }

    func selectPOC(_ quickWinID: String) {
        guard quickWins.contains(where: { $0.id == quickWinID }) else { return }
        selectedPOCQuickWinID = quickWinID
    }

    /// Replaces every disposable cockpit projection with one rebuilt from a verified event replay.
    func applyReplayProjection(_ projection: WorkspaceReplayProjection) {
        pauseDemo()
        let titleParts = projection.title.components(separatedBy: " — ")
        let organization = titleParts.count > 1 ? titleParts[0] : "Recovered discovery"
        let title = titleParts.count > 1
            ? titleParts.dropFirst().joined(separator: " — ")
            : projection.title
        let minutes = max(1, Int(ceil(Double(projection.elapsedSeconds) / 60)))
        sessions[0] = SessionSummary(
            id: projection.sessionID,
            organization: organization,
            title: title,
            relativeDate: "Recovered",
            duration: "\(minutes) min",
            participantCount: projection.participantCount,
            status: projection.captureState == .complete ? .ready : .live,
            summary: "Verified replay from Scout's encrypted event journal"
        )
        selectedSessionID = projection.sessionID
        activeEvidenceSessionID = projection.sessionID
        captureState = projection.captureState
        elapsedSeconds = projection.elapsedSeconds
        transcript = projection.transcript
        entities = projection.entities
        relationships = projection.relationships
        claims = projection.claims
        projectionEvidenceByID = projection.projectionEvidenceByID
        claimProvenanceByID = [:]
        claimEvidenceIDsByID = projection.claimEvidenceIDsByID
        selectedPOCQuickWinID = nil
        selectedEntityID = projection.entities.first?.id
        questions = []
        artifacts = Self.draftingArtifacts
        visualEvidenceAsset = projection.visualEvidenceAsset
        visualEvidenceProposals = projection.visualEvidenceProposals
        visualEvidencePhase = projection.visualEvidenceAsset == nil ? .idle : .ready
        visualEvidenceReviewError = nil
        reviewingVisualObservationIDs = []
        if projection.visualEvidenceAsset == nil {
            visualEvidenceMessage = nil
        } else {
            refreshVisualEvidenceReviewSummary()
        }
        hasStartedLiveSession = true
        refreshDerivedIntelligence()
        liveError = nil
    }

    private func loadSeed() {
        hasStartedLiveSession = false
        activeEvidenceSessionID = selectedSessionID
        demoStep = 0
        captureState = .paused
        elapsedSeconds = 1_842
        liveError = nil
        resetVisualEvidence()
        claimEvidenceIDsByID = [:]
        selectedPOCQuickWinID = nil
        transcript = [
            TranscriptUtterance(
                id: "utterance-0",
                speaker: alex,
                secondsFromStart: 1_822,
                text: "If this engagement succeeds, what changes for the customer and for your team?",
                provenance: .heard,
                confidence: 0.99,
                isFinal: true
            ),
            TranscriptUtterance(
                id: "utterance-1",
                speaker: maya,
                secondsFromStart: 1_830,
                text: "We need to cut order exception resolution from two days to under two hours, without adding headcount.",
                provenance: .heard,
                confidence: 0.98,
                isFinal: true
            )
        ]
        entities = [
            GraphEntity(
                id: "goal-resolution",
                title: "Resolve in < 2h",
                subtitle: "Business outcome",
                kind: .goal,
                x: 0.14,
                y: 0.23,
                provenance: .heard,
                confidence: 0.98
            ),
            GraphEntity(
                id: "process-exceptions",
                title: "Order exceptions",
                subtitle: "Current workflow",
                kind: .process,
                x: 0.40,
                y: 0.23,
                provenance: .heard,
                confidence: 0.96
            )
        ]
        relationships = [
            GraphRelationship(
                id: "edge-process-goal",
                sourceID: "process-exceptions",
                targetID: "goal-resolution",
                label: "blocks",
                confidence: 0.94,
                isFriction: true,
                provenance: .heard,
                needsValidation: false,
                supportingClaimIDs: ["claim-resolution"],
                evidenceIDs: ["evidence-claim-resolution"]
            )
        ]
        claims = [
            TrustClaim(
                id: "claim-resolution",
                title: "Two-hour resolution target",
                detail: "Order exceptions should be resolved in under two hours without increasing headcount.",
                provenance: .heard,
                confidence: 0.98,
                evidenceQuote: "…cut order exception resolution from two days to under two hours…",
                speakerName: maya.name,
                timestamp: "30:30",
                relatedEntityID: "goal-resolution",
                needsValidation: false
            )
        ]
        questions = [
            DiscoveryQuestion(
                id: "question-baseline",
                priority: .high,
                topic: "Success metric",
                text: "How is exception resolution time measured today?",
                rationale: "A trusted baseline is needed to prove the two-hour outcome.",
                isAsked: false
            )
        ]
        quickWins = []
        artifacts = Self.draftingArtifacts
        selectedEntityID = "goal-resolution"
    }

    private func resetVisualEvidence() {
        visualEvidencePhase = .idle
        visualEvidenceAsset = nil
        visualEvidenceProposals = []
        visualEvidenceMessage = nil
        visualEvidenceReviewError = nil
        reviewingVisualObservationIDs = []
    }

    private static func upsert<Value: Identifiable>(_ additions: [Value], into values: inout [Value])
    where Value.ID: Hashable {
        var indexByID = Dictionary(uniqueKeysWithValues: values.indices.map { (values[$0].id, $0) })
        for addition in additions {
            if let index = indexByID[addition.id] {
                values[index] = addition
            } else {
                indexByID[addition.id] = values.count
                values.append(addition)
            }
        }
    }

    private static let totalDemoSteps = 6

    private static let draftingArtifacts: [ActionArtifact] = [
        ActionArtifact(
            id: "artifact-brief",
            title: "Customer reality brief",
            detail: "Goals, constraints, stakeholders, and open questions",
            symbol: "doc.text",
            readiness: .drafting
        ),
        ActionArtifact(
            id: "artifact-architecture",
            title: "Current-state architecture",
            detail: "Evidence-linked systems and information flows",
            symbol: "point.3.connected.trianglepath.dotted",
            readiness: .drafting
        ),
        ActionArtifact(
            id: "artifact-codex",
            title: "Codex build context",
            detail: "Structured constraints, acceptance criteria, and tasks",
            symbol: "hammer",
            readiness: .drafting
        ),
    ]

    private func applyNextDemoStep() {
        guard demoStep < Self.totalDemoSteps else { return }

        switch demoStep {
        case 0:
            transcript.append(
                TranscriptUtterance(
                    id: "utterance-2",
                    speaker: raj,
                    secondsFromStart: 1_846,
                    text: "Salesforce owns the customer record. NetSuite owns inventory, but the two only reconcile through a nightly CSV export.",
                    provenance: .heard,
                    confidence: 0.97,
                    isFinal: true
                )
            )
            entities.append(contentsOf: [
                GraphEntity(id: "system-salesforce", title: "Salesforce", subtitle: "Customer record", kind: .system, x: 0.18, y: 0.55, provenance: .heard, confidence: 0.98),
                GraphEntity(id: "system-netsuite", title: "NetSuite", subtitle: "Inventory system", kind: .system, x: 0.49, y: 0.55, provenance: .heard, confidence: 0.98),
                GraphEntity(id: "data-csv", title: "Nightly CSV", subtitle: "Batch handoff", kind: .data, x: 0.34, y: 0.79, provenance: .heard, confidence: 0.96)
            ])
            relationships.append(contentsOf: [
                GraphRelationship(id: "edge-sf-csv", sourceID: "system-salesforce", targetID: "data-csv", label: "exports", confidence: 0.93, isFriction: false, provenance: .heard, needsValidation: false, supportingClaimIDs: ["claim-nightly"], evidenceIDs: ["evidence-claim-nightly"]),
                GraphRelationship(id: "edge-csv-ns", sourceID: "data-csv", targetID: "system-netsuite", label: "reconciles nightly", confidence: 0.94, isFriction: true, provenance: .heard, needsValidation: false, supportingClaimIDs: ["claim-nightly"], evidenceIDs: ["evidence-claim-nightly"]),
                GraphRelationship(id: "edge-ns-process", sourceID: "system-netsuite", targetID: "process-exceptions", label: "inventory status", confidence: 0.91, isFriction: false, provenance: .heard, needsValidation: false, supportingClaimIDs: ["claim-nightly"], evidenceIDs: ["evidence-claim-nightly"])
            ])
            claims.append(
                TrustClaim(id: "claim-nightly", title: "Inventory reconciliation is batch-only", detail: "Salesforce and NetSuite reconcile inventory through a nightly CSV export.", provenance: .heard, confidence: 0.97, evidenceQuote: "…the two only reconcile through a nightly CSV export.", speakerName: raj.name, timestamp: "30:46", relatedEntityID: "data-csv", needsValidation: false)
            )
            selectedEntityID = "data-csv"

        case 1:
            transcript.append(
                TranscriptUtterance(
                    id: "utterance-3",
                    speaker: maya,
                    secondsFromStart: 1_858,
                    text: "Support agents copy order IDs from Zendesk into both systems. Most exceptions need three handoffs before anyone can answer the customer.",
                    provenance: .heard,
                    confidence: 0.96,
                    isFinal: true
                )
            )
            entities.append(contentsOf: [
                GraphEntity(id: "system-zendesk", title: "Zendesk", subtitle: "Support workspace", kind: .system, x: 0.75, y: 0.55, provenance: .heard, confidence: 0.97),
                GraphEntity(id: "friction-rekey", title: "Manual re-keying", subtitle: "3 handoffs", kind: .friction, x: 0.72, y: 0.25, provenance: .heard, confidence: 0.95)
            ])
            relationships.append(contentsOf: [
                GraphRelationship(id: "edge-zendesk-rekey", sourceID: "system-zendesk", targetID: "friction-rekey", label: "creates", confidence: 0.94, isFriction: true, provenance: .heard, needsValidation: false, supportingClaimIDs: ["claim-rekey"], evidenceIDs: ["evidence-claim-rekey"]),
                GraphRelationship(id: "edge-rekey-process", sourceID: "friction-rekey", targetID: "process-exceptions", label: "delays", confidence: 0.94, isFriction: true, provenance: .heard, needsValidation: false, supportingClaimIDs: ["claim-rekey"], evidenceIDs: ["evidence-claim-rekey"])
            ])
            claims.append(
                TrustClaim(id: "claim-rekey", title: "Agents re-key order IDs", detail: "Support agents manually copy the same order identifier across Zendesk, Salesforce, and NetSuite.", provenance: .heard, confidence: 0.96, evidenceQuote: "Support agents copy order IDs from Zendesk into both systems.", speakerName: maya.name, timestamp: "30:58", relatedEntityID: "friction-rekey", needsValidation: false)
            )
            questions.append(
                DiscoveryQuestion(id: "question-volume", priority: .critical, topic: "Volume", text: "How many order exceptions and manual handoffs occur per day?", rationale: "Volume determines the automation upside and POC capacity target.", isAsked: false)
            )
            selectedEntityID = "friction-rekey"

        case 2:
            transcript.append(
                TranscriptUtterance(
                    id: "utterance-4",
                    speaker: raj,
                    secondsFromStart: 1_871,
                    text: "Customer PII must stay in our EU boundary. Any integration can pass order status and IDs, but not names, emails, or addresses.",
                    provenance: .heard,
                    confidence: 0.98,
                    isFinal: true
                )
            )
            entities.append(
                GraphEntity(id: "policy-eu", title: "EU data boundary", subtitle: "No PII in integration", kind: .policy, x: 0.88, y: 0.79, provenance: .heard, confidence: 0.98)
            )
            relationships.append(
                GraphRelationship(id: "edge-policy-zendesk", sourceID: "policy-eu", targetID: "system-zendesk", label: "constrains", confidence: 0.96, isFriction: false, provenance: .heard, needsValidation: true, supportingClaimIDs: ["claim-eu"], evidenceIDs: ["evidence-claim-eu"])
            )
            claims.append(
                TrustClaim(id: "claim-eu", title: "Integration must exclude PII", detail: "Order status and identifiers may cross the boundary; names, emails, and addresses may not.", provenance: .heard, confidence: 0.98, evidenceQuote: "…can pass order status and IDs, but not names, emails, or addresses.", speakerName: raj.name, timestamp: "31:11", relatedEntityID: "policy-eu", needsValidation: true)
            )
            questions.append(
                DiscoveryQuestion(id: "question-controls", priority: .high, topic: "Guardrail", text: "Which existing control validates payloads before they leave the EU boundary?", rationale: "A POC must inherit or explicitly implement this control.", isAsked: false)
            )
            selectedEntityID = "policy-eu"

        case 3:
            transcript.append(
                TranscriptUtterance(
                    id: "utterance-5",
                    speaker: maya,
                    secondsFromStart: 1_885,
                    text: "The stale stock position contributes to about eighteen percent of abandoned carts. Fixing that would be visible to the board immediately.",
                    provenance: .heard,
                    confidence: 0.95,
                    isFinal: true
                )
            )
            entities.append(
                GraphEntity(id: "goal-conversion", title: "Recover conversion", subtitle: "18% cart signal", kind: .goal, x: 0.62, y: 0.79, provenance: .heard, confidence: 0.95)
            )
            relationships.append(
                GraphRelationship(id: "edge-inventory-conversion", sourceID: "system-netsuite", targetID: "goal-conversion", label: "stock accuracy", confidence: 0.89, isFriction: false, provenance: .heard, needsValidation: true, supportingClaimIDs: ["claim-conversion"], evidenceIDs: ["evidence-claim-conversion"])
            )
            claims.append(
                TrustClaim(id: "claim-conversion", title: "Stock accuracy affects conversion", detail: "The customer estimates stale stock contributes to 18% of cart abandonment.", provenance: .heard, confidence: 0.95, evidenceQuote: "…contributes to about eighteen percent of abandoned carts.", speakerName: maya.name, timestamp: "31:25", relatedEntityID: "goal-conversion", needsValidation: true)
            )
            quickWins.append(
                QuickWin(id: "win-status", title: "Exception status assistant", detail: "Give support a grounded, PII-safe order-status view across the three systems.", impact: 5, effort: 2, readiness: 4, timeToValue: "2–3 weeks", evidenceCount: 6, supportingClaimIDs: ["claim-rekey", "claim-eu", "claim-resolution"])
            )
            selectedEntityID = "goal-conversion"

        case 4:
            transcript.append(
                TranscriptUtterance(
                    id: "utterance-6",
                    speaker: raj,
                    secondsFromStart: 1_899,
                    text: "The export runs at 2 a.m. There is no alert when it fails, so operations often discovers the issue from a customer ticket the next morning.",
                    provenance: .heard,
                    confidence: 0.97,
                    isFinal: true
                )
            )
            claims.append(
                TrustClaim(id: "claim-failure", title: "Batch failures are silent", detail: "Operations learns about failed inventory exports indirectly from customer tickets.", provenance: .heard, confidence: 0.97, evidenceQuote: "There is no alert when it fails…", speakerName: raj.name, timestamp: "31:39", relatedEntityID: "data-csv", needsValidation: false)
            )
            quickWins.append(
                QuickWin(id: "win-monitor", title: "Inventory feed sentinel", detail: "Detect missing or anomalous exports and notify operations before customer impact.", impact: 4, effort: 1, readiness: 5, timeToValue: "3–5 days", evidenceCount: 4, supportingClaimIDs: ["claim-nightly", "claim-failure", "claim-resolution"])
            )
            questions.append(
                DiscoveryQuestion(id: "question-owner", priority: .explore, topic: "Ownership", text: "Who owns the inventory feed and the incident response today?", rationale: "A named operator is required for alert routing and POC acceptance.", isAsked: false)
            )
            selectedEntityID = "data-csv"

        default:
            transcript.append(
                TranscriptUtterance(
                    id: "utterance-7",
                    speaker: alex,
                    secondsFromStart: 1_914,
                    text: "I’m hearing a safe first move: detect failed feeds, then give support a read-only exception view. We can validate impact without changing the systems of record.",
                    provenance: .proposed,
                    confidence: 0.91,
                    isFinal: true
                )
            )
            entities.append(
                GraphEntity(id: "action-poc", title: "Read-only POC", subtitle: "Detect + explain", kind: .action, x: 0.88, y: 0.25, provenance: .proposed, confidence: 0.91)
            )
            relationships.append(contentsOf: [
                GraphRelationship(id: "edge-action-feed", sourceID: "action-poc", targetID: "data-csv", label: "monitors", confidence: 0.90, isFriction: false, provenance: .proposed, needsValidation: true, supportingClaimIDs: ["claim-poc"], evidenceIDs: ["evidence-claim-poc"]),
                GraphRelationship(id: "edge-action-process", sourceID: "action-poc", targetID: "process-exceptions", label: "accelerates", confidence: 0.88, isFriction: false, provenance: .proposed, needsValidation: true, supportingClaimIDs: ["claim-poc"], evidenceIDs: ["evidence-claim-poc"])
            ])
            claims.append(
                TrustClaim(id: "claim-poc", title: "Read-only POC is the safest wedge", detail: "Monitoring plus a grounded support view can demonstrate value without mutating systems of record.", provenance: .proposed, confidence: 0.91, evidenceQuote: "I’m hearing a safe first move…", speakerName: alex.name, timestamp: "31:54", relatedEntityID: "action-poc", needsValidation: true)
            )
            artifacts = artifacts.map {
                ActionArtifact(id: $0.id, title: $0.title, detail: $0.detail, symbol: $0.symbol, readiness: $0.id == "artifact-codex" ? .review : .ready)
            }
            selectedEntityID = "action-poc"
        }

        demoStep += 1
    }
}
