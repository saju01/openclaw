import Foundation

public enum WatchDirectSetupOrdering {
    public static func isNewer(
        sentAtMs: Int64,
        thanWatermark watermarkMs: Int64,
        installedSetupSentAtMs: Int64? = nil) -> Bool
    {
        sentAtMs > max(watermarkMs, installedSetupSentAtMs ?? 0)
    }
}
