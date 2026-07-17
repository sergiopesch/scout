import Foundation
import XCTest
@testable import Scout

final class ClaimProposalProjectorTests: XCTestCase {
    func testDeduplicatesSemanticClaimsAndPreservesCompleteEvidenceProvenance() throws {
        let projection = try ClaimProposalProjector().project(
            decodeResult(claims: [firstClaim, duplicateClaim]),
            for: request,
            speakerNamesByID: ["speaker-raj": "Raj Patel", "speaker-maya": "Maya Chen"]
        )

        XCTAssertEqual(projection.entities.count, 2)
        XCTAssertEqual(projection.relationships.count, 1)
        XCTAssertEqual(projection.claims.count, 1)

        let entityIDs = Set(projection.entities.map(\.id))
        let relationship = try XCTUnwrap(projection.relationships.first)
        XCTAssertTrue(entityIDs.contains(relationship.sourceID))
        XCTAssertTrue(entityIDs.contains(relationship.targetID))
        XCTAssertEqual(relationship.confidence, 0.98)
        XCTAssertEqual(relationship.provenance, .proposed)
        XCTAssertTrue(relationship.needsValidation)
        XCTAssertEqual(relationship.supportingClaimIDs.count, 1)
        XCTAssertEqual(relationship.evidenceIDs, ["evidence-1", "evidence-2"])

        let claim = try XCTUnwrap(projection.claims.first)
        XCTAssertEqual(claim.provenance, .proposed)
        XCTAssertEqual(claim.confidence, 0.98)
        XCTAssertEqual(claim.evidenceQuote, "Inventory lives in NetSuite. · The inventory record is stored in NetSuite.")
        XCTAssertEqual(claim.speakerName, "Maya Chen, Raj Patel")
        XCTAssertEqual(claim.timestamp, "00:01")
        XCTAssertTrue(claim.needsValidation)

        let provenance = try XCTUnwrap(projection.claimProvenance.first)
        XCTAssertEqual(provenance.clientReferences, ["claim-a", "claim-b"])
        XCTAssertEqual(provenance.evidenceUtteranceIDs, ["utterance-1", "utterance-2"])
        XCTAssertEqual(provenance.evidenceIDs, ["evidence-1", "evidence-2"])
        XCTAssertEqual(provenance.rationales, ["Direct statement.", "Repeated direct statement."])
        XCTAssertEqual(provenance.modelCall.inputEventBoundary, 42)
        XCTAssertEqual(projection.entityEvidence.count, 2)
        XCTAssertEqual(projection.relationshipEvidence.first?.evidenceIDs, ["evidence-1", "evidence-2"])
    }

    func testProjectionIsIndependentOfProposalOrdering() throws {
        let projector = ClaimProposalProjector()
        let forward = try projector.project(
            decodeResult(claims: [firstClaim, duplicateClaim]),
            for: request
        )
        let reversed = try projector.project(
            decodeResult(claims: [duplicateClaim, firstClaim]),
            for: request
        )

        XCTAssertEqual(forward, reversed)
        for entity in forward.entities {
            XCTAssertTrue((0 ... 1).contains(entity.x))
            XCTAssertTrue((0 ... 1).contains(entity.y))
            XCTAssertTrue(entity.id.hasPrefix("entity-"))
        }
    }

    func testDisplayNamesAreDeterministicAcrossEquivalentCasing() throws {
        let alternateCasing = duplicateClaim
            .replacingOccurrences(of: "NetSuite", with: "NETSUITE")
            .replacingOccurrences(of: "Inventory", with: "INVENTORY")
        let projector = ClaimProposalProjector()
        let forward = try projector.project(
            decodeResult(claims: [firstClaim, alternateCasing]),
            for: request
        )
        let reversed = try projector.project(
            decodeResult(claims: [alternateCasing, firstClaim]),
            for: request
        )

        XCTAssertEqual(forward, reversed)
    }

    func testSemanticIdentifiersDoNotDependOnModelReferenceRationaleOrConfidence() throws {
        let changed = firstClaim
            .replacingOccurrences(of: "claim-a", with: "model-ref-99")
            .replacingOccurrences(of: "Direct statement.", with: "Different model rationale.")
            .replacingOccurrences(of: "0.98", with: "0.77")
        let original = try ClaimProposalProjector().project(decodeResult(claims: [firstClaim]), for: request)
        let revised = try ClaimProposalProjector().project(decodeResult(claims: [changed]), for: request)

        XCTAssertEqual(original.entities.map(\.id), revised.entities.map(\.id))
        XCTAssertEqual(original.relationships.map(\.id), revised.relationships.map(\.id))
        XCTAssertEqual(original.claims.map(\.id), revised.claims.map(\.id))
    }

    func testFailsClosedWhenEvidenceCannotBeResolved() throws {
        let invalid = firstClaim.replacingOccurrences(of: "utterance-1", with: "utterance-missing")

        XCTAssertThrowsError(
            try ClaimProposalProjector().project(decodeResult(claims: [invalid]), for: request)
        ) { error in
            XCTAssertEqual(
                error as? ClaimProposalProjectionError,
                .missingEvidenceUtterance("utterance-missing")
            )
        }
    }

