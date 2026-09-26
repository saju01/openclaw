import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

struct EmbeddedTailnetRoutePolicyTests {
    private let loopback = GatewayProxyEndpoint(host: "127.0.0.1", port: 50123, username: "tsnet", password: "cred")

    @Test func `only a running node with a live loopback proxies`() {
        #expect(EmbeddedTailnetRoutePolicy.route(phase: .running, loopback: self.loopback, required: true)
            == .proxy(self.loopback))
        #expect(EmbeddedTailnetRoutePolicy.route(phase: .running, loopback: nil, required: true) == .unavailable)
    }

    @Test func `required route fails closed until running`() {
        for phase: EmbeddedTailnetPhase in [.starting, .needsLogin(nil), .needsApproval, .failed("x"), .notConfigured] {
            #expect(EmbeddedTailnetRoutePolicy.route(phase: phase, loopback: self.loopback, required: true)
                == .unavailable)
        }
    }

    @Test func `optional route falls back to direct`() {
        #expect(EmbeddedTailnetRoutePolicy.route(phase: .starting, loopback: nil, required: false) == .direct)
    }
}

struct EmbeddedTailnetStatusTests {
    @Test func `status parses running identity`() throws {
        let json = #"""
        {"BackendState":"Running","AuthURL":"","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::1"],
         "Self":{"UserID":42,"DNSName":"openclaw-iphone.example.ts.net.","Tags":[]},
         "User":{"42":{"LoginName":"user@example.com"}},"CurrentTailnet":{"Name":"example.com"}}
        """#
        let status = try EmbeddedTailnetStatus.parse(Data(json.utf8))
        #expect(status.backendState == "Running")
        #expect(status.authURL == nil)
        #expect(status.ipv4 == "100.101.102.103")
        #expect(status.ipv6 == "fd7a:115c:a1e0::1")
        #expect(status.loginName == "user@example.com")
        #expect(status.dnsName == "openclaw-iphone.example.ts.net")
        #expect(status.tailnetName == "example.com")
    }

    @Test func `status parses needs login with auth URL`() throws {
        let json = #"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/abc123"}"#
        let status = try EmbeddedTailnetStatus.parse(Data(json.utf8))
        #expect(status.backendState == "NeedsLogin")
        #expect(status.authURL?.absoluteString == "https://login.tailscale.com/a/abc123")
        #expect(status.ipv4 == nil)
        #expect(status.loginName == nil)
    }

    @Test func `login URL accepts only https`() {
        #expect(EmbeddedTailnetController.loginURL(" https://login.tailscale.com/a/x ")?.host
            == "login.tailscale.com")
        #expect(EmbeddedTailnetController.loginURL("http://login.tailscale.com/a/x") == nil)
        #expect(EmbeddedTailnetController.loginURL("javascript:alert(1)") == nil)
        #expect(EmbeddedTailnetController.loginURL("") == nil)
    }
}

@MainActor
struct EmbeddedTailnetControllerRoutingTests {
    @Test func `stored required config publishes an unavailable route before the node starts`() async throws {
        let suite = "ai.openclaw.tests.embeddedTailnet.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = try #require(GatewayEmbeddedTailnetSetup())
        let stored = EmbeddedTailnetStoredConfig(setup: setup, gatewayHosts: ["gateway.example.ts.net"])
        defaults.set(try JSONEncoder().encode(stored), forKey: EmbeddedTailnetController.defaultsKey)

        let router = GatewayNetworkRouter()
        let controller = EmbeddedTailnetController(
            router: router,
            defaults: defaults,
            stateRoot: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
            startNode: false)
        #expect(controller.isConfigured)
        #expect(router.route(forHost: "gateway.example.ts.net") == .unavailable)
        #expect(router.route(forHost: "example.com") == .direct)

        await controller.remove()
        #expect(router.route(forHost: "gateway.example.ts.net") == .direct)
        #expect(defaults.data(forKey: EmbeddedTailnetController.defaultsKey) == nil)
    }
}
