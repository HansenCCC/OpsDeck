import AppKit
import Foundation

struct LocalDirectorySelection {
    let url: URL
    let bookmarkData: Data
}

enum LocalFileServiceError: LocalizedError {
    case bookmarkStale
    case directoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .bookmarkStale:
            return String(localized: "已保存的文件夹权限已过期，请重新选择。")
        case .directoryUnavailable(let path):
            return String(localized: "无法读取本地文件夹：\(path)")
        }
    }
}

@MainActor
final class LocalFileService {
    private var scopedURL: URL?
    private var isAccessingScopedURL = false

    func chooseDirectory() throws -> LocalDirectorySelection? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选择用于 OpsDeck 传输的本地文件夹。")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let bookmark = try makeBookmark(for: url)
        activateSecurityScope(for: url)
        return LocalDirectorySelection(url: url, bookmarkData: bookmark)
    }

    func chooseDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "下载")
        panel.message = String(localized: "选择远端文件或文件夹的保存位置。")
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseUploadFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "上传")
        panel.message = String(localized: "选择要上传到当前远端目录的文件或文件夹。")
        return panel.runModal() == .OK ? panel.url : nil
    }

    func restoreDirectory(from bookmarkData: Data) throws -> LocalDirectorySelection {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw LocalFileServiceError.bookmarkStale }

        activateSecurityScope(for: url)
        return LocalDirectorySelection(url: url, bookmarkData: bookmarkData)
    }

    func listDirectory(at url: URL) throws -> [LocalFileItem] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        let items = try contents.map { fileURL in
            let values = try fileURL.resourceValues(forKeys: keys)
            let isDirectory = values.isDirectory ?? false
            let isPackage = values.isPackage ?? false
            let size = values.fileSize ?? values.totalFileAllocatedSize
            return LocalFileItem(
                url: fileURL,
                name: fileURL.lastPathComponent,
                isDirectory: isDirectory,
                isPackage: isPackage,
                byteSize: size.map(Int64.init),
                modifiedAt: values.contentModificationDate
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func stopAccessingDirectory() {
        if isAccessingScopedURL {
            scopedURL?.stopAccessingSecurityScopedResource()
        }
        scopedURL = nil
        isAccessingScopedURL = false
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func activateSecurityScope(for url: URL) {
        if scopedURL != url {
            stopAccessingDirectory()
        }
        scopedURL = url
        isAccessingScopedURL = url.startAccessingSecurityScopedResource()
    }
}
