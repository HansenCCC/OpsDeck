import Foundation

struct SSHSessionSummary: Equatable, Sendable {
    let hostID: UUID
    let displayName: String
    let systemSummary: String
    let connectedAt: Date
}

actor SSHSessionManager {
    private var activeSessions: [UUID: SSHSessionSummary] = [:]
    private var activeConfigs: [UUID: SSHConnectionConfig] = [:]

    var activeSession: SSHSessionSummary? {
        activeSessions.values.sorted { $0.connectedAt > $1.connectedAt }.first
    }

    func connect(hostID: UUID, config: SSHConnectionConfig, sshService: SSHService) async throws -> SSHSessionSummary {
        let result = try await sshService.runConnectionTest(config: config)
        let summary = SSHSessionSummary(
            hostID: hostID,
            displayName: config.displayName,
            systemSummary: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            connectedAt: Date()
        )
        activeSessions[hostID] = summary
        activeConfigs[hostID] = config
        return summary
    }

    func disconnect(sshService: SSHService) async {
        let configs = Array(activeConfigs.values)
        activeSessions = [:]
        activeConfigs = [:]
        for config in configs {
            await sshService.disconnect(config: config)
        }
    }

    func disconnect(hostID: UUID, sshService: SSHService) async {
        activeSessions[hostID] = nil
        if let config = activeConfigs.removeValue(forKey: hostID) {
            await sshService.disconnect(config: config)
        }
    }
}
