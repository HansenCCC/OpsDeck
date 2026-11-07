import Foundation
#if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
import Citadel
import Crypto
import NIO
#endif

struct SSHConnectionConfig: Sendable, Equatable {
    var host: String
    var port: Int
    var authentication: SSHAuthConfig
    var connectTimeoutSeconds: Int64

    init(
        host: String,
        port: Int = 22,
        authentication: SSHAuthConfig,
        connectTimeoutSeconds: Int64 = 15
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.authentication = authentication
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    var displayName: String {
        "\(authentication.username)@\(host):\(port)"
    }
}

enum SSHAuthConfig: Sendable, Equatable {
    case password(username: String, password: String)
    case privateKey(username: String, key: String, passphrase: String?)

    var username: String {
        switch self {
        case .password(let username, _):
            username
        case .privateKey(let username, _, _):
            username
        }
    }

    var redactedDescription: String {
        switch self {
        case .password(let username, _):
            "password(\(username), redacted)"
        case .privateKey(let username, _, _):
            "privateKey(\(username), redacted)"
        }
    }

    /// The login password, if this is password auth. Used to prime `sudo -S` for
    /// privileged writes (on most servers the login password is the sudo password).
    var password: String? {
        switch self {
        case .password(_, let password):
            password
        case .privateKey:
            nil
        }
    }

}

struct SSHCommandResult: Sendable, Equatable {
    var command: String
    var stdout: String
    var duration: TimeInterval
}

enum SSHCommandStreamSource: Sendable, Equatable {
    case stdout
    case stderr
}

struct SSHCommandStreamChunk: Sendable, Equatable {
    var source: SSHCommandStreamSource
    var bytes: [UInt8]
}

enum SSHServiceError: LocalizedError, Sendable, Equatable {
    case invalidHost
    case invalidPort
    case connectionTimeout
    case authenticationFailed
    case hostUnreachable
    case commandFailed(String)
    case invalidPrivateKey
    case hostKeyTrustRequired(KnownHostChallenge)
    case hostKeyChanged(KnownHostChallenge)
    case citadelNotLinked
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return String(localized: "服务器地址不能为空。")
        case .invalidPort:
            return String(localized: "端口必须在 1 到 65535 之间。")
        case .connectionTimeout:
            return String(localized: "连接超时，请检查服务器地址、端口和网络。")
        case .authenticationFailed:
            return String(localized: "认证失败，请检查用户名、密码或私钥。")
        case .hostUnreachable:
            return String(localized: "无法访问服务器，请检查地址和防火墙。")
        case .commandFailed(let message):
            return String(localized: "命令执行失败：\(message)")
        case .invalidPrivateKey:
            return String(localized: "无法解析私钥。当前支持 OpenSSH 格式的 Ed25519 和 RSA 私钥，请检查私钥内容和口令。")
        case .hostKeyTrustRequired(let challenge):
            return String(localized: "需要先确认服务器 \(challenge.endpoint) 的 Host Key 指纹。")
        case .hostKeyChanged(let challenge):
            return String(localized: "服务器 \(challenge.endpoint) 的 Host Key 已变化，连接已阻止。")
        case .citadelNotLinked:
            return String(localized: "SSH 组件未链接，请重新生成工程后再试。")
        case .unknown(let message):
            return message
        }
    }
}

