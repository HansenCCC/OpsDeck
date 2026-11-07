import Foundation

actor RunbookService {
    func execute(
        plan: RunbookPlan,
        hostID: UUID,
        config: SSHConnectionConfig,
        sshService: SSHService,
        initialRun: RunbookRun? = nil,
        onUpdate: @escaping @MainActor @Sendable (RunbookRun) async -> Void = { _ in }
    ) async -> RunbookRun {
        var run = initialRun ?? RunbookRun(plan: plan, hostID: hostID)
        run.status = .running
        await onUpdate(run)

        for index in run.steps.indices {
            if Task.isCancelled {
                run.status = .cancelled
                break
            }
            run.steps[index].status = .running
            await onUpdate(run)
            let startedAt = Date()
            var outputBytes: [UInt8] = []
            var lastPublishedAt = Date.distantPast
            do {
                let stream = await sshService.executeCommandStream(
                    wrappedCommand(run.steps[index].command),
                    on: config,
                    maxResponseSize: 2 * 1024 * 1024
                )
                for try await chunk in stream {
                    try Task.checkCancellation()
                    outputBytes.append(contentsOf: chunk.bytes)
                    run.steps[index].output = liveOutput(from: outputBytes)
                    let now = Date()
                    if now.timeIntervalSince(lastPublishedAt) >= 0.12 {
                        await onUpdate(run)
                        lastPublishedAt = now
                    }
                }
                try Task.checkCancellation()

                let rawOutput = String(decoding: outputBytes, as: UTF8.self)
                let parsed = parseWrappedOutput(rawOutput)
                run.steps[index].output = parsed.output
                run.steps[index].exitCode = parsed.exitCode
                run.steps[index].duration = Date().timeIntervalSince(startedAt)
                if parsed.exitCode == 0 {
                    run.steps[index].status = .succeeded
                } else {
                    run.steps[index].status = .failed
                    run.status = .failed
                    run.errorMessage = Self.failureMessage(
                        stepTitle: run.steps[index].title,
                        output: parsed.output,
                        exitCode: parsed.exitCode
                    )
                    await onUpdate(run)
                    break
                }
            } catch is CancellationError {
                run.steps[index].status = .cancelled
                let existingOutput = liveOutput(from: outputBytes)
                run.steps[index].output = existingOutput.isEmpty
                    ? String(localized: "已由用户取消。")
                    : "\(existingOutput)\n\(String(localized: "已由用户取消。"))"
                run.steps[index].duration = Date().timeIntervalSince(startedAt)
                run.status = .cancelled
                run.errorMessage = nil
                await onUpdate(run)
                break
            } catch where Task.isCancelled {
                run.steps[index].status = .cancelled
                let existingOutput = liveOutput(from: outputBytes)
                run.steps[index].output = existingOutput.isEmpty
                    ? String(localized: "已由用户取消。")
                    : "\(existingOutput)\n\(String(localized: "已由用户取消。"))"
                run.steps[index].duration = Date().timeIntervalSince(startedAt)
                run.status = .cancelled
                run.errorMessage = nil
                await onUpdate(run)
                break
            } catch {
                run.steps[index].status = .failed
                let existingOutput = liveOutput(from: outputBytes)
                run.steps[index].output = existingOutput.isEmpty
                    ? error.localizedDescription
                    : "\(existingOutput)\n\(error.localizedDescription)"
                run.steps[index].duration = Date().timeIntervalSince(startedAt)
                run.status = .failed
                run.errorMessage = error.localizedDescription
                await onUpdate(run)
                break
            }
            await onUpdate(run)
        }

        if run.status == .running {
            run.status = .succeeded
        }
        run.finishedAt = Date()
        await onUpdate(run)
        return run
    }

    private func wrappedCommand(_ command: String) -> String {
        """
        set +e
        (
        \(command)
        ) 2>&1
        __opsdeck_exit=$?
        printf '\\n__OPSDECK_EXIT_CODE__=%s\\n' "$__opsdeck_exit"
        exit 0
        """
    }

    private func parseWrappedOutput(_ output: String) -> (output: String, exitCode: Int) {
        let marker = "__OPSDECK_EXIT_CODE__="
        guard let range = output.range(of: marker, options: .backwards) else {
            let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = String(localized: "OpsDeck 未收到远端命令的退出状态，SSH 会话可能已中断。")
            return (body.isEmpty ? detail : "\(body)\n\(detail)", 255)
        }
        let body = String(output[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let exitText = output[range.upperBound...]
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? "1"
        return (body, Int(exitText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1)
    }

    private func liveOutput(from bytes: [UInt8]) -> String {
        let output = String(decoding: bytes, as: UTF8.self)
        let marker = "__OPSDECK_EXIT_CODE__="
        guard let range = output.range(of: marker) else {
            return output
        }
        return String(output[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func failureMessage(stepTitle: String, output: String, exitCode: Int) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Package managers often end with a generic wrapper such as
        // "Sub-process dpkg returned an error". Prefer the earlier line that
        // names the condition users can actually fix.
        let preferredSignatures = [
            ["fatal error", "can't open config file"],
            ["failed to load configuration"],
            ["configuration file", "not found"],
            ["address already in use"],
            ["unknown system user", "statoverride"],
            ["unknown system group", "statoverride"],
            ["no space left on device"],
            ["read-only file system"],
            ["dpkg was interrupted"],
            ["unable to acquire the dpkg frontend lock"],
            ["could not get lock"],
            ["unmet dependencies"],
            ["--fix-broken install"],
            ["dependency problems"],
            ["held broken packages"],
            ["hash sum mismatch"],
            ["failed to fetch"],
            ["no_pubkey"],
            ["repository", "is not signed"],
            ["temporary failure resolving"],
            ["could not resolve host"],
            ["unable to locate package"],
            ["has no installation candidate"]
        ]
        let preferredLine = preferredSignatures.lazy.compactMap { signature in
            lines.reversed().first { line in
                let lowercased = line.lowercased()
                return signature.allSatisfy(lowercased.contains)
            }
        }.first
        let errorKeywords = [
            "error", "failed", "failure", "unable", "not found", "denied",
            "could not", "cannot", "fatal", "e:"
        ]
        let usefulLine = preferredLine ?? lines.reversed().first { line in
            let lowercased = line.lowercased()
            return errorKeywords.contains(where: lowercased.contains)
        } ?? lines.last
        let detail = usefulLine.map { String($0.prefix(300)) }
        if let detail, !detail.isEmpty {
            return String(localized: "\(stepTitle)失败（退出码 \(exitCode)）：\(detail)")
        }
        return String(localized: "\(stepTitle)失败（退出码 \(exitCode)）")
    }
}
