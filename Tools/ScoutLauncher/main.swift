import Foundation
import Security
import LocalAuthentication
import CryptoKit
import Darwin

private enum LauncherFailure: LocalizedError {
    case invalidCommand
    case invalidInput
    case keychain(OSStatus)
    case missingOpenAIKey
    case invalidKeyring
    case keyringFull
    case activeKeyCannotBeRevoked
    case approvalKeyNotFound
    case missingRuntime(String)
    case gatewayFailed(String)
    case gatewayTimeout
    case invalidGatewayReadiness
    case smokeFailed(String)
    case localAuthenticationUnavailable
    case localAuthenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidCommand:
            "Unknown Scout launcher command."
        case .invalidInput:
            "Scout secret import input is invalid."
        case let .keychain(status):
            "Scout could not access Keychain (status \(status))."
        case .missingOpenAIKey:
            "Scout's OpenAI API key is not configured in Keychain. Run `make configure-secrets`."
        case .invalidKeyring:
            "Scout's approval keyring is invalid."
        case .keyringFull:
            "Scout's approval keyring reached its 32-key safety limit. Reapprove or expire packs before retiring an old key."
        case .activeKeyCannotBeRevoked:
            "The active approval key cannot be revoked. Rotate first, then revoke the compromised former key."
        case .approvalKeyNotFound:
            "The requested approval key does not exist in this Keychain namespace."
        case let .missingRuntime(path):
            "Scout's packaged runtime is incomplete: \(path) is missing."
        case let .gatewayFailed(message):
            "Scout Gateway failed: \(message)"
        case .gatewayTimeout:
            "Scout Gateway did not become ready within 15 seconds."
        case .invalidGatewayReadiness:
            "Scout Gateway emitted an invalid readiness event."
        case let .smokeFailed(message):
            "Packaged Scout smoke test failed: \(message)"
        case .localAuthenticationUnavailable:
            "Device-owner authentication is unavailable for this Scout security operation."
        case .localAuthenticationFailed:
            "Scout did not authenticate the local device owner for this security operation."
        }
    }
}

private final class LauncherAuthenticationContext: @unchecked Sendable {
    let value = LAContext()

    init() {
        value.localizedCancelTitle = "Cancel"
    }

    func invalidate() {
        value.invalidate()
    }
}

private enum LauncherLocalAuthorization {
    static func require(for arguments: [String]) async throws {
        let context = LauncherAuthenticationContext()
        var availabilityError: NSError?
        guard context.value.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &availabilityError
        ) else {
            throw LauncherFailure.localAuthenticationUnavailable
        }

        let reason = authenticationReason(for: arguments)
        let authenticated: Bool
        do {
            authenticated = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let result = try await context.value.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
                try Task.checkCancellation()
                return result
            } onCancel: {
                context.invalidate()
            }
        } catch is CancellationError {
            throw LauncherFailure.localAuthenticationFailed
        } catch {
            throw LauncherFailure.localAuthenticationFailed
        }
        guard authenticated else { throw LauncherFailure.localAuthenticationFailed }
    }

    private static func authenticationReason(for arguments: [String]) -> String {
        switch arguments {
        case ["secrets", "export"]:
            "Authenticate to use Scout's local development secret bridge."
        case ["secrets", "import"]:
            "Authenticate to import Scout secrets into this Keychain namespace."
        case ["secrets", "rotate-approval"]:
            "Authenticate to rotate Scout's context-pack approval key."
        case ["secrets", "configure-openai"]:
            "Authenticate to configure Scout's OpenAI credential."
        default:
            "Authenticate to change Scout's security configuration."
        }
    }
}

private struct ApprovalSigningKey: Codable {
    var privateKey: String?
    let publicKey: String
}

private struct ApprovalKeyring: Codable {
    let version: Int
    var generation: Int
    var activeKeyID: String
    var keys: [String: ApprovalSigningKey]
    var revokedKeyIDs: [String]

