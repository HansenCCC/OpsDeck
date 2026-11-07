import Foundation
#if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
import Citadel
import Crypto
import NIO
#endif

struct SFTPListResult: Sendable, Equatable {
    let path: String
    let items: [RemoteFileItem]
}

struct SFTPTransferResult: Sendable, Equatable {
    let remotePath: String
    let byteCount: Int
}

struct SFTPPartialReadResult: Sendable, Equatable {
    let remotePath: String
    let data: Data
    let fileByteCount: UInt64
    let loadedByteCount: UInt64
    let offset: UInt64
}

enum SFTPServiceError: LocalizedError, Sendable, Equatable {
    case citadelNotLinked
    case invalidPath
    case unsupportedWithoutCitadel
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .citadelNotLinked:
            return "Citadel is not linked. Regenerate the Xcode project with Citadel enabled."
        case .invalidPath:
            return "The remote path is invalid."
        case .unsupportedWithoutCitadel:
            return "SFTP needs the Citadel package."
        case .unknown(let message):
            return message
        }
    }
}

actor SFTPService {
    func listDirectory(path: String, config: SSHConnectionConfig) async throws -> SFTPListResult {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        return try await withSFTPClient(config: config) { sftp in
            let realPath = try await sftp.getRealPath(atPath: normalized(path))
            let names = try await sftp.listDirectory(atPath: realPath)
            var items: [RemoteFileItem] = []
            for component in names.flatMap(\.components) {
                guard component.filename != ".", component.filename != ".." else { continue }
                items.append(makeRemoteFileItem(component, parentPath: realPath))
            }
            items.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return SFTPListResult(path: realPath, items: items)
        }
        #else
        throw SFTPServiceError.citadelNotLinked
        #endif
    }

    func upload(
        data: Data,
        to remotePath: String,
        permissions: UInt32? = nil,
        config: SSHConnectionConfig
    ) async throws -> SFTPTransferResult {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        let path = normalized(remotePath)
        guard !path.isEmpty else { throw SFTPServiceError.invalidPath }
        return try await withSFTPClient(config: config) { sftp in
            try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await file.write(buffer)
            }
            if let permissions {
                var attributes = SFTPFileAttributes.none
                attributes.permissions = permissions
                try await sftp.setAttributes(at: path, to: attributes)
            }
            return SFTPTransferResult(remotePath: path, byteCount: data.count)
        }
        #else
        throw SFTPServiceError.citadelNotLinked
        #endif
    }

    func uploadReplacing(
        data: Data,
        to remotePath: String,
        permissions: UInt32? = nil,
        config: SSHConnectionConfig
    ) async throws -> SFTPTransferResult {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        let path = normalized(remotePath)
        let temporaryPath = replacementTemporaryPath(for: path)
        guard !path.isEmpty, !temporaryPath.isEmpty, path != temporaryPath else {
            throw SFTPServiceError.invalidPath
        }

        return try await withSFTPClient(config: config) { sftp in
            let existingAttributes = try? await sftp.getAttributes(at: path)
            let finalPermissions = permissions ?? existingAttributes?.permissions.map { $0 & 0o777 }

            do {
                try await self.write(data: data, to: temporaryPath, permissions: finalPermissions, sftp: sftp)
                try await self.replace(at: path, with: temporaryPath, sftp: sftp)
            } catch {
                try? await sftp.remove(at: temporaryPath)
                throw error
            }

            return SFTPTransferResult(remotePath: path, byteCount: data.count)
        }
        #else
        throw SFTPServiceError.citadelNotLinked
        #endif
    }

    func download(remotePath: String, config: SSHConnectionConfig) async throws -> Data {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        let path = normalized(remotePath)
        guard !path.isEmpty else { throw SFTPServiceError.invalidPath }
        return try await withSFTPClient(config: config) { sftp in
            let buffer = try await sftp.withFile(filePath: path, flags: .read) { file in
                try await file.readAll()
            }
            return Data(buffer.readableBytesView)
        }
        #else
        throw SFTPServiceError.citadelNotLinked
        #endif
    }

    func remove(remotePath: String, config: SSHConnectionConfig) async throws {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        let path = normalized(remotePath)
        guard !path.isEmpty else { throw SFTPServiceError.invalidPath }
        try await withSFTPClient(config: config) { sftp in
            try await sftp.remove(at: path)
        }
        #else
        throw SFTPServiceError.citadelNotLinked
        #endif
    }

    func removeDirectory(remotePath: String, config: SSHConnectionConfig) async throws {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        let path = normalized(remotePath)
        guard !path.isEmpty else { throw SFTPServiceError.invalidPath }
        try await withSFTPClient(config: config) { sftp in
            try await sftp.rmdir(at: path)
        }
        #else
        throw SFTPServiceError.citadelNotLinked
        #endif
    }

    func createDirectory(remotePath: String, config: SSHConnectionConfig) async throws {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        let path = normalized(remotePath)
        guard !path.isEmpty else { throw SFTPServiceError.invalidPath }
        try await withSFTPClient(config: config) { sftp in
            var attributes = SFTPFileAttributes.none
            attributes.permissions = 0o755
            try await sftp.createDirectory(atPath: path, attributes: attributes)
        }
        #else
        throw SFTPServiceError.citadelNotLinked
        #endif
    }

    func rename(remotePath: String, to newRemotePath: String, config: SSHConnectionConfig) async throws {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        let oldPath = normalized(remotePath)
        let newPath = normalized(newRemotePath)
        guard !oldPath.isEmpty, !newPath.isEmpty else { throw SFTPServiceError.invalidPath }
        try await withSFTPClient(config: config) { sftp in
            try await sftp.rename(at: oldPath, to: newPath)
        }
        #else
        throw SFTPServiceError.citadelNotLinked
        #endif
    }

    func downloadTail(remotePath: String, maxBytes: UInt64, config: SSHConnectionConfig) async throws -> SFTPPartialReadResult {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        let path = normalized(remotePath)
        guard !path.isEmpty else { throw SFTPServiceError.invalidPath }
        return try await withSFTPClient(config: config) { sftp in
            let attributes = try await sftp.getAttributes(at: path)
            let fileSize = attributes.size ?? 0
            let loadedSize = min(fileSize, maxBytes)
            let offset = fileSize > loadedSize ? fileSize - loadedSize : 0
            guard loadedSize > 0 else {
                return SFTPPartialReadResult(
                    remotePath: path,
                    data: Data(),
                    fileByteCount: fileSize,
                    loadedByteCount: 0,
                    offset: 0
                )
            }
            let buffer = try await sftp.withFile(filePath: path, flags: .read) { file in
                try await file.read(from: offset, length: UInt32(min(loadedSize, UInt64(UInt32.max))))
            }
            return SFTPPartialReadResult(
                remotePath: path,
                data: Data(buffer.readableBytesView),
                fileByteCount: fileSize,
                loadedByteCount: UInt64(buffer.readableBytes),
                offset: offset
            )
        }
        #else
        throw SFTPServiceError.citadelNotLinked
        #endif
    }
}

