import AppKit
import Foundation
import ScoutCore
import ScoutLocalReviewAuthority
import UniformTypeIdentifiers

/// Owns the explicit user-selection workflow for whiteboards and architecture images.
/// Its ordering is intentional: normalize, commit evidence, request observations, commit the
/// provider receipt, then (and only then) expose non-canonical proposals in the workspace.
@MainActor
final class VisualEvidenceCoordinator {
    typealias PrepareImage = @Sendable (URL) throws -> PreparedImageEvidence
    typealias ObserveImage = @Sendable (ImageObservationRequest) async throws -> ImageObservationResult
    typealias SelectImage = @MainActor @Sendable () async -> URL?
    typealias AuthorizeReview = @Sendable (LocalReviewIntent) async throws -> AuthenticatedLocalReview
    typealias PrepareReview = @Sendable (
        _ sessionID: String,
        _ observationID: String,
        _ disposition: VisualObservationDisposition
    ) async throws -> LiveEventJournal.VisualObservationReviewPreparation
    typealias RecordReview = @Sendable (
        _ sessionID: String,
        _ authenticatedReview: AuthenticatedLocalReview
    ) async throws -> LiveEventJournal.VisualObservationReviewReceipt

    private weak var workspace: ScoutWorkspace?
    private let journal: LiveEventJournal
    private let prepareImage: PrepareImage
    private let observeImage: ObserveImage
    private let selectImage: SelectImage
    private let authorizeReview: AuthorizeReview
    private let prepareReview: PrepareReview
    private let recordReview: RecordReview
    private var importTask: Task<Void, Never>?
    private var reviewTasks: [String: Task<Void, Never>] = [:]

    convenience init(
        workspace: ScoutWorkspace,
        journal: LiveEventJournal,
        importer: ImageEvidenceImporter = .init(),
        client: ImageObservationClient = .init()
    ) {
        let reviewAuthority = DeviceOwnerReviewAuthority()
        self.init(
            workspace: workspace,
            journal: journal,
            prepareImage: { try importer.prepareUserSelectedImage(at: $0) },
            observeImage: { try await client.observe($0) },
            selectImage: Self.presentImagePanel,
            authorizeReview: { try await reviewAuthority.authorize($0) }
        )
    }

    init(
        workspace: ScoutWorkspace,
        journal: LiveEventJournal,
        prepareImage: @escaping PrepareImage,
        observeImage: @escaping ObserveImage,
        selectImage: @escaping SelectImage = VisualEvidenceCoordinator.presentImagePanel,
        authorizeReview: @escaping AuthorizeReview = {
            try await DeviceOwnerReviewAuthority().authorize($0)
        },
        prepareReview: PrepareReview? = nil,
        recordReview: RecordReview? = nil
    ) {
        self.workspace = workspace
        self.journal = journal
        self.prepareImage = prepareImage
        self.observeImage = observeImage
        self.selectImage = selectImage
        self.authorizeReview = authorizeReview
        self.prepareReview = prepareReview ?? { sessionID, observationID, disposition in
            try await journal.prepareVisualObservationReview(
                sessionID: sessionID,
                observationID: observationID,
                disposition: disposition
            )
        }
        self.recordReview = recordReview ?? { sessionID, authenticatedReview in
            try await journal.recordVisualObservationReview(
                sessionID: sessionID,
                authenticatedReview: authenticatedReview
            )
        }
    }

    func install() {
        workspace?.visualEvidenceImport = { [weak self] in
            self?.chooseAndImport()
        }
        workspace?.visualEvidenceReview = { [weak self] observationID, disposition in
            self?.review(observationID, disposition: disposition)
        }
    }

    func cancel() {
        importTask?.cancel()
        importTask = nil
        let observationIDs = Array(reviewTasks.keys)
        reviewTasks.values.forEach { $0.cancel() }
        reviewTasks.removeAll()
        for observationID in observationIDs {
            workspace?.setVisualObservationReviewInProgress(observationID, false)
        }
    }