    func testInferredClaimRemainsExplicitlyInferredAndNeedsValidation() throws {
        let inferred = firstClaim
            .replacingOccurrences(of: "\"heard\"", with: "\"inferred\"")
        let projection = try ClaimProposalProjector().project(decodeResult(claims: [inferred]), for: request)
        let claim = try XCTUnwrap(projection.claims.first)

        XCTAssertEqual(claim.provenance, .proposed)
        XCTAssertTrue(claim.needsValidation)
        XCTAssertEqual(projection.entities.map(\.provenance), [.proposed, .proposed])
    }

    func testCarriesDecodedScalarObjectValueAsStructuredProvenance() throws {
        let scalar = firstClaim.replacingOccurrences(
            of: "\"value\":null",
            with: "\"value\":\" 97.5% in Q4 \""
        )

        let projection = try ClaimProposalProjector().project(
            decodeResult(claims: [scalar]),
            for: request
        )

        XCTAssertEqual(projection.claimProvenance.first?.objectValue, " 97.5% in Q4 ")
        XCTAssertTrue(projection.claims.first?.detail.contains("Value:  97.5% in Q4 .") == true)
        XCTAssertEqual(projection.relationships.count, 1)
        XCTAssertEqual(projection.entities.count, 2)
    }

    func testScalarValueChangesClaimIdentityButNotEntityRelationshipIdentity() throws {
        let target95 = firstClaim.replacingOccurrences(
            of: "\"value\":null",
            with: "\"value\":\"95%\""
        )
        let target97 = firstClaim.replacingOccurrences(
            of: "\"value\":null",
            with: "\"value\":\"97%\""
        )
        let projector = ClaimProposalProjector()

        let projection95 = try projector.project(decodeResult(claims: [target95]), for: request)
        let projection97 = try projector.project(decodeResult(claims: [target97]), for: request)

        XCTAssertNotEqual(projection95.claims.map(\.id), projection97.claims.map(\.id))
        XCTAssertEqual(projection95.entities.map(\.id), projection97.entities.map(\.id))
        XCTAssertEqual(projection95.relationships.map(\.id), projection97.relationships.map(\.id))
        XCTAssertEqual(projection95.claimProvenance.first?.objectValue, "95%")
        XCTAssertEqual(projection97.claimProvenance.first?.objectValue, "97%")
    }

    func testAbsentObjectValueDoesNotCollideWithPresentEmptyLiteral() throws {
        let emptyLiteral = firstClaim.replacingOccurrences(
            of: "\"value\":null",
            with: "\"value\":\"\""
        )

        let entityObject = try ClaimProposalProjector().project(
            decodeResult(claims: [firstClaim]),
            for: request
        )
        let scalarObject = try ClaimProposalProjector().project(
            decodeResult(claims: [emptyLiteral]),
            for: request
        )

        XCTAssertNotEqual(entityObject.claims.map(\.id), scalarObject.claims.map(\.id))
        XCTAssertNil(entityObject.claimProvenance.first?.objectValue)
        XCTAssertEqual(scalarObject.claimProvenance.first?.objectValue, "")
        XCTAssertEqual(entityObject.relationships.map(\.id), scalarObject.relationships.map(\.id))
    }

    private var request: ClaimExtractionRequest {
        ClaimExtractionRequest(
            sessionID: "session-1",
            eventBoundary: 42,
            utterances: [
                ClaimExtractionUtterance(
                    utteranceID: "utterance-1",
                    evidenceID: "evidence-1",
                    speakerID: "speaker-raj",
                    text: "Inventory lives in NetSuite.",
                    startMilliseconds: 1_000,
                    endMilliseconds: 2_000,
                    source: .realtime
                ),
                ClaimExtractionUtterance(
                    utteranceID: "utterance-2",
                    evidenceID: "evidence-2",
                    speakerID: "speaker-maya",
                    text: "The inventory record is stored in NetSuite.",
                    startMilliseconds: 2_100,
                    endMilliseconds: 3_500,
                    source: .diarizationRevision
                ),
            ]
        )
    }

    private var firstClaim: String {
        """
        {
          "client_ref":"claim-a",
          "subject":{"kind":"system","name":"NetSuite"},
          "predicate":"stores",
          "object":{"kind":"data","name":"Inventory","value":null},
          "epistemic_status":"heard",
          "confidence":0.98,
          "evidence_utterance_ids":["utterance-1"],
          "rationale":"Direct statement."
        }
        """
    }

    private var duplicateClaim: String {
        """
        {
          "client_ref":"claim-b",
          "subject":{"kind":"system","name":"NetSuite"},
          "predicate":"stores",
          "object":{"kind":"data","name":"Inventory","value":null},
          "epistemic_status":"heard",
          "confidence":0.91,
          "evidence_utterance_ids":["utterance-2"],
          "rationale":"Repeated direct statement."
        }
        """
    }

    private func decodeResult(claims: [String]) throws -> ClaimExtractionResult {
        let data = Data(
            """
            {
              "proposal": {
                "schema_version": "1.0",
                "claims": [\(claims.joined(separator: ","))],
                "unresolved_terms": []
              },
              "model_call": {
                "response_id": "resp-test",
                "model": "gpt-test",
                "prompt_version": "claims-v1",
                "schema_version": "1.0",
                "input_event_boundary": 42,
                "output_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              }
            }
            """.utf8
        )
        return try JSONDecoder().decode(ClaimExtractionResult.self, from: data)
    }
}
