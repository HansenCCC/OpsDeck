import Foundation

enum DangerousActionKind: Equatable, Sendable {
    case deleteRemote([RemoteFileItem])
    case createRemoteFile(remotePath: String)
    case uploadOverwrite(localURL: URL, byteSize: Int64?, remotePath: String)
    case compressRemote([RemoteFileItem], archivePath: String)
    case saveRemoteText
    case runCommand(command: String, snippetID: UUID?)
}

struct DangerousActionRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let kind: DangerousActionKind
    /// The host whose session created this request. Confirmation routes back to
    /// this host's session so a destructive action never executes against a
    /// different server the user may have switched to while the modal was open.
    var hostID: UUID? = nil

    var title: String {
        switch kind {
        case .deleteRemote:
            return String(localized: "确认删除")
        case .createRemoteFile:
            return String(localized: "确认覆盖")
        case .uploadOverwrite:
            return String(localized: "确认覆盖")
        case .compressRemote:
            return String(localized: "确认压缩")
        case .saveRemoteText:
            return String(localized: "确认保存远端文件")
        case .runCommand:
            return String(localized: "确认执行命令")
        }
    }

    var message: String {
        switch kind {
        case .deleteRemote(let items):
            if items.count > 1 {
                return String(localized: "要删除远端服务器上选中的 \(items.count) 个项目吗？其中的文件夹会被递归删除，此操作无法撤销。")
            }
            guard let item = items.first else {
                return String(localized: "没有可删除的远端项目。")
            }
            if item.isDirectory {
                return String(localized: "要递归删除远端服务器上的文件夹 \(item.path) 以及其中所有内容吗？此操作无法撤销。")
            }
            return String(localized: "要删除远端服务器上的 \(item.path) 吗？此操作无法撤销。")
        case .createRemoteFile(let remotePath):
            return String(localized: "要创建空文件并覆盖远端服务器上的 \(remotePath) 吗？")
        case .uploadOverwrite(_, _, let remotePath):
            return String(localized: "要覆盖远端服务器上的 \(remotePath) 吗？")
        case .compressRemote(let items, let archivePath):
            if items.count > 1 {
                return String(localized: "要把选中的 \(items.count) 个远端项目压缩为 \(archivePath) 吗？如果目标已存在会被覆盖。")
            }
            let path = items.first?.path ?? String(localized: "所选项目")
            return String(localized: "要在远端服务器上把 \(path) 压缩为 \(archivePath) 吗？如果目标已存在会被覆盖。")
        case .saveRemoteText:
            return String(localized: "要把修改保存回远端文件吗？")
        case .runCommand(let command, _):
            return command
        }
    }

    var confirmTitle: String {
        switch kind {
        case .deleteRemote:
            return String(localized: "删除")
        case .createRemoteFile:
            return String(localized: "覆盖")
        case .uploadOverwrite:
            return String(localized: "覆盖")
        case .compressRemote:
            return String(localized: "压缩")
        case .saveRemoteText:
            return String(localized: "保存")
        case .runCommand:
            return String(localized: "执行")
        }
    }
}
