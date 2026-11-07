import Foundation

struct LocalFileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let byteSize: Int64?
    let modifiedAt: Date?

    var id: URL { url }

    var iconSystemName: String {
        if isDirectory { return isPackage ? "shippingbox" : "folder" }
        return "doc.text"
    }

    var detailText: String {
        var parts: [String] = []
        parts.append(isDirectory ? String(localized: "文件夹") : sizeText)
        if let modifiedAt {
            parts.append(Self.modifiedFormatter.localizedString(for: modifiedAt, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    var sizeText: String {
        guard let byteSize else { return "--" }
        return Self.byteFormatter.string(fromByteCount: byteSize)
    }

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
