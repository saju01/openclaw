import Foundation
import Network
import OpenClawKit

enum GatewayConnectionIssue: Equatable {
    case none
    case tokenMissing
    case passwordMissing
    case unauthorized
    case pairingRequired(requestId: String?)
    case network
    case unknown(String)

    var requestId: String? {
        if case let .pairingRequired(requestId) = self {
            return requestId
        }
        return nil
    }

    var needsAuthCredentials: Bool {
        switch self {
        case .tokenMissing, .passwordMissing, .unauthorized:
            true
        default:
            false
        }
    }

    var needsPairing: Bool {
        if case .pairingRequired = self { return true }
        return false
    }

    static func detect(problem: GatewayConnectionProblem?) -> Self {
        guard let problem else { return .none }
        if problem.needsPairingApproval {
            return .pairingRequired(requestId: problem.requestId)
        }
        if problem.kind == .gatewayAuthTokenMissing {
            return .tokenMissing
        }
        if problem.kind == .gatewayAuthPasswordMissing {
            return .passwordMissing
        }
        if problem.needsCredentialUpdate {
            return .unauthorized
        }
        switch problem.kind {
        case .deviceIdentityRequired,
             .deviceSignatureExpired,
             .deviceNonceRequired,
             .deviceNonceMismatch,
             .deviceSignatureInvalid,
             .devicePublicKeyInvalid,
             .deviceIdMismatch,
             .tailscaleIdentityMissing,
             .tailscaleProxyMissing,
             .tailscaleWhoisFailed,
             .tailscaleIdentityMismatch,
             .authRateLimited:
            return .unauthorized
        case .timeout, .connectionRefused, .reachabilityFailed, .websocketCancelled:
            return .network
        case .unknown:
            return .unknown(problem.message)
        default:
            return .none
        }
    }

    static func detect(from statusText: String) -> Self {
        let trimmed = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let lower = trimmed.lowercased()

        if lower.contains("pairing required") || lower.contains("not_paired") || lower.contains("not paired") {
            return .pairingRequired(requestId: self.extractRequestId(from: trimmed))
        }
        if lower.contains("gateway token missing") {
            return .tokenMissing
        }
        if lower.contains("gateway password missing") {
            return .passwordMissing
        }
        if lower.contains("unauthorized") {
            return .unauthorized
        }
        if lower.contains("connection refused") ||
            lower.contains("timed out") ||
            lower.contains("network is unreachable") ||
            lower.contains("cannot find host") ||
            lower.contains("could not connect")
        {
            return .network
        }
        if lower.hasPrefix("gateway error:") {
            return .unknown(trimmed)
        }
        return .none
    }

    private static func extractRequestId(from statusText: String) -> String? {
        let marker = "requestId:"
        guard let range = statusText.range(of: marker) else { return nil }
        let suffix = statusText[range.upperBound...]
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = trimmed.firstIndex(where: { ch in
            ch == ")" || ch.isWhitespace || ch == "," || ch == ";"
        }) ?? trimmed.endIndex
        let id = String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}

extension GatewayConnectionIssue {
    static let tailscaleSetupURL = URL(string: "https://tailscale.com/docs/install/ios")!

    /// These addresses suggest Tailscale, not proof of VPN state or permission to use plaintext.
    static func isTailnetEndpoint(_ host: String) -> Bool {
        GatewayEmbeddedTailnetSetup.isTailnetHost(host)
    }

    private static let transportKinds: [GatewayConnectionProblem.Kind] = [
        .timeout, .connectionRefused, .reachabilityFailed,
    ]

    /// Plain-language fix for a gateway transport failure, chosen from how this host is routed.
    /// Nil when the failure is not a reachability problem this layer can explain.
    static func endpointGuidance(
        kind: GatewayConnectionProblem.Kind,
        host: String?,
        route: GatewayNetworkRoute) -> String?
    {
        guard let host else { return nil }
        switch route {
        case .unavailable:
            // The in-app node owns this host but is not running: traffic fails closed on purpose.
            guard self.transportKinds.contains(kind) || kind == .websocketCancelled || kind == .unknown
            else { return nil }
            return String(localized: """
            In-app Tailscale is not connected, so OpenClaw is holding Gateway traffic instead of \
            sending it over the regular network. Open Settings › Gateway › Tailscale and sign in, \
            or tap Reconnect, then retry.
            """)
        case .proxy:
            guard self.transportKinds.contains(kind) else { return nil }
            return String(localized: """
            Tailscale is connected, but the Gateway did not answer. Check that the Gateway is \
            running and that your tailnet allows this device to reach it, then retry.
            """)
        case .direct:
            guard self.isTailnetEndpoint(host), self.transportKinds.contains(kind) else { return nil }
            return String(localized: """
            This Gateway address only works inside a tailnet. Turn on Tailscale for this \
            gateway in Settings › Gateway › Tailscale, or open the Tailscale app on this device \
            and connect to the same tailnet, then retry.
            """)
        }
    }

    static func addingEndpointGuidance(
        to problem: GatewayConnectionProblem,
        host: String?,
        route: GatewayNetworkRoute? = nil) -> GatewayConnectionProblem
    {
        let route = route ?? GatewayNetworkRouter.shared.route(forHost: host)
        guard let guidance = self.endpointGuidance(kind: problem.kind, host: host, route: route),
              problem.docsURL != self.tailscaleSetupURL,
              !problem.localizedMessage.contains(guidance)
        else { return problem }
        let message = problem.localizedMessage + "\n\n" + guidance
        return GatewayConnectionProblem(
            kind: problem.kind,
            owner: problem.owner,
            title: problem.title,
            message: message,
            actionLabel: "Retry",
            titlePresentation: problem.titlePresentation,
            messagePresentation: .verbatim(message),
            actionCommand: problem.actionCommand,
            docsURL: self.tailscaleSetupURL,
            requestId: problem.requestId,
            retryable: problem.retryable,
            pauseReconnect: problem.pauseReconnect,
            technicalDetails: problem.technicalDetails,
            tlsStoreKey: problem.tlsStoreKey,
            tlsExpectedFingerprint: problem.tlsExpectedFingerprint,
            tlsObservedFingerprint: problem.tlsObservedFingerprint,
            tlsSystemTrustOk: problem.tlsSystemTrustOk)
    }
}
