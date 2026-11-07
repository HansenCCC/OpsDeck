import Foundation
import SwiftData

enum HostAuthType: String, CaseIterable, Codable, Sendable {
    case password
    case privateKey
}

@Model
final class HostProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var groupID: UUID?
    var host: String
    var port: Int
    var username: String
    var authTypeRaw: String
    var credentialID: String?
    var privateKeyPassphraseCredentialID: String?
    var identityFileBookmark: Data?
    var tagsRaw: String
    var note: String
    var lastConnectedAt: Date?
    var lastStatus: String
    var createdAt: Date
    var updatedAt: Date
    /// User-controlled sidebar sort position. Sorting the list by this (instead of
    /// `updatedAt`) keeps the order stable across connect/disconnect and lets the
    /// user drag rows to reorder. Default 0; new hosts are appended (max+1).
    var orderIndex: Int = 0
    /// Per-host override for the download-source policy. `nil` = follow the global
    /// default in `AppSettings.downloadMirrorPolicy`. Stored as the enum rawValue.
    var downloadMirrorPolicyRaw: String? = nil

    init(
        id: UUID = UUID(),
        name: String,
        groupID: UUID? = nil,
        host: String,
        port: Int = 22,
        username: String,
        authType: HostAuthType = .password,
        credentialID: String? = nil,
        privateKeyPassphraseCredentialID: String? = nil,
        identityFileBookmark: Data? = nil,
        tags: [String] = [],
        note: String = "",
        lastConnectedAt: Date? = nil,
        lastStatus: String = "disconnected",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        orderIndex: Int = 0,
        downloadMirrorPolicyRaw: String? = nil
    ) {
        self.id = id
        self.name = name
        self.groupID = groupID
        self.host = host
        self.port = port
        self.username = username
        self.authTypeRaw = authType.rawValue
        self.credentialID = credentialID
        self.privateKeyPassphraseCredentialID = privateKeyPassphraseCredentialID
        self.identityFileBookmark = identityFileBookmark
        self.tagsRaw = tags.joined(separator: ",")
        self.note = note
        self.lastConnectedAt = lastConnectedAt
        self.lastStatus = lastStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.orderIndex = orderIndex
        self.downloadMirrorPolicyRaw = downloadMirrorPolicyRaw
    }

    var authType: HostAuthType {
        get { HostAuthType(rawValue: authTypeRaw) ?? .password }
        set { authTypeRaw = newValue.rawValue }
    }

    /// The host's explicit policy, or `nil` to follow the global default.
    var downloadMirrorPolicy: DownloadMirrorPolicy? {
        get { downloadMirrorPolicyRaw.flatMap(DownloadMirrorPolicy.init(rawValue:)) }
        set { downloadMirrorPolicyRaw = newValue?.rawValue }
    }

    var tags: [String] {
        get { tagsRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { tagsRaw = newValue.joined(separator: ",") }
    }

    var endpoint: String {
        "\(host):\(port)"
    }
}
