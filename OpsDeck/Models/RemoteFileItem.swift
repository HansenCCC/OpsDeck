import Foundation
import UniformTypeIdentifiers

enum RemoteFileKind: String, Sendable, Codable {
    case file
    case directory
    case symbolicLink
    case unknown
}

struct RemoteFileItem: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let kind: RemoteFileKind
    let byteSize: UInt64?
    let permissions: UInt32?
    let modifiedAt: Date?
    let longName: String
    var childCount: Int? = nil

    var id: String { path }

    var isDirectory: Bool { kind == .directory }

    var isEditableTextFile: Bool {
        guard kind == .file else { return false }
        let normalizedName = name.lowercased()
        if Self.textFilenames.contains(normalizedName)
            || Self.textFilenamePrefixes.contains(where: normalizedName.hasPrefix) {
            return true
        }
        let ext = fileExtension
        guard !ext.isEmpty else { return false }
        if Self.textExtensions.contains(ext) {
            return true
        }
        return uniformType?.conforms(to: .text) == true
    }

    var isSystemPreviewableFile: Bool {
        guard kind == .file else { return false }
        let ext = fileExtension
        guard !ext.isEmpty else { return false }
        if Self.previewExtensions.contains(ext) {
            return true
        }
        guard let uniformType else { return false }
        return uniformType.conforms(to: .image)
            || uniformType.conforms(to: .pdf)
            || uniformType.conforms(to: .movie)
            || uniformType.conforms(to: .audio)
    }

    var canOpenByDoubleClick: Bool {
        isDirectory || isEditableTextFile || isSystemPreviewableFile
    }

    var iconSystemName: String {
        switch kind {
        case .directory:
            return "folder"
        case .symbolicLink:
            return "link"
        case .file:
            return "doc.text"
        case .unknown:
            return "questionmark.square"
        }
    }

    var permissionsText: String {
        guard let permissions else { return "---------" }
        return String(format: "%04o", permissions & 0o7777)
    }

    /// SFTP's long-name field follows the common `ls -l` layout. These values are
    /// best-effort display metadata; mutations still target the canonical path.
    var ownerName: String? {
        longNameFields.count > 2 ? longNameFields[2] : nil
    }

    var groupName: String? {
        longNameFields.count > 3 ? longNameFields[3] : nil
    }

    var symbolicLinkTarget: String? {
        guard kind == .symbolicLink,
              let range = longName.range(of: " -> ") else { return nil }
        return String(longName[range.upperBound...])
    }

    private var longNameFields: [String] {
        longName.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var detailText: String {
        var parts: [String] = []
        if isDirectory {
            if let childCount {
                parts.append(String(localized: "\(childCount) 项"))
            } else {
                parts.append(String(localized: "文件夹"))
            }
        } else if let byteSize {
            parts.append(Self.byteFormatter.string(fromByteCount: Int64(byteSize)))
        } else {
            parts.append("--")
        }
        parts.append(permissionsText)
        if let modifiedAt {
            parts.append(Self.modifiedFormatter.localizedString(for: modifiedAt, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    func withChildCount(_ count: Int?) -> RemoteFileItem {
        var item = self
        item.childCount = count
        return item
    }

    private var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    private var uniformType: UTType? {
        UTType(filenameExtension: fileExtension)
    }

    private static let textFilenames: Set<String> = [
        ".bash_history", ".bash_logout", ".bash_profile", ".bashrc", ".dockerignore", ".editorconfig",
        ".env", ".gitattributes", ".gitconfig", ".gitignore", ".npmrc", ".profile", ".viminfo",
        ".vimrc", ".wget-hsts", ".yarnrc", ".zprofile", ".zsh_history", ".zshrc", "authorized_keys", "dockerfile",
        "known_hosts", "license", "makefile", "readme"
    ]

    private static let textFilenamePrefixes = [".env."]

    private static let textExtensions: Set<String> = [
        "bash", "c", "cfg", "conf", "cpp", "css", "csv", "env", "go", "h", "htm", "html",
        "ini", "java", "js", "json", "log", "lua", "m", "md", "mm", "php", "plist",
        "properties", "py", "rb", "rs", "sh", "sql", "swift", "toml", "ts", "tsx",
        "txt", "vue", "xml", "yaml", "yml", "zsh"
    ]

    private static let previewExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "m4a", "m4v", "mov",
        "mp3", "mp4", "pdf", "png", "svg", "tif", "tiff", "wav", "webp"
    ]

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private static let modifiedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
