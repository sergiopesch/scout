import Foundation

/// Stable fixture shared by tests, previews, and integration adapters.
public enum ScoutFixtures {
    public static let sessionID: SessionID = id("session-acme-retail")
    public static let speakerID: SpeakerID = id("speaker-emma")
    public static let utteranceID: UtteranceID = id("utterance-001")
    public static let evidenceID: EvidenceID = id("evidence-001")
    public static let modelCallReceiptID: ModelCallReceiptID = id("model-call-001")
    public static let customerDataEntityID: EntityID = id("entity-customer-data")
    public static let salesforceEntityID: EntityID = id("entity-salesforce")
    public static let claimID: ClaimID = id("claim-customer-data-salesforce")
    public static let relationshipID: RelationshipID = id("relationship-data-salesforce")

    public static let baseTimestamp = ScoutTimestamp(millisecondsSinceUnixEpoch: 1_750_000_000_000)

    public static let heardTrust = TrustAssessment(
        origin: .heard,
        confidence: try! Confidence(basisPoints: 9_200),
        validationStatus: .needsValidation,
        rationale: text("Directly stated by the customer; architectural detail needs confirmation.")
    )

    public static func sampleEvents(includeSessionEnd: Bool = false) throws -> [ScoutEventEnvelope] {
        try sampleValidatedEvents(includeSessionEnd: includeSessionEnd).map(\.envelope)
    }