    func validated() throws -> ApprovalKeyring {
        guard version == 2,
              generation > 0,
              Self.validKeyID(activeKeyID),
              keys.count <= 32,
              let active = keys[activeKeyID],
              active.privateKey != nil,
              revokedKeyIDs.count <= 256,
              Set(revokedKeyIDs).count == revokedKeyIDs.count,
              !revokedKeyIDs.contains(activeKeyID),
              revokedKeyIDs.allSatisfy({ Self.validKeyID($0) && keys[$0] == nil }),
              keys.allSatisfy({ keyID, key in
                  guard Self.validKeyID(keyID), Self.validRawKey(key.publicKey) else { return false }
                  if keyID != activeKeyID && key.privateKey != nil { return false }
                  guard let privateKey = key.privateKey else { return true }
                  return Self.validRawKey(privateKey)
                      && Self.publicKey(for: privateKey) == key.publicKey
              })
        else { throw LauncherFailure.invalidKeyring }
        return self
    }

    static func validKeyID(_ value: String) -> Bool {
        guard (1...128).contains(value.count),
              value.first?.isLetter == true || value.first?.isNumber == true
        else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }

    static func encodeRawKey(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeRawKey(_ value: String) -> Data? {
        guard value.count == 43,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        else { return nil }
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: standard), data.count == 32 else { return nil }
        return data
    }

    static func validRawKey(_ value: String) -> Bool {
        decodeRawKey(value) != nil
    }

    static func publicKey(for privateKey: String) -> String? {
        guard let raw = decodeRawKey(privateKey),
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        else { return nil }
        return encodeRawKey(signingKey.publicKey.rawRepresentation)
    }
}

private struct SecretImport: Decodable {
    let openAIAPIKey: String?
    let approvalPrivateKey: String?
    let approvalKeyID: String?
    let verificationKeys: [String: String]?
    let revokedKeyIDs: [String]?
}

private struct SecretExport: Encodable {
    let openAIAPIKey: String?
    let approvalPrivateKey: String
    let approvalKeyID: String
    let verificationKeys: [String: String]
    let revokedKeyIDs: [String]
}

private struct SecretStatus: Encodable {
    let openAIConfigured: Bool
    let activeApprovalKeyID: String
    let verificationKeyIDs: [String]
    let revokedApprovalKeyIDs: [String]
    let approvalKeyringGeneration: Int
}

private struct PublishedApprovalKeyring: Encodable {
    let version: Int
    let generation: Int
    let activeKeyID: String
    let keys: [String: String]
    let revokedKeyIDs: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case generation
        case activeKeyID = "active_key_id"
        case keys
        case revokedKeyIDs = "revoked_key_ids"
    }
}

private struct ApprovalKeyUsage: Encodable {
    let contextPackDirectory: String
    let packCountByKeyID: [String: Int]
    let unsignedApprovedPackCount: Int
}

private enum ScoutSecrets {
    private static var service: String {
        let base = "dev.scout.discovery.gateway-secrets"
        guard let namespace = Bundle.main.object(forInfoDictionaryKey: "ScoutKeychainNamespace") as? String,
              !namespace.isEmpty,
              namespace.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" })
        else { return base }
        return "\(base).\(namespace)"
    }
    private static let openAIAccount = "openai-api-key-v1"
    private static let keyringAccount = "approval-signing-keyring-v2"

    static func importSecrets(_ input: SecretImport) throws {
        if let key = input.openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            guard key.utf8.count >= 20 else { throw LauncherFailure.invalidInput }
            try upsert(account: openAIAccount, data: Data(key.utf8))
        }

