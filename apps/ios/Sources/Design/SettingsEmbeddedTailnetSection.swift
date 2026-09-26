import SwiftUI

/// Settings controls for the in-app userspace tailnet node. Shown only after a setup code
/// enabled it; ordinary gateways never see this section.
struct SettingsEmbeddedTailnetSection: View {
    @Environment(EmbeddedTailnetController.self) private var tailnet
    @State private var isWorking = false
    @State private var confirmReset = false

    var body: some View {
        if self.tailnet.isConfigured {
            Section {
                self.row(title: "State", value: self.stateText)
                self.row(title: "Tailnet IP", value: self.tailnet.status?.ipv4 ?? self.tailnet.status?.ipv6 ?? "—")
                self.row(title: "User", value: self.tailnet.status?.loginName ?? "—")
                if let name = self.tailnet.status?.dnsName {
                    self.row(title: "Device", value: name)
                }
                if self.tailnet.phase != .running {
                    self.actionButton(title: "Sign in to Tailscale", icon: "person.badge.key") {
                        await self.tailnet.presentLogin()
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
            } header: {
                Text("Tailnet").font(OpenClawType.subheadSemiBold)
            } footer: {
                Text(self.footerText).font(OpenClawType.footnote)
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
    }

    private var stateText: String {
        switch self.tailnet.phase {
        case .notConfigured: String(localized: "Off")
        case .starting: String(localized: "Starting…")
        case .needsLogin: String(localized: "Sign-in required")
        case .needsApproval: String(localized: "Waiting for admin approval")
        case .running: String(localized: "Connected")
        case let .failed(message): String(format: String(localized: "Failed: %@"), message)
        }
    }

    private var footerText: String {
        if self.tailnet.config?.setup.required == true, self.tailnet.phase != .running {
            return String(
                localized: "Gateway traffic waits for the tailnet. It never uses the regular network.")
        }
        return String(
            localized: "An in-app Tailscale node carries only Gateway traffic, alongside any VPN.")
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
