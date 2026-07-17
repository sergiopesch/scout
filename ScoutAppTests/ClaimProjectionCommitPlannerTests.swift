import Foundation
@testable import Scout
import ScoutCore
import XCTest

final class ClaimProjectionCommitPlannerTests: XCTestCase {
    func testPlanIsDeterministicAndOrdersCorePayloads() throws {
        let fixture = try makeInitialFixture()
        let projection = makeProjection(
            evidenceID: "evidence-1",
            boundary: fixture.boundary,
            responseID: "resp-one",
            outputHashCharacter: "a"
        )
        let planner = ClaimProjectionCommitPlanner()

        let first = try planner.plan(
            projection,
            inputBoundary: fixture.boundary,
            currentState: fixture.state
        )
        let second = try planner.plan(
            projection,
            inputBoundary: fixture.boundary,
            currentState: fixture.state
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.shouldRecordModelCall)
        XCTAssertEqual(first.modelCallReceipt.provider.rawValue, "openai")
        XCTAssertEqual(first.modelCallReceipt.purpose, .claimExtraction)
        XCTAssertEqual(first.modelCallReceipt.outputHash.rawValue, String(repeating: "a", count: 64))
        XCTAssertEqual(
            first.derivedEvents.map(\.payload.kind),
            ["entity.upserted", "entity.upserted", "claim.proposed", "relationship.upserted"]
        )
        XCTAssertEqual(first.derivedEvents.map(\.id).count, Set(first.derivedEvents.map(\.id)).count)
        let proposedClaim = try XCTUnwrap(first.derivedEvents.compactMap { event -> ScoutCore.Claim? in
            guard case let .claimProposed(claim) = event.payload else { return nil }
            return claim
        }.first)
        XCTAssertEqual(proposedClaim.trust.origin, .suggested)
        XCTAssertEqual(proposedClaim.trust.validationStatus, .needsValidation)
        let proposedRelationship = try XCTUnwrap(first.derivedEvents.compactMap { event -> ScoutCore.GraphRelationship? in
            guard case let .relationshipUpserted(relationship) = event.payload else { return nil }
            return relationship
        }.first)
        XCTAssertEqual(proposedRelationship.trust.origin, .suggested)
        XCTAssertEqual(proposedRelationship.trust.validationStatus, .needsValidation)
    }

    func testRejectsProjectionWhoseEvidenceIsNotCommitted() throws {
        let fixture = try makeInitialFixture()
        let projection = makeProjection(
            evidenceID: "evidence-missing",
            boundary: fixture.boundary,
            responseID: "resp-missing",
            outputHashCharacter: "b"
        )
        let missingID = try EvidenceID(validating: "evidence-missing")

        XCTAssertThrowsError(
            try ClaimProjectionCommitPlanner().plan(
                projection,
                inputBoundary: fixture.boundary,
                currentState: fixture.state
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaimProjectionCommitPlanningError,
                .missingEvidence(missingID)
            )
        }
    }

    func testRepeatingTheSameProviderResponseIsANoOp() throws {
        let fixture = try makeInitialFixture()
        let projection = makeProjection(
            evidenceID: "evidence-1",
            boundary: fixture.boundary,
            responseID: "resp-idempotent",
            outputHashCharacter: "c"
        )
        let planner = ClaimProjectionCommitPlanner()
        let first = try planner.plan(
            projection,
            inputBoundary: fixture.boundary,
            currentState: fixture.state
        )
        let committed = try apply(first, to: fixture.state)

        let repeated = try planner.plan(
            projection,
            inputBoundary: fixture.boundary,
            currentState: committed
        )

        XCTAssertTrue(repeated.isNoOp)
        XCTAssertFalse(repeated.shouldRecordModelCall)
        XCTAssertTrue(repeated.derivedEvents.isEmpty)
        XCTAssertEqual(repeated.modelCallEventID, first.modelCallEventID)
        XCTAssertEqual(repeated.modelCallReceipt, first.modelCallReceipt)
    }

