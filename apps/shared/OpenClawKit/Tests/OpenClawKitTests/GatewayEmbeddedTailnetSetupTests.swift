import Foundation
import Network
import Testing
@testable import OpenClawKit

private func setupCode(fromJSON data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

struct GatewayEmbeddedTailnetSetupTests {
    @Test func `setup code fixtures parse legacy, extended, and reject invalid tailnet values`() throws {
        let url = try #require(Bundle.module.url(
            forResource: "embedded-tailnet", withExtension: "json", subdirectory: "Fixtures/SetupCodes"))
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(cases.count >= 16)
        for fixture in cases {
            let name = fixture["name"] as? String ?? "?"
            let payload = try JSONSerialization.data(withJSONObject: #require(fixture["payload"]))
            let link = GatewayConnectDeepLink.fromSetupCode(setupCode(fromJSON: payload))
            guard let expect = fixture["expect"] as? [String: Any] else {
                #expect(link == nil, "\(name) must be rejected")
                continue
            }
            let parsed = try #require(link, "\(name) must parse")
            #expect(parsed.host == expect["host"] as? String, "\(name)")
            if let tailnet = expect["tailnet"] as? [String: Any] {
                let setup = try #require(parsed.embeddedTailnet, "\(name)")
                #expect(setup.controlURL.absoluteString == tailnet["controlURL"] as? String, "\(name)")
                #expect(setup.hostname == tailnet["hostname"] as? String, "\(name)")
                #expect(setup.required == tailnet["required"] as? Bool, "\(name)")
            } else {
                #expect(parsed.embeddedTailnet == nil, "\(name)")
            }
        }
    }

    @Test func `embedded tailnet survives link persistence round trip`() throws {
        let setup = try #require(GatewayEmbeddedTailnetSetup(hostname: "openclaw-iphone"))
        let link = GatewayConnectDeepLink(
            host: "gateway.example.ts.net", port: 443, tls: true,
            bootstrapToken: nil, token: nil, password: nil, embeddedTailnet: setup)
        let decoded = try JSONDecoder().decode(GatewayConnectDeepLink.self, from: JSONEncoder().encode(link))
        #expect(decoded.embeddedTailnet == setup)

        // Links persisted before this field existed still decode without a tailnet.
        var legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(link)) as? [String: Any])
        legacy.removeValue(forKey: "embeddedTailnet")
        let old = try JSONDecoder().decode(
            GatewayConnectDeepLink.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.embeddedTailnet == nil)
    }

    @Test func `tailnet host classifier matches only tailnet-only ranges`() {
        for host in [
            "gateway.example.ts.net", "GATEWAY.EXAMPLE.TS.NET.", "100.64.0.0", "100.127.255.255",
            "100.101.102.103", "fd7a:115c:a1e0::1", "[fd7a:115c:a1e0:ab12::1]",
        ] {
            #expect(GatewayEmbeddedTailnetSetup.isTailnetHost(host), "\(host)")
            #expect(GatewayEmbeddedTailnetSetup.inferred(forHost: host) == .defaults, "\(host)")
        }
        for host in [
            "gateway.example.com", "ts.net", "gateway.ts.net.example.com", "100.63.255.255",
            "100.128.0.0", "192.168.1.20", "10.0.0.1", "127.0.0.1", "fd7a:115c:a1e1::1", "fd00::1",
            "openclaw.local",
        ] {
            #expect(!GatewayEmbeddedTailnetSetup.isTailnetHost(host), "\(host)")
            #expect(GatewayEmbeddedTailnetSetup.inferred(forHost: host) == nil, "\(host)")
        }
    }

    @Test func `inferred defaults use Tailscale control, openclaw-iphone, and a required route`() {
        let setup = GatewayEmbeddedTailnetSetup.defaults
        #expect(setup.controlURL.absoluteString == "https://controlplane.tailscale.com")
        #expect(setup.hostname == "openclaw-iphone")
        #expect(setup.required)
        #expect(GatewayEmbeddedTailnetSetup() == setup)
    }

    @Test func `inference uses the primary host, not fallbacks`() throws {
        let lanFirst = try JSONSerialization.data(withJSONObject: [
            "url": "wss://gateway.example.com",
            "urls": ["wss://gateway.example.com", "wss://gateway.example.ts.net"],
        ])
        let direct = try #require(GatewayConnectDeepLink.fromSetupCode(setupCode(fromJSON: lanFirst)))
        #expect(direct.embeddedTailnet == nil)

        let tailnetFirst = try JSONSerialization.data(withJSONObject: [
            "url": "wss://gateway.example.ts.net",
            "urls": ["wss://gateway.example.ts.net", "wss://100.101.102.103"],
        ])
        let routed = try #require(GatewayConnectDeepLink.fromSetupCode(setupCode(fromJSON: tailnetFirst)))
        #expect(routed.embeddedTailnet == .defaults)
        #expect(GatewayEmbeddedTailnetSetup.routedHosts(for: routed.connectionEndpoints)
            == ["gateway.example.ts.net", "100.101.102.103"])
        // Endpoint selection keeps the inferred setup.
        let fallback = try #require(routed.fallbackEndpoints.first)
        #expect(routed.selectingEndpoint(fallback).embeddedTailnet == .defaults)
    }

    @Test func `inference opt-out and non setup-code inputs keep legacy direct links`() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["url": "wss://gateway.example.ts.net"])
        let code = setupCode(fromJSON: payload)
        #expect(GatewayConnectDeepLink.fromSetupCode(code, inferTailnet: false)?.embeddedTailnet == nil)
        #expect(GatewayConnectDeepLink.fromSetupCode(code)?.embeddedTailnet == .defaults)
        // Raw URLs and openclaw:// deep links are not setup codes and never infer.
        #expect(GatewayConnectDeepLink.fromSetupInput("wss://gateway.example.ts.net")?.embeddedTailnet == nil)
        let deepLink = try #require(URL(string: "openclaw://gateway?host=gateway.example.ts.net&port=443&tls=1"))
        guard case let .gateway(link)? = DeepLinkParser.parse(deepLink) else {
            Issue.record("deep link did not parse")
            return
        }
        #expect(link.embeddedTailnet == nil)
    }

    @Test func `persisted legacy links do not gain an inferred tailnet on upgrade`() throws {
        // Links saved by older builds for a ts.net gateway must decode exactly as saved:
        // upgrading never migrates, re-routes, or forces re-pairing of existing installs.
        let saved = #"{"host":"gateway.example.ts.net","port":443,"tls":true,"bootstrapToken":null}"#
        let link = try JSONDecoder().decode(GatewayConnectDeepLink.self, from: Data(saved.utf8))
        #expect(link.embeddedTailnet == nil)
    }

    @Test func `withEmbeddedTailnet overrides only the tailnet choice`() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "url": "wss://gateway.example.ts.net", "bootstrapToken": "synthetic-bootstrap",
        ])
        let link = try #require(GatewayConnectDeepLink.fromSetupCode(setupCode(fromJSON: payload)))
        let off = link.withEmbeddedTailnet(nil)
        #expect(off.embeddedTailnet == nil)
        #expect(off.host == link.host && off.port == link.port && off.bootstrapToken == link.bootstrapToken)
        #expect(off.withEmbeddedTailnet(.defaults) == link)
    }

    @Test func `all setup endpoints are routed and deduplicated`() {
        let endpoints: [GatewayConnectEndpoint] = [
            .init(host: "192.168.1.20", port: 18789, tls: false),
            .init(host: "Gateway.Example.TS.net", port: 443, tls: true),
            .init(host: "100.101.102.103", port: 443, tls: true),
        ]
        #expect(GatewayEmbeddedTailnetSetup.routedHosts(for: endpoints) == [
            "192.168.1.20", "gateway.example.ts.net", "100.101.102.103",
        ])
        let custom: [GatewayConnectEndpoint] = [.init(host: "gw.corp.example", port: 443, tls: true)]
        #expect(GatewayEmbeddedTailnetSetup.routedHosts(for: custom) == ["gw.corp.example"])
    }
}

