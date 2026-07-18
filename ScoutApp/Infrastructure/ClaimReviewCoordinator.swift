import Foundation
import ScoutCore
import ScoutLocalReviewAuthority

/// Bridges explicit workspace review intents to Scout's authenticated canonical command boundary.
/// The coordinator never edits a `TrustClaim`; successful work is projected only from the
/// canonical state returned by the journal.
@MainActor
final class ClaimReviewCoordinator {
    typealias AuthorizeReview = @Sendable (LocalReviewIntent) async throws -> AuthenticatedLocalReview
    typealias PrepareReview = @Sendable (
        _ sessionID: String,
        _ claimID: String,
        _ status: ClaimStatus
    ) async throws -> LiveEventJournal.ClaimReviewPreparation
    typealias RecordReview = @Sendable (
        _ sessionID: String,
        _ authenticatedReview: AuthenticatedLocalReview
    ) async throws -> LiveEventJournal.ClaimReviewReceipt

    private weak var workspace: ScoutWorkspace?
    private let prepareReview: PrepareReview
    private let recordReview: RecordReview
    private let authorizeReview: AuthorizeReview
    private var reviewTasks: [String: Task<Void, Never>] = [:]

    convenience init(
        workspace: ScoutWorkspace,
        journal: LiveEventJournal,
        authorizeReview: @escaping AuthorizeReview = {
            try await DeviceOwnerReviewAuthority().authorize($0)
        }
    ) {
        self.init(
            workspace: workspace,
            prepareReview: { sessionID, claimID, status in
                try await journal.prepareClaimReview(
                    sessionID: sessionID,
                    claimID: claimID,
                    status: status
                )
            },
            recordReview: { sessionID, authenticatedReview in
                try await journal.recordClaimReview(
                    sessionID: sessionID,
                    authenticatedReview: authenticatedReview
                )
            },
            authorizeReview: authorizeReview
        )
    }

    init(
        workspace: ScoutWorkspace,
        prepareReview: @escaping PrepareReview,
        recordReview: @escaping RecordReview,
        authorizeReview: @escaping AuthorizeReview
    ) {
        self.workspace = workspace
        self.prepareReview = prepareReview
        self.recordReview = recordReview
        self.authorizeReview = authorizeReview
    }

    func install() {
        workspace?.claimReview = { [weak self] claimID, decision in
            self?.review(claimID, decision: decision)
        }
    }

    func cancel() {
        let claimIDs = Array(reviewTasks.keys)
        reviewTasks.values.forEach { $0.cancel() }
        reviewTasks.removeAll()
        for claimID in claimIDs {
            workspace?.setClaimReviewInProgress(claimID, false)
        }
    }

    private func review(_ claimID: String, decision: ClaimReviewDecision) {
        guard let workspace,
              reviewTasks[claimID] == nil,
              isAllowed(decision, for: workspace.claims.first(where: { $0.id == claimID })?.reviewStatus)
        else { return }

        let sessionID = workspace.activeEvidenceSessionID
        let status: ClaimStatus = switch decision {
        case .accept, .reattestAcceptance: .accepted
        case .reject: .rejected
        }
        workspace.setClaimReviewInProgress(claimID, true)
        reviewTasks[claimID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reviewTasks[claimID] = nil }
            do {
                let preparation = try await self.prepareReview(sessionID, claimID, status)
                try Task.checkCancellation()
                guard self.workspace?.activeEvidenceSessionID == sessionID else {
                    self.workspace?.setClaimReviewInProgress(claimID, false)
                    return
                }
                let receipt: LiveEventJournal.ClaimReviewReceipt
                switch preparation {
                case let .alreadyCommitted(committed):
                    receipt = committed

                case let .authorizationRequired(intent):
                    let authorization = try await self.authorizeReview(intent)
                    try Task.checkCancellation()
                    guard self.workspace?.activeEvidenceSessionID == sessionID else {
                        self.workspace?.setClaimReviewInProgress(claimID, false)
                        return
                    }
                    receipt = try await self.recordReview(sessionID, authorization)
                }

                try Task.checkCancellation()
                guard let workspace = self.workspace else { return }
                guard workspace.activeEvidenceSessionID == sessionID else {
                    workspace.setClaimReviewInProgress(claimID, false)
                    return
                }
                guard let projection = WorkspaceStateProjector().project(receipt.canonicalState) else {
                    throw ClaimReviewCoordinatorError.missingCanonicalProjection
                }
                workspace.applyCanonicalClaimProjection(projection)
            } catch {
                guard let workspace = self.workspace else { return }
                if Task.isCancelled || workspace.activeEvidenceSessionID != sessionID {
                    workspace.setClaimReviewInProgress(claimID, false)
                } else {
                    workspace.failClaimReview(claimID, message: error.localizedDescription)
                }
            }
        }
    }

    private func isAllowed(
        _ decision: ClaimReviewDecision,
        for status: ClaimReviewStatus?
    ) -> Bool {
        guard let status else { return false }
        return switch (status, decision) {
        case (.proposed, .accept), (.proposed, .reject),
             (.legacyAccepted, .reattestAcceptance):
            true
        default:
            false
        }
    }
}

private enum ClaimReviewCoordinatorError: LocalizedError {
    case missingCanonicalProjection

    var errorDescription: String? {
        "Scout committed the claim review but could not rebuild its canonical workspace projection."
    }
}
