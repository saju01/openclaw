import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

private func fixtureSetupCode(_ object: [String: Any]) throws -> String {
    try JSONSerialization.data(withJSONObject: object).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// "Connect through Tailscale" toggle state for a pasted setup code. Fixture data only.
struct EmbeddedTailnetSetupChoiceTests {
    @Test func `legacy ts.net code pre-sets the toggle on with default setup`() throws {
        let code = try fixtureSetupCode(["url": "wss://gateway.example.ts.net", "bootstrapToken": "synthetic"])
        let choice = try #require(EmbeddedTailnetSetupChoice.updated(nil, forInput: code))
        #expect(choice.connectThroughTailscale)
        #expect(choice.isTailnetOnlyHost)
        #expect(choice.effectiveLink.embeddedTailnet == .defaults)
        #expect(choice.directRouteWarning == nil)
    }

    @Test func `ordinary legacy code leaves the toggle off and unchanged`() throws {
        let code = try fixtureSetupCode(["url": "wss://gateway.example.com", "bootstrapToken": "synthetic"])
        let choice = try #require(EmbeddedTailnetSetupChoice.updated(nil, forInput: code))
        #expect(!choice.connectThroughTailscale)
        #expect(choice.effectiveLink == choice.link)
        #expect(choice.effectiveLink.embeddedTailnet == nil)
        #expect(choice.directRouteWarning == nil)
    }

    @Test func `explicit required false keeps its setup when toggled on`() throws {
        let code = try fixtureSetupCode([
            "url": "wss://gateway.example.ts.net", "tailnet": ["required": false, "hostname": "family-phone"],
        ])
        let choice = try #require(EmbeddedTailnetSetupChoice.updated(nil, forInput: code))
        #expect(choice.connectThroughTailscale)
        #expect(choice.effectiveLink.embeddedTailnet?.required == false)
        #expect(choice.effectiveLink.embeddedTailnet?.hostname == "family-phone")
    }

    @Test func `user can turn Tailscale off and on and the override sticks for the same code`() throws {
        let code = try fixtureSetupCode(["url": "wss://100.101.102.103", "bootstrapToken": "synthetic"])
        var choice = try #require(EmbeddedTailnetSetupChoice.updated(nil, forInput: code))
        choice.connectThroughTailscale = false
        #expect(choice.effectiveLink.embeddedTailnet == nil)
        #expect(choice.directRouteWarning != nil)
        // Re-parsing the same code (for example whitespace edits) keeps the override.
        let same = try #require(EmbeddedTailnetSetupChoice.updated(choice, forInput: "  \(code)\n"))
        #expect(!same.connectThroughTailscale)
        #expect(EmbeddedTailnetSetupChoice.resolve(choice.link, choice: same).embeddedTailnet == nil)

        // Turning an ordinary gateway on adds the default in-app setup.
        let other = try fixtureSetupCode(["url": "wss://gateway.example.com"])
        var ordinary = try #require(EmbeddedTailnetSetupChoice.updated(same, forInput: other))
        #expect(!ordinary.connectThroughTailscale)
        ordinary.connectThroughTailscale = true
        #expect(ordinary.effectiveLink.embeddedTailnet == .defaults)
    }

    @Test func `a different code resets the override and resolve ignores stale choices`() throws {
        let tailnetCode = try fixtureSetupCode(["url": "wss://gateway.example.ts.net"])
        var choice = try #require(EmbeddedTailnetSetupChoice.updated(nil, forInput: tailnetCode))
        choice.connectThroughTailscale = false
        let otherCode = try fixtureSetupCode(["url": "wss://other.example.ts.net"])
        let next = try #require(EmbeddedTailnetSetupChoice.updated(choice, forInput: otherCode))
        #expect(next.connectThroughTailscale)
        #expect(EmbeddedTailnetSetupChoice.resolve(next.link, choice: choice) == next.link)
    }

    @Test func `empty, unparseable, and demo inputs clear the choice`() {
        #expect(EmbeddedTailnetSetupChoice.updated(nil, forInput: "") == nil)
        #expect(EmbeddedTailnetSetupChoice.updated(nil, forInput: "not a setup code") == nil)
    }

    @Test func `scanned link is a staged choice and resolve honors its toggle`() throws {
        let code = try fixtureSetupCode([
            "url": "wss://gateway.example.com",
            "tailnet": ["hostname": "scanned-phone", "required": true],
        ])
        let link = try #require(GatewayConnectDeepLink.fromSetupInput(code))
        var choice = EmbeddedTailnetSetupChoice(link: link)
        #expect(choice.connectThroughTailscale)
        #expect(EmbeddedTailnetSetupChoice.resolve(link, choice: choice).embeddedTailnet?.hostname == "scanned-phone")
        choice.connectThroughTailscale = false
        #expect(EmbeddedTailnetSetupChoice.resolve(link, choice: choice).embeddedTailnet == nil)
    }

    @Test func `required setup warns when disabled even for an ordinary host`() throws {
        let requiredCode = try fixtureSetupCode([
            "url": "wss://gateway.example.com", "tailnet": ["required": true],
        ])
        var required = try #require(EmbeddedTailnetSetupChoice.updated(nil, forInput: requiredCode))
        required.connectThroughTailscale = false
        #expect(required.directRouteWarning?.contains("requires Tailscale") == true)
        let optionalCode = try fixtureSetupCode([
            "url": "wss://gateway.example.com", "tailnet": ["required": false],
        ])
        var optional = try #require(EmbeddedTailnetSetupChoice.updated(nil, forInput: optionalCode))
        optional.connectThroughTailscale = false
        #expect(optional.directRouteWarning == nil)
    }

    @Test func `standalone settings control hides for either staged toggle value`() throws {
        let code = try fixtureSetupCode(["url": "wss://gateway.example.ts.net"])
        var choice = try #require(EmbeddedTailnetSetupChoice.updated(nil, forInput: code))
        #expect(!EmbeddedTailnetSettingsPresentation.showsStandaloneSection(stagedChoice: choice))
        choice.connectThroughTailscale = false
        #expect(!EmbeddedTailnetSettingsPresentation.showsStandaloneSection(stagedChoice: choice))
        #expect(EmbeddedTailnetSettingsPresentation.showsStandaloneSection(stagedChoice: nil))
    }
}

/// Tailscale step presentation for each in-app node state.
struct EmbeddedTailnetStepStateTests {
    private let running = EmbeddedTailnetStatus(
        backendState: "Running", authURL: nil, ipv4: "100.101.102.103", ipv6: nil,
        loginName: "fixture@example.com", dnsName: nil, tailnetName: nil, tags: [])

    @Test func `sign-in is prominent until the node is connected`() {
        let signIn = EmbeddedTailnetStepState(phase: .needsLogin(nil), hasBeenRunning: false, status: nil)
        #expect(signIn == .needsSignIn)
        #expect(signIn.showsSignIn)
        #expect(EmbeddedTailnetStepState(phase: .notConfigured, hasBeenRunning: false, status: nil).showsSignIn)
        #expect(EmbeddedTailnetStepState(phase: .failed("offline"), hasBeenRunning: false, status: nil).showsSignIn)
    }

    @Test func `starting and reconnecting are distinct busy states`() {
        let starting = EmbeddedTailnetStepState(phase: .starting, hasBeenRunning: false, status: nil)
        let reconnecting = EmbeddedTailnetStepState(phase: .starting, hasBeenRunning: true, status: nil)
        #expect(starting == .starting && starting.isBusy && !starting.showsSignIn)
        #expect(reconnecting == .reconnecting && reconnecting.isBusy)
        #expect(reconnecting.title.contains("Reconnecting"))
    }

    @Test func `connected shows the tailnet IP`() {
        let state = EmbeddedTailnetStepState(phase: .running, hasBeenRunning: true, status: self.running)
        #expect(state == .connected(address: "100.101.102.103"))
        #expect(state.isConnected && !state.showsSignIn)
        #expect(state.detail.contains("100.101.102.103"))
    }

    @Test func `running node on a different effective setup is not connected`() throws {
        let selected = try #require(GatewayEmbeddedTailnetSetup(
            controlURL: "https://control.one.example", hostname: "selected-phone"))
        let configured = try #require(GatewayEmbeddedTailnetSetup(
            controlURL: "https://control.two.example", hostname: "existing-phone"))
        let mismatch = EmbeddedTailnetStepState(
            phase: .running, hasBeenRunning: true, status: self.running,
            selectedSetup: selected, configuredSetup: configured)
        #expect(mismatch == .differentNetwork)
        #expect(!mismatch.isConnected)
        #expect(mismatch.title == "Different Tailscale network")
        #expect(mismatch.detail.contains("Reset the existing Tailnet node"))
        let optional = try #require(GatewayEmbeddedTailnetSetup(
            controlURL: selected.controlURL.absoluteString, hostname: selected.hostname, required: false))
        let match = EmbeddedTailnetStepState(
            phase: .running, hasBeenRunning: true, status: self.running,
            selectedSetup: optional, configuredSetup: selected)
        #expect(match.isConnected)
    }

    @Test func `failure text names the fix`() {
        let state = EmbeddedTailnetStepState(phase: .failed("Control unreachable."), hasBeenRunning: false, status: nil)
        #expect(state.detail.contains("Control unreachable."))
        #expect(state.detail.contains("Sign in to Tailscale"))
        for readiness: EmbeddedTailnetReadiness in [.needsLogin, .needsApproval, .failed("x"), .timedOut] {
            #expect(readiness.setupStatusText.lowercased().contains("tap"), "\(readiness)")
        }
    }
}