        if let privateKey = input.approvalPrivateKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !privateKey.isEmpty {
            let keyID = input.approvalKeyID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "scout-local-v1"
            guard ApprovalKeyring.validKeyID(keyID),
                  let publicKey = ApprovalKeyring.publicKey(for: privateKey)
            else { throw LauncherFailure.invalidInput }
            let revokedKeyIDs = input.revokedKeyIDs ?? []
            let publicKeys = input.verificationKeys ?? [keyID: publicKey]
            guard publicKeys[keyID] == publicKey,
                  publicKeys.count <= 32,
                  revokedKeyIDs.count <= 256,
                  Set(revokedKeyIDs).count == revokedKeyIDs.count,
                  revokedKeyIDs.allSatisfy({ ApprovalKeyring.validKeyID($0) && publicKeys[$0] == nil })
            else {
                throw LauncherFailure.invalidKeyring
            }
            var keys = publicKeys.mapValues { ApprovalSigningKey(privateKey: nil, publicKey: $0) }
            keys[keyID] = ApprovalSigningKey(privateKey: privateKey, publicKey: publicKey)
            try saveKeyring(ApprovalKeyring(
                version: 2,
                generation: 1,
                activeKeyID: keyID,
                keys: keys,
                revokedKeyIDs: revokedKeyIDs
            ))
        } else if try loadKeyring(required: false) == nil {
            let keyID = newKeyID()
            try saveKeyring(ApprovalKeyring(
                version: 2,
                generation: 1,
                activeKeyID: keyID,
                keys: [keyID: createSigningKey()],
                revokedKeyIDs: []
            ))
        }
    }

    static func export(includeOpenAI: Bool) throws -> SecretExport {
        let keyring = try loadKeyring(required: true)!.validated()
        try publishVerificationKeyring(keyring)
        let openAI = try read(account: openAIAccount).flatMap { String(data: $0, encoding: .utf8) }
        if includeOpenAI && openAI == nil { throw LauncherFailure.missingOpenAIKey }
        guard let active = keyring.keys[keyring.activeKeyID],
              let privateKey = active.privateKey
        else { throw LauncherFailure.invalidKeyring }
        return SecretExport(
            openAIAPIKey: includeOpenAI ? openAI : nil,
            approvalPrivateKey: privateKey,
            approvalKeyID: keyring.activeKeyID,
            verificationKeys: keyring.keys.mapValues(\.publicKey),
            revokedKeyIDs: keyring.revokedKeyIDs.sorted()
        )
    }

    static func status() throws -> SecretStatus {
        let keyring = try loadKeyring(required: true)!.validated()
        try publishVerificationKeyring(keyring)
        return SecretStatus(
            openAIConfigured: try read(account: openAIAccount) != nil,
            activeApprovalKeyID: keyring.activeKeyID,
            verificationKeyIDs: keyring.keys.keys.filter {
                $0 != keyring.activeKeyID && !keyring.revokedKeyIDs.contains($0)
            }.sorted(),
            revokedApprovalKeyIDs: keyring.revokedKeyIDs.sorted(),
            approvalKeyringGeneration: keyring.generation
        )
    }

    static func rotateApproval() throws -> SecretStatus {
        var keyring = try loadKeyring(required: true)!.validated()
        guard keyring.keys.count < 32 else { throw LauncherFailure.keyringFull }
        guard let active = keyring.keys[keyring.activeKeyID] else { throw LauncherFailure.invalidKeyring }
        keyring.keys[keyring.activeKeyID] = ApprovalSigningKey(
            privateKey: nil,
            publicKey: active.publicKey
        )
        let keyID = newKeyID()
        keyring.keys[keyID] = createSigningKey()
        keyring.activeKeyID = keyID
        keyring.generation += 1
        try saveKeyring(keyring)
        return try status()
    }

    static func revokeApproval(keyID: String) throws -> SecretStatus {
        var keyring = try loadKeyring(required: true)!.validated()
        guard keyID != keyring.activeKeyID else { throw LauncherFailure.activeKeyCannotBeRevoked }
        guard keyring.keys.removeValue(forKey: keyID) != nil else {
            throw LauncherFailure.approvalKeyNotFound
        }
        if !keyring.revokedKeyIDs.contains(keyID) {
            keyring.revokedKeyIDs.append(keyID)
            keyring.generation += 1
        }
        try saveKeyring(keyring)
        return try status()
    }

    static func configureOpenAIInteractively() throws -> SecretStatus {
        guard isatty(STDIN_FILENO) == 1,
              let pointer = getpass("OpenAI API key (input hidden): ")
        else { throw LauncherFailure.invalidInput }
        let key = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count >= 20 else { throw LauncherFailure.invalidInput }
        try importSecrets(SecretImport(
            openAIAPIKey: key,
            approvalPrivateKey: nil,
            approvalKeyID: nil,
            verificationKeys: nil,
            revokedKeyIDs: nil
        ))
        return try status()
    }

    private static func createSigningKey() -> ApprovalSigningKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        return ApprovalSigningKey(
            privateKey: ApprovalKeyring.encodeRawKey(privateKey.rawRepresentation),
            publicKey: ApprovalKeyring.encodeRawKey(privateKey.publicKey.rawRepresentation)
        )
    }

    private static func loadKeyring(required: Bool) throws -> ApprovalKeyring? {
        guard let data = try read(account: keyringAccount) else {
            if required { throw LauncherFailure.invalidKeyring }
            return nil
        }
        guard let keyring = try? JSONDecoder().decode(ApprovalKeyring.self, from: data) else {
            throw LauncherFailure.invalidKeyring
        }
        return try keyring.validated()
    }

    private static func saveKeyring(_ keyring: ApprovalKeyring) throws {
        let validated = try keyring.validated()
        try upsert(account: keyringAccount, data: try JSONEncoder().encode(validated))
        try publishVerificationKeyring(validated)
    }

    private static func publishVerificationKeyring(_ keyring: ApprovalKeyring) throws {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Scout", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let published = PublishedApprovalKeyring(
            version: 1,
            generation: keyring.generation,
            activeKeyID: keyring.activeKeyID,
            keys: keyring.keys.mapValues(\.publicKey),
            revokedKeyIDs: keyring.revokedKeyIDs.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let destination = root.appendingPathComponent("approval-public-keyring-v1.json")
        try encoder.encode(published).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    private static func read(account: String) throws -> Data? {
        var value: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw LauncherFailure.keychain(status)
        }
        return data
    }

    private static func upsert(account: String, data: Data) throws {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ] as CFDictionary
        let updateStatus = SecItemUpdate(query, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw LauncherFailure.keychain(updateStatus) }
        var attributes = query as! [String: Any]
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw LauncherFailure.keychain(addStatus) }
    }

    private static func randomSecret(byteCount: Int = 48) throws -> String {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, base)
        }
        guard status == errSecSuccess else { throw LauncherFailure.keychain(status) }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func newKeyID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "scout-local-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

