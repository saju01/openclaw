import Foundation
import Network

/// SOCKSv5 endpoint that carries gateway traffic, for example an in-app tailnet node.
public struct GatewayProxyEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let password: String

    public init(host: String, port: UInt16, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

/// How connections to one gateway host leave this process.
public enum GatewayNetworkRoute: Sendable, Equatable {
    /// The system network stack (LAN, cellular, or any OS-level VPN).
    case direct
    /// A SOCKSv5 proxy that resolves names remotely, so tailnet names never hit system DNS.
    case proxy(GatewayProxyEndpoint)
    /// The host requires a route that is not available right now. Traffic fails closed.
    case unavailable
}

/// Process-wide projection of gateway routing decisions.
///
/// The owner of an alternate route (the iOS embedded tailnet controller) publishes which
/// gateway hosts it carries and the current route for them. Every gateway transport
/// (URLSession WebSocket/HTTP, Network.framework probes, WebKit data stores) consults this
/// projection when it creates its connection so no path silently bypasses the route.
///
/// Sessions capture the route when they are created. The publisher bumps `generation`
/// whenever the route changes and must force gateway transports to reconnect.
public final class GatewayNetworkRouter: @unchecked Sendable {
    public static let shared = GatewayNetworkRouter()

    /// Unroutable loopback endpoint used for `.unavailable`: connections fail immediately and,
    /// with failover disabled, URLSession never falls back to a direct connection.
    static let blackholeEndpoint = GatewayProxyEndpoint(
        host: "127.0.0.1",
        port: 9,
        username: "openclaw-route-unavailable",
        password: "openclaw-route-unavailable")

    private let lock = NSLock()
    private var routedHosts: Set<String> = []
    private var routedRoute: GatewayNetworkRoute = .direct
    private var currentGeneration: UInt64 = 0

    public init() {}

    /// Replace the routed host set and their route. Hosts outside the set stay direct.
    public func publish(hosts: some Sequence<String>, route: GatewayNetworkRoute) {
        let normalized = Set(hosts.compactMap(Self.normalizedHost))
        self.lock.lock()
        self.routedHosts = normalized
        self.routedRoute = normalized.isEmpty ? .direct : route
        self.currentGeneration &+= 1
        self.lock.unlock()
    }

    public var generation: UInt64 {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.currentGeneration
    }

    public func isRouted(host: String?) -> Bool {
        guard let host = host.flatMap(Self.normalizedHost) else { return false }
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.routedHosts.contains(host)
    }

    public func route(forHost host: String?) -> GatewayNetworkRoute {
        guard let host = host.flatMap(Self.normalizedHost) else { return .direct }
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.routedHosts.contains(host) ? self.routedRoute : .direct
    }

    public func route(for url: URL?) -> GatewayNetworkRoute {
        self.route(forHost: url?.host)
    }

    /// Proxy configurations for URLSession, Network.framework privacy contexts, or WebKit
    /// data stores. Empty means the system route.
    public func proxyConfigurations(forHost host: String?) -> [ProxyConfiguration] {
        Self.proxyConfigurations(for: self.route(forHost: host))
    }

    public func proxyConfigurations(for url: URL?) -> [ProxyConfiguration] {
        self.proxyConfigurations(forHost: url?.host)
    }

    @discardableResult
    public func apply(to configuration: URLSessionConfiguration, forHost host: String?) -> GatewayNetworkRoute {
        let route = self.route(forHost: host)
        let proxies = Self.proxyConfigurations(for: route)
        if !proxies.isEmpty {
            configuration.proxyConfigurations = proxies
        }
        return route
    }

    @discardableResult
    public func apply(to parameters: NWParameters, forHost host: String?) -> GatewayNetworkRoute {
        let route = self.route(forHost: host)
        let proxies = Self.proxyConfigurations(for: route)
        if !proxies.isEmpty {
            let context = NWParameters.PrivacyContext(description: "OpenClaw gateway route")
            context.proxyConfigurations = proxies
            parameters.setPrivacyContext(context)
        }
        return route
    }

    static func proxyConfigurations(for route: GatewayNetworkRoute) -> [ProxyConfiguration] {
        let endpoint: GatewayProxyEndpoint
        switch route {
        case .direct:
            return []
        case let .proxy(proxy):
            endpoint = proxy
        case .unavailable:
            endpoint = self.blackholeEndpoint
        }
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return [] }
        var configuration = ProxyConfiguration(
            socksv5Proxy: .hostPort(host: NWEndpoint.Host(endpoint.host), port: port))
        configuration.applyCredential(username: endpoint.username, password: endpoint.password)
        // A proxied gateway must never be retried on the system route.
        configuration.allowFailover = false
        return [configuration]
    }

    static func normalizedHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host.isEmpty ? nil : host
    }
}