/// Plain, fix-oriented gateway errors for each route.
struct GatewayTailnetGuidanceTests {
    private let proxy = GatewayProxyEndpoint(host: "127.0.0.1", port: 50123, username: "tsnet", password: "cred")

    private func timeout() throws -> GatewayConnectionProblem {
        try #require(GatewayConnectionProblemMapper.map(error: URLError(.timedOut)))
    }

    @Test func `tailnet host with Tailscale off says to turn it on`() throws {
        let guided = try GatewayConnectionIssue.addingEndpointGuidance(
            to: self.timeout(), host: "gateway.example.ts.net", route: .direct)
        #expect(guided.message.contains("only works inside a tailnet"))
        #expect(guided.message.contains("Turn on Tailscale"))
        #expect(guided.docsURL == GatewayConnectionIssue.tailscaleSetupURL)
        #expect(GatewayConnectionIssue.detect(problem: guided) == .network)
    }

    @Test func `held route explains the in-app node is not running`() throws {
        let guided = try GatewayConnectionIssue.addingEndpointGuidance(
            to: self.timeout(), host: "100.101.102.103", route: .unavailable)
        #expect(guided.message.contains("In-app Tailscale is not connected"))
        #expect(guided.message.contains("sign in"))
        #expect(guided.message.contains("Reconnect"))
        #expect(guided.retryable)
    }

