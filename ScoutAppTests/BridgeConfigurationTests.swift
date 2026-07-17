import Foundation
import XCTest
@testable import Scout

final class BridgeConfigurationTests: XCTestCase {
    func testMissingEnvironmentFailsClosedInsteadOfUsingAFixedLoopbackPort() {
        let configuration = BridgeConfiguration.fromEnvironment([:])

        XCTAssertFalse(configuration.isConfigured)
        XCTAssertNotEqual(configuration.baseURL.absoluteString, "http://127.0.0.1:4317")
    }

    func testPromotesHTTPSBridgeToSecureWebSocket() {
        let configuration = BridgeConfiguration.fromEnvironment([
            "SCOUT_BRIDGE_URL": "https://scout.example.test"
        ])

        XCTAssertEqual(configuration.realtimeURL.absoluteString, "wss://scout.example.test/realtime")
    }

    func testRejectsNonHTTPEnvironmentSchemes() {
        let configuration = BridgeConfiguration.fromEnvironment([
            "SCOUT_BRIDGE_URL": "file:///private/tmp/not-a-bridge"
        ])

        XCTAssertFalse(configuration.isConfigured)
    }

    func testRejectsPlaintextRemoteBridge() {
        let configuration = BridgeConfiguration.fromEnvironment([
            "SCOUT_BRIDGE_URL": "http://scout.example.test"
        ])

        XCTAssertFalse(configuration.isConfigured)
    }

    func testRejectsCredentialsEmbeddedInBridgeURL() {
        let configuration = BridgeConfiguration.fromEnvironment([
            "SCOUT_BRIDGE_URL": "https://user:password@scout.example.test"
        ])

        XCTAssertFalse(configuration.isConfigured)
    }

    func testCarriesGatewayTokenWithoutPuttingItInTheURL() async throws {
        let token = String(repeating: "a", count: 64)
        let configuration = BridgeConfiguration(
            baseURL: URL(string: "https://scout.example.test")!,
            authenticationToken: token
        )

        let request = try await configuration.authorizedRequest(url: configuration.healthURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertFalse(request.url!.absoluteString.contains(token))
    }

    func testSupervisedLoopbackAttestsPeerBeforeAddingBearer() async throws {
        PeerAttestationURLProtocol.sawAuthorization = false
        let token = String(repeating: "a", count: 64)
        let instanceID = String(repeating: "b", count: 64)
        let configuration = BridgeConfiguration.fromEnvironment([
            "SCOUT_BRIDGE_URL": "http://127.0.0.1:49123",
            "SCOUT_GATEWAY_TOKEN": token,
            "SCOUT_GATEWAY_SUPERVISED": "1",
            "SCOUT_GATEWAY_INSTANCE_ID": instanceID,
        ])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PeerAttestationURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)

        let request = try await configuration.authorizedRequest(
            url: configuration.baseURL.appending(path: "v1/claims/extract"),
            session: session
        )

        XCTAssertTrue(configuration.isConfigured)
        XCTAssertFalse(PeerAttestationURLProtocol.sawAuthorization)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testWrongLoopbackPeerReceivesNoBearer() async throws {
        WrongPeerURLProtocol.sawAuthorization = false
        let configuration = BridgeConfiguration.fromEnvironment([
            "SCOUT_BRIDGE_URL": "http://127.0.0.1:49123",
            "SCOUT_GATEWAY_TOKEN": String(repeating: "a", count: 64),
            "SCOUT_GATEWAY_SUPERVISED": "1",
            "SCOUT_GATEWAY_INSTANCE_ID": String(repeating: "b", count: 64),
        ])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [WrongPeerURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)

        do {
            _ = try await configuration.authorizedRequest(
                url: configuration.baseURL.appending(path: "v1/claims/extract"),
                session: session
            )
            XCTFail("A wrong local peer must fail before authorization")
        } catch {
            XCTAssertEqual(error as? BridgeConfigurationError, .peerAuthenticationFailed)
        }
        XCTAssertFalse(WrongPeerURLProtocol.sawAuthorization)
    }
}

private final class PeerAttestationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var sawAuthorization = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.sawAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["X-Scout-Gateway-Instance-ID": String(repeating: "b", count: 64)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class WrongPeerURLProtocol: URLProtocol {
    nonisolated(unsafe) static var sawAuthorization = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.sawAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["X-Scout-Gateway-Instance-ID": String(repeating: "c", count: 64)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
