import Foundation
import SwiftData

enum TransferDirection: String, Codable, Sendable {
    case upload
    case download

    var displayName: String {
        switch self {
        case .upload:
            return String(localized: "上传")
        case .download:
            return String(localized: "下载")
        }
    }
}

enum TransferStatus: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .queued:
            return String(localized: "等待中")
        case .running:
            return String(localized: "进行中")
        case .succeeded:
            return String(localized: "已完成")
        case .failed:
            return String(localized: "失败")
        case .cancelled:
            return String(localized: "已取消")
        }
    }
}

@Model
final class TransferTask {
    @Attribute(.unique) var id: UUID
    var hostID: UUID
    var directionRaw: String
    var localPath: String
    var remotePath: String
    var statusRaw: String
    var progress: Double
    var bytesTransferred: Int64
    var totalBytes: Int64
    var startedAt: Date
    var finishedAt: Date?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        hostID: UUID,
        direction: TransferDirection,
        localPath: String,
        remotePath: String,
        status: TransferStatus = .queued,
        progress: Double = 0,
        bytesTransferred: Int64 = 0,
        totalBytes: Int64 = 0,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.directionRaw = direction.rawValue
        self.localPath = localPath
        self.remotePath = remotePath
        self.statusRaw = status.rawValue
        self.progress = progress
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }

    var direction: TransferDirection {
        get { TransferDirection(rawValue: directionRaw) ?? .upload }
        set { directionRaw = newValue.rawValue }
    }

    var status: TransferStatus {
        get { TransferStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }
}
