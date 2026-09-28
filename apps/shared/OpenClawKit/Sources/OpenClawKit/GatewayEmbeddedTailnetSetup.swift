import Foundation
import Network

/// Setup-code extension asking the app to reach this Gateway through an in-app,
/// userspace Tailscale node (tsnet) instead of the system network or a VPN profile.
///
/// Wire shape inside the setup payload: `"tailnet": {"controlURL"?, "hostname"?, "required"?}`.
/// Every field is optional; an empty object selects Tailscale's control plane, the
/// `openclaw-iphone` hostname, and a required route.
///
/// Legacy setup codes without a `tailnet` object whose primary Gateway host is a tailnet-only
/// address (`*.ts.net`, `100.64.0.0/10`, or `fd7a:115c:a1e0::/48`) are treated as if they
/// carried `"tailnet": {}` (see `inferred(forHost:)`). Those names and addresses resolve and
/// route only inside a tailnet, and relying on the system network or a system VPN profile made
/// such gateways fail silently whenever the Tailscale app was off. An explicit `tailnet` object
/// always wins, including `required: false`.
public struct GatewayEmbeddedTailnetSetup: Codable, Sendable, Equatable {
    public static let defaultControlURL = URL(string: "https://controlplane.tailscale.com")!
    public static let defaultHostname = "openclaw-iphone"
    /// Tailscale control plane, `openclaw-iphone`, required route: the shape an empty
    /// `tailnet` object selects and the one inferred for tailnet-only legacy hosts.
    public static let defaults = GatewayEmbeddedTailnetSetup(
        uncheckedControlURL: defaultControlURL,
        hostname: defaultHostname,
        required: true)

    /// Setup inferred for a legacy setup code without a `tailnet` object. Only tailnet-only
    /// hosts get one; every other legacy host keeps today's direct route (`nil`).
    public static func inferred(forHost host: String) -> GatewayEmbeddedTailnetSetup? {
        self.isTailnetHost(host) ? self.defaults : nil
    }

    /// True for addresses that only exist inside a tailnet: MagicDNS names under `ts.net`,
    /// Tailscale's CGNAT IPv4 range `100.64.0.0/10`, and its ULA IPv6 range
    /// `fd7a:115c:a1e0::/48`. A hint about reachability, not proof of any VPN state.
    public static func isTailnetHost(_ raw: String) -> Bool {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasSuffix(".ts.net") {
            return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { byte in
                        (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
                    }
            }
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let address = IPv4Address(host) {
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4,
                  octets.allSatisfy({ octet in UInt8(octet).map { String($0) == octet } ?? false })
            else { return false }
            let bytes = address.rawValue
            return bytes[0] == 100 && (64...127).contains(bytes[1])
        }
        if let address = IPv6Address(host) {
            return address.rawValue.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
        }
        return false
    }

    /// Coordination server. Only HTTPS origins are accepted.
    public let controlURL: URL
    /// Tailnet machine name requested for this device (a single DNS label).
    public let hostname: String
    /// When true the Gateway is never contacted outside the embedded tailnet: while the
    /// node is not running, gateway traffic fails closed instead of using the system route.
    public let required: Bool

    /// Raw setup-payload object before validation.
    public struct Payload: Decodable, Sendable {
        let controlURL: String?
        let hostname: String?
        let required: Bool?
    }

    private enum CodingKeys: String, CodingKey {
        case controlURL
        case hostname
        case required
    }

    public init?(
        controlURL: String? = nil,
        hostname: String? = nil,
        required: Bool = true)
    {
        let url: URL
        if let controlURL {
            guard let normalized = Self.normalizedControlURL(controlURL) else { return nil }
            url = normalized
        } else {
            url = Self.defaultControlURL
        }
        let name: String
        if let hostname {
            guard let normalized = Self.normalizedHostname(hostname) else { return nil }
            name = normalized
        } else {
            name = Self.defaultHostname
        }
        self.controlURL = url
        self.hostname = name
        self.required = required
    }

    private init(uncheckedControlURL: URL, hostname: String, required: Bool) {
        self.controlURL = uncheckedControlURL
        self.hostname = hostname
        self.required = required
    }

    public init?(payload: Payload) {
        self.init(
            controlURL: payload.controlURL,
            hostname: payload.hostname,
            required: payload.required ?? true)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try Payload(
            controlURL: container.decodeIfPresent(String.self, forKey: .controlURL),
            hostname: container.decodeIfPresent(String.self, forKey: .hostname),
            required: container.decodeIfPresent(Bool.self, forKey: .required))
        guard let setup = Self(payload: payload) else {
            throw DecodingError.dataCorruptedError(
                forKey: .controlURL,
                in: container,
                debugDescription: "Invalid embedded tailnet setup.")
        }
        self = setup
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.controlURL.absoluteString, forKey: .controlURL)
        try container.encode(self.hostname, forKey: .hostname)
        try container.encode(self.required, forKey: .required)
    }

    /// Every endpoint carried by an embedded-tailnet setup must use the in-app route.
    /// Required setups may never fall back to LAN or the system VPN.
    public static func routedHosts(for endpoints: [GatewayConnectEndpoint]) -> [String] {
        var hosts: [String] = []
        for endpoint in endpoints {
            let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !host.isEmpty, !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return hosts
    }

    /// HTTPS origin (optionally with a path) without credentials, query, or fragment.
    static func normalizedControlURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        return components.url
    }

    /// One lowercase DNS label: letters, digits, and inner hyphens, at most 63 bytes.
    static func normalizedHostname(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1...63).contains(name.utf8.count),
              name.utf8.allSatisfy({ byte in
                  (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
              }),
              name.first != "-",
              name.last != "-"
        else { return nil }
        return name
    }
}