struct GatewayNetworkRouterTests {
    private let proxy = GatewayProxyEndpoint(host: "127.0.0.1", port: 41641, username: "tsnet", password: "cred")

    @Test func `unpublished and unrelated hosts stay direct`() {
        let router = GatewayNetworkRouter()
        #expect(router.route(forHost: "gateway.example.ts.net") == .direct)
        router.publish(hosts: ["gateway.example.ts.net"], route: .proxy(self.proxy))
        #expect(router.route(forHost: "example.com") == .direct)
        #expect(router.proxyConfigurations(forHost: "example.com").isEmpty)
        #expect(!router.isRouted(host: "example.com"))
    }

    @Test func `published hosts use the proxy with normalized matching`() {
        let router = GatewayNetworkRouter()
        router.publish(hosts: ["Gateway.Example.TS.net."], route: .proxy(self.proxy))
        #expect(router.route(forHost: "gateway.example.ts.net") == .proxy(self.proxy))
        #expect(router.route(for: URL(string: "wss://GATEWAY.example.ts.net:443/ws")) == .proxy(self.proxy))
        #expect(router.proxyConfigurations(forHost: "gateway.example.ts.net").count == 1)

        let configuration = URLSessionConfiguration.ephemeral
        #expect(router.apply(to: configuration, forHost: "gateway.example.ts.net") == .proxy(self.proxy))
        #expect(configuration.proxyConfigurations.count == 1)
    }

    @Test func `unavailable route fails closed instead of going direct`() {
        let router = GatewayNetworkRouter()
        router.publish(hosts: ["100.101.102.103"], route: .unavailable)
        #expect(router.route(forHost: "100.101.102.103") == .unavailable)
        let configuration = URLSessionConfiguration.ephemeral
        router.apply(to: configuration, forHost: "100.101.102.103")
        #expect(configuration.proxyConfigurations.count == 1)
        #expect(configuration.proxyConfigurations.first?.allowFailover == false)
    }

    @Test func `unavailable route never falls back to the system route for URLSession or Network`() {
        let router = GatewayNetworkRouter()
        router.publish(hosts: ["gateway.example.ts.net"], route: .unavailable)
        #expect(router.isRouted(host: "GATEWAY.example.ts.net."))
        let configurations = router.proxyConfigurations(forHost: "gateway.example.ts.net")
        #expect(configurations.count == 1)
        #expect(configurations.allSatisfy { !$0.allowFailover })
        let parameters = NWParameters.tls
        #expect(router.apply(to: parameters, forHost: "gateway.example.ts.net") == .unavailable)
        // Unrelated hosts keep the system route while the tailnet host is held.
        #expect(router.route(forHost: "gateway.example.com") == .direct)
        #expect(router.proxyConfigurations(forHost: "gateway.example.com").isEmpty)
    }

    @Test func `publishing bumps generation and empty host set clears routing`() {
        let router = GatewayNetworkRouter()
        let start = router.generation
        router.publish(hosts: ["gateway.example.ts.net"], route: .unavailable)
        router.publish(hosts: [], route: .unavailable)
        #expect(router.generation == start &+ 2)
        #expect(router.route(forHost: "gateway.example.ts.net") == .direct)
    }
}
