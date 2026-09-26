import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

struct WatchDirectNodeRevocationTests {
    @Test @MainActor func `reset payload carries revocation timestamp`() {
        let sentAtMs: Int64 = 1_725_000_000_123
        let payload = WatchMessagingPayloadCodec.encodeDirectNodeResetPayload(sentAtMs: sentAtMs)

        #expect(payload["type"] as? String == OpenClawWatchPayloadType.directNodeReset.rawValue)
        #expect((payload["sentAtMs"] as? NSNumber)?.int64Value == sentAtMs)
    }
}
