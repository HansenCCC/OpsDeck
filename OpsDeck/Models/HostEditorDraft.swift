import Foundation

struct HostEditorDraft: Identifiable, Equatable {
    var id = UUID()
    var editingHostID: UUID?
    var groupID: UUID?
    var name: String = ""
    var host: String = ""
    var portText: String = "22"
    var username: String = ""
    var authType: HostAuthType = .password
    var password: String = ""
    var privateKeyText: String = ""
    var privateKeyPassphrase: String = ""
    var note: String = ""
    /// Per-host download-source override; `nil` = follow the global default.
    var downloadMirrorPolicy: DownloadMirrorPolicy? = nil

    init() {}

    init(host: HostProfile) {
        id = UUID()
        editingHostID = host.id
        groupID = host.groupID
        name = host.name
        self.host = host.host
        portText = String(host.port)
        username = host.username
        authType = host.authType
        note = host.note
        downloadMirrorPolicy = host.downloadMirrorPolicy
    }

    var port: Int? {
        Int(portText)
    }

    func validationError() -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "名称不能为空。")
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "地址不能为空。")
        }
        guard let port, (1...65535).contains(port) else {
            return String(localized: "端口必须在 1 到 65535 之间。")
        }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "用户名不能为空。")
        }
        if editingHostID == nil {
            switch authType {
            case .password where password.isEmpty:
                return String(localized: "密码不能为空。")
            case .privateKey where privateKeyText.isEmpty:
                return String(localized: "私钥不能为空。")
            default:
                break
            }
        }
        return nil
    }
}
