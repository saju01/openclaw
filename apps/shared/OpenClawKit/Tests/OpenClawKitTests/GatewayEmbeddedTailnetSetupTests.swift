import Foundation
import Network
@testable import OpenClawKit
import Testing

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
        #expect(cases.count >= 8)
        for fixture in cases {
            let name = fixture["name"] as? String ?? "?"
            let payload = try JSONSerialization.data(withJSONObject: try #require(fixture["payload"]))
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

    @Test func `publishing bumps generation and empty host set clears routing`() {
        let router = GatewayNetworkRouter()
        let start = router.generation
        router.publish(hosts: ["gateway.example.ts.net"], route: .unavailable)
        router.publish(hosts: [], route: .unavailable)
        #expect(router.generation == start &+ 2)
        #expect(router.route(forHost: "gateway.example.ts.net") == .direct)
    }
}