private struct GatewayReady: Decodable {
    let event: String
    let service: String
    let host: String
    let port: Int
}

private struct LaunchCredentials {
    let gatewayToken: String
    let approvalToken: String
    let instanceID: String

    static func fresh() throws -> LaunchCredentials {
        try LaunchCredentials(
            gatewayToken: random(),
            approvalToken: random(),
            instanceID: random()
        )
    }

    private static func random() throws -> String {
        var data = Data(count: 48)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, 48, base)
        }
        guard status == errSecSuccess else { throw LauncherFailure.keychain(status) }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum PackagedScoutLauncher {
    static func approvalKeyUsage() throws -> ApprovalKeyUsage {
        let directory = try applicationSupportRoot().appendingPathComponent("context-packs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        var counts: [String: Int] = [:]
        var unsignedApproved = 0
        for file in files where file.pathExtension.lowercased() == "json" {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            guard data.count <= 2 * 1_024 * 1_024,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = object["body"] as? [String: Any],
                  body["approved_at"] is String
            else { continue }
            if let approval = object["approval"] as? [String: Any],
               let keyID = approval["key_id"] as? String,
               ApprovalKeyring.validKeyID(keyID) {
                counts[keyID, default: 0] += 1
            } else {
                unsignedApproved += 1
            }
        }
        return ApprovalKeyUsage(
            contextPackDirectory: directory.path,
            packCountByKeyID: counts,
            unsignedApprovedPackCount: unsignedApproved
        )
    }

    static func run(smokeOnly: Bool, liveSmoke: Bool = false) async throws -> Int32 {
        guard let resources = Bundle.main.resourceURL else {
            throw LauncherFailure.missingRuntime("Contents/Resources")
        }
        let runtime = resources.appendingPathComponent("runtime", isDirectory: true)
        let node = runtime.appendingPathComponent("node")
        let gatewayScript = runtime.appendingPathComponent("scout-gateway.cjs")
        let nestedApp = resources.appendingPathComponent("ScoutUI.app", isDirectory: true)
        let uiExecutable = nestedApp.appendingPathComponent("Contents/MacOS/Scout")
        guard FileManager.default.isExecutableFile(atPath: node.path) else {
            throw LauncherFailure.missingRuntime(node.path)
        }
        guard FileManager.default.fileExists(atPath: gatewayScript.path) else {
            throw LauncherFailure.missingRuntime(gatewayScript.path)
        }
        if !smokeOnly && !FileManager.default.isExecutableFile(atPath: uiExecutable.path) {
            throw LauncherFailure.missingRuntime(uiExecutable.path)
        }

        let secrets = try ScoutSecrets.export(includeOpenAI: true)
        guard let openAIAPIKey = secrets.openAIAPIKey,
              let activePublicKey = secrets.verificationKeys[secrets.approvalKeyID],
              let encodedVerificationKeys = String(
                  data: try JSONEncoder().encode(secrets.verificationKeys.filter {
                      !secrets.revokedKeyIDs.contains($0.key)
                  }),
                  encoding: .utf8
              )
        else { throw LauncherFailure.invalidKeyring }
        guard ApprovalKeyring.publicKey(for: secrets.approvalPrivateKey) == activePublicKey else {
            throw LauncherFailure.invalidKeyring
        }
        let credentials = try LaunchCredentials.fresh()
        let dataRoot = try applicationSupportRoot()
        let contextPacks = dataRoot.appendingPathComponent("context-packs", isDirectory: true)
        try FileManager.default.createDirectory(at: contextPacks, withIntermediateDirectories: true)

        let gatewayEnvironment = LauncherSecurityPolicy.packagedGatewayEnvironment(
            parent: ProcessInfo.processInfo.environment,
            trustedValues: [
                "OPENAI_API_KEY": openAIAPIKey,
                "SCOUT_GATEWAY_HOST": "127.0.0.1",
                "SCOUT_GATEWAY_PORT": "0",
                "SCOUT_GATEWAY_TOKEN": credentials.gatewayToken,
                "SCOUT_APPROVAL_TOKEN": credentials.approvalToken,
                "SCOUT_GATEWAY_INSTANCE_ID": credentials.instanceID,
                "SCOUT_APPROVAL_ED25519_PRIVATE_KEY": secrets.approvalPrivateKey,
                "SCOUT_APPROVAL_KEY_ID": secrets.approvalKeyID,
                "SCOUT_APPROVAL_PUBLIC_KEYS": encodedVerificationKeys,
                "SCOUT_GATEWAY_ROOT": runtime.path,
                "SCOUT_DATA_ROOT": dataRoot.path,
                "SCOUT_CONTEXT_PACK_DIR": contextPacks.path,
            ]
        )

        let stderrPipe = Pipe()
        let gateway = Process()
        gateway.executableURL = node
        gateway.arguments = [gatewayScript.path]
        gateway.currentDirectoryURL = runtime
        gateway.environment = gatewayEnvironment
        gateway.standardInput = FileHandle.nullDevice
        gateway.standardOutput = FileHandle.nullDevice
        gateway.standardError = stderrPipe
        try gateway.run()

        do {
            let ready = try await readiness(from: stderrPipe.fileHandleForReading)
            guard ready.event == "gateway_started",
                  ready.service == "scout-gateway",
                  ready.host == "127.0.0.1",
                  (1...65_535).contains(ready.port)
            else { throw LauncherFailure.invalidGatewayReadiness }

            if smokeOnly {
                try await smokeGateway(ready, credentials: credentials)
                if liveSmoke {
                    try await smokeSyntheticMeeting(ready, credentials: credentials)
                }
                gateway.terminate()
                gateway.waitUntilExit()
                return gateway.terminationStatus == 0 || gateway.terminationReason == .uncaughtSignal ? 0 : gateway.terminationStatus
            }

            let appEnvironment = LauncherSecurityPolicy.packagedAppEnvironment(
                parent: ProcessInfo.processInfo.environment,
                trustedValues: [
                    "SCOUT_BRIDGE_URL": "http://127.0.0.1:\(ready.port)",
                    "SCOUT_GATEWAY_TOKEN": credentials.gatewayToken,
                    "SCOUT_APPROVAL_TOKEN": credentials.approvalToken,
                    "SCOUT_GATEWAY_INSTANCE_ID": credentials.instanceID,
                    "SCOUT_GATEWAY_SUPERVISED": "1",
                ]
            )

            let app = Process()
            app.executableURL = uiExecutable
            app.environment = appEnvironment
            app.standardInput = FileHandle.nullDevice
            try app.run()
            switch LauncherProcessSupervisor.firstExit(gateway: gateway, app: app) {
            case .app:
                if gateway.isRunning { gateway.terminate() }
                gateway.waitUntilExit()
                app.waitUntilExit()
                return app.terminationStatus
            case .gateway:
                if app.isRunning { app.terminate() }
                app.waitUntilExit()
                gateway.waitUntilExit()
                return gateway.terminationStatus == 0 ? 1 : gateway.terminationStatus
            }
        } catch {
            if gateway.isRunning { gateway.terminate() }
            gateway.waitUntilExit()
            throw error
        }
    }

    private static func readiness(from handle: FileHandle) async throws -> GatewayReady {
        try await withThrowingTaskGroup(of: GatewayReady.self) { group in
            group.addTask {
                for try await line in handle.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let ready = try? JSONDecoder().decode(GatewayReady.self, from: data)
                    else {
                        FileHandle.standardError.write(Data((line + "\n").utf8))
                        continue
                    }
                    return ready
                }
                throw LauncherFailure.gatewayFailed("process exited before readiness")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw LauncherFailure.gatewayTimeout
            }
            guard let ready = try await group.next() else { throw LauncherFailure.gatewayTimeout }
            group.cancelAll()
            return ready
        }
    }

    private static func smokeGateway(_ ready: GatewayReady, credentials: LaunchCredentials) async throws {
        let base = URL(string: "http://127.0.0.1:\(ready.port)")!
        var health = URLRequest(url: base.appendingPathComponent("health"))
        health.timeoutInterval = 5
        let (_, healthResponse) = try await URLSession.shared.data(for: health)
        guard let healthHTTP = healthResponse as? HTTPURLResponse,
              healthHTTP.statusCode == 200,
              healthHTTP.value(forHTTPHeaderField: "X-Scout-Gateway-Instance-ID") == credentials.instanceID
        else { throw LauncherFailure.smokeFailed("Gateway peer attestation failed") }

        var packs = URLRequest(url: base.appendingPathComponent("v1/context-packs"))
        packs.setValue("Bearer \(credentials.gatewayToken)", forHTTPHeaderField: "Authorization")
        packs.timeoutInterval = 5
        let (_, packResponse) = try await URLSession.shared.data(for: packs)
        guard let packHTTP = packResponse as? HTTPURLResponse, packHTTP.statusCode == 200 else {
            throw LauncherFailure.smokeFailed("authenticated context-pack read failed")
        }
    }

    private static func smokeSyntheticMeeting(
        _ ready: GatewayReady,
        credentials: LaunchCredentials
    ) async throws {
        let endpoint = URL(string: "http://127.0.0.1:\(ready.port)/v1/claims/extract")!
        let body: [String: Any] = [
            "session_id": "packaged-live-smoke",
            "event_boundary": 2,
            "utterances": [
                [
                    "utterance_id": "utterance-emma-1",
                    "evidence_id": "evidence-emma-1",
                    "speaker_id": "speaker-emma",
                    "text": "We use Salesforce for customer support, but inventory status is copied manually from NetSuite every morning.",
                    "start_ms": 0,
                    "end_ms": 4_000,
                    "source": "manual",
                ],
                [
                    "utterance_id": "utterance-raj-1",
                    "evidence_id": "evidence-raj-1",
                    "speaker_id": "speaker-raj",
                    "text": "The manual inventory handoff delays responses and our goal is to answer customers within five minutes.",
                    "start_ms": 4_500,
                    "end_ms": 9_000,
                    "source": "manual",
                ],
            ],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.gatewayToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 70
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proposal = result["proposal"] as? [String: Any],
              let claims = proposal["claims"] as? [[String: Any]],
              !claims.isEmpty,
              let modelCall = result["model_call"] as? [String: Any],
              let hash = modelCall["output_sha256"] as? String,
              hash.count == 64
        else { throw LauncherFailure.smokeFailed("packaged synthetic discovery extraction failed") }
        let allowedEvidence = Set(["utterance-emma-1", "utterance-raj-1"])
        for claim in claims {
            guard let evidence = claim["evidence_utterance_ids"] as? [String],
                  !evidence.isEmpty,
                  evidence.allSatisfy({ allowedEvidence.contains($0) })
            else { throw LauncherFailure.smokeFailed("provider proposal escaped the synthetic evidence boundary") }
        }
    }

    private static func applicationSupportRoot() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Scout", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

@main
private struct ScoutLauncherMain {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
#if SCOUT_SECRET_TOOL
            let secretToolBuild = true
#else
            let secretToolBuild = false
#endif
#if SCOUT_ADHOC_PROVISIONING
            let adHocProvisioningBuild = true
#else
            let adHocProvisioningBuild = false
#endif
            switch LauncherSecurityPolicy.commandAccess(
                arguments: arguments,
                secretToolBuild: secretToolBuild,
                adHocProvisioningBuild: adHocProvisioningBuild
            ) {
            case .ordinary:
                break
            case .authenticationRequired:
                try await LauncherLocalAuthorization.require(for: arguments)
            case .unavailable:
                throw LauncherFailure.invalidCommand
            }

            let status: Int32
            switch arguments {
#if SCOUT_SECRET_TOOL || SCOUT_ADHOC_PROVISIONING
            case ["secrets", "import"]:
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard let input = try? JSONDecoder().decode(SecretImport.self, from: data) else {
                    throw LauncherFailure.invalidInput
                }
                try ScoutSecrets.importSecrets(input)
                try writeJSON(ScoutSecrets.status())
                status = 0
#endif
#if SCOUT_SECRET_TOOL
            case ["secrets", "export"]:
                try writeJSON(ScoutSecrets.export(includeOpenAI: true))
                status = 0
#endif
            case ["secrets", "status"]:
                try writeJSON(ScoutSecrets.status())
                status = 0
            case ["secrets", "rotate-approval"]:
                try writeJSON(ScoutSecrets.rotateApproval())
                status = 0
            case ["secrets", "configure-openai"]:
                try writeJSON(ScoutSecrets.configureOpenAIInteractively())
                status = 0
            case ["secrets", "approval-key-usage"]:
                try writeJSON(PackagedScoutLauncher.approvalKeyUsage())
                status = 0
            case ["--smoke-test"]:
                status = try await PackagedScoutLauncher.run(smokeOnly: true)
            case ["--live-smoke"]:
                status = try await PackagedScoutLauncher.run(smokeOnly: true, liveSmoke: true)
            case []:
                status = try await PackagedScoutLauncher.run(smokeOnly: false)
            default:
                if arguments.count == 4,
                   arguments[0] == "secrets",
                   arguments[1] == "revoke-approval",
                   arguments[3] == "--confirm-invalidates-packs" {
                    try writeJSON(ScoutSecrets.revokeApproval(keyID: arguments[2]))
                    status = 0
                } else if arguments.count == 1, arguments[0].hasPrefix("-psn_") {
                    status = try await PackagedScoutLauncher.run(smokeOnly: false)
                } else {
                    throw LauncherFailure.invalidCommand
                }
            }
            exit(status)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Scout launcher failed."
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