private func normalized(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "." : trimmed
}

private func joinedRemotePath(parent: String, child: String) -> String {
    if parent == "/" { return "/" + child }
    return parent.hasSuffix("/") ? parent + child : parent + "/" + child
}

private func replacementTemporaryPath(for path: String) -> String {
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmed.isEmpty else { return "" }
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard let name = components.last, name != ".", name != ".." else { return "" }
    let temporaryName = ".\(name).opsdeck-\(UUID().uuidString).tmp"
    let isAbsolute = path.hasPrefix("/")
    let parentComponents = components.dropLast()
    if parentComponents.isEmpty {
        return isAbsolute ? "/\(temporaryName)" : temporaryName
    }
    let parent = parentComponents.joined(separator: "/")
    return isAbsolute ? "/\(parent)/\(temporaryName)" : "\(parent)/\(temporaryName)"
}

#if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
private extension SFTPService {
    func write(data: Data, to path: String, permissions: UInt32?, sftp: SFTPClient) async throws {
        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await file.write(buffer)
        }
        if let permissions {
            var attributes = SFTPFileAttributes.none
            attributes.permissions = permissions
            try await sftp.setAttributes(at: path, to: attributes)
        }
    }

    func replace(at path: String, with temporaryPath: String, sftp: SFTPClient) async throws {
        // Fast path: a plain rename succeeds when the destination doesn't exist
        // (or the server's rename overwrites in place).
        do {
            try await sftp.rename(at: temporaryPath, to: path)
            return
        } catch {
            // The destination most likely already exists and this SFTP server
            // refuses to overwrite via rename. Fall through to a backup-based
            // swap that never leaves both the original and the new copy missing.
        }

        // Move the original aside first. If we can't preserve it, abort WITHOUT
        // touching it so the user's existing file stays intact.
        let backupPath = "\(path).opsdeck-bak-\(UUID().uuidString)"
        try await sftp.rename(at: path, to: backupPath)
        do {
            try await sftp.rename(at: temporaryPath, to: path)
        } catch {
            // Restore the original and rethrow; the caller cleans up the temp file.
            try? await sftp.rename(at: backupPath, to: path)
            throw error
        }
        // New file is in place — drop the backup (best-effort).
        try? await sftp.remove(at: backupPath)
    }

    func withSFTPClient<Result: Sendable>(
        config: SSHConnectionConfig,
        operation: @escaping @Sendable (SFTPClient) async throws -> Result
    ) async throws -> Result {
        let authentication = try config.authentication.makeCitadelAuthMethod()
        var settings = SSHClientSettings(
            host: config.host,
            port: config.port,
            authenticationMethod: {
                authentication
            },
            hostKeyValidator: KnownHostStore.shared.validator(host: config.host, port: config.port)
        )
        settings.connectTimeout = .seconds(config.connectTimeoutSeconds)

        let client: SSHClient
        do {
            client = try await SSHClient.connect(to: settings)
        } catch {
            throw mapSFTPError(error, config: config)
        }

        do {
            let result = try await client.withSFTP { sftp in
                try await operation(sftp)
            }
            try? await client.close()
            return result
        } catch {
            try? await client.close()
            throw mapSFTPError(error, config: config)
        }
    }

    func mapSFTPError(_ error: Error, config: SSHConnectionConfig) -> Error {
        if let challenge = KnownHostStore.shared.pendingChallenge(host: config.host, port: config.port) {
            switch challenge.kind {
            case .firstUse:
                return SSHServiceError.hostKeyTrustRequired(challenge)
            case .changed:
                return SSHServiceError.hostKeyChanged(challenge)
            }
        }
        if let sshError = error as? SSHServiceError { return sshError }
        let message = String(describing: error)
        let lower = message.lowercased()
        if lower.contains("authentication") || lower.contains("permission denied") {
            return SSHServiceError.authenticationFailed
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return SSHServiceError.connectionTimeout
        }
        if lower.contains("unreachable") || lower.contains("refused") || lower.contains("network") {
            return SSHServiceError.hostUnreachable
        }
        return SFTPServiceError.unknown(message)
    }
}

private func makeRemoteFileItem(_ component: SFTPPathComponent, parentPath: String) -> RemoteFileItem {
    let permissions = component.attributes.permissions
    let kind = remoteFileKind(permissions: permissions, longName: component.longname)
    return RemoteFileItem(
        path: joinedRemotePath(parent: parentPath, child: component.filename),
        name: component.filename,
        kind: kind,
        byteSize: component.attributes.size,
        permissions: permissions,
        modifiedAt: component.attributes.accessModificationTime?.modificationTime,
        longName: component.longname
    )
}

private func remoteFileKind(permissions: UInt32?, longName: String) -> RemoteFileKind {
    if let permissions {
        let fileType = permissions & 0o170000
        if fileType == 0o040000 { return .directory }
        if fileType == 0o120000 { return .symbolicLink }
        if fileType == 0o100000 { return .file }
    }

    if longName.hasPrefix("d") { return .directory }
    if longName.hasPrefix("l") { return .symbolicLink }
    if longName.hasPrefix("-") { return .file }
    return .unknown
}
#endif
