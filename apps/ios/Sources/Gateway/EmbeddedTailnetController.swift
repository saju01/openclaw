import AuthenticationServices
import Foundation
import Observation
import OpenClawKit
import os
import TailscaleKit
import UIKit

/// Persisted embedded-tailnet choice: the setup-code extension plus the gateway hosts it carries.
struct EmbeddedTailnetStoredConfig: Codable, Equatable, Sendable {
    let setup: GatewayEmbeddedTailnetSetup
    let gatewayHosts: [String]
}

enum EmbeddedTailnetPhase: Equatable, Sendable {
    case notConfigured
    case starting
    /// The node waits for interactive login. The URL arrives on the IPN bus as BrowseToURL.
    case needsLogin(URL?)
    /// Logged in, but the tailnet admin must approve this device.
    case needsApproval
    case running
    case failed(String)
}

enum EmbeddedTailnetReadiness: Equatable, Sendable {
    case running
    case needsLogin
    case needsApproval
    case failed(String)
    case timedOut

    var setupStatusText: String {
        switch self {
        case .running:
            String(localized: "Tailnet connected.")
        case .needsLogin:
            String(localized: "Sign in to Tailscale below, then tap Connect again.")
        case .needsApproval:
            String(localized: "Waiting for your tailnet admin to approve this device.")
        case let .failed(message):
            String(format: String(localized: "Tailnet failed: %@"), message)
        case .timedOut:
            String(localized: "Tailnet is still starting. Try Connect again in a moment.")
        }
    }
}

/// Pure route decision so every transport sees the same answer for the same node state.
enum EmbeddedTailnetRoutePolicy {
    static func route(
        phase: EmbeddedTailnetPhase,
        loopback: GatewayProxyEndpoint?,
        required: Bool) -> GatewayNetworkRoute
    {
        if phase == .running, let loopback {
            return .proxy(loopback)
        }
        return required ? .unavailable : .direct
    }
}

/// Owns the in-app userspace Tailscale node (libtailscale tsnet via TailscaleKit).
///
/// There is no NetworkExtension, VPN profile, or packet tunnel: the node lives inside the
/// app process and exposes a loopback SOCKSv5 proxy. This controller is the only writer of
/// `GatewayNetworkRouter` routes for embedded-tailnet gateways, so it also coexists with any
/// system VPN (for example Defender) because it never touches system routing.
///
/// Lifecycle: iOS may reclaim the loopback listener while the app is suspended. On foreground
/// and on a periodic health check the controller probes the listener and restarts the node when
/// it is stale; route changes force gateway sessions to reconnect so nothing claims to be
/// connected over a dead proxy.
@MainActor
@Observable
final class EmbeddedTailnetController {
    private(set) var phase: EmbeddedTailnetPhase = .notConfigured
    private(set) var config: EmbeddedTailnetStoredConfig?
    private(set) var status: EmbeddedTailnetStatus?
    private(set) var lastError: String?

    var isConfigured: Bool {
        self.config != nil
    }

    var authURL: URL? {
        if case let .needsLogin(url) = self.phase { return url }
        return nil
    }

    /// Called after the published gateway route changes (not on the initial publish).
    @ObservationIgnored var onRouteChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onRequiredRouteAdopted: (@MainActor () async -> Void)?

    static let defaultsKey = "gateway.embeddedTailnet.v1"
    private static let logger = Logger(subsystem: "ai.openclawfoundation.app", category: "EmbeddedTailnet")

    @ObservationIgnored private let router: GatewayNetworkRouter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let stateRoot: URL
    @ObservationIgnored private var runtime: Runtime?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var publishedHosts: [String]?
    @ObservationIgnored private var publishedRoute: GatewayNetworkRoute?
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var requestedInteractiveLogin = false
    @ObservationIgnored private let loginPresenter = EmbeddedTailnetLoginPresenter()

    private struct Runtime {
        let generation: UInt64
        let node: TailscaleNode
        let client: LocalAPIClient
        let processor: MessageProcessor
        let loopback: GatewayProxyEndpoint
    }

