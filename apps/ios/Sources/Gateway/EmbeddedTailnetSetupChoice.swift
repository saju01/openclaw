import Foundation
import OpenClawKit

/// The "Connect through Tailscale" choice for one parsed setup code.
///
/// The toggle starts from the parsed setup (an explicit `tailnet` object, or one inferred for a
/// tailnet-only host) and the user may override it before connecting. Overrides survive edits
/// that parse to the same link and reset when a different setup code is entered.
struct EmbeddedTailnetSetupChoice: Equatable {
    let link: GatewayConnectDeepLink
    var connectThroughTailscale: Bool

    init(link: GatewayConnectDeepLink) {
        self.link = link
        self.connectThroughTailscale = link.embeddedTailnet != nil
    }

    /// Re-derive the choice for edited setup input, keeping the user's override when the input
    /// still describes the same gateway link.
    static func updated(
        _ current: EmbeddedTailnetSetupChoice?,
        forInput raw: String) -> EmbeddedTailnetSetupChoice?
    {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !AppleReviewDemoMode.isSetupCode(trimmed),
              let link = GatewayConnectDeepLink.fromSetupInput(trimmed)
        else { return nil }
        if let current, current.link == link { return current }
        return EmbeddedTailnetSetupChoice(link: link)
    }

    /// The link to hand to the tailnet controller and pairing: the parsed link when the user did
    /// not override it, otherwise the same gateway with Tailscale turned on (defaults) or off.
    static func resolve(
        _ parsed: GatewayConnectDeepLink,
        choice: EmbeddedTailnetSetupChoice?) -> GatewayConnectDeepLink
    {
        guard let choice, choice.link == parsed else { return parsed }
        return choice.effectiveLink
    }

    var effectiveLink: GatewayConnectDeepLink {
        guard self.connectThroughTailscale else { return self.link.withEmbeddedTailnet(nil) }
        return self.link.withEmbeddedTailnet(self.link.embeddedTailnet ?? GatewayEmbeddedTailnetSetup.defaults)
    }

    /// The gateway address exists only inside a tailnet (`*.ts.net`, 100.64.0.0/10, fd7a:115c:a1e0::/48).
    var isTailnetOnlyHost: Bool {
        GatewayEmbeddedTailnetSetup.isTailnetHost(self.link.host)
    }

    /// Shown when the user turned Tailscale off for an address that needs it.
    var directRouteWarning: String? {
        guard !self.connectThroughTailscale else { return nil }
        if self.link.embeddedTailnet?.required == true {
            return String(
                localized: "This setup requires Tailscale. Turning it off can prevent the gateway from connecting.")
        }
        guard self.isTailnetOnlyHost else { return nil }
        return String(localized: """
        This address only works inside a tailnet. With in-app Tailscale off, open the Tailscale \
        app on this device and connect to the same tailnet first, or the connection will fail.
        """)
    }
}

enum EmbeddedTailnetSettingsPresentation {
    static func showsStandaloneSection(stagedChoice: EmbeddedTailnetSetupChoice?) -> Bool {
        stagedChoice == nil
    }
}

/// What the Tailscale step of setup shows for the current in-app node state.
enum EmbeddedTailnetStepState: Equatable {
    case notSignedIn
    case starting
    case reconnecting
    case needsSignIn
    case needsApproval
    case differentNetwork
    case connected(address: String?)
    case failed(String)

    init(
        phase: EmbeddedTailnetPhase,
        hasBeenRunning: Bool,
        status: EmbeddedTailnetStatus?,
        selectedSetup: GatewayEmbeddedTailnetSetup? = nil,
        configuredSetup: GatewayEmbeddedTailnetSetup? = nil)
    {
        if let selectedSetup, let configuredSetup,
           selectedSetup.controlURL != configuredSetup.controlURL ||
           selectedSetup.hostname != configuredSetup.hostname
        {
            self = .differentNetwork
            return
        }
        switch phase {
        case .notConfigured:
            self = .notSignedIn
        case .starting:
            self = hasBeenRunning ? .reconnecting : .starting
        case .needsLogin:
            self = .needsSignIn
        case .needsApproval:
            self = .needsApproval
        case .running:
            self = .connected(address: status?.ipv4 ?? status?.ipv6)
        case let .failed(message):
            self = .failed(message)
        }
    }

    @MainActor
    init(controller: EmbeddedTailnetController, selectedSetup: GatewayEmbeddedTailnetSetup? = nil) {
        self.init(
            phase: controller.phase,
            hasBeenRunning: controller.hasBeenRunning,
            status: controller.status,
            selectedSetup: selectedSetup,
            configuredSetup: controller.config?.setup)
    }

    var title: String {
        switch self {
        case .notSignedIn: String(localized: "Not signed in")
        case .starting: String(localized: "Starting Tailscale…")
        case .reconnecting: String(localized: "Reconnecting to Tailscale…")
        case .needsSignIn: String(localized: "Sign-in required")
        case .needsApproval: String(localized: "Waiting for admin approval")
        case .differentNetwork: String(localized: "Different Tailscale network")
        case .connected: String(localized: "Connected")
        case .failed: String(localized: "Tailscale is not connected")
        }
    }

    var detail: String {
        switch self {
        case .notSignedIn, .needsSignIn:
            String(localized: "Sign in to Tailscale before pairing. Gateway traffic waits for the tailnet.")
        case .starting:
            String(localized: "Starting the in-app Tailscale node. This usually takes a few seconds.")
        case .reconnecting:
            String(localized: "Rechecking the tailnet after the app returned. Gateway traffic resumes when it is back.")
        case .needsApproval:
            String(localized: "Ask your tailnet admin to approve this device, then tap Reconnect.")
        case .differentNetwork:
            String(localized: "Reset the existing Tailnet node to use the network in this setup code.")
        case let .connected(address):
            if let address {
                String(format: String(localized: "Tailnet IP %@. You can pair now."), address)
            } else {
                String(localized: "Tailnet connected. You can pair now.")
            }
        case let .failed(message):
            String(format: String(localized: "%@ Tap Sign in to Tailscale to retry."), message)
        }
    }

    var showsSignIn: Bool {
        switch self {
        case .notSignedIn, .needsSignIn, .failed: true
        default: false
        }
    }

    var isBusy: Bool {
        self == .starting || self == .reconnecting
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
