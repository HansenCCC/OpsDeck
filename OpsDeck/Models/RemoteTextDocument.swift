import Foundation

enum RemoteTextMode: String, Sendable, Codable {
    case editable
    case tailPreview
}

/// A config-file validator run on save (write → validate → roll back on failure).
/// Generic so other config types (Caddy, sshd, …) can be added; each maps to a
/// shell test command that must exit non-zero on an invalid config.
enum ConfigValidator: String, Sendable, Codable, CaseIterable {
    case nginx

    /// Human-facing name of the validator/tool (not localized — it's a tool name).
    var toolName: String {
        switch self {
        case .nginx: return "nginx"
        }
    }

    /// The validation command body (a sudo prefix is prepended by the caller).
    /// Must exit non-zero when the config is invalid.
    var testCommand: String {
        switch self {
        case .nginx: return "nginx -t"
        }
    }
}

struct RemoteTextDocument: Identifiable, Equatable, Sendable {
    let id = UUID()
    var path: String
    var title: String
    var content: String
    var originalContent: String
    var mode: RemoteTextMode
    var byteCount: UInt64
    var loadedByteCount: UInt64
    var message: String?
    /// When set, saving runs this validator (write → validate → roll back on
    /// failure) and always goes through a privileged (sudo) write path.
    var validator: ConfigValidator? = nil

    var isReadOnly: Bool {
        mode == .tailPreview
    }

    var hasUnsavedChanges: Bool {
        content != originalContent
    }
}

/// Builds the shell commands for privileged remote-config saves and parses their
/// result. Pure/string-only so it can be smoke-tested without a live server.
///
/// The editor's normal save path is SFTP as the login user, which fails for
/// root-owned files (e.g. `/etc/nginx/*`) — the login user can't even create the
/// atomic temp file in the target directory. These commands stage the content in
/// a user-writable temp and `sudo cp` it into place, optionally validating the
/// result and rolling back on failure.
///
/// `executeCommand` only returns stdout (no exit code), so success/failure is
/// encoded as ASCII sentinels on stdout, with `2>&1` folding the tool's own
/// diagnostics (e.g. `nginx -t` output) in after the sentinel line.
enum RemoteConfigSave {
    static let saveOK = "OPSDECK_SAVE_OK"
    static let saveFail = "OPSDECK_SAVE_FAIL"
    static let validOK = "OPSDECK_VALID_OK"
    static let validFail = "OPSDECK_VALID_FAIL"
    static let sudoAuthFail = "OPSDECK_SUDO_AUTH_FAIL"

    enum Outcome: Equatable {
        case saved
        case validated(detail: String)
        case validationFailed(detail: String)
        case saveFailed(detail: String)
        case sudoAuthFailed
    }

    /// How privileged commands run on a given server: an optional credential-priming
    /// preamble plus the per-command prefix.
    struct SudoContext: Equatable {
        /// Runs first to authenticate sudo (empty for root / passwordless). On failure
        /// it echoes `sudoAuthFail` and exits, so the caller can report it cleanly.
        var primer: String
        /// Prefix for each privileged command ("" for root, "sudo " / "sudo -n ").
        var prefix: String
    }

    /// Build the sudo strategy for a server. `.root` needs no sudo; `.passwordless`
    /// uses `sudo -n`; otherwise prime sudo's credential cache once with the SSH
    /// login password (usually the same as the sudo password) and reuse the cache.
    static func sudoContext(profile: ServerProfileSnapshot?, password: String?) -> SudoContext {
        switch profile?.sudoStatus {
        case .root:
            return SudoContext(primer: "", prefix: "")
        case .passwordless:
            return SudoContext(primer: "", prefix: "sudo -n ")
        default:
            guard let password, !password.isEmpty else {
                return SudoContext(primer: "", prefix: "sudo ")
            }
            let primer = "printf '%s\\n' \(OpsShell.quote(password)) | sudo -S -p '' -v 2>/dev/null || { echo \(sudoAuthFail); exit 0; }\n"
            return SudoContext(primer: primer, prefix: "sudo ")
        }
    }

    /// A user-writable staging path in /tmp (login user owns it, cleaned up after).
    static func stagingPath(id: UUID) -> String {
        "/tmp/.opsdeck-save-\(id.uuidString)"
    }

    /// Privileged copy of `stage` onto `target`, no validation.
    static func sudoWriteCommand(stage: String, target: String, ctx: SudoContext) -> String {
        let qs = OpsShell.quote(stage)
        let qt = OpsShell.quote(target)
        return """
        \(ctx.primer)cpout="$(\(ctx.prefix)cp -f \(qs) \(qt) 2>&1)"; cprc=$?
        rm -f \(qs)
        if [ $cprc -eq 0 ]; then echo \(saveOK); else echo \(saveFail); echo "$cpout"; fi
        """
    }

    /// Privileged write with validate-and-rollback: back up the target, copy the
    /// staged content in, run `test`, and on failure restore the backup (or remove
    /// a newly-created file) so a broken config never survives.
    static func validateWriteCommand(stage: String, target: String, test: String, ctx: SudoContext) -> String {
        let qs = OpsShell.quote(stage)
        let qt = OpsShell.quote(target)
        let s = ctx.prefix
        return """
        \(ctx.primer)BAK=\(qt).opsdeck-bak
        if [ -e \(qt) ]; then \(s)cp -f \(qt) "$BAK" 2>/dev/null; HADBAK=1; else HADBAK=0; fi
        cpout="$(\(s)cp -f \(qs) \(qt) 2>&1)"; cprc=$?
        rm -f \(qs)
        if [ $cprc -ne 0 ]; then echo \(saveFail); echo "$cpout"; exit 0; fi
        testout="$(\(s)\(test) 2>&1)"; testrc=$?
        if [ $testrc -eq 0 ]; then
          [ "$HADBAK" = 1 ] && \(s)rm -f "$BAK"
          echo \(validOK); echo "$testout"
        else
          if [ "$HADBAK" = 1 ]; then \(s)cp -f "$BAK" \(qt) 2>/dev/null; \(s)rm -f "$BAK"; else \(s)rm -f \(qt) 2>/dev/null; fi
          echo \(validFail); echo "$testout"
        fi
        """
    }

    /// Classify a command's stdout, extracting the tool output that follows the
    /// sentinel line.
    static func parse(_ stdout: String) -> Outcome {
        func detail(after sentinel: String) -> String {
            guard let range = stdout.range(of: sentinel) else { return "" }
            return String(stdout[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if stdout.contains(sudoAuthFail) { return .sudoAuthFailed }
        if stdout.contains(validOK) { return .validated(detail: detail(after: validOK)) }
        if stdout.contains(validFail) { return .validationFailed(detail: detail(after: validFail)) }
        if stdout.contains(saveOK) { return .saved }
        let failDetail = detail(after: saveFail)
        return .saveFailed(detail: failDetail.isEmpty
            ? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : failDetail)
    }
}