    init(
        router: GatewayNetworkRouter = .shared,
        defaults: UserDefaults = .standard,
        stateRoot: URL = EmbeddedTailnetController.defaultStateRoot(),
        startNode: Bool = true)
    {
        self.router = router
        self.defaults = defaults
        self.stateRoot = stateRoot
        self.config = Self.loadConfig(defaults: defaults)
        // Publish before any gateway autoconnect so a required route fails closed immediately.
        self.publishRoute()
        if self.config != nil, startNode {
            self.startNode(reason: "launch")
        }
    }

    /// Inert controller for previews and view tests: private router, empty defaults, no node.
    static func preview() -> EmbeddedTailnetController {
        let suite = "ai.openclaw.embeddedTailnet.preview"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return EmbeddedTailnetController(
            router: GatewayNetworkRouter(),
            defaults: defaults,
            stateRoot: FileManager.default.temporaryDirectory.appendingPathComponent("EmbeddedTailnetPreview"),
            startNode: false)
    }

    nonisolated static func defaultStateRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EmbeddedTailnet", isDirectory: true)
    }

    // MARK: - Setup

    /// Adopt a setup-code tailnet extension, start the node, and wait until it is usable or
    /// needs the user (login/approval). Callers must not probe the gateway unless `.running`.
    func prepare(
        setup: GatewayEmbeddedTailnetSetup,
        gatewayHosts: [String],
        timeout: Duration = .seconds(30)) async -> EmbeddedTailnetReadiness
    {
        var hosts: [String] = []
        for host in gatewayHosts {
            let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty, !hosts.contains(normalized) {
                hosts.append(normalized)
            }
        }
        if setup.required {
            // Extensions cannot use the app-process loopback. Revoke old direct paths before
            // publishing a required route so they cannot bypass it during login or failure.
            ShareGatewayRelaySettings.clearConfig()
            await self.onRequiredRouteAdopted?()
        }
        let previous = self.config
        if let previous,
           !previous.gatewayHosts.isEmpty,
           previous.setup.controlURL != setup.controlURL || previous.setup.hostname != setup.hostname
        {
            return .failed(String(localized: "Remove the existing embedded tailnet before joining another one."))
        }
        for host in previous?.gatewayHosts ?? [] where !hosts.contains(host) {
            hosts.append(host)
        }
        let next = EmbeddedTailnetStoredConfig(setup: setup, gatewayHosts: hosts)
        self.config = next
        Self.saveConfig(next, defaults: self.defaults)
        let sameNode = previous?.setup.controlURL == setup.controlURL &&
            previous?.setup.hostname == setup.hostname
        if !sameNode || (self.runtime == nil && self.startTask == nil) {
            self.startNode(reason: "setup")
        } else {
            self.publishRoute()
        }

        return await self.waitForReadiness(timeout: timeout, acceptLoginPrompt: true)
    }

    /// Setup entry point used by Settings and onboarding before any gateway probe or pairing.
    ///
    /// Links without the tailnet extension return `nil` immediately and keep today's behavior.
    /// Otherwise the node is started, the real BrowseToURL is presented when login is needed,
    /// and this waits until the node is running. A non-nil result is user-facing failure text;
    /// the caller must stop before touching the gateway.
    func prepareForSetupLink(_ link: GatewayConnectDeepLink) async -> String? {
        guard let setup = link.embeddedTailnet else {
            await self.releaseRouteOwnership(for: link.connectionEndpoints)
            return nil
        }
        let hosts = GatewayEmbeddedTailnetSetup.routedHosts(for: link.connectionEndpoints)
        var readiness = await self.prepare(setup: setup, gatewayHosts: hosts)
        if readiness == .needsLogin, let url = self.authURL {
            // The user completes login in the browser; nothing here submits credentials.
            await self.loginPresenter.present(url: url)
            readiness = await self.waitForReadiness(timeout: .seconds(120), acceptLoginPrompt: false)
        }
        return readiness == .running ? nil : readiness.setupStatusText
    }

    private func releaseRouteOwnership(for endpoints: [GatewayConnectEndpoint]) async {
        guard let config else { return }
        let released = Set(endpoints.map { $0.host.lowercased() })
        let retained = config.gatewayHosts.filter { !released.contains($0.lowercased()) }
        guard retained != config.gatewayHosts else { return }
        if retained.isEmpty {
            await self.remove()
            return
        }
        let updated = EmbeddedTailnetStoredConfig(setup: config.setup, gatewayHosts: retained)
        self.config = updated
        Self.saveConfig(updated, defaults: self.defaults)
        self.publishRoute()
    }

    /// Present the current Tailscale login URL (Settings "Sign in" action).
    func presentLogin() async {
        if self.authURL == nil, let runtime {
            self.requestedInteractiveLogin = true
            try? await runtime.client.startLoginInteractive()
            _ = await self.waitForReadiness(timeout: .seconds(10), acceptLoginPrompt: true)
        }
        guard let url = self.authURL else { return }
        await self.loginPresenter.present(url: url)
        try? await self.refreshStatus()
    }

    private func waitForReadiness(timeout: Duration, acceptLoginPrompt: Bool) async -> EmbeddedTailnetReadiness {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            switch self.phase {
            case .running:
                return .running
            case .needsLogin(.some) where acceptLoginPrompt:
                return .needsLogin
            case .needsApproval:
                return .needsApproval
            case let .failed(message):
                return .failed(message)
            case .notConfigured:
                return .failed(String(localized: "Tailnet was removed."))
            case .starting, .needsLogin:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        if case .needsLogin = self.phase { return .needsLogin }
        return .timedOut
    }

    // MARK: - User actions

    func reconnect() {
        guard self.config != nil else { return }
        self.startNode(reason: "user_reconnect")
    }

    /// Log this node out of the tailnet and surface a fresh login URL. The node key stays
    /// on disk, but control forgets its authorization.
    func logOut() async {
        guard let runtime else {
            self.reconnect()
            return
        }
        do {
            try await runtime.client.resetAuth()
            guard runtime.generation == self.generation else { return }
            self.requestedInteractiveLogin = true
            self.setPhase(.needsLogin(nil))
            try await runtime.client.startLoginInteractive()
            try await self.refreshStatus()
        } catch {
            self.lastError = Self.describe(error)
            self.startNode(reason: "logout_recovery")
        }
    }

    /// Stop the node, delete its persisted identity, and stop routing gateways through it.
    func remove() async {
        self.generation &+= 1
        let pendingStart = self.startTask
        self.setPhase(.starting)
        self.stopRuntime()
        // A cancelled detached start can still be opening the state database. Wait for both
        // start and close ownership before deleting the directory so it cannot be recreated.
        await pendingStart?.value
        await self.closingTask?.value
        if let config {
            try? FileManager.default.removeItem(at: self.stateDirectory(for: config.setup))
        }
        self.config = nil
        self.defaults.removeObject(forKey: Self.defaultsKey)
        self.status = nil
        self.lastError = nil
        self.setPhase(.notConfigured)
    }

    // MARK: - Lifecycle

    func setScenePhase(foreground: Bool) {
        let wasForeground = self.isForeground
        self.isForeground = foreground
        guard foreground, !wasForeground else { return }
        // A listener that survived in memory can already be stale after suspension. Stop
        // advertising a healthy route synchronously; healthCheck republishes it only after a probe.
        if self.config != nil {
            self.setPhase(.starting)
        }
        Task { await self.healthCheck(reason: "foreground") }
    }

    /// Verify both the in-memory backend and the loopback SOCKS listener. A dead listener
    /// means every proxied connection would fail, so restart instead of reporting healthy.
    func healthCheck(reason: String) async {
        guard self.config != nil else { return }
        guard let runtime else {
            if self.startTask == nil {
                self.startNode(reason: "health_\(reason)")
            }
            return
        }
        let alive = await Self.isLoopbackAlive(runtime.loopback)
        guard runtime.generation == self.generation else { return }
        guard alive else {
            Self.logger.info("embedded tailnet loopback stale reason=\(reason, privacy: .public); restarting")
            self.startNode(reason: "stale_loopback_\(reason)")
            return
        }
        do {
            try await self.refreshStatus()
        } catch {
            guard runtime.generation == self.generation else { return }
            self.lastError = Self.describe(error)
            self.startNode(reason: "status_failed_\(reason)")
        }
    }

    // MARK: - Node management

    private func startNode(reason: String) {
        guard let config else { return }
        self.generation &+= 1
        let generation = self.generation
        let previousStart = self.startTask
        self.stopRuntime()
        self.status = nil
        self.requestedInteractiveLogin = false
        self.setPhase(.starting)
        Self.logger.info("embedded tailnet start reason=\(reason, privacy: .public)")

        let directory: URL
        do {
            directory = try self.prepareStateDirectory(for: config.setup)
        } catch {
            self.setPhase(.failed(Self.describe(error)))
            return
        }
        let nodeConfig = TailscaleKit.Configuration(
            hostName: config.setup.hostname,
            path: directory.path,
            authKey: nil,
            controlURL: config.setup.controlURL.absoluteString,
            ephemeral: false)
        let previousClose = self.closingTask
        self.startTask = Task { [weak self] in
            // Cancellation cannot interrupt TailscaleNode initialization. Wait for an in-flight
            // start to retire and close before another node opens the same state directory.
            await previousStart?.value
            await previousClose?.value
            do {
                let logger = EmbeddedTailnetLogSink()
                let node = try await Task.detached(priority: .userInitiated) {
                    try TailscaleNode(config: nodeConfig, logger: logger)
                }.value
                let loopback = try await node.loopback()
                guard let host = loopback.ip,
                      let rawPort = loopback.port,
                      let port = UInt16(exactly: rawPort)
                else { throw TailscaleError.invalidProxyAddress }
                let endpoint = GatewayProxyEndpoint(
                    host: host,
                    port: port,
                    username: "tsnet",
                    password: loopback.proxyCredential)
                let client = LocalAPIClient(localNode: node, logger: logger)
                let consumer = EmbeddedTailnetBusConsumer { [weak self] notify, error in
                    await self?.handleBus(notify: notify, error: error, generation: generation)
                }
                let processor = try await client.watchIPNBus(
                    mask: [.initialState, .prefs, .noPrivateKeys, .rateLimitNetmaps],
                    consumer: consumer)
                guard let self else {
                    processor.cancel()
                    try? await node.close()
                    return
                }
                await self.install(Runtime(
                    generation: generation,
                    node: node,
                    client: client,
                    processor: processor,
                    loopback: endpoint))
            } catch {
                await self?.startFailed(error, generation: generation)
            }
        }
    }

    private func install(_ runtime: Runtime) async {
        guard runtime.generation == self.generation else {
            runtime.processor.cancel()
            try? await runtime.node.close()
            return
        }
        self.startTask = nil
        self.runtime = runtime
        self.lastError = nil
        try? await self.refreshStatus()
        self.startMonitor(generation: runtime.generation)
    }

    private func startFailed(_ error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        self.startTask = nil
        let message = Self.describe(error)
        self.lastError = message
        self.setPhase(.failed(message))
    }

    private func stopRuntime() {
        self.startTask?.cancel()
        self.startTask = nil
        self.monitorTask?.cancel()
        self.monitorTask = nil
        guard let runtime else { return }
        self.runtime = nil
        runtime.processor.cancel()
        let node = runtime.node
        let previousClose = self.closingTask
        self.closingTask = Task.detached {
            await previousClose?.value
            try? await node.close()
        }
    }

    private func startMonitor(generation: UInt64) {
        self.monitorTask?.cancel()
        self.monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Duration = await self?.phase == .running ? .seconds(20) : .seconds(2)
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                guard self.isForeground else { continue }
                await self.healthCheck(reason: "monitor")
            }
        }
    }

    // MARK: - IPN bus and status

    private func handleBus(notify: Ipn.Notify?, error: String?, generation: UInt64) async {
        guard generation == self.generation else { return }
        if let error {
            // The bus rides the loopback listener; a broken stream usually means it went stale.
            Self.logger.info("embedded tailnet bus error: \(error, privacy: .public)")
            await self.healthCheck(reason: "bus_error")
            return
        }
        guard let notify else { return }
        if let message = notify.ErrMessage, !message.isEmpty {
            self.lastError = message
        }
        if let raw = notify.BrowseToURL, let url = Self.loginURL(raw) {
            self.setPhase(.needsLogin(url))
        }
        if notify.State != nil || notify.LoginFinished != nil {
            try? await self.refreshStatus()
        }
    }

    private func refreshStatus() async throws {
        guard let runtime else { return }
        let data = try await runtime.node.statusJSON()
        guard runtime.generation == self.generation else { return }
        let status = try EmbeddedTailnetStatus.parse(data)
        self.status = status
        switch status.backendState {
        case "Running":
            // Running needs both a healthy backend and a live loopback proxy; the proxy is what
            // gateway traffic actually uses.
            if self.phase != .running {
                guard await Self.isLoopbackAlive(runtime.loopback) else {
                    guard runtime.generation == self.generation else { return }
                    self.startNode(reason: "stale_loopback_status")
                    return
                }
                guard runtime.generation == self.generation else { return }
            }
            self.setPhase(.running)
        case "NeedsLogin":
            let url = status.authURL ?? self.authURL
            self.setPhase(.needsLogin(url))
            if url == nil, !self.requestedInteractiveLogin {
                self.requestedInteractiveLogin = true
                try? await runtime.client.startLoginInteractive()
            }
        case "NeedsMachineAuth":
            self.setPhase(.needsApproval)
        case "Stopped":
            self.setPhase(.failed(String(localized: "Tailnet node stopped.")))
        default:
            if case .needsLogin = self.phase { return }
            self.setPhase(.starting)
        }
    }

    private static func isLoopbackAlive(_ loopback: GatewayProxyEndpoint) async -> Bool {
        await TCPProbe.probe(
            host: loopback.host,
            port: Int(loopback.port),
            timeoutSeconds: 2,
            queueLabel: "ai.openclaw.tailnet.loopback-probe")
    }

    // MARK: - Routing

    private func setPhase(_ phase: EmbeddedTailnetPhase) {
        if self.phase != phase {
            self.phase = phase
        }
        self.publishRoute()
    }

    private func publishRoute() {
        let hosts = self.config?.gatewayHosts ?? []
        let route = EmbeddedTailnetRoutePolicy.route(
            phase: self.phase,
            loopback: self.runtime?.loopback,
            required: self.config?.setup.required ?? true)
        guard self.publishedHosts != hosts || self.publishedRoute != route else { return }
        let isInitialPublish = self.publishedHosts == nil
        self.publishedHosts = hosts
        self.publishedRoute = route
        self.router.publish(hosts: hosts, route: route)
        if !isInitialPublish {
            self.onRouteChanged?()
        }
    }

    // MARK: - Persistence

    private func stateDirectory(for setup: GatewayEmbeddedTailnetSetup) -> URL {
        self.stateRoot
            .appendingPathComponent(setup.controlURL.host ?? "control", isDirectory: true)
            .appendingPathComponent(setup.hostname, isDirectory: true)
    }

    /// Node keys are device identity: keep them out of backups so a restored device joins
    /// as a new node instead of cloning this one.
    private func prepareStateDirectory(for setup: GatewayEmbeddedTailnetSetup) throws -> URL {
        let directory = self.stateDirectory(for: setup)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = self.stateRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        return directory
    }

    static func loadConfig(defaults: UserDefaults) -> EmbeddedTailnetStoredConfig? {
        guard let data = defaults.data(forKey: self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(EmbeddedTailnetStoredConfig.self, from: data)
    }

    private static func saveConfig(_ config: EmbeddedTailnetStoredConfig, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: self.defaultsKey)
    }

    nonisolated static func loginURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? TailscaleError {
            return String(describing: error)
        }
        return error.localizedDescription
    }
}