actor SSHService {
#if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
    private struct CommandConnectionKey: Hashable {
        var host: String
        var port: Int
        var username: String
    }

    private struct CachedCommandClient {
        var config: SSHConnectionConfig
        var client: SSHClient
    }

    /// Short control commands share one SSH transport per connected host. Opening
    /// a fresh TCP + SSH session for every database query adds more latency than
    /// the query itself on a typical WAN connection.
    private var commandClients: [CommandConnectionKey: CachedCommandClient] = [:]
#endif

    func runConnectionTest(config: SSHConnectionConfig) async throws -> SSHCommandResult {
        try await executeCommand("uname -a", on: config, maxResponseSize: 16 * 1024)
    }

    func executeCommand(
        _ command: String,
        on config: SSHConnectionConfig,
        maxResponseSize: Int = 512 * 1024
    ) async throws -> SSHCommandResult {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        return try await executeCommandWithCitadel(command, on: config, maxResponseSize: maxResponseSize)
        #else
        throw SSHServiceError.citadelNotLinked
        #endif
    }

    func executeCommandStream(
        _ command: String,
        on config: SSHConnectionConfig,
        maxResponseSize: Int = 2 * 1024 * 1024
    ) -> AsyncThrowingStream<SSHCommandStreamChunk, Error> {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        return executeCommandStreamWithCitadel(
            command,
            on: config,
            maxResponseSize: maxResponseSize
        )
        #else
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: SSHServiceError.citadelNotLinked)
        }
        #endif
    }

    func disconnect(config: SSHConnectionConfig) async {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        let key = commandConnectionKey(for: config)
        guard let cached = commandClients.removeValue(forKey: key) else { return }
        try? await cached.client.close()
        #endif
    }

    func disconnectAll() async {
        #if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
        let clients = commandClients.values.map(\.client)
        commandClients.removeAll()
        for client in clients {
            try? await client.close()
        }
        #endif
    }

    private func validate(_ config: SSHConnectionConfig) throws {
        guard !config.host.isEmpty else { throw SSHServiceError.invalidHost }
        guard (1...65535).contains(config.port) else { throw SSHServiceError.invalidPort }
    }
}

#if canImport(Citadel) && canImport(NIO) && canImport(Crypto)
extension SSHAuthConfig {
    func makeCitadelAuthMethod() throws -> SSHAuthenticationMethod {
        switch self {
        case .password(let username, let password):
            return .passwordBased(username: username, password: password)
        case .privateKey(let username, let key, let passphrase):
            let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            if let ed25519 = try? Curve25519.Signing.PrivateKey(
                sshEd25519: key,
                decryptionKey: decryptionKey
            ) {
                return .ed25519(username: username, privateKey: ed25519)
            }
            if let rsa = try? Insecure.RSA.PrivateKey(
                sshRsa: key,
                decryptionKey: decryptionKey
            ) {
                return .rsa(username: username, privateKey: rsa)
            }
            throw SSHServiceError.invalidPrivateKey
        }
    }
}

private extension SSHService {
    private func commandConnectionKey(for config: SSHConnectionConfig) -> CommandConnectionKey {
        CommandConnectionKey(
            host: config.host,
            port: config.port,
            username: config.authentication.username
        )
    }

    private func commandClient(for config: SSHConnectionConfig) async throws -> SSHClient {
        let key = commandConnectionKey(for: config)
        if let cached = commandClients[key], cached.config == config, cached.client.isConnected {
            return cached.client
        }

        if let stale = commandClients.removeValue(forKey: key) {
            try? await stale.client.close()
        }

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
            throw mapConnectionError(error, config: config)
        }

