import Testing
@testable import OpenClawKit

struct WatchDirectSetupOrderingTests {
    @Test func `setup at or before revocation watermark is rejected`() {
        #expect(!WatchDirectSetupOrdering.isNewer(sentAtMs: 99, thanWatermark: 100))
        #expect(!WatchDirectSetupOrdering.isNewer(sentAtMs: 100, thanWatermark: 100))
        #expect(WatchDirectSetupOrdering.isNewer(sentAtMs: 101, thanWatermark: 100))
    }

    @Test func `setup older than installed setup is rejected`() {
        #expect(!WatchDirectSetupOrdering.isNewer(
            sentAtMs: 150,
            thanWatermark: 100,
            installedSetupSentAtMs: 200))
        #expect(WatchDirectSetupOrdering.isNewer(
            sentAtMs: 201,
            thanWatermark: 100,
            installedSetupSentAtMs: 200))
    }
}