/// Decoded subset of tsnet's `ipnstate.Status` used by Settings.
struct EmbeddedTailnetStatus: Equatable, Sendable {
    let backendState: String
    let authURL: URL?
    let ipv4: String?
    let ipv6: String?
    let loginName: String?
    let dnsName: String?
    let tailnetName: String?
    let tags: [String]

    private struct Wire: Decodable {
        struct SelfNode: Decodable {
            let userID: Int64?
            let dnsName: String?
            let tags: [String]?

            enum CodingKeys: String, CodingKey {
                case userID = "UserID"
                case dnsName = "DNSName"
                case tags = "Tags"
            }
        }

        struct Profile: Decodable {
            let loginName: String?

            enum CodingKeys: String, CodingKey {
                case loginName = "LoginName"
            }
        }

        struct Tailnet: Decodable {
            let name: String?

            enum CodingKeys: String, CodingKey {
                case name = "Name"
            }
        }

        let backendState: String
        let authURL: String?
        let tailscaleIPs: [String]?
        let selfNode: SelfNode?
        let users: [String: Profile]?
        let currentTailnet: Tailnet?

        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState"
            case authURL = "AuthURL"
            case tailscaleIPs = "TailscaleIPs"
            case selfNode = "Self"
            case users = "User"
            case currentTailnet = "CurrentTailnet"
        }
    }

    static func parse(_ data: Data) throws -> EmbeddedTailnetStatus {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let ips = wire.tailscaleIPs ?? []
        let userID = wire.selfNode?.userID
        let loginName = userID.flatMap { wire.users?[String($0)]?.loginName }
        var dnsName = wire.selfNode?.dnsName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if dnsName?.hasSuffix(".") == true {
            dnsName?.removeLast()
        }
        return EmbeddedTailnetStatus(
            backendState: wire.backendState,
            authURL: wire.authURL.flatMap(EmbeddedTailnetController.loginURL),
            ipv4: ips.first { $0.contains(".") },
            ipv6: ips.first { $0.contains(":") },
            loginName: loginName?.isEmpty == false ? loginName : nil,
            dnsName: dnsName?.isEmpty == false ? dnsName : nil,
            tailnetName: wire.currentTailnet?.name,
            tags: wire.selfNode?.tags ?? [])
    }
}

