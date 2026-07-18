import Foundation

@main
private enum LauncherSecurityPolicyTests {
    static func main() throws {
        try testChildEnvironmentIsClosed()
        try testCommandAuthorizationMatrix()
        try testGatewayExitWinsTheRace()
        try testAppExitWinsTheRace()
        print("Launcher security policy tests passed")
    }

    private static func testChildEnvironmentIsClosed() throws {
        let parent = [
            "LANG": "en_GB.UTF-8",
            "NODE_OPTIONS": "--require=/tmp/attacker.js",
            "NODE_PATH": "/tmp/attacker-modules",
            "DYLD_INSERT_LIBRARIES": "/tmp/attacker.dylib",
            "OPENAI_BASE_URL": "http://127.0.0.1:9999/v1",
            "OPENAI_API_KEY": "ambient-secret",
            "HTTPS_PROXY": "http://127.0.0.1:8888",
            "SCOUT_GATEWAY_TOKEN": "ambient-token",
            "SSLKEYLOGFILE": "/tmp/keys.log",
        ]
        let trusted = [
            "OPENAI_API_KEY": "trusted-secret",
            "SCOUT_GATEWAY_TOKEN": "trusted-token",
        ]
        let gateway = LauncherSecurityPolicy.packagedGatewayEnvironment(
            parent: parent,
            trustedValues: trusted
        )

        try require(gateway["LANG"] == "en_GB.UTF-8", "locale did not cross the child boundary")
        try require(gateway["OPENAI_API_KEY"] == "trusted-secret", "trusted provider key was lost")
        try require(gateway["SCOUT_GATEWAY_TOKEN"] == "trusted-token", "trusted bearer was lost")
        try require(
            gateway["OPENAI_BASE_URL"] == LauncherSecurityPolicy.productionOpenAIBaseURL,
            "production provider URL was not pinned"
        )
        for forbidden in [
            "NODE_OPTIONS", "NODE_PATH", "DYLD_INSERT_LIBRARIES", "HTTPS_PROXY", "SSLKEYLOGFILE",
        ] {
            try require(gateway[forbidden] == nil, "unsafe inherited variable survived: \(forbidden)")
        }

        let app = LauncherSecurityPolicy.packagedAppEnvironment(
            parent: parent,
            trustedValues: ["SCOUT_BRIDGE_URL": "http://127.0.0.1:49123"]
        )
        try require(app["SCOUT_BRIDGE_URL"] != nil, "trusted bridge URL was lost")
        try require(app["OPENAI_API_KEY"] == nil, "provider key crossed into the UI")
        try require(app["NODE_OPTIONS"] == nil, "runtime injection crossed into the UI")
    }

    private static func testCommandAuthorizationMatrix() throws {
        let export = ["secrets", "export"]
        try require(
            LauncherSecurityPolicy.commandAccess(
                arguments: export,
                secretToolBuild: false,
                adHocProvisioningBuild: false
            ) == .unavailable,
            "distributable launcher exposes plaintext secret export"
        )
        try require(
            LauncherSecurityPolicy.commandAccess(
                arguments: export,
                secretToolBuild: true,
                adHocProvisioningBuild: false
            ) == .authenticationRequired,
            "developer secret export is not authenticated"
        )
        try require(
            LauncherSecurityPolicy.commandAccess(
                arguments: ["secrets", "approval-export"],
                secretToolBuild: false,
                adHocProvisioningBuild: false
            ) == .unavailable,
            "distributable launcher exposes approval-key export"
        )
        try require(
            LauncherSecurityPolicy.commandAccess(
                arguments: ["secrets", "import"],
                secretToolBuild: false,
                adHocProvisioningBuild: false
            ) == .unavailable,
            "distributable launcher exposes secret import"
        )
        try require(
            LauncherSecurityPolicy.commandAccess(
                arguments: ["secrets", "import"],
                secretToolBuild: false,
                adHocProvisioningBuild: true
            ) == .authenticationRequired,
            "ad-hoc provisioning import is not authenticated"
        )
        for command in [
            ["secrets", "rotate-approval"],
            ["secrets", "configure-openai"],
            ["secrets", "revoke-approval", "old-key", "--confirm-invalidates-packs"],
        ] {
            try require(
                LauncherSecurityPolicy.commandAccess(
                    arguments: command,
                    secretToolBuild: false,
                    adHocProvisioningBuild: false
                ) == .authenticationRequired,
                "mutation command is not authenticated: \(command)"
            )
        }
        try require(
            LauncherSecurityPolicy.commandAccess(
                arguments: ["secrets", "status"],
                secretToolBuild: false,
                adHocProvisioningBuild: false
            ) == .ordinary,
            "non-secret status unexpectedly requires authentication"
        )
    }

    private static func testGatewayExitWinsTheRace() throws {
        let gateway = sleepProcess(seconds: "0.02")
        let app = sleepProcess(seconds: "2")
        try gateway.run()
        try app.run()
        let winner = LauncherProcessSupervisor.firstExit(gateway: gateway, app: app)
        try require(winner == .gateway, "Gateway termination was not supervised")
        if app.isRunning { app.terminate() }
        app.waitUntilExit()
        gateway.waitUntilExit()
    }

    private static func testAppExitWinsTheRace() throws {
        let gateway = sleepProcess(seconds: "2")
        let app = sleepProcess(seconds: "0.02")
        try gateway.run()
        try app.run()
        let winner = LauncherProcessSupervisor.firstExit(gateway: gateway, app: app)
        try require(winner == .app, "UI termination was not supervised")
        if gateway.isRunning { gateway.terminate() }
        gateway.waitUntilExit()
        app.waitUntilExit()
    }

    private static func sleepProcess(seconds: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw TestFailure(message: message)
        }
    }

    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