    /// Testable workflow entry point after the user has explicitly selected a local file.
    func importUserSelectedImage(at url: URL) async {
        guard let workspace else { return }

        workspace.beginLiveSessionIfNeeded()
        workspace.beginVisualEvidenceImport()
        let sessionID = workspace.activeEvidenceSessionID
        let title = "\(workspace.selectedSession.organization) — \(workspace.selectedSession.title)"
        var durableEvidence: LiveEventJournal.ImageEvidenceReceipt?

        do {
            let prepareImage = self.prepareImage
            let image = try await Task.detached(priority: .userInitiated) {
                try prepareImage(url)
            }.value
            try Task.checkCancellation()

            try await journal.prepareSession(
                sessionID: sessionID,
                title: title,
                speakers: []
            )
            let evidence = try await journal.recordImageEvidence(
                sessionID: sessionID,
                image: image
            )
            durableEvidence = evidence
            workspace.markVisualEvidencePersisted(evidence)
            workspace.markVisualEvidenceAnalyzing()

            let result = try await observeImage(ImageObservationRequest(
                sessionID: sessionID,
                image: image
            ))
            try Task.checkCancellation()

            let observation = try await journal.recordImageObservation(
                sessionID: sessionID,
                evidence: evidence,
                result: result
            )
            workspace.applyVisualEvidenceObservation(
                result,
                evidence: evidence,
                observation: observation
            )
        } catch is CancellationError {
            workspace.failVisualEvidenceImport(
                "Visual evidence analysis was cancelled.",
                evidenceRetained: durableEvidence != nil
            )
        } catch {
            workspace.failVisualEvidenceImport(
                error.localizedDescription,
                evidenceRetained: durableEvidence != nil
            )
        }
    }

    private func chooseAndImport() {
        guard importTask == nil else { return }
        importTask = Task { [weak self] in
            guard let self else { return }
            guard let url = await self.selectImage() else {
                self.importTask = nil
                return
            }
            await self.importUserSelectedImage(at: url)
            self.importTask = nil
        }
    }

    private func review(
        _ observationID: String,
        disposition: VisualEvidenceReviewStatus
    ) {
        guard let workspace,
              disposition != .proposed,
              reviewTasks[observationID] == nil
        else { return }
        let sessionID = workspace.activeEvidenceSessionID
        let coreDisposition: VisualObservationDisposition = disposition == .confirmed
            ? .confirmed
            : .rejected
        workspace.setVisualObservationReviewInProgress(observationID, true)
        reviewTasks[observationID] = Task { [weak self] in
            guard let self else { return }
            defer { self.reviewTasks[observationID] = nil }
            do {
                try Task.checkCancellation()
                let preparation = try await self.prepareReview(
                    sessionID,
                    observationID,
                    coreDisposition
                )
                try Task.checkCancellation()
                guard self.workspace?.activeEvidenceSessionID == sessionID else {
                    self.workspace?.setVisualObservationReviewInProgress(observationID, false)
                    return
                }
                let receipt: LiveEventJournal.VisualObservationReviewReceipt
                switch preparation {
                case let .alreadyCommitted(committed):
                    receipt = committed
                case let .authorizationRequired(intent):
                    let authorization = try await self.authorizeReview(intent)
                    try Task.checkCancellation()
                    guard self.workspace?.activeEvidenceSessionID == sessionID else {
                        self.workspace?.setVisualObservationReviewInProgress(observationID, false)
                        return
                    }
                    receipt = try await self.recordReview(sessionID, authorization)
                }
                try Task.checkCancellation()
                guard self.workspace?.activeEvidenceSessionID == sessionID else {
                    self.workspace?.setVisualObservationReviewInProgress(observationID, false)
                    return
                }
                guard let projection = WorkspaceStateProjector().project(receipt.canonicalState) else {
                    throw VisualReviewError.missingCanonicalProjection
                }
                self.workspace?.applyCanonicalVisualEvidenceProjection(projection)
            } catch {
                guard let workspace = self.workspace else { return }
                if Task.isCancelled || workspace.activeEvidenceSessionID != sessionID {
                    workspace.setVisualObservationReviewInProgress(observationID, false)
                } else {
                    workspace.failVisualObservationReview(
                        observationID,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private enum VisualReviewError: LocalizedError {
        case missingCanonicalProjection

        var errorDescription: String? {
            "Scout could not rebuild the visual review from canonical event history."
        }
    }

    private static func presentImagePanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import visual evidence"
        panel.message = "Choose one whiteboard, process sketch, or architecture image. Scout normalizes it and removes metadata before analysis."
        panel.prompt = "Import Evidence"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false

        var acceptedTypes: [UTType] = [.jpeg, .png, .heic]
        if let heif = UTType("public.heif") {
            acceptedTypes.append(heif)
        }
        panel.allowedContentTypes = acceptedTypes
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }
        return response == .OK ? panel.url : nil
    }
}