private actor EmbeddedTailnetBusConsumer: MessageConsumer {
    private let deliver: @Sendable (Ipn.Notify?, String?) async -> Void

    init(deliver: @escaping @Sendable (Ipn.Notify?, String?) async -> Void) {
        self.deliver = deliver
    }

    func notify(_ notify: Ipn.Notify) {
        let deliver = self.deliver
        Task { await deliver(notify, nil) }
    }

    func error(_ error: Error) {
        let deliver = self.deliver
        let message = String(describing: error)
        Task { await deliver(nil, message) }
    }
}

/// Swift-side TailscaleKit logs go to the unified log with private redaction. No Go log fd is
/// set, and the pinned build compiles out log upload (`ts_omit_logtail`).
private struct EmbeddedTailnetLogSink: LogSink {
    let logFileHandle: Int32? = nil
    private static let logger = Logger(subsystem: "ai.openclawfoundation.app", category: "EmbeddedTailnet.Kit")

    func log(_ message: String) {
        Self.logger.debug("\(message, privacy: .private)")
    }
}

/// Presents Tailscale's BrowseToURL in an ASWebAuthenticationSession anchored to the key window,
/// so onboarding (a full-screen cover) and Settings share one presenter. Tailscale login does
/// not redirect back to the app: the user closes the sheet after signing in, and the IPN bus
/// reports the resulting state.
@MainActor
private final class EmbeddedTailnetLoginPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func present(url: URL) async {
        self.session?.cancel()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme("openclaw-tailnet-login"))
            { _, _ in
                continuation.resume()
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume()
            }
        }
        self.session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
                return window
            }
            if let scene = scenes.first {
                return UIWindow(windowScene: scene)
            }
            return ASPresentationAnchor()
        }
    }
}
