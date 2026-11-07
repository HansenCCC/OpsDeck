import Foundation

struct ServerStatusSnapshot: Equatable, Sendable {
    let loadAverage: Double?
    let cpuCount: Int?
    let memoryUsedMB: Int?
    let memoryTotalMB: Int?
    let diskUsedPercent: Double?
    let capturedAt: Date

    var memoryUsedPercent: Double? {
        guard let memoryUsedMB, let memoryTotalMB, memoryTotalMB > 0 else { return nil }
        return Double(memoryUsedMB) / Double(memoryTotalMB)
    }

    /// 1-minute load average normalized by online logical CPU count. A value of
    /// 1 means roughly one runnable task per logical CPU, which is a more useful
    /// ring scale than the previous fixed `/ 4` approximation.
    var normalizedLoad: Double? {
        guard let loadAverage, let cpuCount, cpuCount > 0 else { return nil }
        return loadAverage / Double(cpuCount)
    }
}
