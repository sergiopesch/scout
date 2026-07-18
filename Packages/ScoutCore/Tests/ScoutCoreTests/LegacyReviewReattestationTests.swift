import Foundation
import Testing
@testable import ScoutCore

@Suite("Legacy local-review re-attestation")
struct LegacyReviewReattestationTests {
    @Test("A legacy terminal decision gains assurance without rewriting the decision")
    func reattestsLegacyClaimAppendOnly() throws {
        let history = try legacyClaimHistory()
        let state = try ScoutGraphReducer.replay(history.events)
        let originalClaim = try #require(state.claims[history.claimID])
        let eventID: EventID = testID("event-legacy-claim-attested")
        let operation = LocalReviewOperation.attestLegacyReview(.init(
            target: .claim(history.claimID)
        ))
        let intent = try LocalReviewIntent.preparing(
            eventID: eventID,
            operation: operation,
            in: state
        )

        #expect(intent.targetEventID == history.reviewEvent.id)
        #expect(intent.targetStateHash == .hash(originalClaim.canonicalValue))

        let grant = AuthenticatedLocalReview(intent: intent, authenticatedAt: timestamp(4))
        var chain = try chainContinuing(after: history.events)
        let event = try chain.seal(
            occurredAt: timestamp(5),
            recordedAt: timestamp(5),
            authenticatedReview: grant
        )
        let next = try ScoutGraphReducer.reduce(state, event: event)

        #expect(event.envelope.schemaVersion == .current)
        #expect(event.envelope.payload == .localReviewAttested(.init(
            target: .claim(history.claimID)
        )))
        #expect(next.claims[history.claimID] == originalClaim)
        #expect(next.claimReviewEvents[history.claimID] == history.reviewEvent.id)
        #expect(next.claimReviewAttestations[history.claimID]
            == .deviceOwnerAuthenticated(grant.authorization))
        #expect(next.consumedReviewAuthorizationIDs.contains(grant.authorization.id))

        let encoded = try JSONEncoder().encode(event.envelope)
        let decoded = try JSONDecoder().decode(ScoutEventEnvelope.self, from: encoded)
        #expect(decoded == event.envelope)

        let replayed = try ScoutGraphReducer.replay(history.events + [event.envelope])
        #expect(replayed.digest == next.digest)
        #expect(replayed.claims[history.claimID] == originalClaim)
        #expect(replayed.claimReviewEvents[history.claimID] == history.reviewEvent.id)
        #expect(replayed.claimReviewAttestations[history.claimID]
            == .deviceOwnerAuthenticated(grant.authorization))
    }

    @Test("A proposed target cannot be presented or committed as a legacy attestation")
    func rejectsProposedTarget() throws {
        let history = try legacyClaimHistory()
        let events = Array(history.events.dropLast())
        let state = try ScoutGraphReducer.replay(events)
        let target = LocalReviewTarget.claim(history.claimID)
        let operation = LocalReviewOperation.attestLegacyReview(.init(target: target))
        let eventID: EventID = testID("event-proposed-claim-attestation")

        #expect(throws: LocalReviewAuthorizationError.targetIsNotTerminal(target)) {
            _ = try LocalReviewIntent.preparing(
                eventID: eventID,
                operation: operation,
                in: state
            )
        }

        let claim = try #require(state.claims[history.claimID])
        let forgedIntent = LocalReviewIntent(
            sessionID: state.sessionID,
            eventID: eventID,
            operation: operation,
            targetEventID: history.proposalEvent.id,
            targetStateHash: .hash(claim.canonicalValue)
        )
        let grant = AuthenticatedLocalReview(
            intent: forgedIntent,
            authenticatedAt: timestamp(4)
        )
        var chain = try chainContinuing(after: events)
        let event = try chain.seal(
            occurredAt: timestamp(5),
            recordedAt: timestamp(5),
            authenticatedReview: grant
        )

        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: eventID,
            failure: .targetIsNotTerminal
        ))) {
            _ = try ScoutGraphReducer.reduce(state, event: event)
        }
        #expect(state.claims[history.claimID] == claim)
        #expect(state.claimReviewAttestations[history.claimID] == nil)
    }

    @Test("An authenticated target cannot be attested a second time")
    func rejectsAlreadyAuthenticatedTarget() throws {
        let history = try legacyClaimHistory()
        let legacyState = try ScoutGraphReducer.replay(history.events)
        let firstEventID: EventID = testID("event-first-legacy-attestation")
        let operation = LocalReviewOperation.attestLegacyReview(.init(
            target: .claim(history.claimID)
        ))
        let firstIntent = try LocalReviewIntent.preparing(
            eventID: firstEventID,
            operation: operation,
            in: legacyState
        )
        let firstGrant = AuthenticatedLocalReview(
            intent: firstIntent,
            authenticatedAt: timestamp(4)
        )
        var chain = try chainContinuing(after: history.events)
        let firstEvent = try chain.seal(
            occurredAt: timestamp(5),
            recordedAt: timestamp(5),
            authenticatedReview: firstGrant
        )
        let authenticatedState = try ScoutGraphReducer.reduce(legacyState, event: firstEvent)
        let target = LocalReviewTarget.claim(history.claimID)
        let secondEventID: EventID = testID("event-second-legacy-attestation")

        #expect(throws: LocalReviewAuthorizationError.targetAlreadyAuthenticated(target)) {
            _ = try LocalReviewIntent.preparing(
                eventID: secondEventID,
                operation: operation,
                in: authenticatedState
            )
        }

        let terminalClaim = try #require(authenticatedState.claims[history.claimID])
        let forgedIntent = LocalReviewIntent(
            sessionID: authenticatedState.sessionID,
            eventID: secondEventID,
            operation: operation,
            targetEventID: history.reviewEvent.id,
            targetStateHash: .hash(terminalClaim.canonicalValue)
        )
        let secondGrant = AuthenticatedLocalReview(
            intent: forgedIntent,
            authenticatedAt: timestamp(6)
        )
        let secondEvent = try chain.seal(
            occurredAt: timestamp(7),
            recordedAt: timestamp(7),
            authenticatedReview: secondGrant
        )

        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: secondEventID,
            failure: .targetAlreadyAuthenticated
        ))) {
            _ = try ScoutGraphReducer.reduce(authenticatedState, event: secondEvent)
        }
        #expect(authenticatedState.claims[history.claimID] == terminalClaim)
        #expect(authenticatedState.claimReviewEvents[history.claimID] == history.reviewEvent.id)
        #expect(authenticatedState.claimReviewAttestations[history.claimID]
            == .deviceOwnerAuthenticated(firstGrant.authorization))
    }

    @Test("Re-attestation binds the original review event and terminal state")
    func rejectsWrongReviewEventAndState() throws {
        let history = try legacyClaimHistory()
        let state = try ScoutGraphReducer.replay(history.events)
        let claim = try #require(state.claims[history.claimID])
        let operation = LocalReviewOperation.attestLegacyReview(.init(
            target: .claim(history.claimID)
        ))

        let wrongEventID: EventID = testID("event-attestation-wrong-review-event")
        let wrongEventIntent = LocalReviewIntent(
            sessionID: state.sessionID,
            eventID: wrongEventID,
            operation: operation,
            targetEventID: history.proposalEvent.id,
            targetStateHash: .hash(claim.canonicalValue)
        )
        let wrongEventGrant = AuthenticatedLocalReview(
            intent: wrongEventIntent,
            authenticatedAt: timestamp(4)
        )
        var wrongEventChain = try chainContinuing(after: history.events)
        let wrongEvent = try wrongEventChain.seal(
            occurredAt: timestamp(5),
            recordedAt: timestamp(5),
            authenticatedReview: wrongEventGrant
        )

        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: wrongEventID,
            failure: .targetEventMismatch
        ))) {
            _ = try ScoutGraphReducer.reduce(state, event: wrongEvent)
        }

        let wrongStateEventID: EventID = testID("event-attestation-wrong-terminal-state")
        let wrongStateIntent = LocalReviewIntent(
            sessionID: state.sessionID,
            eventID: wrongStateEventID,
            operation: operation,
            targetEventID: history.reviewEvent.id,
            targetStateHash: .hash(Data("substituted terminal state".utf8))
        )
        let wrongStateGrant = AuthenticatedLocalReview(
            intent: wrongStateIntent,
            authenticatedAt: timestamp(4)
        )
        var wrongStateChain = try chainContinuing(after: history.events)
        let wrongStateEvent = try wrongStateChain.seal(
            occurredAt: timestamp(5),
            recordedAt: timestamp(5),
            authenticatedReview: wrongStateGrant
        )

        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: wrongStateEventID,
            failure: .targetStateMismatch
        ))) {
            _ = try ScoutGraphReducer.reduce(state, event: wrongStateEvent)
        }
        #expect(state.claims[history.claimID] == claim)
        #expect(state.claimReviewEvents[history.claimID] == history.reviewEvent.id)
        #expect(state.claimReviewAttestations[history.claimID]
            == .legacyUnattested(schemaVersion: history.schema))
    }

    @Test("Missing legacy assurance and a substituted proof target fail closed")
    func rejectsMissingAssuranceAndSubstitutedTarget() throws {
        let history = try legacyClaimHistory()
        let state = try ScoutGraphReducer.replay(history.events)
        let claim = try #require(state.claims[history.claimID])
        let target = LocalReviewTarget.claim(history.claimID)
        let operation = LocalReviewOperation.attestLegacyReview(.init(target: target))

        var missingAssuranceState = state
        missingAssuranceState.claimReviewAttestations.removeValue(forKey: history.claimID)
        let missingEventID: EventID = testID("event-attestation-missing-assurance")
        #expect(throws: LocalReviewAuthorizationError.missingReviewAttestation(target)) {
            _ = try LocalReviewIntent.preparing(
                eventID: missingEventID,
                operation: operation,
                in: missingAssuranceState
            )
        }

        let missingIntent = LocalReviewIntent(
            sessionID: state.sessionID,
            eventID: missingEventID,
            operation: operation,
            targetEventID: history.reviewEvent.id,
            targetStateHash: .hash(claim.canonicalValue)
        )
        let missingGrant = AuthenticatedLocalReview(
            intent: missingIntent,
            authenticatedAt: timestamp(4)
        )
        var missingChain = try chainContinuing(after: history.events)
        let missingEvent = try missingChain.seal(
            occurredAt: timestamp(5),
            recordedAt: timestamp(5),
            authenticatedReview: missingGrant
        )
        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: missingEventID,
            failure: .missingReviewAttestation
        ))) {
            _ = try ScoutGraphReducer.reduce(missingAssuranceState, event: missingEvent)
        }

        let validEventID: EventID = testID("event-attestation-substituted-target")
        let validIntent = try LocalReviewIntent.preparing(
            eventID: validEventID,
            operation: operation,
            in: state
        )
        let validGrant = AuthenticatedLocalReview(
            intent: validIntent,
            authenticatedAt: timestamp(4)
        )
        let substitutedRecord = try replacingTarget(
            in: validGrant.authorization,
            with: .claim(testID("claim-substituted-proof-target"))
        )
        let component = testText("scout-macos-review-ui")
        var substitutedChain = try chainContinuing(after: history.events)
        let substituted = try substitutedChain.seal(
            schemaVersion: .current,
            id: validEventID,
            occurredAt: timestamp(5),
            recordedAt: timestamp(5),
            actor: .system(component: component),
            authorization: .init(
                scope: .localReview,
                component: component,
                localReviewAuthorization: substitutedRecord
            ),
            payload: operation.payload
        )
        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: validEventID,
            failure: .targetMismatch
        ))) {
            _ = try ScoutGraphReducer.reducePersisted(state, event: substituted)
        }
        #expect(state.claims[history.claimID] == claim)
        #expect(state.claimReviewAttestations[history.claimID]
            == .legacyUnattested(schemaVersion: history.schema))
    }

    private struct LegacyClaimHistory {
        let schema: EventSchemaVersion
        let claimID: ClaimID
        let proposalEvent: ScoutEventEnvelope
        let reviewEvent: ScoutEventEnvelope
        let events: [ScoutEventEnvelope]
    }

    private func legacyClaimHistory() throws -> LegacyClaimHistory {
        let schema = EventSchemaVersion(major: 1, minor: 3)
        let sessionID: SessionID = testID("session-legacy-reattest")
        let evidenceID: EvidenceID = testID("evidence-legacy-reattest")
        let claimID: ClaimID = testID("claim-legacy-reattest")
        let component = testText("legacy-review-fixture")
        let actor = EventActor.system(component: component)
        var chain = EventChainBuilder(sessionID: sessionID)

        let start = try chain.seal(
            schemaVersion: schema,
            id: testID("event-legacy-reattest-start"),
            occurredAt: timestamp(),
            recordedAt: timestamp(),
            actor: actor,
            authorization: .init(scope: .sessionLifecycle, component: component),
            payload: .sessionStarted(DiscoverySession(
                id: sessionID,
                title: testText("Legacy re-attestation fixture"),
                startedAt: timestamp()
            ))
        )
        let evidence = try chain.seal(
            schemaVersion: schema,
            id: testID("event-legacy-reattest-evidence"),
            occurredAt: timestamp(1),
            recordedAt: timestamp(1),
            actor: actor,
            authorization: .init(scope: .evidenceImport, component: component),
            payload: .evidenceRecorded(Evidence(
                id: evidenceID,
                source: .external(reference: testText("legacy-review-record")),
                excerpt: testText("Legacy evidence remains immutable."),
                capturedAt: timestamp(1),
                capturedBy: actor
            ))
        )
        let proposal = try chain.seal(
            schemaVersion: schema,
            id: testID("event-legacy-reattest-claim"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(2),
            actor: actor,
            authorization: .init(scope: .deterministicProjection, component: component),
            payload: .claimProposed(Claim(
                id: claimID,
                subject: .session(sessionID),
                predicate: .hasGoal,
                object: .value(.text("Preserve the historical decision")),
                evidenceIDs: [evidenceID],
                trust: TrustAssessment(
                    origin: .suggested,
                    confidence: try Confidence(basisPoints: 7_500),
                    validationStatus: .needsValidation
                )
            ))
        )
        let review = try chain.seal(
            schemaVersion: schema,
            id: testID("event-original-legacy-claim-review"),
            occurredAt: timestamp(3),
            recordedAt: timestamp(3),
            actor: actor,
            authorization: .init(scope: .localReview, component: component),
            payload: .claimReviewed(.init(
                claimID: claimID,
                status: .accepted,
                trust: confirmedTrust()
            ))
        )
        return LegacyClaimHistory(
            schema: schema,
            claimID: claimID,
            proposalEvent: proposal,
            reviewEvent: review,
            events: [start, evidence, proposal, review]
        )
    }

    private func confirmedTrust() -> TrustAssessment {
        TrustAssessment(
            origin: .confirmed,
            confidence: try! Confidence(basisPoints: 10_000),
            validationStatus: .validated
        )
    }

    private func replacingTarget(
        in record: LocalReviewAuthorizationRecord,
        with target: LocalReviewTarget
    ) throws -> LocalReviewAuthorizationRecord {
        let encoder = JSONEncoder()
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any]
        )
        object["target"] = try JSONSerialization.jsonObject(with: encoder.encode(target))
        return try JSONDecoder().decode(
            LocalReviewAuthorizationRecord.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}