    public static func sampleValidatedEvents(
        includeSessionEnd: Bool = false
    ) throws -> [ValidatedScoutEvent] {
        var chain = EventChainBuilder(sessionID: sessionID)
        var events: [ValidatedScoutEvent] = []

        func timestamp(_ offset: Int64) -> ScoutTimestamp {
            ScoutTimestamp(
                millisecondsSinceUnixEpoch: baseTimestamp.millisecondsSinceUnixEpoch + offset
            )
        }

        let systemComponent = text("scout-core-fixture")
        let captureComponent = text("scout-core-fixture-capture")
        let modelValidator = text("scout-core-fixture-model-validator")
        let speakerActor = EventActor.speaker(speakerID)
        let modelIdentity = ModelIdentity(
            provider: text("openai"),
            model: text("gpt-fixture"),
            operationVersion: text("claim-extraction.v1")
        )

        events.append(try chain.seal(
            id: id("event-001"),
            occurredAt: timestamp(0),
            recordedAt: timestamp(1),
            command: .sessionLifecycle(component: systemComponent, operation: .start(DiscoverySession(
                id: sessionID,
                title: text("Acme Retail discovery"),
                startedAt: timestamp(0)
            )))
        ))

        events.append(try chain.seal(
            id: id("event-002"),
            occurredAt: timestamp(100),
            recordedAt: timestamp(101),
            command: .sessionLifecycle(component: systemComponent, operation: .upsertSpeaker(Speaker(
                id: speakerID,
                displayName: text("Emma Lewis"),
                role: text("VP, Digital Commerce"),
                organization: text("Acme Retail"),
                affiliation: .customer
            )))
        ))

        let quote = text(
            "Salesforce holds our customer data, but our inventory is in NetSuite and the hand-off is still manual."
        )
        events.append(try chain.seal(
            id: id("event-003"),
            occurredAt: timestamp(200),
            recordedAt: timestamp(205),
            command: .capturePipeline(component: captureComponent, operation: .finalizeUtterance(Utterance(
                id: utteranceID,
                speakerID: speakerID,
                startedAt: timestamp(200),
                endedAt: timestamp(4_200),
                text: quote,
                transcriptionConfidence: try! Confidence(basisPoints: 9_650),
                languageCode: "en-GB"
            )))
        ))

        events.append(try chain.seal(
            id: id("event-004"),
            occurredAt: timestamp(4_210),
            recordedAt: timestamp(4_220),
            causationID: id("event-003"),
            command: .capturePipeline(component: captureComponent, operation: .recordEvidence(Evidence(
                id: evidenceID,
                source: .utterance(utteranceID),
                excerpt: quote,
                capturedAt: timestamp(4_210),
                capturedBy: speakerActor
            )))
        ))

        events.append(try chain.seal(
            id: id("event-005"),
            occurredAt: timestamp(4_230),
            recordedAt: timestamp(4_240),
            causationID: id("event-004"),
            command: .deterministicProjection(component: systemComponent, operation: .upsertEntity(GraphEntity(
                id: customerDataEntityID,
                kind: .dataAsset,
                canonicalName: text("Customer data"),
                aliases: [text("CRM data")],
                attributes: ["owner": .text("Digital Commerce")],
                evidenceIDs: [evidenceID],
                trust: heardTrust
            )))
        ))

        events.append(try chain.seal(
            id: id("event-006"),
            occurredAt: timestamp(4_250),
            recordedAt: timestamp(4_260),
            causationID: id("event-004"),
            command: .deterministicProjection(component: systemComponent, operation: .upsertEntity(GraphEntity(
                id: salesforceEntityID,
                kind: .system,
                canonicalName: text("Salesforce"),
                attributes: ["category": .text("CRM")],
                evidenceIDs: [evidenceID],
                trust: heardTrust
            )))
        ))

        events.append(try chain.seal(
            id: id("event-007"),
            occurredAt: timestamp(4_270),
            recordedAt: timestamp(4_280),
            causationID: id("event-004"),
            command: .deterministicProjection(component: systemComponent, operation: .proposeClaim(Claim(
                id: claimID,
                subject: .entity(customerDataEntityID),
                predicate: .storesDataIn,
                object: .entity(salesforceEntityID),
                assertedBy: speakerID,
                evidenceIDs: [evidenceID],
                trust: heardTrust
            )))
        ))

        events.append(try chain.seal(
            id: id("event-008"),
            occurredAt: timestamp(4_290),
            recordedAt: timestamp(4_300),
            causationID: id("event-007"),
            command: .deterministicProjection(
                component: systemComponent,
                operation: .upsertRelationship(GraphRelationship(
                id: relationshipID,
                sourceID: customerDataEntityID,
                targetID: salesforceEntityID,
                kind: .stores,
                label: text("stored in"),
                claimIDs: [claimID],
                evidenceIDs: [evidenceID],
                trust: heardTrust
                ))
            )
        ))

        let inputBoundary = ModelInputEventBoundary(events[3].envelope)
        let outputHash = SHA256Digest.hash(Data("fixture-claim-proposal".utf8))
        let baseReceipt = try ModelCallReceipt(
            id: modelCallReceiptID,
            provider: text("openai"),
            providerResponseID: text("resp_fixture_claims_001"),
            purpose: .claimExtraction,
            inputBoundary: inputBoundary,
            promptVersion: text("claim-extraction.v1"),
            outputSchemaVersion: text("claim-proposals.v1"),
            model: text("gpt-fixture"),
            outputHash: outputHash,
            metadata: [
                "input_tokens": .integer(128),
                "output_tokens": .integer(42),
            ]
        )
        let projectionBase = ModelInputEventBoundary(events.last!.envelope)
        let manifest = try DerivedEventManifest.committing(
            adapterID: text("scout-fixture-claim-projection"),
            adapterVersion: text("fixture.v1"),
            projectionBase: projectionBase,
            receiptID: baseReceipt.id,
            outputHash: outputHash,
            entries: []
        )
        let receipt = try ModelCallReceipt(
            id: baseReceipt.id,
            provider: baseReceipt.provider,
            providerResponseID: baseReceipt.providerResponseID,
            purpose: baseReceipt.purpose,
            inputBoundary: baseReceipt.inputBoundary,
            promptVersion: baseReceipt.promptVersion,
            outputSchemaVersion: baseReceipt.outputSchemaVersion,
            model: baseReceipt.model,
            outputHash: baseReceipt.outputHash,
            derivedEventManifest: manifest,
            metadata: baseReceipt.metadata
        )
        events.append(try chain.seal(
            id: id("event-009"),
            occurredAt: timestamp(4_310),
            recordedAt: timestamp(4_320),
            causationID: inputBoundary.eventID,
            command: .modelProjection(
                validator: modelValidator,
                model: modelIdentity,
                operation: .recordCall(receipt)
            )
        ))

        if includeSessionEnd {
            events.append(try chain.seal(
                id: id("event-010"),
                occurredAt: timestamp(60_000),
                recordedAt: timestamp(60_001),
                command: .sessionLifecycle(
                    component: systemComponent,
                    operation: .end(SessionEnded(endedAt: timestamp(60_000)))
                )
            ))
        }

        return events
    }

    public static func sampleState(includeSessionEnd: Bool = false) throws -> ScoutState {
        try ScoutGraphReducer.replay(sampleEvents(includeSessionEnd: includeSessionEnd))
    }

    private static func id<Tag: Sendable>(_ value: String) -> ScoutID<Tag> {
        try! ScoutID<Tag>(validating: value)
    }

    private static func text(_ value: String) -> NonEmptyString {
        try! NonEmptyString(validating: value)
    }
}