        // The actor is re-entrant while connecting. If another command won the
        // race and installed an equivalent client, keep that one and close ours.
        if let cached = commandClients[key], cached.config == config, cached.client.isConnected {
            try? await client.close()
            return cached.client
        }
        commandClients[key] = CachedCommandClient(config: config, client: client)
        return client
    }

    func executeCommandStreamWithCitadel(
        _ command: String,
        on config: SSHConnectionConfig,
        maxResponseSize: Int
    ) -> AsyncThrowingStream<SSHCommandStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    try Task.checkCancellation()
                    try validate(config)
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
                        throw mapConnectionError(error, config: config)
                    }

                    do {
                        let outputStream = try await client.executeCommandStream(Self.posixWrapped(command))
                        var receivedBytes = 0
                        for try await output in outputStream {
                            try Task.checkCancellation()
                            var buffer: ByteBuffer
                            let source: SSHCommandStreamSource
                            switch output {
                            case .stdout(let stdout):
                                buffer = stdout
                                source = .stdout
                            case .stderr(let stderr):
                                buffer = stderr
                                source = .stderr
                            }
                            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
                            guard !bytes.isEmpty else { continue }
                            receivedBytes += bytes.count
                            guard receivedBytes <= maxResponseSize else {
                                throw SSHServiceError.commandFailed(String(localized: "命令输出超过 \(maxResponseSize) 字节限制。"))
                            }
                            continuation.yield(SSHCommandStreamChunk(source: source, bytes: bytes))
                        }
                        try? await client.close()
                        continuation.finish()
                    } catch is CancellationError {
                        try? await client.close()
                        throw CancellationError()
                    } catch {
                        try? await client.close()
                        if let serviceError = error as? SSHServiceError {
                            throw serviceError
                        }
                        throw mapCommandError(error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                worker.cancel()
            }
        }
    }

    func executeCommandWithCitadel(
        _ command: String,
        on config: SSHConnectionConfig,
        maxResponseSize: Int
    ) async throws -> SSHCommandResult {
        try validate(config)
        let startedAt = Date()
        let key = commandConnectionKey(for: config)
        let client = try await commandClient(for: config)

        do {
            let output = try await client.executeCommand(Self.posixWrapped(command), maxResponseSize: maxResponseSize)
            let stdout = output.getString(at: output.readerIndex, length: output.readableBytes) ?? ""
            return SSHCommandResult(
                command: command,
                stdout: stdout,
                duration: Date().timeIntervalSince(startedAt)
            )
        } catch {
            // A remote idle timeout can close the pooled transport. Evict it so
            // the next command reconnects; command failures on a healthy channel
            // are surfaced unchanged and are never executed twice.
            if !client.isConnected {
                commandClients[key] = nil
            }
            throw mapCommandError(error)
        }
    }

    func mapConnectionError(_ error: Error, config: SSHConnectionConfig) -> SSHServiceError {
        if let challenge = KnownHostStore.shared.pendingChallenge(host: config.host, port: config.port) {
            switch challenge.kind {
            case .firstUse:
                return .hostKeyTrustRequired(challenge)
            case .changed:
                return .hostKeyChanged(challenge)
            }
        }
        if let serviceError = error as? SSHServiceError {
            return serviceError
        }
        let message = String(describing: error)
        let lower = message.lowercased()
        if lower.contains("timeout") || lower.contains("timed out") {
            return .connectionTimeout
        }
        if lower.contains("authentication") || lower.contains("password") || lower.contains("permission denied") {
            return .authenticationFailed
        }
        if lower.contains("network") || lower.contains("unreachable") || lower.contains("refused") || lower.contains("dns") {
            return .hostUnreachable
        }
        return .unknown(message)
    }

    func mapCommandError(_ error: Error) -> SSHServiceError {
        let message = Self.humanize(String(describing: error))
        let lower = message.lowercased()
        if lower.contains("exitcode") || lower.contains("exit status") {
            return .commandFailed(message)
        }
        return .unknown(message)
    }

    /// Run a POSIX script under /bin/sh regardless of the account's login shell.
    /// zsh/fish (a chsh'd default) would otherwise misinterpret our sh scripts
    /// and emit "command not found", breaking collection. Base64 sidesteps all
    /// quoting concerns.
    static func posixWrapped(_ command: String) -> String {
        let b64 = Data(command.utf8).base64EncodedString()
        return "printf %s '\(b64)' | base64 -d | sh"
    }

    /// Some SSH errors surface stderr as a raw byte/hex dump (e.g. Citadel's
    /// TTYSTDError). Decode long hex runs back into readable text for display.
    static func humanize(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "[0-9a-f]{8,}") else { return text }
        let ns = text as NSString
        var out = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let hex = ns.substring(with: match.range)
            guard hex.count % 2 == 0 else { continue }
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { bytes = []; break }
                bytes.append(byte)
                index = next
            }
            guard !bytes.isEmpty,
                  let decoded = String(bytes: bytes, encoding: .utf8),
                  decoded.unicodeScalars.allSatisfy({ $0.value >= 9 && $0.value < 127 }) else { continue }
            out = (out as NSString).replacingCharacters(in: match.range, with: decoded.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }
}
#endif
