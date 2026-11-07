import Foundation
import SwiftData

@MainActor
final class StorageService {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        let schema = Schema([
            HostProfile.self,
            HostGroup.self,
            CommandSnippet.self,
            CommandRun.self,
            TransferTask.self,
            AppSettings.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    func fetchHosts() throws -> [HostProfile] {
        // Stable, user-controlled order: sort by orderIndex (createdAt as a
        // deterministic tiebreak) so connect/disconnect no longer reshuffles the
        // list — and drag-to-reorder can persist a custom order.
        let descriptor = FetchDescriptor<HostProfile>(
            sortBy: [SortDescriptor(\.orderIndex, order: .forward),
                     SortDescriptor(\.createdAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    /// Persist a new sidebar order. `orderedIDs` is the full host list in the
    /// desired top-to-bottom order; each host's `orderIndex` is set to its
    /// position.
    func persistHostOrder(_ orderedIDs: [UUID]) throws {
        let hosts = try context.fetch(FetchDescriptor<HostProfile>())
        let byID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        for (index, id) in orderedIDs.enumerated() {
            byID[id]?.orderIndex = index
        }
        try context.save()
    }

    func fetchGroups() throws -> [HostGroup] {
        let descriptor = FetchDescriptor<HostGroup>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor)
    }

    func fetchSnippets() throws -> [CommandSnippet] {
        let descriptor = FetchDescriptor<CommandSnippet>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    @discardableResult
    func createGroup(name: String) throws -> HostGroup {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextIndex = (try context.fetch(FetchDescriptor<HostGroup>()).map(\.sortIndex).max() ?? -1) + 1
        let group = HostGroup(name: normalized, sortIndex: nextIndex)
        context.insert(group)
        try context.save()
        return group
    }

    func renameGroup(_ group: HostGroup, name: String) throws {
        group.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try context.save()
    }

    func deleteGroup(_ group: HostGroup) throws {
        let groupID = group.id
        let hosts = try context.fetch(FetchDescriptor<HostProfile>())
        hosts.filter { $0.groupID == groupID }.forEach { $0.groupID = nil }
        context.delete(group)
        try context.save()
    }

    func assignHost(_ host: HostProfile, to groupID: UUID?) throws {
        host.groupID = groupID
        host.updatedAt = Date()
        try context.save()
    }

    @discardableResult
    func createSnippet(title: String, command: String, group: String, requiresConfirmation: Bool) throws -> CommandSnippet {
        let snippet = CommandSnippet(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            group: group.trimmingCharacters(in: .whitespacesAndNewlines),
            requiresConfirmation: requiresConfirmation
        )
        context.insert(snippet)
        try context.save()
        return snippet
    }

    func updateSnippet(_ snippet: CommandSnippet, title: String, command: String, group: String, requiresConfirmation: Bool) throws {
        snippet.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.requiresConfirmation = requiresConfirmation
        snippet.updatedAt = Date()
        try context.save()
    }

    func deleteSnippet(_ snippet: CommandSnippet) throws {
        context.delete(snippet)
        try context.save()
    }

    func fetchTransfers(limit: Int = 12) throws -> [TransferTask] {
        var descriptor = FetchDescriptor<TransferTask>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func fetchCommandRuns(limit: Int = 12) throws -> [CommandRun] {
        var descriptor = FetchDescriptor<CommandRun>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func fetchSettings() throws -> AppSettings {
        var descriptor = FetchDescriptor<AppSettings>()
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let settings = AppSettings()
        context.insert(settings)
        try context.save()
        return settings
    }

    func createHost(
        name: String,
        host: String,
        port: Int,
        username: String,
        authType: HostAuthType,
        credentialValue: String?,
        privateKeyPassphrase: String? = nil,
        credentialStore: CredentialStore
    ) throws -> HostProfile {
        let mainCredentialID = try credentialValue.map {
            try credentialStore.save($0, kind: authType == .password ? .password : .privateKey)
        }
        let passphraseID = try privateKeyPassphrase.map {
            try credentialStore.save($0, kind: .privateKeyPassphrase)
        }

        let profile = HostProfile(
            name: name,
            host: host,
            port: port,
            username: username,
            authType: authType,
            credentialID: mainCredentialID,
            privateKeyPassphraseCredentialID: passphraseID
        )
        context.insert(profile)
        try context.save()
        return profile
    }

    func updateCredential(
        for host: HostProfile,
        value: String,
        kind: CredentialKind,
        credentialStore: CredentialStore
    ) throws {
        let id = try credentialStore.save(value, kind: kind, id: host.credentialID ?? UUID().uuidString)
        host.credentialID = id
        host.updatedAt = Date()
        try context.save()
    }

    func saveHostDraft(_ draft: HostEditorDraft, credentialStore: CredentialStore) throws -> HostProfile {
        guard let port = draft.port else { throw SSHServiceError.invalidPort }
        if let editingHostID = draft.editingHostID,
           let existing = try fetchHost(id: editingHostID) {
            existing.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.groupID = draft.groupID
            existing.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.port = port
            existing.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.authType = draft.authType
            existing.note = draft.note
            existing.downloadMirrorPolicy = draft.downloadMirrorPolicy
            existing.updatedAt = Date()
            try saveDraftCredentials(draft, to: existing, credentialStore: credentialStore)
            try context.save()
            return existing
        }

        // Append new hosts at the end of the user's order.
        let nextOrderIndex = (try context.fetch(FetchDescriptor<HostProfile>())
            .map(\.orderIndex).max() ?? -1) + 1
        let profile = HostProfile(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            groupID: draft.groupID,
            host: draft.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: draft.username.trimmingCharacters(in: .whitespacesAndNewlines),
            authType: draft.authType,
            note: draft.note,
            orderIndex: nextOrderIndex,
            downloadMirrorPolicyRaw: draft.downloadMirrorPolicy?.rawValue
        )
        try saveDraftCredentials(draft, to: profile, credentialStore: credentialStore)
        context.insert(profile)
        try context.save()
        return profile
    }

    func fetchHost(id: UUID) throws -> HostProfile? {
        var descriptor = FetchDescriptor<HostProfile>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func deleteHost(_ host: HostProfile, credentialStore: CredentialStore) throws {
        if let credentialID = host.credentialID {
            try credentialStore.delete(id: credentialID)
        }
        if let passphraseID = host.privateKeyPassphraseCredentialID {
            try credentialStore.delete(id: passphraseID)
        }
        context.delete(host)
        try context.save()
    }

    func updateDefaultLocalDirectoryBookmark(_ bookmarkData: Data?) throws {
        let settings = try fetchSettings()
        settings.defaultLocalDirectoryBookmark = bookmarkData
        settings.updatedAt = Date()
        try context.save()
    }

    func updateSecuritySettings(confirmDangerousActions: Bool? = nil, protectWithTouchID: Bool? = nil) throws {
        let settings = try fetchSettings()
        if let confirmDangerousActions {
            settings.confirmDangerousActions = confirmDangerousActions
        }
        if let protectWithTouchID {
            settings.protectWithTouchID = protectWithTouchID
        }
        settings.updatedAt = Date()
        try context.save()
    }

    func updateDefaultDownloadMirrorPolicy(_ policy: DownloadMirrorPolicy) throws {
        let settings = try fetchSettings()
        settings.downloadMirrorPolicy = policy
        settings.updatedAt = Date()
        try context.save()
    }

    func updateAcmeEmail(_ email: String) throws {
        let settings = try fetchSettings()
        settings.acmeEmail = email
        settings.updatedAt = Date()
        try context.save()
    }

    func updateAppearanceMode(_ mode: AppAppearanceMode) throws {
        let settings = try fetchSettings()
        settings.appearanceMode = mode
        settings.updatedAt = Date()
        try context.save()
    }

    func updateProUnlocked(_ isUnlocked: Bool) throws {
        let settings = try fetchSettings()
        settings.isProUnlocked = isUnlocked
        settings.updatedAt = Date()
        try context.save()
    }

    func updateHostStatus(_ host: HostProfile, status: String, connectedAt: Date? = nil) throws {
        host.lastStatus = status
        host.lastConnectedAt = connectedAt ?? host.lastConnectedAt
        host.updatedAt = Date()
        try context.save()
    }

    @discardableResult
    func recordTransfer(
        hostID: UUID,
        direction: TransferDirection,
        localPath: String,
        remotePath: String,
        status: TransferStatus,
        bytes: Int64,
        errorMessage: String? = nil
    ) throws -> TransferTask {
        let task = TransferTask(
            hostID: hostID,
            direction: direction,
            localPath: localPath,
            remotePath: remotePath,
            status: status,
            progress: status == .succeeded ? 1 : 0,
            bytesTransferred: status == .succeeded ? bytes : 0,
            totalBytes: bytes,
            finishedAt: Date(),
            errorMessage: errorMessage
        )
        context.insert(task)
        try context.save()
        return task
    }

    @discardableResult
    func recordCommandRun(
        hostID: UUID,
        snippetID: UUID? = nil,
        command: String,
        stdout: String,
        exitCode: Int = 0,
        duration: TimeInterval
    ) throws -> CommandRun {
        let run = CommandRun(
            hostID: hostID,
            snippetID: snippetID,
            command: command,
            stdoutPreview: String(stdout.prefix(2000)),
            exitCode: exitCode,
            duration: duration
        )
        context.insert(run)
        try context.save()
        return run
    }

    func clearTransferAndCommandHistory() throws {
        let transfers = try context.fetch(FetchDescriptor<TransferTask>())
        for transfer in transfers {
            context.delete(transfer)
        }
        let commandRuns = try context.fetch(FetchDescriptor<CommandRun>())
        for run in commandRuns {
            context.delete(run)
        }
        try context.save()
    }

    private func saveDraftCredentials(
        _ draft: HostEditorDraft,
        to host: HostProfile,
        credentialStore: CredentialStore
    ) throws {
        switch draft.authType {
        case .password:
            if !draft.password.isEmpty {
                host.credentialID = try credentialStore.save(
                    draft.password,
                    kind: .password,
                    id: host.credentialID ?? UUID().uuidString
                )
            }
            if let passphraseID = host.privateKeyPassphraseCredentialID {
                try credentialStore.delete(id: passphraseID)
                host.privateKeyPassphraseCredentialID = nil
            }
        case .privateKey:
            if !draft.privateKeyText.isEmpty {
                host.credentialID = try credentialStore.save(
                    draft.privateKeyText,
                    kind: .privateKey,
                    id: host.credentialID ?? UUID().uuidString
                )
            }
            if !draft.privateKeyPassphrase.isEmpty {
                host.privateKeyPassphraseCredentialID = try credentialStore.save(
                    draft.privateKeyPassphrase,
                    kind: .privateKeyPassphrase,
                    id: host.privateKeyPassphraseCredentialID ?? UUID().uuidString
                )
            }
        }
    }

    /// Removes the placeholder server inserted by early builds. Demo state now
    /// lives exclusively in ScreenshotRenderer and must never enter user data.
    func removeLegacySampleDataIfNeeded() throws {
        let allHosts = try context.fetch(FetchDescriptor<HostProfile>())
        let legacyHosts = allHosts.filter {
            $0.name == "prod-web-01"
                && $0.host == "203.0.113.24"
                && $0.port == 22
                && $0.username == "deploy"
                && $0.tags == ["nginx", "web"]
                && $0.note == "Demo data for local UI validation."
                && $0.credentialID == nil
                && $0.privateKeyPassphraseCredentialID == nil
        }
        guard !legacyHosts.isEmpty else { return }

        let legacyHostIDs = Set(legacyHosts.map(\.id))
        let legacyGroupIDs = Set(legacyHosts.compactMap(\.groupID))
        for host in legacyHosts {
            context.delete(host)
        }

        let remainingGroupIDs = Set(
            allHosts
                .filter { !legacyHostIDs.contains($0.id) }
                .compactMap(\.groupID)
        )
        let groups = try context.fetch(FetchDescriptor<HostGroup>())
        for group in groups where legacyGroupIDs.contains(group.id)
            && !remainingGroupIDs.contains(group.id)
            && group.name == "Production" {
            context.delete(group)
        }

        let snippets = try context.fetch(FetchDescriptor<CommandSnippet>())
        for snippet in snippets where snippet.title == "Disk usage"
            && snippet.command == "df -h"
            && snippet.group == "Inspect" {
            context.delete(snippet)
        }
        try context.save()
    }
}
