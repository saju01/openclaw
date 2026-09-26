import Foundation

/// Setup-code extension asking the app to reach this Gateway through an in-app,
/// userspace Tailscale node (tsnet) instead of the system network or a VPN profile.
///
/// Wire shape inside the setup payload: `"tailnet": {"controlURL"?, "hostname"?, "required"?}`.
/// Every field is optional; an empty object selects Tailscale's control plane, the
/// `openclaw-iphone` hostname, and a required route.
public struct GatewayEmbeddedTailnetSetup: Codable, Sendable, Equatable {
    public static let defaultControlURL = URL(string: "https://controlplane.tailscale.com")!
    public static let defaultHostname = "openclaw-iphone"

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
