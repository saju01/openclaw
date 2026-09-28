import SwiftUI

/// "Connect through Tailscale" toggle plus the sign-in step shown before pairing.
///
/// Onboarding and Settings share this for a parsed setup code. The toggle comes from the parsed
/// setup and the user can override it. When it is on, the in-app node must be connected before
/// the gateway is contacted, so the sign-in step comes first and shows the node's state.
struct EmbeddedTailnetSetupStepSection: View {
    @Environment(EmbeddedTailnetController.self) private var tailnet
    @Binding var choice: EmbeddedTailnetSetupChoice?
    let isConnecting: Bool
    @State private var isSigningIn = false
    @State private var signInFailure: String?

    var body: some View {
        if let choice {
            Section {
                Toggle(isOn: self.toggleBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect through Tailscale")
                            .font(OpenClawType.body)
                        Text(self.toggleDetail(for: choice))
                            .font(OpenClawType.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(self.isConnecting || self.isSigningIn)
                .accessibilityIdentifier("TailnetSetup.Toggle")

                if choice.connectThroughTailscale {
                    self.signInStep
                } else if let warning = choice.directRouteWarning {
                    Label {
                        Text(warning).font(OpenClawType.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(OpenClawBrand.warn)
                    }
                    .accessibilityIdentifier("TailnetSetup.DirectWarning")
                }
            } header: {
                Text("Setup Code Connection").font(OpenClawType.footnoteSemiBold)
            }
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { self.choice?.connectThroughTailscale ?? false },
            set: { value in
                self.choice?.connectThroughTailscale = value
                self.signInFailure = nil
            })
    }

    private func toggleDetail(for choice: EmbeddedTailnetSetupChoice) -> String {
        if choice.link.embeddedTailnet != nil {
            return String(
                localized: """
                This setup code uses Tailscale. OpenClaw runs its own Tailscale connection for this \
                gateway only.
                """)
        }
        if choice.isTailnetOnlyHost {
            return String(localized: "This gateway's address only works inside a tailnet.")
        }
        return String(localized: "Use an in-app Tailscale connection for this gateway only.")
    }

    private var stepState: EmbeddedTailnetStepState {
        // A node that is not set up yet still reads as not signed in.
        guard self.tailnet.isConfigured else { return .notSignedIn }
        return EmbeddedTailnetStepState(controller: self.tailnet)
    }

    @ViewBuilder
    private var signInStep: some View {
        let state = self.stepState
        HStack(alignment: .top, spacing: 12) {
            Group {
                if state.isBusy || self.isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.isConnected ? "checkmark.circle.fill" : "person.badge.key.fill")
                        .foregroundStyle(state.isConnected ? OpenClawBrand.ok : OpenClawBrand.accent)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(OpenClawType.subheadSemiBold)
                Text(self.signInFailure ?? state.detail)
                    .font(OpenClawType.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("TailnetSetup.State")

        if state.showsSignIn {
            Button {
                Task { await self.signIn() }
            } label: {
                Label {
                    Text("Sign in to Tailscale").font(OpenClawType.subheadSemiBold)
                } icon: {
                    Image(systemName: "person.badge.key")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(OpenClawPrimaryActionButtonStyle())
            .disabled(self.isConnecting || self.isSigningIn)
            .accessibilityIdentifier("TailnetSetup.SignIn")
        } else if case .needsApproval = state {
            Button {
                self.tailnet.reconnect()
            } label: {
                Label {
                    Text("Reconnect").font(OpenClawType.body)
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    private func signIn() async {
        guard let link = self.choice?.effectiveLink else { return }
        self.isSigningIn = true
        self.signInFailure = nil
        defer { self.isSigningIn = false }
        if let failure = await self.tailnet.prepareForSetupLink(link) {
            self.signInFailure = failure
        }
    }
}