    func testNewEvidenceNeverSupersedesAnAcceptedClaim() throws {
        let fixture = try makeInitialFixture()
        let planner = ClaimProjectionCommitPlanner()
        let initialProjection = makeProjection(
            evidenceID: "evidence-1",
            boundary: fixture.boundary,
            responseID: "resp-initial",
            outputHashCharacter: "d"
        )
        let initialPlan = try planner.plan(
            initialProjection,
            inputBoundary: fixture.boundary,
            currentState: fixture.state
        )
        var state = try apply(initialPlan, to: fixture.state)
        let acceptedClaimID = try XCTUnwrap(initialPlan.derivedEvents.compactMap { event -> ClaimID? in
            guard case let .claimProposed(claim) = event.payload else { return nil }
            return claim.id
        }.first)

        let acceptedTrust = try TrustAssessment(
            origin: .confirmed,
            confidence: .certain,
            validationStatus: .validated,
            rationale: NonEmptyString(validating: "Accepted by a human reviewer.")
        )
        (state, _) = try append(
            .claimReviewed(ClaimReviewed(
                claimID: acceptedClaimID,
                status: .accepted,
                trust: acceptedTrust
            )),
            id: "event-accept-claim",
            to: state
        )

        let secondUtteranceID = try UtteranceID(validating: "utterance-2")
        let speakerID = try SpeakerID(validating: "speaker-customer")
        (state, _) = try append(
            .utteranceFinalized(Utterance(
                id: secondUtteranceID,
                speakerID: speakerID,
                startedAt: timestamp(2000),
                endedAt: timestamp(2800),
                text: NonEmptyString(validating: "Inventory is still stored in NetSuite."),
                transcriptionConfidence: Confidence(basisPoints: 9800),
                languageCode: "en-GB"
            )),
            id: "event-utterance-2",
            to: state
        )
        let secondEvidenceID = try EvidenceID(validating: "evidence-2")
        let (stateWithEvidence, secondBoundary) = try append(
            .evidenceRecorded(Evidence(
                id: secondEvidenceID,
                source: .utterance(secondUtteranceID),
                excerpt: NonEmptyString(validating: "Inventory is still stored in NetSuite."),
                capturedAt: timestamp(2900),
                capturedBy: .speaker(speakerID)
            )),
            id: "event-evidence-2",
            to: state
        )
        state = stateWithEvidence

        let revisedProjection = makeProjection(
            evidenceID: "evidence-2",
            boundary: secondBoundary,
            responseID: "resp-revised",
            outputHashCharacter: "e"
        )
        let revisedPlan = try planner.plan(
            revisedProjection,
            inputBoundary: secondBoundary,
            currentState: state
        )
        let revisedClaim = try XCTUnwrap(revisedPlan.derivedEvents.compactMap { event -> ScoutCore.Claim? in
            guard case let .claimProposed(claim) = event.payload else { return nil }
            return claim
        }.first)

        XCTAssertNil(revisedClaim.supersedes)
        XCTAssertNotEqual(revisedClaim.id, acceptedClaimID)

        let finalState = try apply(revisedPlan, to: state)
        XCTAssertEqual(finalState.claims[acceptedClaimID]?.status, .accepted)
        XCTAssertEqual(finalState.claims[revisedClaim.id]?.status, .proposed)
    }

    func testContradictoryScalarValuesCoexistAndKeepEntityRelationship() throws {
        let fixture = try makeInitialFixture()
        let planner = ClaimProjectionCommitPlanner()
        let initialProjection = makeProjection(
            evidenceID: "evidence-1",
            boundary: fixture.boundary,
            responseID: "resp-target-95",
            outputHashCharacter: "f",
            claimID: "claim-inventory-target-95",
            objectValue: "95%"
        )
        let initialPlan = try planner.plan(
            initialProjection,
            inputBoundary: fixture.boundary,
            currentState: fixture.state
        )
        var state = try apply(initialPlan, to: fixture.state)
        let initialClaim = try XCTUnwrap(initialPlan.derivedEvents.compactMap { event -> ScoutCore.Claim? in
            guard case let .claimProposed(claim) = event.payload else { return nil }
            return claim
        }.first)
        XCTAssertEqual(initialClaim.object, .value(.text("95%")))

        let secondUtteranceID = try UtteranceID(validating: "utterance-scalar-2")
        let speakerID = try SpeakerID(validating: "speaker-customer")
        (state, _) = try append(
            .utteranceFinalized(Utterance(
                id: secondUtteranceID,
                speakerID: speakerID,
                startedAt: timestamp(30_000),
                endedAt: timestamp(30_800),
                text: NonEmptyString(validating: "The target is 97%."),
                transcriptionConfidence: Confidence(basisPoints: 9_800),
                languageCode: "en-GB"
            )),
            id: "event-utterance-scalar-2",
            to: state
        )
        let secondEvidenceID = try EvidenceID(validating: "evidence-scalar-2")
        let (stateWithEvidence, secondBoundary) = try append(
            .evidenceRecorded(Evidence(
                id: secondEvidenceID,
                source: .utterance(secondUtteranceID),
                excerpt: NonEmptyString(validating: "The target is 97%."),
                capturedAt: timestamp(30_900),
                capturedBy: .speaker(speakerID)
            )),
            id: "event-evidence-scalar-2",
            to: state
        )
        state = stateWithEvidence

        let contradictoryProjection = makeProjection(
            evidenceID: secondEvidenceID.rawValue,
            boundary: secondBoundary,
            responseID: "resp-target-97",
            outputHashCharacter: "0",
            claimID: "claim-inventory-target-97",
            objectValue: "97%"
        )
        let contradictoryPlan = try planner.plan(
            contradictoryProjection,
            inputBoundary: secondBoundary,
            currentState: state
        )
        let contradictoryClaim = try XCTUnwrap(
            contradictoryPlan.derivedEvents.compactMap { event -> ScoutCore.Claim? in
                guard case let .claimProposed(claim) = event.payload else { return nil }
                return claim
            }.first
        )

        XCTAssertEqual(contradictoryClaim.object, .value(.text("97%")))
        XCTAssertNil(contradictoryClaim.supersedes)
        let finalState = try apply(contradictoryPlan, to: state)
        XCTAssertEqual(finalState.claims[initialClaim.id]?.status, .proposed)
        XCTAssertEqual(finalState.claims[contradictoryClaim.id]?.status, .proposed)
        XCTAssertEqual(
            Set(finalState.graph.relationships.values.first?.claimIDs ?? []),
            Set([initialClaim.id, contradictoryClaim.id])
        )
    }

