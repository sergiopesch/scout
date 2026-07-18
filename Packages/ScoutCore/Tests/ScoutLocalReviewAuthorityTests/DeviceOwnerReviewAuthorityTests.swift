import Foundation
import ScoutCore
import Testing
@testable import ScoutLocalReviewAuthority

@Suite("Device-owner review authority")
struct DeviceOwnerReviewAuthorityTests {
    @Test("Successful device-owner authentication mints an exact opaque grant")
    func successfulAuthentication() async throws {
        let intent = try reviewIntent()
        let authenticatedAt = ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_000_123)
        let authority = DeviceOwnerReviewAuthority(
            evaluator: { reason in
                #expect(
                    reason
                        == "Authenticate to accept Scout claim claim-review-authority."
                )
                return true
            },
            clock: { authenticatedAt }
        )

        let grant = try await authority.authorize(intent)

        #expect(grant.intent == intent)
        #expect(grant.authorization.sessionID == intent.sessionID)
        #expect(grant.authorization.eventID == intent.eventID)
        #expect(grant.authorization.operationHash == intent.operationHash)
        #expect(grant.authorization.authenticatedAt == authenticatedAt)
        #expect(grant.authorization.assurance == .deviceOwnerAuthentication)
        #expect(grant.authorization.reviewer == .localDeviceOwner)
    }

    @Test("A denied authentication produces no review grant")
    func deniedAuthentication() async throws {
        let authority = DeviceOwnerReviewAuthority(
            evaluator: { _ in false },
            clock: { ScoutTimestamp(millisecondsSinceUnixEpoch: 0) }
        )

        await #expect(throws: DeviceOwnerReviewAuthorizationError.authenticationFailed) {
            _ = try await authority.authorize(try reviewIntent())
        }
    }

    @Test("Cancellation remains cancellation and produces no review grant")
    func cancelledAuthentication() async throws {
        let authority = DeviceOwnerReviewAuthority(
            evaluator: { _ in throw CancellationError() },
            clock: { ScoutTimestamp(millisecondsSinceUnixEpoch: 0) }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await authority.authorize(try reviewIntent())
        }
    }

    @Test("Cancellation wins even when an evaluator returns success afterward")
    func cancelledTaskCannotMintGrantAfterSuccess() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let authority = DeviceOwnerReviewAuthority(
            evaluator: { _ in
                started.continuation.yield()
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                return true
            },
            clock: { ScoutTimestamp(millisecondsSinceUnixEpoch: 0) }
        )
        let intent = try reviewIntent()
        let task = Task { try await authority.authorize(intent) }
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()

        task.cancel()
        release.continuation.yield()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        started.continuation.finish()
        release.continuation.finish()
    }

    private func reviewIntent() throws -> LocalReviewIntent {
        LocalReviewIntent(
            sessionID: try SessionID(validating: "session-review-authority"),
            eventID: try EventID(validating: "event-review-authority"),
            operation: .reviewClaim(ClaimReviewed(
                claimID: try ClaimID(validating: "claim-review-authority"),
                status: .accepted,
                trust: TrustAssessment(
                    origin: .confirmed,
                    confidence: try Confidence(basisPoints: 10_000),
                    validationStatus: .validated
                )
            )),
            targetEventID: try EventID(validating: "event-claim-proposal"),
            targetStateHash: SHA256Digest.hash(Data("claim-state".utf8))
        )
    }
}
