import XCTest

/// Simulator screenshots of the Tailscale onboarding states. Synthetic fixture data only: no
/// setup tokens, no Tailscale login, and no network. The app renders fixture node states via
/// `--openclaw-tailnet-fixture` in DEBUG screenshot mode.
@MainActor
final class TailnetOnboardingScreenshotUITests: XCTestCase {
    /// base64url of `{"url":"wss://gateway.example.ts.net"}`: a legacy code without `tailnet`.
    private static let legacyTailnetSetupCode = "eyJ1cmwiOiJ3c3M6Ly9nYXRld2F5LmV4YW1wbGUudHMubmV0In0"

    private var app: XCUIApplication?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        self.app?.terminate()
        self.app = nil
        try super.tearDownWithError()
    }

    func testLegacyTailnetSetupCodeShowsToggleAndSignIn() {
        let app = self.launch(fixture: "off", extra: [
            "--openclaw-setup-code-fixture", Self.legacyTailnetSetupCode,
        ])
        let toggle = app.switches["TailnetSetup.Toggle"]
        self.scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1", "ts.net setup code must pre-enable Tailscale")
        let signIn = app.buttons["TailnetSetup.SignIn"]
        self.scrollTo(signIn, in: app)
        XCTAssertTrue(signIn.exists)
        self.capture("tailnet-01-legacy-ts-net-toggle-sign-in")
    }

    func testTurningTailscaleOffForTailnetHostWarns() {
        let app = self.launch(fixture: "off", extra: [
            "--openclaw-setup-code-fixture", Self.legacyTailnetSetupCode,
        ])
        let toggle = app.switches["TailnetSetup.Toggle"]
        self.scrollTo(toggle, in: app)
        // Tap the switch itself; a Form row label tap does not flip a SwiftUI Toggle.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        let warning = app.descendants(matching: .any)["TailnetSetup.DirectWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 3))
        self.capture("tailnet-05-tailscale-off-warning")
    }

    func testSettingsUnconfiguredOffersEnableAction() {
        let app = self.launch(fixture: "off", extra: [
            "--openclaw-manual-host-fixture", "gateway.example.ts.net",
        ])
        let enable = app.buttons["TailnetSettings.Enable"]
        self.scrollTo(enable, in: app)
        XCTAssertTrue(enable.isEnabled)
        self.capture("tailnet-02-settings-unconfigured-enable")
    }

    func testTailnetFailureShowsPlainFix() {
        let app = self.launch(fixture: "failed", extra: [
            "--openclaw-manual-host-fixture", "gateway.example.ts.net",
            "--openclaw-setup-code-fixture", Self.legacyTailnetSetupCode,
        ])
        let state = app.descendants(matching: .any)["TailnetSetup.State"]
        self.scrollTo(state, in: app)
        XCTAssertTrue(app.buttons["TailnetSetup.SignIn"].exists)
        self.capture("tailnet-03-error-state")
        let settingsSignIn = app.buttons["TailnetSettings.SignIn"]
        self.scrollTo(settingsSignIn, in: app)
        self.capture("tailnet-04-settings-error-sign-in")
    }

    private func launch(fixture: String, extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--openclaw-initial-tab", "settings",
            "--openclaw-initial-destination", "gateway",
            "--openclaw-sidebar-visibility", "hidden",
            "--openclaw-ui-test-readiness",
            "--openclaw-screenshot-mode",
            "--openclaw-appearance", "light",
            "--openclaw-tailnet-fixture", fixture,
        ] + extra
        app.launch()
        self.app = app
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.navigationBars["Gateway"].waitForExistence(timeout: 15))
        return app
    }

    private func scrollTo(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line)
    {
        let list = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if element.exists, element.isHittable { break }
            list.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 3), "missing \(element)", file: file, line: line)
        // Leave some room above the target so its section header is visible.
        if element.frame.minY > app.frame.height * 0.7 {
            list.swipeUp(velocity: .slow)
        }
    }

    private func capture(_ name: String) {
        guard let app else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