    private struct Fixture {
        let state: ScoutState
        let boundary: ScoutEventEnvelope
    }

    private func makeInitialFixture() throws -> Fixture {
        let sessionID = try SessionID(validating: "session-commit-planner")
        let speakerID = try SpeakerID(validating: "speaker-customer")
        let utteranceID = try UtteranceID(validating: "utterance-1")
        let evidenceID = try EvidenceID(validating: "evidence-1")
        let systemActor = try EventActor.system(component: NonEmptyString(validating: "planner-test"))
        var chain = EventChainBuilder(sessionID: sessionID)
        var events: [ScoutEventEnvelope] = []

        try events.append(chain.seal(
            id: EventID(validating: "event-session"),
            occurredAt: timestamp(0),
            recordedAt: timestamp(0),
            actor: systemActor,
            payload: .sessionStarted(DiscoverySession(
                id: sessionID,
                title: NonEmptyString(validating: "Commit planner test"),
                startedAt: timestamp(0)
            ))
        ))
        try events.append(chain.seal(
            id: EventID(validating: "event-speaker"),
            occurredAt: timestamp(100),
            recordedAt: timestamp(100),
            actor: systemActor,
            payload: .speakerUpserted(ScoutCore.Speaker(
                id: speakerID,
                displayName: NonEmptyString(validating: "Customer speaker"),
                affiliation: .customer
            ))
        ))
        try events.append(chain.seal(
            id: EventID(validating: "event-utterance-1"),
            occurredAt: timestamp(1000),
            recordedAt: timestamp(1100),
            actor: .speaker(speakerID),
            payload: .utteranceFinalized(Utterance(
                id: utteranceID,
                speakerID: speakerID,
                startedAt: timestamp(1000),
                endedAt: timestamp(1800),
                text: NonEmptyString(validating: "NetSuite stores inventory."),
                transcriptionConfidence: Confidence(basisPoints: 9700),
                languageCode: "en-GB"
            ))
        ))
        let boundary = try chain.seal(
            id: EventID(validating: "event-evidence-1"),
            occurredAt: timestamp(1900),
            recordedAt: timestamp(1900),
            actor: .speaker(speakerID),
            payload: .evidenceRecorded(Evidence(
                id: evidenceID,
                source: .utterance(utteranceID),
                excerpt: NonEmptyString(validating: "NetSuite stores inventory."),
                capturedAt: timestamp(1900),
                capturedBy: .speaker(speakerID)
            ))
        )
        events.append(boundary)
        return try Fixture(state: ScoutGraphReducer.replay(events), boundary: boundary)
    }

