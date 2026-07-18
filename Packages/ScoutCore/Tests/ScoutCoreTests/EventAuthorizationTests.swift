import Foundation
import Testing
@testable import ScoutCore

@Suite("Event command authorization")
struct EventAuthorizationTests {
    @Test("A model capability cannot review or self-validate a claim")
    func modelCannotReviewClaim() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        let model = modelIdentity()
        var chain = try chainContinuing(after: events)
        let event = try chain.seal(
            id: testID("event-model-self-review"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: .model(model),
            authorization: .init(
                scope: .modelProjection,
                component: testText("claim-projection-validator")
            ),
            payload: .claimReviewed(.init(
                claimID: ScoutFixtures.claimID,
                status: .accepted,
                trust: confirmedTrust()
            ))
        )

        #expect(throws: ScoutReducerError.authorization(.scopePayloadMismatch(
            scope: .modelProjection,
            payloadKind: "claim.reviewed"
        ))) {
            _ = try ScoutGraphReducer.reducePersisted(state, event: event)
        }
        #expect(state.claims[ScoutFixtures.claimID]?.status == .proposed)
    }

    @Test("Authenticated model context rejects a forged system actor")
    func modelCannotSpoofReviewActor() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        let receiptEvent = try #require(events.last)
        var chain = try chainContinuing(after: events)
        let event = try chain.seal(
            id: testID("event-model-spoofed-review"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: .system(component: testText("scout-macos-review-ui")),
            authorization: .init(
                scope: .modelProjection,
                component: testText("claim-projection-validator")
            ),
            correlationID: receiptEvent.id,
            causationID: receiptEvent.id,
            payload: .claimProposed(proposedClaim(id: "claim-model-spoofed-actor"))
        )

        #expect(throws: ScoutReducerError.authorization(.actorMismatch(event.id))) {
            _ = try ScoutGraphReducer.reducePersisted(state, event: event)
        }
        #expect(state.claims[ScoutFixtures.claimID]?.status == .proposed)
    }

    @Test("Local review capability can accept an evidence-linked claim")
    func localReviewSucceeds() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        var chain = try chainContinuing(after: events)
        let eventID: EventID = testID("event-local-review")
        let grant = try authenticatedClaimReview(
            eventID: eventID,
            claimID: ScoutFixtures.claimID,
            targetEventID: claimProposalEventID(ScoutFixtures.claimID, in: events),
            state: state
        )
        let event = try chain.seal(
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            authenticatedReview: grant
        )

        let next = try ScoutGraphReducer.reduce(state, event: event)
        #expect(next.claims[ScoutFixtures.claimID]?.status == .accepted)
        #expect(next.claims[ScoutFixtures.claimID]?.trust == confirmedTrust())
        #expect(event.envelope.actor == .system(component: testText("scout-macos-review-ui")))
        #expect(event.envelope.authorization?.scope == .localReview)
        #expect(next.claimReviewAttestations[ScoutFixtures.claimID]
            == .deviceOwnerAuthenticated(grant.authorization))
    }

    @Test("Schema v1.4 rejects a local-review record with no authenticated capability")
    func currentReviewRequiresAuthentication() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        var chain = try chainContinuing(after: events)
        let eventID: EventID = testID("event-review-without-authentication")
        let event = try chain.seal(
            schemaVersion: .current,
            id: eventID,
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: .system(component: testText("scout-macos-review-ui")),
            authorization: .init(
                scope: .localReview,
                component: testText("scout-macos-review-ui")
            ),
            payload: .claimReviewed(.init(
                claimID: ScoutFixtures.claimID,
                status: .accepted,
                trust: confirmedTrust()
            ))
        )

        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: eventID,
            failure: .missing
        ))) {
            _ = try ScoutGraphReducer.reducePersisted(state, event: event)
        }
    }

    @Test("An authenticated review cannot be substituted with the opposite decision")
    func authenticatedReviewBindsExactPayload() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        let eventID: EventID = testID("event-review-payload-substitution")
        let grant = try authenticatedClaimReview(
            eventID: eventID,
            claimID: ScoutFixtures.claimID,
            targetEventID: claimProposalEventID(ScoutFixtures.claimID, in: events),
            state: state
        )
        var chain = try chainContinuing(after: events)
        let event = try chain.seal(
            schemaVersion: .current,
            id: eventID,
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: .system(component: testText("scout-macos-review-ui")),
            authorization: .init(
                scope: .localReview,
                component: testText("scout-macos-review-ui"),
                localReviewAuthorization: grant.authorization
            ),
            payload: .claimReviewed(.init(
                claimID: ScoutFixtures.claimID,
                status: .rejected,
                trust: rejectedTrust()
            ))
        )

        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: eventID,
            failure: .operationMismatch
        ))) {
            _ = try ScoutGraphReducer.reducePersisted(state, event: event)
        }
    }

    @Test("A review grant becomes invalid when its target revision changes")
    func authenticatedReviewRejectsStaleTarget() throws {
        let events = try ScoutFixtures.sampleEvents()
        var state = try ScoutGraphReducer.replay(events)
        let reviewID: EventID = testID("event-review-stale-target")
        let grant = try authenticatedClaimReview(
            eventID: reviewID,
            claimID: ScoutFixtures.claimID,
            targetEventID: claimProposalEventID(ScoutFixtures.claimID, in: events),
            state: state
        )
        var chain = try chainContinuing(after: events)
        let replacement = try chain.seal(
            id: testID("event-supersede-before-review"),
            occurredAt: timestamp(1),
            recordedAt: timestamp(2),
            command: .deterministicProjection(
                component: testText("deterministic-test-projection"),
                operation: .proposeClaim(proposedClaim(
                    id: "claim-supersedes-before-review",
                    supersedes: ScoutFixtures.claimID
                ))
            )
        )
        state = try ScoutGraphReducer.reduce(state, event: replacement)
        let review = try chain.seal(
            occurredAt: timestamp(3),
            recordedAt: timestamp(4),
            authenticatedReview: grant
        )

        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: reviewID,
            failure: .targetIsNotProposed
        ))) {
            _ = try ScoutGraphReducer.reduce(state, event: review)
        }
    }

    @Test("A review capability cannot cross sessions or outlive its commit window")
    func authenticatedReviewScopeAndExpiry() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        let eventID: EventID = testID("event-review-expiring")
        let grant = try authenticatedClaimReview(
            eventID: eventID,
            claimID: ScoutFixtures.claimID,
            targetEventID: claimProposalEventID(ScoutFixtures.claimID, in: events),
            state: state
        )
        var otherSessionChain = EventChainBuilder(
            sessionID: testID("session-other-review-target")
        )
        #expect(throws: LocalReviewAuthorizationError.sessionMismatch(
            expected: testID("session-other-review-target"),
            actual: state.sessionID
        )) {
            _ = try otherSessionChain.seal(
                occurredAt: timestamp(),
                recordedAt: timestamp(1),
                authenticatedReview: grant
            )
        }

        var chain = try chainContinuing(after: events)
        let expired = try chain.seal(
            occurredAt: timestamp(300_001),
            recordedAt: timestamp(300_001),
            authenticatedReview: grant
        )
        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: eventID,
            failure: .expired
        ))) {
            _ = try ScoutGraphReducer.reduce(state, event: expired)
        }
    }

    @Test("A presealed review cannot be retained past its live append window")
    func presealedReviewExpiresBeforeStoreAppend() async throws {
        let prefix = try ScoutFixtures.sampleValidatedEvents()
        let envelopes = prefix.map(\.envelope)
        let state = try ScoutGraphReducer.replay(envelopes)
        let eventID: EventID = testID("event-review-retained-before-append")
        let grant = try authenticatedClaimReview(
            eventID: eventID,
            claimID: ScoutFixtures.claimID,
            targetEventID: claimProposalEventID(ScoutFixtures.claimID, in: envelopes),
            state: state
        )
        var chain = try chainContinuing(after: envelopes)
        let presealed = try chain.seal(
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            authenticatedReview: grant
        )

        // Its persisted timestamps are internally valid, so replay alone cannot know it was held.
        #expect(try ScoutGraphReducer.reduce(state, event: presealed)
            .claims[ScoutFixtures.claimID]?.status == .accepted)

        let store = InMemoryEventStore()
        _ = try await store.append(prefix)
        await #expect(throws: EventStoreError.reduction(.authorization(.localReviewAuthorization(
            eventID: eventID,
            failure: .expired
        )))) {
            _ = try await store.append(presealed)
        }
        #expect(await store.eventCount(for: ScoutFixtures.sessionID) == prefix.count)
        #expect(await store.state(for: ScoutFixtures.sessionID)?.claims[ScoutFixtures.claimID]?.status
            == .proposed)
    }

    @Test("A consumed review authorization cannot be replayed")
    func authenticatedReviewIsOneTime() throws {
        let events = try ScoutFixtures.sampleEvents()
        var state = try ScoutGraphReducer.replay(events)
        let eventID: EventID = testID("event-review-one-time")
        let grant = try authenticatedClaimReview(
            eventID: eventID,
            claimID: ScoutFixtures.claimID,
            targetEventID: claimProposalEventID(ScoutFixtures.claimID, in: events),
            state: state
        )
        var chain = try chainContinuing(after: events)
        let first = try chain.seal(
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            authenticatedReview: grant
        )
        state = try ScoutGraphReducer.reduce(state, event: first)
        let replay = try chain.seal(
            schemaVersion: .current,
            id: eventID,
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            actor: first.envelope.actor,
            authorization: first.envelope.authorization,
            payload: first.envelope.payload
        )

        #expect(throws: ScoutReducerError.authorization(.localReviewAuthorization(
            eventID: eventID,
            failure: .reused(grant.authorization.id)
        ))) {
            _ = try ScoutGraphReducer.reducePersisted(state, event: replay)
        }
    }

    @Test("A historical schema v1.3 local review remains replayable and explicitly unattested")
    func legacyReviewCompatibility() throws {
        let schema = EventSchemaVersion(major: 1, minor: 3)
        let sessionID: SessionID = testID("session-legacy-review")
        let evidenceID: EvidenceID = testID("evidence-legacy-review")
        let claimID: ClaimID = testID("claim-legacy-review")
        let component = testText("legacy-review-ui")
        let actor = EventActor.system(component: component)
        var chain = EventChainBuilder(sessionID: sessionID)
        var events = [try chain.seal(
            schemaVersion: schema,
            id: testID("event-legacy-session"),
            occurredAt: timestamp(),
            recordedAt: timestamp(),
            actor: actor,
            authorization: .init(scope: .sessionLifecycle, component: component),
            payload: .sessionStarted(DiscoverySession(
                id: sessionID,
                title: testText("Legacy review fixture"),
                startedAt: timestamp()
            ))
        )]
        events.append(try chain.seal(
            schemaVersion: schema,
            id: testID("event-legacy-evidence"),
            occurredAt: timestamp(1),
            recordedAt: timestamp(1),
            actor: actor,
            authorization: .init(scope: .evidenceImport, component: component),
            payload: .evidenceRecorded(Evidence(
                id: evidenceID,
                source: .external(reference: testText("legacy-fixture")),
                excerpt: testText("Legacy evidence"),
                capturedAt: timestamp(1),
                capturedBy: actor
            ))
        ))
        events.append(try chain.seal(
            schemaVersion: schema,
            id: testID("event-legacy-claim"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(2),
            actor: actor,
            authorization: .init(scope: .deterministicProjection, component: component),
            payload: .claimProposed(Claim(
                id: claimID,
                subject: .session(sessionID),
                predicate: .hasGoal,
                object: .value(.text("Preserve historical review")),
                evidenceIDs: [evidenceID],
                trust: TrustAssessment(
                    origin: .suggested,
                    confidence: try Confidence(basisPoints: 7_500),
                    validationStatus: .needsValidation
                )
            ))
        ))
        let state = try ScoutGraphReducer.replay(events)
        let legacy = try chain.seal(
            schemaVersion: schema,
            id: testID("event-legacy-local-review"),
            occurredAt: timestamp(3),
            recordedAt: timestamp(3),
            actor: actor,
            authorization: .init(
                scope: .localReview,
                component: component
            ),
            payload: .claimReviewed(.init(
                claimID: claimID,
                status: .accepted,
                trust: confirmedTrust()
            ))
        )

        let next = try ScoutGraphReducer.reducePersisted(state, event: legacy)
        #expect(next.claims[claimID]?.status == .accepted)
        #expect(legacy.authorization?.localReviewAuthorization == nil)
        #expect(next.claimReviewAttestations[claimID]
            == .legacyUnattested(schemaVersion: schema))
    }

    @Test("Persisted replay cannot downgrade after a stream advances to schema v1.4")
    func persistedReplayRejectsSchemaRegression() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        var chain = try chainContinuing(after: events)
        let legacy = try chain.seal(
            schemaVersion: EventSchemaVersion(major: 1, minor: 3),
            id: testID("event-post-v14-legacy-review"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: .system(component: testText("legacy-review-ui")),
            authorization: .init(
                scope: .localReview,
                component: testText("legacy-review-ui")
            ),
            payload: .claimReviewed(.init(
                claimID: ScoutFixtures.claimID,
                status: .accepted,
                trust: confirmedTrust()
            ))
        )

        #expect(throws: ScoutReducerError.schemaVersionRegression(
            previous: .current,
            actual: EventSchemaVersion(major: 1, minor: 3)
        )) {
            _ = try ScoutGraphReducer.reducePersisted(state, event: legacy)
        }
    }

    @Test("New writes cannot downgrade to a replay-only schema")
    func newWritesCannotDowngradeSchema() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        var chain = try chainContinuing(after: events)
        let legacyEnvelope = try chain.seal(
            schemaVersion: EventSchemaVersion(major: 1, minor: 2),
            id: testID("event-schema-downgrade"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            actor: .system(component: testText("scout-macos-review-ui")),
            payload: .claimReviewed(.init(
                claimID: ScoutFixtures.claimID,
                status: .accepted,
                trust: confirmedTrust()
            ))
        )

        #expect(throws: ScoutReducerError.writeSchemaMustBeCurrent(
            expected: .current,
            actual: EventSchemaVersion(major: 1, minor: 2)
        )) {
            _ = try ScoutGraphReducer.reduce(
                state,
                event: ValidatedScoutEvent(envelope: legacyEnvelope)
            )
        }
    }

    @Test("Model proposals require suggested trust and an exact receipt binding")
    func modelProposalPolicy() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)

        let privileged = Claim(
            id: testID("claim-model-privileged"),
            subject: .entity(ScoutFixtures.customerDataEntityID),
            predicate: .hasGoal,
            object: .value(.text("Privileged model assertion")),
            evidenceIDs: [ScoutFixtures.evidenceID],
            trust: confirmedTrust()
        )
        let privilegedID: EventID = testID("event-model-privileged")
        let privilegedPayload = ScoutEventPayload.claimProposed(privileged)
        let privilegedContext = try beginModelProjection(
            in: state,
            suffix: "privileged",
            entries: [.init(eventID: privilegedID, payload: privilegedPayload)]
        )
        var privilegedChain = privilegedContext.chain
        let privilegedEvent = try privilegedChain.seal(
            id: privilegedID,
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            correlationID: privilegedContext.receiptEvent.envelope.id,
            causationID: privilegedContext.receiptEvent.envelope.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(privileged)
            )
        )
        #expect(throws: ScoutReducerError.authorization(
            .modelProposalRequiresSuggestedTrust(privilegedEvent.envelope.id)
        )) {
            _ = try ScoutGraphReducer.reduce(privilegedContext.state, event: privilegedEvent)
        }

        let proposed = proposedClaim(id: "claim-model-valid")
        let validID: EventID = testID("event-model-valid")
        let validContext = try beginModelProjection(
            in: state,
            suffix: "valid",
            entries: [.init(
                eventID: validID,
                payload: .claimProposed(proposed)
            )]
        )
        var validChain = validContext.chain
        let validEvent = try validChain.seal(
            id: validID,
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            correlationID: validContext.receiptEvent.envelope.id,
            causationID: validContext.receiptEvent.envelope.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(proposed)
            )
        )
        let next = try ScoutGraphReducer.reduce(validContext.state, event: validEvent)
        #expect(next.claims[proposed.id]?.status == .proposed)

        var unboundChain = try chainContinuing(after: events)
        let unboundEvent = try unboundChain.seal(
            id: testID("event-model-unbound"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(proposedClaim(id: "claim-model-unbound"))
            )
        )
        #expect(throws: ScoutReducerError.authorization(
            .modelProposalNotBoundToReceipt(unboundEvent.envelope.id)
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: unboundEvent)
        }
    }

    @Test("A model proposal cannot supersede a reviewed claim")
    func modelCannotSupersedeReviewedClaim() throws {
        let events = try ScoutFixtures.sampleEvents()
        var state = try ScoutGraphReducer.replay(events)
        let receiptEvent = try #require(events.last)
        var chain = try chainContinuing(after: events)
        let grant = try authenticatedClaimReview(
            eventID: testID("event-review-before-model-supersession"),
            claimID: ScoutFixtures.claimID,
            targetEventID: claimProposalEventID(ScoutFixtures.claimID, in: events),
            state: state
        )
        let review = try chain.seal(
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            authenticatedReview: grant
        )
        state = try ScoutGraphReducer.reduce(state, event: review)

        let proposal = try chain.seal(
            id: testID("event-model-supersedes-reviewed"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            correlationID: receiptEvent.id,
            causationID: receiptEvent.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(proposedClaim(
                    id: "claim-model-replacement",
                    supersedes: ScoutFixtures.claimID
                ))
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .modelProposalCannotSupersedeProtectedClaim(
                eventID: proposal.envelope.id,
                claimID: ScoutFixtures.claimID
            )
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: proposal)
        }
        #expect(state.claims[ScoutFixtures.claimID]?.status == .accepted)

        var deterministicChain = try chainContinuing(after: events + [review.envelope])
        let deterministic = try deterministicChain.seal(
            id: testID("event-deterministic-supersedes-reviewed"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            command: .deterministicProjection(
                component: testText("deterministic-claim-projection"),
                operation: .proposeClaim(proposedClaim(
                    id: "claim-deterministic-replacement",
                    supersedes: ScoutFixtures.claimID
                ))
            )
        )
        #expect(throws: ScoutReducerError.protectedClaimCannotBeSuperseded(
            ScoutFixtures.claimID
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: deterministic)
        }
    }

    @Test("A model proposal cannot reactivate a retired entity")
    func modelCannotReactivateRetiredEntity() throws {
        let events = try ScoutFixtures.sampleEvents()
        var state = try ScoutGraphReducer.replay(events)
        let receiptEvent = try #require(events.last)
        var chain = try chainContinuing(after: events)
        let retirement = try chain.seal(
            id: testID("event-retire-before-model-upsert"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            command: .graphMaintenance(
                component: testText("graph-maintenance"),
                operation: .retireEntity(.init(
                    entityID: ScoutFixtures.customerDataEntityID,
                    reason: testText("Merged into a canonical replacement")
                ))
            )
        )
        state = try ScoutGraphReducer.reduce(state, event: retirement)
        let retired = try #require(state.graph.entities[ScoutFixtures.customerDataEntityID])
        let suggested = TrustAssessment(
            origin: .suggested,
            confidence: try Confidence(basisPoints: 8_000),
            validationStatus: .needsValidation
        )
        let candidate = GraphEntity(
            id: retired.id,
            kind: retired.kind,
            canonicalName: retired.canonicalName,
            aliases: retired.aliases,
            attributes: retired.attributes,
            evidenceIDs: retired.evidenceIDs,
            trust: suggested,
            lifecycle: .active
        )
        let proposal = try chain.seal(
            id: testID("event-model-reactivates-entity"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            correlationID: receiptEvent.id,
            causationID: receiptEvent.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .upsertEntity(candidate)
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .modelProposalCannotModifyProtectedEntity(
                eventID: proposal.envelope.id,
                entityID: candidate.id
            )
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: proposal)
        }
        #expect(state.graph.entities[candidate.id]?.lifecycle == retired.lifecycle)

        var deterministicChain = try chainContinuing(after: events + [retirement.envelope])
        let deterministic = try deterministicChain.seal(
            id: testID("event-deterministic-reactivates-entity"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            command: .deterministicProjection(
                component: testText("deterministic-entity-projection"),
                operation: .upsertEntity(candidate)
            )
        )
        #expect(throws: ScoutReducerError.entityWasRetired(candidate.id)) {
            _ = try ScoutGraphReducer.reduce(state, event: deterministic)
        }
    }

    @Test("A model proposal cannot overwrite a protected relationship")
    func modelCannotOverwriteProtectedRelationship() throws {
        let events = try ScoutFixtures.sampleEvents()
        let state = try ScoutGraphReducer.replay(events)
        let receiptEvent = try #require(events.last)
        let existing = try #require(state.graph.relationships[ScoutFixtures.relationshipID])
        var chain = try chainContinuing(after: events)
        let candidate = GraphRelationship(
            id: existing.id,
            sourceID: existing.sourceID,
            targetID: existing.targetID,
            kind: existing.kind,
            label: testText("model-overwrite"),
            attributes: existing.attributes,
            claimIDs: existing.claimIDs,
            evidenceIDs: existing.evidenceIDs,
            trust: TrustAssessment(
                origin: .suggested,
                confidence: try Confidence(basisPoints: 8_000),
                validationStatus: .needsValidation
            )
        )
        let proposal = try chain.seal(
            id: testID("event-model-overwrites-relationship"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            correlationID: receiptEvent.id,
            causationID: receiptEvent.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .upsertRelationship(candidate)
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .modelProposalCannotModifyProtectedRelationship(
                eventID: proposal.envelope.id,
                relationshipID: candidate.id
            )
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: proposal)
        }
        #expect(state.graph.relationships[candidate.id] == existing)
    }

    @Test("A model proposal cannot cite evidence outside its input boundary")
    func modelCannotCiteLaterEvidence() throws {
        let events = try ScoutFixtures.sampleEvents()
        var state = try ScoutGraphReducer.replay(events)
        let receiptEvent = try #require(events.last)
        var chain = try chainContinuing(after: events)
        let utteranceID: UtteranceID = testID("utterance-after-model-input")
        let utterance = try chain.seal(
            id: testID("event-utterance-after-model-input"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            command: .capturePipeline(
                component: testText("capture-pipeline"),
                operation: .finalizeUtterance(.init(
                    id: utteranceID,
                    speakerID: ScoutFixtures.speakerID,
                    startedAt: timestamp(),
                    endedAt: timestamp(1),
                    text: testText("This evidence arrived after the recorded model input."),
                    transcriptionConfidence: try Confidence(basisPoints: 9_000)
                ))
            )
        )
        state = try ScoutGraphReducer.reduce(state, event: utterance)
        let lateEvidenceID: EvidenceID = testID("evidence-after-model-input")
        let evidence = try chain.seal(
            id: testID("event-evidence-after-model-input"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            command: .capturePipeline(
                component: testText("capture-pipeline"),
                operation: .recordEvidence(.init(
                    id: lateEvidenceID,
                    source: .utterance(utteranceID),
                    excerpt: testText("This evidence arrived after the recorded model input."),
                    capturedAt: timestamp(2),
                    capturedBy: .speaker(ScoutFixtures.speakerID)
                ))
            )
        )
        state = try ScoutGraphReducer.reduce(state, event: evidence)
        let proposal = try chain.seal(
            id: testID("event-model-cites-later-evidence"),
            occurredAt: timestamp(4),
            recordedAt: timestamp(5),
            correlationID: receiptEvent.id,
            causationID: receiptEvent.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(proposedClaim(
                    id: "claim-model-late-evidence",
                    evidenceIDs: [lateEvidenceID]
                ))
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .modelProposalEvidenceOutsideInputBoundary(
                eventID: proposal.envelope.id,
                evidenceID: lateEvidenceID
            )
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: proposal)
        }
        #expect(state.claims[testID("claim-model-late-evidence")] == nil)
    }

    @Test("Capture evidence provenance is verified and import provenance is derived")
    func evidenceProvenanceIsNotCallerControlled() throws {
        let prefix = Array(try ScoutFixtures.sampleEvents().prefix(3))
        let state = try ScoutGraphReducer.replay(prefix)
        let modelActor = EventActor.model(modelIdentity())
        var captureChain = try chainContinuing(after: prefix)
        let forged = try captureChain.seal(
            id: testID("event-forged-evidence-provenance"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            command: .capturePipeline(
                component: testText("capture-pipeline"),
                operation: .recordEvidence(.init(
                    id: testID("evidence-forged-provenance"),
                    source: .utterance(ScoutFixtures.utteranceID),
                    capturedAt: timestamp(),
                    capturedBy: modelActor
                ))
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .evidenceProvenanceMismatch(forged.envelope.id)
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: forged)
        }

        var importChain = try chainContinuing(after: prefix)
        let importComponent = testText("manual-evidence-import")
        let imported = try importChain.seal(
            id: testID("event-derived-import-provenance"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            command: .evidenceImport(
                component: importComponent,
                operation: .record(.init(
                    id: testID("evidence-derived-import-provenance"),
                    source: .manualNote(noteID: testText("note-1")),
                    capturedAt: timestamp(),
                    capturedBy: modelActor
                ))
            )
        )
        guard case let .evidenceRecorded(evidence) = imported.envelope.payload else {
            Issue.record("Expected evidence payload")
            return
        }
        #expect(evidence.capturedBy == .system(component: importComponent))
        _ = try ScoutGraphReducer.reduce(state, event: imported)
    }

    @Test("A model claim cannot misattribute utterance evidence to another speaker")
    func modelClaimSpeakerMustMatchEvidence() throws {
        let events = try ScoutFixtures.sampleEvents()
        var state = try ScoutGraphReducer.replay(events)
        let receiptEvent = try #require(events.last)
        var chain = try chainContinuing(after: events)
        let otherSpeakerID: SpeakerID = testID("speaker-other")
        let speaker = try chain.seal(
            id: testID("event-other-speaker"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            command: .sessionLifecycle(
                component: testText("speaker-directory"),
                operation: .upsertSpeaker(.init(
                    id: otherSpeakerID,
                    displayName: testText("Another speaker")
                ))
            )
        )
        state = try ScoutGraphReducer.reduce(state, event: speaker)
        let proposal = try chain.seal(
            id: testID("event-model-wrong-speaker"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            correlationID: receiptEvent.id,
            causationID: receiptEvent.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(proposedClaim(
                    id: "claim-model-wrong-speaker",
                    assertedBy: otherSpeakerID
                ))
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .modelClaimAttributionMismatch(proposal.envelope.id)
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: proposal)
        }
    }

    @Test("Accepted claims transitively protect referenced suggested entities")
    func acceptedClaimProtectsReferencedEntity() throws {
        let events = try ScoutFixtures.sampleEvents()
        let initialState = try ScoutGraphReducer.replay(events)
        let entityID: EntityID = testID("entity-model-protected-by-claim")
        let suggestedTrust = TrustAssessment(
            origin: .suggested,
            confidence: try Confidence(basisPoints: 8_000),
            validationStatus: .needsValidation
        )
        let entity = GraphEntity(
            id: entityID,
            kind: .system,
            canonicalName: testText("Proposed system"),
            evidenceIDs: [ScoutFixtures.evidenceID],
            trust: suggestedTrust
        )
        let entityEventID: EventID = testID("event-model-protected-entity")
        let claim = Claim(
            id: testID("claim-accepts-model-entity"),
            subject: .entity(entityID),
            predicate: .hasGoal,
            object: .value(.text("Protect this reference")),
            assertedBy: ScoutFixtures.speakerID,
            evidenceIDs: [ScoutFixtures.evidenceID],
            trust: suggestedTrust
        )
        let claimEventID: EventID = testID("event-model-entity-claim")
        let context = try beginModelProjection(
            in: initialState,
            suffix: "protected-reference",
            entries: [
                .init(eventID: entityEventID, payload: .entityUpserted(entity)),
                .init(eventID: claimEventID, payload: .claimProposed(claim)),
            ]
        )
        var state = context.state
        var chain = context.chain
        let entityEvent = try chain.seal(
            id: entityEventID,
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            correlationID: context.receiptEvent.envelope.id,
            causationID: context.receiptEvent.envelope.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .upsertEntity(entity)
            )
        )
        state = try ScoutGraphReducer.reduce(state, event: entityEvent)

        let claimEvent = try chain.seal(
            id: claimEventID,
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            correlationID: context.receiptEvent.envelope.id,
            causationID: context.receiptEvent.envelope.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(claim)
            )
        )
        state = try ScoutGraphReducer.reduce(state, event: claimEvent)
        let grant = try authenticatedClaimReview(
            eventID: testID("event-accept-model-entity-claim"),
            claimID: claim.id,
            targetEventID: claimEvent.envelope.id,
            state: state
        )
        let review = try chain.seal(
            occurredAt: timestamp(4),
            recordedAt: timestamp(5),
            authenticatedReview: grant
        )
        state = try ScoutGraphReducer.reduce(state, event: review)

        let overwrite = GraphEntity(
            id: entityID,
            kind: entity.kind,
            canonicalName: testText("Overwritten system"),
            evidenceIDs: entity.evidenceIDs,
            trust: suggestedTrust
        )
        let overwriteEventID: EventID = testID("event-model-overwrites-transitive-entity")
        let overwriteContext = try beginModelProjection(
            in: state,
            suffix: "protected-overwrite",
            entries: [.init(
                eventID: overwriteEventID,
                payload: .entityUpserted(overwrite)
            )]
        )
        var overwriteChain = overwriteContext.chain
        let overwriteEvent = try overwriteChain.seal(
            id: overwriteEventID,
            occurredAt: timestamp(6),
            recordedAt: timestamp(7),
            correlationID: overwriteContext.receiptEvent.envelope.id,
            causationID: overwriteContext.receiptEvent.envelope.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .upsertEntity(overwrite)
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .modelProposalCannotModifyProtectedEntity(
                eventID: overwriteEvent.envelope.id,
                entityID: entityID
            )
        )) {
            _ = try ScoutGraphReducer.reduce(overwriteContext.state, event: overwriteEvent)
        }
        #expect(state.graph.entities[entityID]?.canonicalName == entity.canonicalName)
    }

    @Test("A removed relationship cannot be recreated by a model proposal")
    func modelCannotRecreateRemovedRelationship() throws {
        let events = try ScoutFixtures.sampleEvents()
        var state = try ScoutGraphReducer.replay(events)
        let receiptEvent = try #require(events.last)
        let original = try #require(state.graph.relationships[ScoutFixtures.relationshipID])
        var chain = try chainContinuing(after: events)
        let removal = try chain.seal(
            id: testID("event-remove-relationship"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            command: .graphMaintenance(
                component: testText("graph-maintenance"),
                operation: .removeRelationship(.init(
                    relationshipID: original.id,
                    reason: testText("Explicitly removed")
                ))
            )
        )
        state = try ScoutGraphReducer.reduce(state, event: removal)
        let candidate = GraphRelationship(
            id: original.id,
            sourceID: original.sourceID,
            targetID: original.targetID,
            kind: original.kind,
            label: original.label,
            attributes: original.attributes,
            claimIDs: original.claimIDs,
            evidenceIDs: original.evidenceIDs,
            trust: TrustAssessment(
                origin: .suggested,
                confidence: try Confidence(basisPoints: 8_000),
                validationStatus: .needsValidation
            )
        )
        let proposal = try chain.seal(
            id: testID("event-model-recreates-relationship"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            correlationID: receiptEvent.id,
            causationID: receiptEvent.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .upsertRelationship(candidate)
            )
        )

        #expect(throws: ScoutReducerError.authorization(
            .modelProposalCannotModifyProtectedRelationship(
                eventID: proposal.envelope.id,
                relationshipID: original.id
            )
        )) {
            _ = try ScoutGraphReducer.reduce(state, event: proposal)
        }
        #expect(state.graph.relationships[original.id] == nil)
        #expect(state.removedRelationships[original.id] != nil)

        var deterministicChain = try chainContinuing(after: events + [removal.envelope])
        let deterministic = try deterministicChain.seal(
            id: testID("event-deterministic-recreates-relationship"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            command: .deterministicProjection(
                component: testText("deterministic-graph-projection"),
                operation: .upsertRelationship(candidate)
            )
        )
        #expect(throws: ScoutReducerError.relationshipWasRemoved(original.id)) {
            _ = try ScoutGraphReducer.reduce(state, event: deterministic)
        }
    }

    @Test("A mixed model batch rolls back when it contains a forged review")
    func mixedBatchRollsBack() async throws {
        let store = InMemoryEventStore()
        let base = try ScoutFixtures.sampleValidatedEvents()
        _ = try await store.append(base)
        let before = try #require(await store.state(for: ScoutFixtures.sessionID))
        let proposalID: EventID = testID("event-model-batch-proposal")
        let proposalPayload = ScoutEventPayload.claimProposed(
            proposedClaim(id: "claim-model-batch")
        )
        let context = try beginModelProjection(
            in: before,
            suffix: "mixed-batch",
            entries: [.init(eventID: proposalID, payload: proposalPayload)]
        )
        var chain = context.chain
        let proposal = try chain.seal(
            id: proposalID,
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            correlationID: context.receiptEvent.envelope.id,
            causationID: context.receiptEvent.envelope.id,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .proposeClaim(proposedClaim(id: "claim-model-batch"))
            )
        )
        let forged = try chain.seal(
            id: testID("event-model-batch-review"),
            occurredAt: timestamp(2),
            recordedAt: timestamp(3),
            actor: .model(modelIdentity()),
            authorization: .init(
                scope: .modelProjection,
                component: testText("claim-projection-validator")
            ),
            correlationID: context.receiptEvent.envelope.id,
            causationID: proposal.envelope.id,
            payload: .claimReviewed(.init(
                claimID: testID("claim-model-batch"),
                status: .accepted,
                trust: confirmedTrust()
            ))
        )

        do {
            _ = try await store.append([
                context.receiptEvent,
                proposal,
                ValidatedScoutEvent(envelope: forged),
            ])
            Issue.record("Expected forged review to reject the entire model batch")
        } catch let error as EventStoreError {
            #expect(error == .reduction(.authorization(.scopePayloadMismatch(
                scope: .modelProjection,
                payloadKind: "claim.reviewed"
            ))))
        }

        let after = try #require(await store.state(for: ScoutFixtures.sessionID))
        #expect(after.digest == before.digest)
        #expect(await store.eventCount(for: ScoutFixtures.sessionID) == base.count)
        #expect(after.claims[testID("claim-model-batch")] == nil)
    }

    private struct ModelProjectionContext {
        let receiptEvent: ValidatedScoutEvent
        let state: ScoutState
        let chain: EventChainBuilder
    }

    private func beginModelProjection(
        in state: ScoutState,
        suffix: String,
        entries: [DerivedEventManifestEntry]
    ) throws -> ModelProjectionContext {
        let evidenceEventID = try #require(state.evidenceEvents[ScoutFixtures.evidenceID])
        let inputBoundary = try #require(state.eventBoundaries[evidenceEventID])
        let projectionBaseEventID = try #require(state.lastEventID)
        let projectionBase = try #require(state.eventBoundaries[projectionBaseEventID])
        let receiptID: ModelCallReceiptID = testID("model-call-\(suffix)")
        let outputHash = SHA256Digest.hash(Data("provider-output-\(suffix)".utf8))
        let manifest = try DerivedEventManifest.committing(
            adapterID: testText("authorization-test-adapter"),
            adapterVersion: testText("v1"),
            projectionBase: projectionBase,
            receiptID: receiptID,
            outputHash: outputHash,
            entries: entries
        )
        let receipt = try ModelCallReceipt(
            id: receiptID,
            provider: testText("openai"),
            providerResponseID: testText("resp_\(suffix)"),
            purpose: .claimExtraction,
            inputBoundary: inputBoundary,
            promptVersion: testText("claim-extraction.v1"),
            outputSchemaVersion: testText("claim-proposals.v1"),
            model: testText("gpt-fixture"),
            outputHash: outputHash,
            derivedEventManifest: manifest
        )
        var chain = EventChainBuilder(
            sessionID: state.sessionID,
            nextSequence: try #require(state.lastSequence).successor(),
            previousHash: state.lastEventHash
        )
        let receiptEvent = try chain.seal(
            id: testID("event-model-call-\(suffix)"),
            occurredAt: timestamp(),
            recordedAt: timestamp(1),
            causationID: inputBoundary.eventID,
            command: .modelProjection(
                validator: testText("claim-projection-validator"),
                model: modelIdentity(),
                operation: .recordCall(receipt)
            )
        )
        return ModelProjectionContext(
            receiptEvent: receiptEvent,
            state: try ScoutGraphReducer.reduce(state, event: receiptEvent),
            chain: chain
        )
    }

    private func modelIdentity() -> ModelIdentity {
        ModelIdentity(
            provider: testText("openai"),
            model: testText("gpt-fixture"),
            operationVersion: testText("claim-extraction.v1")
        )
    }

    private func proposedClaim(
        id: String,
        evidenceIDs: [EvidenceID] = [ScoutFixtures.evidenceID],
        assertedBy: SpeakerID? = ScoutFixtures.speakerID,
        supersedes: ClaimID? = nil
    ) -> Claim {
        Claim(
            id: testID(id),
            subject: .entity(ScoutFixtures.customerDataEntityID),
            predicate: .hasGoal,
            object: .value(.text(id)),
            assertedBy: assertedBy,
            evidenceIDs: evidenceIDs,
            trust: TrustAssessment(
                origin: .suggested,
                confidence: try! Confidence(basisPoints: 7_500),
                validationStatus: .needsValidation
            ),
            supersedes: supersedes
        )
    }

    private func confirmedTrust() -> TrustAssessment {
        TrustAssessment(
            origin: .confirmed,
            confidence: try! Confidence(basisPoints: 10_000),
            validationStatus: .validated
        )
    }

    private func rejectedTrust() -> TrustAssessment {
        TrustAssessment(
            origin: .confirmed,
            confidence: try! Confidence(basisPoints: 10_000),
            validationStatus: .rejected
        )
    }

    private func authenticatedClaimReview(
        eventID: EventID,
        claimID: ClaimID,
        targetEventID: EventID,
        state: ScoutState
    ) throws -> AuthenticatedLocalReview {
        let claim = try #require(state.claims[claimID])
        let intent = LocalReviewIntent(
            sessionID: state.sessionID,
            eventID: eventID,
            operation: .reviewClaim(.init(
                claimID: claimID,
                status: .accepted,
                trust: confirmedTrust()
            )),
            targetEventID: targetEventID,
            targetStateHash: .hash(claim.canonicalValue)
        )
        return AuthenticatedLocalReview(intent: intent, authenticatedAt: timestamp())
    }

    private func claimProposalEventID(
        _ claimID: ClaimID,
        in events: [ScoutEventEnvelope]
    ) throws -> EventID {
        try #require(events.first { event in
            guard case let .claimProposed(claim) = event.payload else { return false }
            return claim.id == claimID
        }?.id)
    }
}
