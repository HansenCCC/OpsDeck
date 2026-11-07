import Foundation
#if canImport(Citadel) && canImport(NIO) && canImport(NIOSSH) && canImport(Crypto)
@preconcurrency import Citadel
import Crypto
import NIO
@preconcurrency import NIOSSH
#endif

struct TerminalCommandResult: Equatable, Sendable {
    let command: String
    let output: String
    let duration: TimeInterval
}

enum TerminalPTYEvent: Sendable, Equatable {
    case ready
    case output([UInt8])
    case closed
    case failed(String)
}

actor TerminalService {
    private struct PTYSession {
        var task: Task<Void, Never>
#if canImport(Citadel) && canImport(NIO) && canImport(NIOSSH) && canImport(Crypto)
        var writer: TTYStdinWriter?
#endif
        var columns: Int
        var rows: Int
        var pixelWidth: Int
        var pixelHeight: Int
    }

    private var ptySessions: [UUID: PTYSession] = [:]
    private var ptyContinuations: [UUID: AsyncStream<TerminalPTYEvent>.Continuation] = [:]

    func run(_ command: String, config: SSHConnectionConfig, sshService: SSHService) async throws -> TerminalCommandResult {
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 1024 * 1024)
        return TerminalCommandResult(
            command: command,
            output: result.stdout,
            duration: result.duration
        )
    }

    func startPTY(
        tabID: UUID,
        config: SSHConnectionConfig,
        initialDirectory: String,
        shellOverride: String? = nil,
        columns: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> AsyncStream<TerminalPTYEvent> {
        stopPTY(tabID: tabID)

        let (stream, continuation) = AsyncStream<TerminalPTYEvent>.makeStream()
        ptyContinuations[tabID] = continuation

#if canImport(Citadel) && canImport(NIO) && canImport(NIOSSH) && canImport(Crypto)
        let safeColumns = max(columns, 40)
        let safeRows = max(rows, 6)
        let safePixelWidth = max(pixelWidth, 1)
        let safePixelHeight = max(pixelHeight, 1)
        let task = Task { [config, initialDirectory, shellOverride] in
            await runPTY(
                tabID: tabID,
                config: config,
                initialDirectory: initialDirectory,
                shellOverride: shellOverride,
                columns: safeColumns,
                rows: safeRows,
                pixelWidth: safePixelWidth,
                pixelHeight: safePixelHeight,
                continuation: continuation
            )
        }
        ptySessions[tabID] = PTYSession(
            task: task,
            writer: nil,
            columns: safeColumns,
            rows: safeRows,
            pixelWidth: safePixelWidth,
            pixelHeight: safePixelHeight
        )
#else
        continuation.yield(.failed(String(localized: "当前构建没有链接 Citadel/NIOSSH，无法打开真终端。")))
        continuation.finish()
#endif
        return stream
    }

    func send(_ bytes: [UInt8], tabID: UUID) async throws {
#if canImport(Citadel) && canImport(NIO) && canImport(NIOSSH) && canImport(Crypto)
        guard let writer = ptySessions[tabID]?.writer else { return }
        try await writer.write(ByteBuffer(bytes: bytes))
#endif
    }

    func resizePTY(
        tabID: UUID,
        columns: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) async {
#if canImport(Citadel) && canImport(NIO) && canImport(NIOSSH) && canImport(Crypto)
        guard var session = ptySessions[tabID] else { return }
        let safeColumns = max(columns, 40)
        let safeRows = max(rows, 6)
        let safePixelWidth = max(pixelWidth, 1)
        let safePixelHeight = max(pixelHeight, 1)

        guard session.columns != safeColumns ||
            session.rows != safeRows ||
            session.pixelWidth != safePixelWidth ||
            session.pixelHeight != safePixelHeight else {
            return
        }

        session.columns = safeColumns
        session.rows = safeRows
        session.pixelWidth = safePixelWidth
        session.pixelHeight = safePixelHeight
        ptySessions[tabID] = session

        do {
            try await session.writer?.changeSize(
                cols: safeColumns,
                rows: safeRows,
                pixelWidth: safePixelWidth,
                pixelHeight: safePixelHeight
            )
        } catch {
            ptyContinuations[tabID]?.yield(.failed(error.localizedDescription))
        }
#endif
    }

    func stopPTY(tabID: UUID) {
#if canImport(Citadel) && canImport(NIO) && canImport(NIOSSH) && canImport(Crypto)
        if let writer = ptySessions[tabID]?.writer {
            Task {
                try? await writer.write(ByteBuffer(string: "exit\n"))
            }
        }
#endif
        ptySessions[tabID]?.task.cancel()
        ptySessions[tabID] = nil
        ptyContinuations[tabID]?.finish()
        ptyContinuations[tabID] = nil
    }

    func stopAllPTY() {
        for tabID in Array(ptySessions.keys) {
            stopPTY(tabID: tabID)
        }
    }
}

#if canImport(Citadel) && canImport(NIO) && canImport(NIOSSH) && canImport(Crypto)
private extension TerminalService {
    func runPTY(
        tabID: UUID,
        config: SSHConnectionConfig,
        initialDirectory: String,
        shellOverride: String? = nil,
        columns: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        continuation: AsyncStream<TerminalPTYEvent>.Continuation
    ) async {
        do {
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

            let client = try await SSHClient.connect(to: settings)
            defer {
                Task {
                    try? await client.close()
                }
            }

            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: columns,
                terminalRowHeight: rows,
                terminalPixelWidth: pixelWidth,
                terminalPixelHeight: pixelHeight,
                terminalModes: SSHTerminalModes([:])
            )

            try await client.withPTY(request) { inbound, outbound in
                setWriter(
                    outbound,
                    tabID: tabID,
                    columns: columns,
                    rows: rows,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                )
                continuation.yield(.ready)

                let directory = initialDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                if !directory.isEmpty, directory != "." {
                    try await outbound.write(ByteBuffer(string: "cd \(shellQuote(directory))\n"))
                }
                if let shellOverride, !shellOverride.isEmpty {
                    try await outbound.write(ByteBuffer(string: "exec \(shellQuote(shellOverride))\n"))
                }

                for try await output in inbound {
                    guard !Task.isCancelled else { break }
                    switch output {
                    case .stdout(var buffer), .stderr(var buffer):
                        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
                        if !bytes.isEmpty {
                            continuation.yield(.output(bytes))
                        }
                    }
                }
            }

            finishPTY(tabID: tabID, event: .closed)
        } catch is CancellationError {
            finishPTY(tabID: tabID, event: .closed)
        } catch {
            finishPTY(tabID: tabID, event: .failed(error.localizedDescription))
        }
    }

    func setWriter(
        _ writer: TTYStdinWriter,
        tabID: UUID,
        columns: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        guard var session = ptySessions[tabID] else { return }
        session.writer = writer
        session.columns = columns
        session.rows = rows
        session.pixelWidth = pixelWidth
        session.pixelHeight = pixelHeight
        ptySessions[tabID] = session
    }

    func finishPTY(tabID: UUID, event: TerminalPTYEvent) {
        ptyContinuations[tabID]?.yield(event)
        ptyContinuations[tabID]?.finish()
        ptyContinuations[tabID] = nil
        ptySessions[tabID] = nil
    }

    func validate(_ config: SSHConnectionConfig) throws {
        guard !config.host.isEmpty else { throw SSHServiceError.invalidHost }
        guard (1...65535).contains(config.port) else { throw SSHServiceError.invalidPort }
    }
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
#endif