    private func makeProjection(
        evidenceID: String,
        boundary: ScoutEventEnvelope,
        responseID: String,
        outputHashCharacter: Character,
        claimID: String = "claim-system-stores-data",
        objectValue: String? = nil
    ) -> ClaimProposalProjection {
        let modelCall = ClaimModelCall(
            responseID: responseID,
            model: "gpt-5.2",
            promptVersion: "claims-v1",
            schemaVersion: "1.0",
            inputEventBoundary: Int(boundary.sequence.rawValue),
            outputSHA256: String(repeating: outputHashCharacter, count: 64)
        )
        let systemID = "entity-system"
        let dataID = "entity-data"
        let relationshipID = "relationship-stores"
        return ClaimProposalProjection(
            modelCall: modelCall,
            entities: [
                GraphEntity(
                    id: systemID,
                    title: "NetSuite",
                    subtitle: "System",
                    kind: .system,
                    x: 0.25,
                    y: 0.5,
                    provenance: .heard,
                    confidence: 0.96
                ),
                GraphEntity(
                    id: dataID,
                    title: "Inventory",
                    subtitle: "Data",
                    kind: .data,
                    x: 0.5,
                    y: 0.5,
                    provenance: .heard,
                    confidence: 0.96
                ),
            ],
            relationships: [
                GraphRelationship(
                    id: relationshipID,
                    sourceID: systemID,
                    targetID: dataID,
                    label: "stores",
                    confidence: 0.96,
                    isFriction: false
                ),
            ],
            claims: [
                TrustClaim(
                    id: claimID,
                    title: "NetSuite stores Inventory",
                    detail: "NetSuite stores Inventory.",
                    provenance: .heard,
                    confidence: 0.96,
                    evidenceQuote: "NetSuite stores inventory.",
                    speakerName: "Customer speaker",
                    timestamp: "00:01",
                    relatedEntityID: systemID,
                    needsValidation: false
                ),
            ],
            entityEvidence: [
                ProjectionEvidenceLink(
                    projectionID: systemID,
                    projectedClaimIDs: [claimID],
                    clientReferences: ["client-claim"],
                    evidenceUtteranceIDs: ["utterance-source"],
                    evidenceIDs: [evidenceID]
                ),
                ProjectionEvidenceLink(
                    projectionID: dataID,
                    projectedClaimIDs: [claimID],
                    clientReferences: ["client-claim"],
                    evidenceUtteranceIDs: ["utterance-source"],
                    evidenceIDs: [evidenceID]
                ),
            ],
            relationshipEvidence: [
                ProjectionEvidenceLink(
                    projectionID: relationshipID,
                    projectedClaimIDs: [claimID],
                    clientReferences: ["client-claim"],
                    evidenceUtteranceIDs: ["utterance-source"],
                    evidenceIDs: [evidenceID]
                ),
            ],
            claimProvenance: [
                ClaimProjectionProvenance(
                    projectedClaimID: claimID,
                    clientReferences: ["client-claim"],
                    evidenceUtteranceIDs: ["utterance-source"],
                    evidenceIDs: [evidenceID],
                    rationales: ["Direct customer statement."],
                    objectValue: objectValue,
                    modelCall: modelCall
                ),
            ]
        )
    }

    private func apply(
        _ plan: ClaimProjectionCommitPlan,
        to state: ScoutState
    ) throws -> ScoutState {
        var next = state
        var chain = try EventChainBuilder(
            sessionID: state.sessionID,
            nextSequence: XCTUnwrap(state.lastSequence).successor(),
            previousHash: state.lastEventHash
        )
        let actor = try EventActor.model(ModelIdentity(
            provider: NonEmptyString(validating: "openai"),
            model: NonEmptyString(validating: plan.modelCallReceipt.model.rawValue),
            operationVersion: NonEmptyString(validating: plan.modelCallReceipt.promptVersion.rawValue)
        ))
        if plan.shouldRecordModelCall {
            let event = try chain.seal(
                id: plan.modelCallEventID,
                occurredAt: timestamp(10000),
                recordedAt: timestamp(10000),
                actor: actor,
                causationID: plan.modelCallReceipt.inputBoundary.eventID,
                payload: .modelCallRecorded(plan.modelCallReceipt)
            )
            next = try ScoutGraphReducer.reduce(next, event: event)
        }
        for planned in plan.derivedEvents {
            let event = try chain.seal(
                id: planned.id,
                occurredAt: timestamp(10000),
                recordedAt: timestamp(10000),
                actor: actor,
                correlationID: plan.modelCallEventID,
                causationID: plan.modelCallEventID,
                payload: planned.payload
            )
            next = try ScoutGraphReducer.reduce(next, event: event)
        }
        return next
    }

    private func append(
        _ payload: ScoutEventPayload,
        id: String,
        to state: ScoutState
    ) throws -> (ScoutState, ScoutEventEnvelope) {
        var chain = try EventChainBuilder(
            sessionID: state.sessionID,
            nextSequence: XCTUnwrap(state.lastSequence).successor(),
            previousHash: state.lastEventHash
        )
        let event = try chain.seal(
            id: EventID(validating: id),
            occurredAt: timestamp(20000),
            recordedAt: timestamp(20000),
            actor: .system(component: NonEmptyString(validating: "planner-test")),
            payload: payload
        )
        return try (ScoutGraphReducer.reduce(state, event: event), event)
    }

    private func timestamp(_ offset: Int64) -> ScoutTimestamp {
        ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_000_000 + offset)
    }
}