    @Test func `connected tailnet with silent gateway points at the gateway`() throws {
        let guided = try GatewayConnectionIssue.addingEndpointGuidance(
            to: self.timeout(), host: "gateway.example.ts.net", route: .proxy(self.proxy))
        #expect(guided.message.contains("Tailscale is connected, but the Gateway did not answer"))
    }

    @Test func `ordinary direct host timeout stays unchanged`() throws {
        let timeout = try self.timeout()
        #expect(GatewayConnectionIssue.addingEndpointGuidance(
            to: timeout, host: "gateway.example.com", route: .direct) == timeout)
    }

    @Test func `guidance is idempotent`() throws {
        let once = try GatewayConnectionIssue.addingEndpointGuidance(
            to: self.timeout(), host: "gateway.example.ts.net", route: .unavailable)
        #expect(GatewayConnectionIssue.addingEndpointGuidance(
            to: once, host: "gateway.example.ts.net", route: .unavailable) == once)
    }
}

@MainActor
struct EmbeddedTailnetControllerOnboardingTests {
    private func makeController(_ suite: String, stored: EmbeddedTailnetStoredConfig? = nil) throws
        -> (EmbeddedTailnetController, GatewayNetworkRouter, UserDefaults)
    {
        let defaults = try #require(UserDefaults(suiteName: suite))
        if let stored {
            try defaults.set(JSONEncoder().encode(stored), forKey: EmbeddedTailnetController.defaultsKey)
        }
        let router = GatewayNetworkRouter()
        let controller = EmbeddedTailnetController(
            router: router,
            defaults: defaults,
            stateRoot: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
            startNode: false)
        return (controller, router, defaults)
    }

