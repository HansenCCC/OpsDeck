import Foundation

actor ServerStatusService {
    func collect(config: SSHConnectionConfig, sshService: SSHService) async throws -> ServerStatusSnapshot {
        let command = """
        printf 'LOAD='; awk '{print $1}' /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}'; \
        printf 'CPU='; getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null; \
        printf 'MEM='; free -m 2>/dev/null | awk 'NR==2{printf "%s/%s", $3,$2}'; printf '\\n'; \
        printf 'DISK='; df -P / 2>/dev/null | awk 'NR==2{print $5}'
        """
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 16 * 1024)
        return parse(result.stdout)
    }

    private func parse(_ output: String) -> ServerStatusSnapshot {
        var load: Double?
        var cpuCount: Int?
        var memoryUsed: Int?
        var memoryTotal: Int?
        var disk: Double?

        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.hasPrefix("LOAD=") {
                load = Double(text.replacingOccurrences(of: "LOAD=", with: "").trimmingCharacters(in: .whitespaces))
            } else if text.hasPrefix("CPU=") {
                cpuCount = Int(text.replacingOccurrences(of: "CPU=", with: "").trimmingCharacters(in: .whitespaces))
            } else if text.hasPrefix("MEM=") {
                let value = text.replacingOccurrences(of: "MEM=", with: "")
                let parts = value.split(separator: "/")
                if parts.count == 2 {
                    memoryUsed = Int(parts[0])
                    memoryTotal = Int(parts[1])
                }
            } else if text.hasPrefix("DISK=") {
                let value = text
                    .replacingOccurrences(of: "DISK=", with: "")
                    .replacingOccurrences(of: "%", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let percent = Double(value) {
                    disk = percent / 100
                }
            }
        }

        return ServerStatusSnapshot(
            loadAverage: load,
            cpuCount: cpuCount,
            memoryUsedMB: memoryUsed,
            memoryTotalMB: memoryTotal,
            diskUsedPercent: disk,
            capturedAt: Date()
        )
    }
}
