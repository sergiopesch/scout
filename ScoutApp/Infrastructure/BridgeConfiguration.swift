import Foundation

enum BridgeConfigurationError: LocalizedError, Equatable {
    case unavailable
    case targetOutsideBridge
    case peerAuthenticationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Scout Gateway is unavailable. Launch Scout with `make run`."
        case .targetOutsideBridge:
            "Scout refused to send Gateway credentials to a different endpoint."
        case .peerAuthenticationFailed:
            "Scout could not authenticate the supervised Gateway instance. No customer data was sent."
        }
    }
}

struct BridgeConfiguration: Hashable, Sendable {
    static let unavailableBaseURL = URL(string: "https://gateway.invalid.scout")!
    static let instanceHeader = "X-Scout-Gateway-Instance-ID"

    private enum TransportSecurity: Hashable, Sendable {
        case unavailable
        case tls
        case supervisedLoopback(instanceID: String)
    }

    let baseURL: URL
    let authenticationToken: String?
    let approvalToken: String?
    private let transportSecurity: TransportSecurity

    var isConfigured: Bool {
        authenticationToken != nil && transportSecurity != .unavailable
    }

    init(
        baseURL: URL = Self.unavailableBaseURL,
        authenticationToken: String? = nil,
        approvalToken: String? = nil,
        supervisedInstanceID: String? = nil
    ) {
        let security = Self.transportSecurity(
            for: baseURL,
            supervisedInstanceID: supervisedInstanceID
        )
        guard security != .unavailable else {
            self.baseURL = Self.unavailableBaseURL
            self.authenticationToken = nil
            self.approvalToken = nil
            transportSecurity = .unavailable
            return
        }
        self.baseURL = baseURL
        self.authenticationToken = authenticationToken.flatMap { $0.count >= 32 ? $0 : nil }
        self.approvalToken = approvalToken.flatMap { $0.count >= 32 ? $0 : nil }
        transportSecurity = security
    }

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        guard let value = environment["SCOUT_BRIDGE_URL"],
              let url = URL(string: value)
        else { return .init() }

        let token = environment["SCOUT_GATEWAY_TOKEN"]
        let approval = environment["SCOUT_APPROVAL_TOKEN"]
        if url.scheme?.lowercased() == "https" {
            return .init(
                baseURL: url,
                authenticationToken: token,
                approvalToken: approval
            )
        }

        guard environment["SCOUT_GATEWAY_SUPERVISED"] == "1",
              let instanceID = environment["SCOUT_GATEWAY_INSTANCE_ID"],
              Self.isValidInstanceID(instanceID)
        else { return .init() }
        return .init(
            baseURL: url,
            authenticationToken: token,
            approvalToken: approval,
            supervisedInstanceID: instanceID
        )
    }

    var realtimeURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/realtime"
        return components.url!
    }

    var healthURL: URL {
        baseURL.appending(path: "health")
    }

    func authorizedRequest(
        url: URL,
        session: URLSession = .shared
    ) async throws -> URLRequest {
        guard let authenticationToken, isConfigured else {
            throw BridgeConfigurationError.unavailable
        }
        guard Self.sameOrigin(url, baseURL) else {
            throw BridgeConfigurationError.targetOutsideBridge
        }

        if case let .supervisedLoopback(instanceID) = transportSecurity {
            var probe = URLRequest(url: healthURL)
            probe.httpMethod = "GET"
            probe.timeoutInterval = 5
            probe.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (_, response) = try await session.data(for: probe)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.value(forHTTPHeaderField: Self.instanceHeader) == instanceID,
                  http.url.map({ Self.sameOrigin($0, baseURL) }) == true
            else {
                throw BridgeConfigurationError.peerAuthenticationFailed
            }
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(authenticationToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func transportSecurity(
        for url: URL,
        supervisedInstanceID: String?
    ) -> TransportSecurity {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return .unavailable }

        if scheme == "https" { return .tls }
        guard scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(host),
              let supervisedInstanceID,
              isValidInstanceID(supervisedInstanceID)
        else { return .unavailable }
        return .supervisedLoopback(instanceID: supervisedInstanceID)
    }

    private static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        guard let lhs = URLComponents(url: left, resolvingAgainstBaseURL: false),
              let rhs = URLComponents(url: right, resolvingAgainstBaseURL: false)
        else { return false }
        return originScheme(lhs.scheme) == originScheme(rhs.scheme)
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func originScheme(_ value: String?) -> String? {
        switch value?.lowercased() {
        case "ws": "http"
        case "wss": "https"
        default: value?.lowercased()
        }
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        return switch components.scheme?.lowercased() {
        case "https", "wss": 443
        case "http", "ws": 80
        default: nil
        }
    }

    private static func isValidInstanceID(_ value: String) -> Bool {
        (32...128).contains(value.count)
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