    @Test func `existing stored config is preserved on launch without migration`() throws {
        let suite = "ai.openclaw.tests.embeddedTailnet.\(UUID().uuidString)"
        let setup = try #require(GatewayEmbeddedTailnetSetup(
            controlURL: "https://headscale.example.com", hostname: "family-phone", required: false))
        let stored = EmbeddedTailnetStoredConfig(setup: setup, gatewayHosts: ["gw.corp.example"])
        let (controller, router, defaults) = try self.makeController(suite, stored: stored)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(controller.config == stored)
        #expect(router.route(forHost: "gw.corp.example") == .direct)
        let persisted = try #require(defaults.data(forKey: EmbeddedTailnetController.defaultsKey))
        #expect(try JSONDecoder().decode(EmbeddedTailnetStoredConfig.self, from: persisted) == stored)
        #expect(!controller.hasBeenRunning)
    }

    @Test func `unconfigured controller carries nothing and enable requires a host`() async throws {
        let suite = "ai.openclaw.tests.embeddedTailnet.\(UUID().uuidString)"
        let (controller, router, defaults) = try self.makeController(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!controller.isConfigured)
        #expect(!controller.carries(host: "gateway.example.ts.net"))
        let failure = await controller.enable(forGatewayHost: "   ")
        #expect(failure != nil)
        #expect(!controller.isConfigured)
        #expect(router.route(forHost: "gateway.example.ts.net") == .direct)
    }

    @Test func `carries matches stored hosts case-insensitively`() throws {
        let suite = "ai.openclaw.tests.embeddedTailnet.\(UUID().uuidString)"
        let stored = EmbeddedTailnetStoredConfig(setup: .defaults, gatewayHosts: ["gateway.example.ts.net"])
        let (controller, router, defaults) = try self.makeController(suite, stored: stored)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(controller.carries(host: " Gateway.Example.TS.net "))
        #expect(!controller.carries(host: "gateway.example.com"))
        // Required and not running: fails closed.
        #expect(router.route(forHost: "gateway.example.ts.net") == .unavailable)
    }

    @Test func `turning Tailscale off for the last gateway stops routing but keeps node state`() async throws {
        let suite = "ai.openclaw.tests.embeddedTailnet.\(UUID().uuidString)"
        let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let nodeDirectory = stateRoot
            .appendingPathComponent("controlplane.tailscale.com", isDirectory: true)
            .appendingPathComponent("openclaw-iphone", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let stored = EmbeddedTailnetStoredConfig(setup: .defaults, gatewayHosts: ["gateway.example.ts.net"])
        let (controller, router, defaults) = try self.makeController(suite, stored: stored)
        defer { defaults.removePersistentDomain(forName: suite) }

        let offLink = GatewayConnectDeepLink(
            host: "gateway.example.ts.net", port: 443, tls: true,
            bootstrapToken: nil, token: nil, password: nil)
        #expect(await controller.prepareForSetupLink(offLink) == nil)
        #expect(!controller.isConfigured)
        #expect(router.route(forHost: "gateway.example.ts.net") == .direct)
        #expect(FileManager.default.fileExists(atPath: nodeDirectory.path))
    }

    @Test func `scene foreground without a running node keeps actionable state`() throws {
        let suite = "ai.openclaw.tests.embeddedTailnet.\(UUID().uuidString)"
        let stored = EmbeddedTailnetStoredConfig(setup: .defaults, gatewayHosts: ["gateway.example.ts.net"])
        let (controller, router, defaults) = try self.makeController(suite, stored: stored)
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.setScenePhase(foreground: false)
        controller.setScenePhase(foreground: true)
        #expect(controller.phase != .running)
        #expect(router.route(forHost: "gateway.example.ts.net") == .unavailable)
    }
}
