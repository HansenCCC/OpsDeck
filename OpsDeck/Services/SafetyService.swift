import Foundation

enum SafetyService {
    static func shouldConfirmDangerousActions(settings: AppSettings?) -> Bool {
        settings?.confirmDangerousActions ?? true
    }

    static func isDangerousCommand(_ command: String) -> Bool {
        let normalized = command
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("\n") || normalized.contains(";") || normalized.contains("&&") {
            return true
        }

        let dangerousFragments = [
            "rm -rf",
            "mkfs",
            "dd if=",
            "shutdown",
            "reboot",
            "halt",
            "poweroff",
            "systemctl restart",
            "systemctl stop",
            "service nginx restart",
            "nginx -s reload",
            "ufw disable",
            "iptables -f",
            "chmod -r 777",
            "chown -r"
        ]
        return dangerousFragments.contains { normalized.contains($0) }
    }
}
