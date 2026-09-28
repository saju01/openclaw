import SwiftUI

/// Settings controls for the in-app userspace tailnet node.
///
/// Always visible under Settings › Gateway. Before anything is configured, it offers
/// "Enable Tailscale for this gateway" for the current gateway host. Existing pairing, device
/// identity, and saved credentials are untouched: enabling only adds an in-app route for that
/// host and asks the user to sign in to Tailscale.
struct SettingsEmbeddedTailnetSection: View {
    @Environment(EmbeddedTailnetController.self) private var tailnet
    var gatewayHost: String?
    @State private var isWorking = false
    @State private var confirmReset = false
    @State private var enableFailure: String?

    var body: some View {
        if self.tailnet.isConfigured {
            self.configuredSection
        } else {
            self.unconfiguredSection
        }
    }

    private var unconfiguredSection: some View {
        Section {
            self.row(title: "State", value: String(localized: "Off"))
            self.actionButton(title: "Enable Tailscale for this gateway", icon: "network.badge.shield.half.filled") {
                await self.enable()
            }
            .disabled(self.isWorking || self.gatewayHost == nil)
            .accessibilityIdentifier("TailnetSettings.Enable")
            if let enableFailure {
                Text(enableFailure)
                    .font(OpenClawType.footnote)
                    .foregroundStyle(OpenClawBrand.danger)
            }
        } header: {
            Text("Tailscale").font(OpenClawType.subheadSemiBold)
        } footer: {
            Text(self.unconfiguredFooter).font(OpenClawType.footnote)
        }
    }

    private var unconfiguredFooter: String {
        guard let gatewayHost else {
            return String(
                localized: """
                Connect to a gateway first, or paste a setup code above. Tailscale can then carry that \
                gateway's traffic.
                """)
        }
        if GatewayConnectionIssue.isTailnetEndpoint(gatewayHost) {
            return String(
                format: String(
                    localized: """
                    %@ only works inside a tailnet. Enable Tailscale here and sign in, or keep the \
                    Tailscale app connected on this device.
                    """),
                gatewayHost)
        }
        return String(
            format: String(
                localized: "Runs an in-app Tailscale connection for %@ only, alongside any VPN. You stay paired."),
            gatewayHost)
    }

    private var configuredSection: some View {
        let state = EmbeddedTailnetStepState(controller: self.tailnet)
        return Section {
            self.row(title: "State", value: self.stateText(state))
            self.row(title: "Tailnet IP", value: self.tailnet.status?.ipv4 ?? self.tailnet.status?.ipv6 ?? "—")
            self.row(title: "User", value: self.tailnet.status?.loginName ?? "—")
            if let name = self.tailnet.status?.dnsName {
                self.row(title: "Device", value: name)
            }
            if state.showsSignIn {
                self.actionButton(title: "Sign in to Tailscale", icon: "person.badge.key") {
                    await self.tailnet.presentLogin()
                }
                .accessibilityIdentifier("TailnetSettings.SignIn")
            }
            if let host = self.gatewayHost, !self.tailnet.carries(host: host) {
                self
                    .actionButton(
                        title: "Enable Tailscale for this gateway",
                        icon: "network.badge.shield.half.filled")
                    {
                        await self.enable()
                    }
            }
            self.actionButton(title: "Reconnect", icon: "arrow.clockwise") {
                self.tailnet.reconnect()
            }
            self.actionButton(title: "Log Out", icon: "rectangle.portrait.and.arrow.right") {
                await self.tailnet.logOut()
            }
            Button(role: .destructive) {
                self.confirmReset = true
            } label: {
                Label {
                    Text("Reset Tailnet Node").font(OpenClawType.body)
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .disabled(self.isWorking)
            if let enableFailure {
                Text(enableFailure)
                    .font(OpenClawType.footnote)
                    .foregroundStyle(OpenClawBrand.danger)
            }
        } header: {
            Text("Tailscale").font(OpenClawType.subheadSemiBold)
        } footer: {
            Text(self.footerText(state)).font(OpenClawType.footnote)
        }
        .alert(
            Text("Reset tailnet node?").font(OpenClawType.headline),
            isPresented: self.$confirmReset)
        {
            Button(role: .destructive) {
                Task { await self.tailnet.remove() }
            } label: {
                Text("Reset").font(OpenClawType.body)
            }
            Button(role: .cancel) {} label: {
                Text("Cancel").font(OpenClawType.body)
            }
        } message: {
            Text(
                "This deletes this iPhone's tailnet identity. Gateways that require the tailnet " +
                    "stay offline until you apply their setup code again.")
                .font(OpenClawType.footnote)
        }
    }

    private func stateText(_ state: EmbeddedTailnetStepState) -> String {
        if case let .failed(message) = state {
            return String(format: String(localized: "Failed: %@"), message)
        }
        return state.title
    }

    private func footerText(_ state: EmbeddedTailnetStepState) -> String {
        switch state {
        case .reconnecting:
            return String(
                localized: """
                Reconnecting after the app returned to the foreground. Gateway traffic resumes when \
                Tailscale is back.
                """)
        case .needsSignIn, .notSignedIn, .failed:
            if self.tailnet.config?.setup.required == true {
                return String(
                    localized: """
                    Sign in to Tailscale to reach the gateway. OpenClaw holds gateway traffic until \
                    Tailscale connects and never sends it over the regular network.
                    """)
            }
        default:
            break
        }
        if self.tailnet.config?.setup.required == true, !state.isConnected {
            return String(
                localized: "Gateway traffic waits for the tailnet. It never uses the regular network.")
        }
        return String(
            localized: "An in-app Tailscale node carries only Gateway traffic, alongside any VPN.")
    }

    private func enable() async {
        guard let gatewayHost else { return }
        self.enableFailure = nil
        if let failure = await self.tailnet.enable(forGatewayHost: gatewayHost) {
            self.enableFailure = failure
        }
    }

    private func row(title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title).font(OpenClawType.body)
            Spacer()
            Text(value)
                .font(OpenClawType.subhead)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func actionButton(
        title: LocalizedStringKey,
        icon: String,
        action: @escaping @MainActor () async -> Void) -> some View
    {
        Button {
            Task {
                self.isWorking = true
                defer { self.isWorking = false }
                await action()
            }
        } label: {
            Label {
                Text(title).font(OpenClawType.body)
            } icon: {
                Image(systemName: icon)
            }
        }
        .disabled(self.isWorking)
    }
}
