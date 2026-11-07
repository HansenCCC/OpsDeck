import AppKit
import Foundation
#if canImport(Citadel) && canImport(Crypto) && canImport(NIOSSH)
import Citadel
import Crypto
import NIOSSH
#endif

#if DEBUG
enum OpsDeckSmokeRunner {
    @MainActor
    static func runIfRequested(appState: AppState) {
        guard ProcessInfo.processInfo.environment["OPSDECK_SMOKE_TEST"] != nil else { return }
        Task {
            await run(appState: appState)
            NSApp.terminate(nil)
        }
    }

    private static func run(appState: AppState) async {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["OPSDECK_SMOKE_HOST"] ?? ""
        let port = Int(environment["OPSDECK_SMOKE_PORT"] ?? "22") ?? 22
        let username = environment["OPSDECK_SMOKE_USER"] ?? ""
        let mode = environment["OPSDECK_SMOKE_TEST"] ?? "ssh"
        let password = readPasswordFromStandardInput()

        let config = SSHConnectionConfig(
            host: host,
            port: port,
            authentication: .password(username: username, password: password),
            connectTimeoutSeconds: 20
        )

        do {
            let offlineModes: Set<String> = [
                "operation-routing", "plan-generation", "session-swap", "host-order",
                "file-selection", "database-performance", "security-logic", "workspace-layout", "ssh-workflow",
                "operations-plans"
            ]
            if !offlineModes.contains(mode), environment["OPSDECK_SMOKE_TRUST_FIRST_HOST_KEY"] == "1" {
                try await prepareSmokeHostKeyTrust(
                    appState: appState,
                    config: config,
                    replaceChangedKey: environment["OPSDECK_SMOKE_REPLACE_HOST_KEY"] == "1"
                )
            }
            switch mode {
            case "operation-routing":
                await runOperationRoutingSmoke(appState: appState)
            case "plan-generation":
                await runPlanGenerationSmoke(appState: appState)
            case "session-swap":
                await runSessionSwapSmoke(appState: appState)
            case "host-order":
                await runHostOrderSmoke(appState: appState)
            case "file-selection":
                await runFileSelectionSmoke(appState: appState)
            case "database-performance":
                runDatabasePerformanceSmoke()
            case "security-logic":
                runSecurityLogicSmoke()
            case "workspace-layout":
                await runWorkspaceLayoutSmoke(appState: appState)
            case "ssh-workflow":
                await runSSHWorkflowSmoke(appState: appState)
            case "operations-plans":
                await runOperationsPlanSmoke(appState: appState)
            case "operations-read":
                try await runOperationsReadSmoke(appState: appState, config: config)
            case "write-verify":
                try await runWriteVerifySmoke(appState: appState, config: config)
            case "verify-mirror":
                try await runMirrorVerifySmoke(appState: appState, config: config)
            case "verify-shell":
                try await runShellVerifySmoke(appState: appState, config: config)
            case "verify-pm2":
                try await runPM2VerifySmoke(appState: appState, config: config)
            case "verify-db":
                try await runDBVerifySmoke(appState: appState, config: config)
            case "redis-repair":
                try await runRedisRepairSmoke(appState: appState, config: config)
            case "redis-manager":
                try await runRedisManagerSmoke(appState: appState, config: config)
            case "verify-extras":
                try await runExtrasVerifySmoke(appState: appState, config: config)
            case "certbot-issue":
                try await runCertbotIssueSmoke(appState: appState, config: config)
            case "verify-refresh":
                try await runRefreshVerifySmoke(appState: appState, config: config)
            case "verify-firewall":
                try await runFirewallVerifySmoke(appState: appState, config: config)
            case "cleanup":
                try await runCleanupSmoke(appState: appState, config: config)
            case "server-profile":
                try await runServerProfileSmoke(appState: appState, config: config)
            case "ssh-stream":
                try await runSSHStreamSmoke(appState: appState, config: config)
            case "ssh-reuse":
                try await runSSHReuseSmoke(appState: appState, config: config)
            case "private-key":
                try await runPrivateKeySmoke(appState: appState, passwordConfig: config)
            case "runbook-cancel":
                try await runRunbookCancellationSmoke(appState: appState, config: config)
            case "ssh-core-write":
                try await runSSHCoreWriteSmoke(appState: appState, config: config)
            case "database-workbench-write":
                try await runDatabaseWorkbenchWriteSmoke(appState: appState, config: config)
            case "cron-write":
                try await runCronWriteSmoke(appState: appState, config: config)
            case "sftp-read":
                try await runSFTPReadSmoke(appState: appState, config: config, environment: environment)
            case "sftp-actions":
                try await runSFTPActionSmoke(appState: appState, config: config)
            case "sftp":
                try await runSFTPSmoke(appState: appState, config: config)
            default:
                try await runSSHSmoke(appState: appState, config: config)
            }
        } catch {
            print("SMOKE_FAIL \(error.localizedDescription)")
        }
    }

    private static func prepareSmokeHostKeyTrust(
        appState: AppState,
        config: SSHConnectionConfig,
        replaceChangedKey: Bool
    ) async throws {
        do {
            _ = try await appState.sshService.runConnectionTest(config: config)
        } catch SSHServiceError.hostKeyTrustRequired(let challenge) {
            appState.knownHostStore.trust(challenge)
            _ = try await appState.sshService.runConnectionTest(config: config)
            print("SMOKE_INFO trusted-first-host-key endpoint=\(challenge.endpoint) fingerprint=\(challenge.fingerprint)")
        } catch SSHServiceError.hostKeyChanged(let challenge) where replaceChangedKey {
            appState.knownHostStore.trust(challenge)
            _ = try await appState.sshService.runConnectionTest(config: config)
            print("SMOKE_INFO replaced-host-key endpoint=\(challenge.endpoint) fingerprint=\(challenge.fingerprint)")
        }
    }

    private static func runSSHCoreWriteSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let directory = "/tmp/opsdeck-smoke-ssh-core-\(UUID().uuidString.lowercased())"
        let file = "\(directory)/live.log"
        let quotedDirectory = OpsShell.quote(directory)
        let quotedFile = OpsShell.quote(file)
        do {
            _ = try await appState.sshService.executeCommand(
                "mkdir -p \(quotedDirectory) && : > \(quotedFile) && chmod 0640 \(quotedFile)",
                on: config
            )
            let stat = try await appState.sshService.executeCommand(
                "stat -c '%a %U %G' \(quotedFile)",
                on: config
            )
            let permissionOK = stat.stdout.split(whereSeparator: \.isWhitespace).first == "640"

            let marker = "OPSDECK_LOG_FOLLOW_\(UUID().uuidString)"
            let command = "(sleep 0.4; printf '%s\\n' \(OpsShell.quote(marker)) >> \(quotedFile)) & timeout 2 tail -n 1 -F \(quotedFile); status=$?; if [ \"$status\" -eq 124 ]; then exit 0; else exit \"$status\"; fi"
            let stream = await appState.sshService.executeCommandStream(command, on: config, maxResponseSize: 256 * 1024)
            var output = ""
            for try await chunk in stream {
                output += String(decoding: chunk.bytes, as: UTF8.self)
            }
            let followOK = output.contains(marker)
            _ = try await appState.sshService.executeCommand("rm -rf \(quotedDirectory)", on: config)
            print("SMOKE_OK ssh-core-write chmod=\(permissionOK) liveFollow=\(followOK) cleanup=true")
        } catch {
            _ = try? await appState.sshService.executeCommand("rm -rf \(quotedDirectory)", on: config)
            throw error
        }
    }

    private static func runDatabaseWorkbenchWriteSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10)
        let database = "opsdeck_smoke_\(suffix)"
        let firstTable = "events"
        let renamedTable = "events_archive"
        let user = "opsdeck_\(suffix)"
        let password = UUID().uuidString
        let engine = appState.databaseBrowser
        let ssh = appState.databaseSSHService
        let sudo = "sudo -n "
        let builder = DatabaseSchemaSQLBuilder()

        func run(_ sql: String, database selected: String? = nil) async throws -> DBResultSet {
            try await engine.runSQL(
                dialect: .mysql, database: selected, sql: sql, config: config,
                credential: nil, adminSudo: sudo, sshService: ssh
            )
        }

        do {
            _ = try await run("CREATE DATABASE `\(database)`")
            _ = try await run(try builder.createTable(
                dialect: .mysql, database: database, table: firstTable, firstColumn: "id", dataType: "BIGINT"
            ))
            _ = try await run(try builder.addColumn(
                dialect: .mysql, database: database, table: firstTable,
                column: "message", dataType: "VARCHAR(255)", nullable: false
            ))
            _ = try await run(try builder.addIndex(
                dialect: .mysql, database: database, table: firstTable,
                index: "idx_message", columns: ["message"], unique: false
            ))
            _ = try await run("INSERT INTO `\(database)`.`\(firstTable)` (`id`, `message`) VALUES (1, 'hello')")
            _ = try await run(try builder.renameTable(
                dialect: .mysql, database: database, table: firstTable, newName: renamedTable
            ))
            let rows = try await engine.selectRows(
                dialect: .mysql, database: database, table: renamedTable,
                orderBy: "id", ascending: true, limit: 50, offset: 0, filter: nil, cursor: nil,
                config: config, credential: nil, adminSudo: sudo, sshService: ssh
            )
            let columns = try await engine.columns(
                dialect: .mysql, database: database, table: renamedTable,
                config: config, credential: nil, adminSudo: sudo, sshService: ssh
            )

            let created = try builder.createUser(dialect: .mysql, username: user, host: "localhost", password: password)
            _ = try await run(created.sql)
            _ = try await run(try builder.grant(
                dialect: .mysql, database: database, username: user, host: "localhost", preset: .readOnly
            ))
            let changed = try builder.changePassword(
                dialect: .mysql, username: user, host: "localhost", password: password + "-changed"
            )
            _ = try await run(changed.sql)

            _ = try await run("DROP USER IF EXISTS '\(user)'@'localhost'")
            _ = try await run(try builder.dropDatabase(dialect: .mysql, database: database))
            let databases = try await engine.listDatabases(
                dialect: .mysql, config: config, credential: nil, adminSudo: sudo, sshService: ssh
            )
            let cleaned = !databases.contains(database)
            let dataOK = rows.rows.first.map { row in
                row.count > 1 && row[0] == "1" && row[1] == "hello"
            } ?? false
            let structureOK = columns.map(\.name) == ["id", "message"]
            print("SMOKE_OK database-workbench-write data=\(dataOK) structure=\(structureOK) userGrant=true cleanup=\(cleaned)")
        } catch {
            _ = try? await run("DROP USER IF EXISTS '\(user)'@'localhost'")
            _ = try? await run("DROP DATABASE IF EXISTS `\(database)`")
            throw error
        }
    }

    private static func runCronWriteSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10)
        let label = "opsdeck-smoke-\(suffix)"
        let command = "/usr/bin/true # \(label)"
        let initialSchedule = "0 0 31 2 *"
        let editedSchedule = "1 0 31 2 *"
        let initialLine = "\(initialSchedule) \(command)"
        let editedLine = "\(editedSchedule) \(command)"
        let marker = "# OpsDeck: \(label)"

        func cleanup() async {
            let values = [marker, initialLine, editedLine, "# OpsDeck disabled: \(initialLine)", "# OpsDeck disabled: \(editedLine)"]
            let assignments = values.enumerated().map { "bad\($0.offset)=\(OpsShell.quote($0.element))" }.joined(separator: "; ")
            let comparisons = values.indices.map { "[ \"$line\" = \"$bad\($0)\" ]" }.joined(separator: " || ")
            let script = "\(assignments); tmp=$(mktemp); crontab -l 2>/dev/null | while IFS= read -r line; do if \(comparisons); then :; else printf '%s\\n' \"$line\"; fi; done > \"$tmp\"; crontab \"$tmp\"; rm -f \"$tmp\""
            _ = try? await appState.sshService.executeCommand(script, on: config, maxResponseSize: 4 * 1024)
        }

        await cleanup()
        do {
            let add = await exec(appState, config, appState.cronService.addUserJobPlan(
                schedule: initialSchedule, command: command, label: label
            ))
            let afterAdd = try await appState.cronService.collect(config: config, sshService: appState.sshService)
            guard let added = afterAdd.jobs.first(where: { $0.source == "用户" && $0.line == initialLine }) else {
                throw DBEngineError.notSupported(String(localized: "未找到新增的 Cron 冒烟任务。"))
            }

            let disable = await exec(appState, config, appState.cronService.setUserJobEnabledPlan(job: added, enabled: false))
            let afterDisable = try await appState.cronService.collect(config: config, sshService: appState.sshService)
            guard let disabled = afterDisable.jobs.first(where: { $0.line == initialLine && !$0.enabled }) else {
                throw DBEngineError.notSupported(String(localized: "Cron 禁用状态未生效。"))
            }

            let enable = await exec(appState, config, appState.cronService.setUserJobEnabledPlan(job: disabled, enabled: true))
            let afterEnable = try await appState.cronService.collect(config: config, sshService: appState.sshService)
            guard let enabled = afterEnable.jobs.first(where: { $0.line == initialLine && $0.enabled }) else {
                throw DBEngineError.notSupported(String(localized: "Cron 启用状态未恢复。"))
            }

            let edit = await exec(appState, config, appState.cronService.editUserJobPlan(
                job: enabled, schedule: editedSchedule, command: command
            ))
            let afterEdit = try await appState.cronService.collect(config: config, sshService: appState.sshService)
            guard let edited = afterEdit.jobs.first(where: { $0.line == editedLine }) else {
                throw DBEngineError.notSupported(String(localized: "Cron 编辑未生效。"))
            }

            let delete = await exec(appState, config, appState.cronService.deleteUserJobPlan(job: edited))
            let afterDelete = try await appState.sshService.executeCommand(
                "crontab -l 2>/dev/null | grep -F \(OpsShell.quote(label)) || true",
                on: config, maxResponseSize: 4 * 1024
            )
            let cleaned = afterDelete.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            print("SMOKE_OK cron-write add=\(ok(add.status)) disable=\(ok(disable.status)) enable=\(ok(enable.status)) edit=\(ok(edit.status)) delete=\(ok(delete.status)) cleanup=\(cleaned)")
        } catch {
            await cleanup()
            throw error
        }
    }

    /// CPU baseline for the largest response the database engine accepts. This
    /// isolates text parsing from SSH and AppKit so a regression is measurable.
    private static func runDatabasePerformanceSmoke() {
        let columns = (0..<40).map { "column_\($0)" }
        let payload = String(repeating: "value-0123456789", count: 28)
        let mysqlHeader = columns.joined(separator: "\t")
        let mysqlRow = Array(repeating: payload, count: columns.count).joined(separator: "\t")
        let mysqlOutput = ([mysqlHeader] + Array(repeating: mysqlRow, count: 200)).joined(separator: "\n")
        let postgresHeader = columns.joined(separator: CLIDatabaseEngine.fieldSep)
        let postgresRow = Array(repeating: payload, count: columns.count).joined(separator: CLIDatabaseEngine.fieldSep)
        let postgresOutput = ([postgresHeader] + Array(repeating: postgresRow, count: 200))
            .joined(separator: CLIDatabaseEngine.recordSep)

        let mysqlStarted = Date()
        let mysqlResult = CLIDatabaseEngine.parseMySQL(mysqlOutput, hasHeader: true)
        let mysqlElapsed = Date().timeIntervalSince(mysqlStarted)
        let postgresStarted = Date()
        let postgresResult = CLIDatabaseEngine.parsePostgres(postgresOutput, hasHeader: true)
        let postgresElapsed = Date().timeIntervalSince(postgresStarted)
        let mysqlDuration = String(format: "%.4fs", mysqlElapsed)
        let postgresDuration = String(format: "%.4fs", postgresElapsed)
        let columnWidthsOK = DBColumnWidthPolicy.initialWidth(name: "id", dataType: "bigint", sampleValues: ["100"]) == 104
            && DBColumnWidthPolicy.initialWidth(name: "created_at", dataType: "timestamp", sampleValues: []) == 176
            && DBColumnWidthPolicy.initialWidth(name: "payload", dataType: "json", sampleValues: []) == 280
            && DBColumnWidthPolicy.initialWidth(name: "name", dataType: "varchar", sampleValues: ["short"]) == 120

        var expansion = DBNavigatorExpansionState()
        expansion.activateConnection("first")
        expansion.activateDatabase(connectionID: "first", database: "app")
        expansion.activateConnection("second")
        let switchingPreservesFirst = expansion.isConnectionExpanded("first")
            && expansion.isConnectionExpanded("second")
            && expansion.isDatabaseExpanded(connectionID: "first", database: "app")
        expansion.toggleConnection("first")
        let firstCanCollapseIndependently = !expansion.isConnectionExpanded("first")
            && expansion.isConnectionExpanded("second")
        expansion.toggleConnection("first")
        let firstCanReopen = expansion.isConnectionExpanded("first")
        let navigationExpansionOK = switchingPreservesFirst && firstCanCollapseIndependently && firstCanReopen
        guard columnWidthsOK, navigationExpansionOK else {
            print("SMOKE_FAIL database-performance columnWidths=\(columnWidthsOK) navigationExpansion=\(navigationExpansionOK)")
            return
        }
        print(
            "SMOKE_OK database-performance bytes=\(mysqlOutput.utf8.count) "
            + "cells=\(mysqlResult.rows.count * mysqlResult.columns.count) "
            + "mysql=\(mysqlDuration) "
            + "postgres=\(postgresDuration) "
            + "pgCells=\(postgresResult.rows.count * postgresResult.columns.count) "
            + "columnWidths=\(columnWidthsOK) "
            + "navigationExpansion=\(navigationExpansionOK)"
        )
    }

    @MainActor
    private static func runOperationsPlanSmoke(appState: AppState) {
        let profile = ServerProfileSnapshot(
            osName: "Ubuntu 24.04", osID: "ubuntu", osVersionID: "24.04", architecture: "x86_64",
            username: "ubuntu", userID: "1000", sudoStatus: .passwordless, packageManager: .apt,
            initSystem: .systemd, tools: [], services: [], capturedAt: Date()
        )

        let container = DockerContainerSummary(id: "abc", name: "web", image: "nginx:latest", status: "Up", ports: "80/tcp")
        let dockerPull = appState.dockerManagerService.pullImagePlan(reference: "registry.example/app:1.0")
        let dockerRun = appState.dockerManagerService.runContainerPlan(
            name: "web", image: "registry.example/app:1.0", portMapping: "8080:80", restartPolicy: "unless-stopped"
        )
        let dockerExec = appState.dockerManagerService.execPlan(container: container, command: "printf '%s' ok")
        let dockerSafe = dockerPull.steps.allSatisfy { $0.command.contains("'registry.example/app:1.0'") }
            && dockerRun.steps.map(\.command).joined().contains("'8080:80'")
            && dockerExec.steps.first?.command.contains("sh -lc 'printf '\\''%s'\\'' ok'") == true

        let pm2 = appState.pm2Service.startApplicationPlan(
            name: "api", scriptPath: "/srv/api/server.js", workingDirectory: "/srv/api"
        )
        let pm2Safe = pm2.steps.map(\.command).joined(separator: "\n").contains("'/srv/api/server.js'")
            && pm2.steps.map(\.command).joined(separator: "\n").contains("pm2 save")

        let cronJob = CronJob(source: "用户", line: "0 * * * * /usr/local/bin/task", enabled: true)
        let cronEdit = appState.cronService.editUserJobPlan(job: cronJob, schedule: "5 * * * *", command: "/usr/local/bin/task")
        let cronDisable = appState.cronService.setUserJobEnabledPlan(job: cronJob, enabled: false)
        let cronDelete = appState.cronService.deleteUserJobPlan(job: cronJob)
        let cronSafe = [cronEdit, cronDisable, cronDelete].allSatisfy { plan in
            let commands = plan.steps.map(\.command).joined(separator: "\n")
            return commands.contains("found") && commands.contains("diff -u") && commands.contains("crontab")
        } && cronDelete.risk == .high

        let staleUser = "unknown system user 'redis' in statoverride file; the system user got removed"
        let staleGroup = "unknown system group 'legacy' in statoverride file"
        let recoveryFactory = PackageRecoveryPlanFactory()
        let recovery = recoveryFactory.plan(for: staleUser, profile: profile)
        let recoveryCommands = recovery?.steps.map(\.command).joined(separator: "\n") ?? ""
        let recoverySafe = recovery?.risk == .high
            && recoveryCommands.contains("statoverride.opsdeck-backup")
            && recoveryCommands.contains("-v p='redis'")
            && recoveryCommands.contains("dpkg --configure -a")
            && recoveryFactory.diagnosis(for: staleGroup) == .missingStatoverrideGroup("legacy")
            && recoveryFactory.diagnosis(for: "Could not get lock /var/lib/dpkg/lock") == nil
            && recoveryFactory.diagnosis(for: "No space left on device") == nil

        let schema = DatabaseSchemaSQLBuilder()
        let createSQL = try? schema.createTable(dialect: .mysql, database: "app", table: "events", firstColumn: "id", dataType: "BIGINT")
        let indexSQL = try? schema.addIndex(dialect: .postgres, database: "app", table: "events", index: "idx_created", columns: ["created_at"], unique: false)
        let userSQL = try? schema.createUser(dialect: .mysql, username: "reader", host: "localhost", password: "secret-value")
        let rejectsInjection = (try? schema.dropTable(dialect: .mysql, database: "app", table: "events; DROP DATABASE app")) == nil
        let schemaSafe = createSQL?.contains("`app`.`events`") == true
            && indexSQL?.contains("\"created_at\"") == true
            && userSQL?.sql.contains("secret-value") == true
            && userSQL?.preview.contains("secret-value") == false
            && rejectsInjection

        let suite = "opsdeck-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = DatabaseQueryStore(defaults: defaults)
        let hostID = UUID()
        let tab = DBQueryTab(sql: "SELECT 1")
        let saved = DBQueryWorkspaceSnapshot(
            tabs: [tab], selectedTabID: tab.id,
            history: [DBSavedQuery(sql: "SELECT 1")], favorites: [DBSavedQuery(sql: "SELECT 2")]
        )
        store.save(saved, hostID: hostID, connectionID: "db-a")
        let loaded = store.load(hostID: hostID, connectionID: "db-a")
        let isolated = store.load(hostID: hostID, connectionID: "db-b").history.isEmpty
        let queryPersistence = loaded == saved && isolated
        defaults.removePersistentDomain(forName: suite)

        print("SMOKE_OK operations-plans dockerSafe=\(dockerSafe) pm2Safe=\(pm2Safe) cronSafe=\(cronSafe) recoverySafe=\(recoverySafe) schemaSafe=\(schemaSafe) queryPersistence=\(queryPersistence)")
    }

    @MainActor
    private static func runWorkspaceLayoutSmoke(appState: AppState) {
        let modes = WorkspaceMode.allCases
        let primaryModesValid = modes == [.files, .tools, .logs, .audit, .history]
        let moduleIDs = WorkbenchRegistry.modules.map(\.id)
        let modulesUnique = Set(moduleIDs).count == moduleIDs.count
        let everyModuleGrouped = WorkbenchRegistry.modules.allSatisfy {
            WorkbenchGroup.allCases.contains($0.group)
        }
        let previousInspectorState = appState.isInspectorVisible
        appState.toggleInspector()
        let inspectorToggled = appState.isInspectorVisible != previousInspectorState
        appState.toggleInspector()
        let inspectorRestored = appState.isInspectorVisible == previousInspectorState
        let suite = "opsdeck-inspector-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let inspectorDefaultsHidden = !InspectorVisibilityPreference.load(from: defaults)
        InspectorVisibilityPreference.save(true, to: defaults)
        let inspectorChoicePersists = InspectorVisibilityPreference.load(from: defaults)
        defaults.removePersistentDomain(forName: suite)
        print("SMOKE_OK workspace-layout primaryModes=\(primaryModesValid) modulesUnique=\(modulesUnique) grouped=\(everyModuleGrouped) inspectorToggled=\(inspectorToggled) inspectorRestored=\(inspectorRestored) inspectorDefaultsHidden=\(inspectorDefaultsHidden) inspectorChoicePersists=\(inspectorChoicePersists)")
    }

    @MainActor
    private static func runSSHWorkflowSmoke(appState: AppState) {
        let config = """
        User ubuntu
        Host web-one
          HostName 192.0.2.10
          Port 2222
          IdentityFile "~/.ssh/opsdeck-missing-test-key"
        Host *
          Port 22
        Host !blocked web-*
          ServerAliveInterval 30
        Host cache-one
          HostName 192.0.2.20
        """
        let entries = SSHConfigImportService().parse(text: config)
        let web = entries.first { $0.alias == "web-one" }
        let cache = entries.first { $0.alias == "cache-one" }
        let parserOK = entries.count == 2
            && web?.hostname == "192.0.2.10"
            && web?.port == 2222
            && web?.username == "ubuntu"
            && web?.identityFile?.hasSuffix("/.ssh/opsdeck-missing-test-key") == true
            && web?.privateKeyText == nil
            && cache?.port == 22
            && cache?.username == "ubuntu"

        let marker = UUID().uuidString
        let groupName = "OpsDeck-Smoke-Group-\(marker)"
        let snippetTitle = "OpsDeck-Smoke-Snippet-\(marker)"
        appState.createGroup(named: groupName)
        appState.createSnippet(title: snippetTitle, command: "printf smoke", group: "Smoke", requiresConfirmation: true)
        let group = appState.groups.first { $0.name == groupName }
        let snippet = appState.snippets.first { $0.title == snippetTitle }
        let persisted = group != nil
            && snippet?.command == "printf smoke"
            && snippet?.requiresConfirmation == true

        if let snippet { appState.deleteSnippet(snippet) }
        if let group { appState.deleteGroup(group) }
        let cleaned = !appState.groups.contains { $0.name == groupName }
            && !appState.snippets.contains { $0.title == snippetTitle }
        print("SMOKE_OK ssh-workflow parser=\(parserOK) persisted=\(persisted) cleanup=\(cleaned)")
    }

    private static func runSecurityLogicSmoke() {
        let readOnly = [
            "SELECT * FROM users",
            "-- comment\nWITH recent AS (SELECT 1) SELECT * FROM recent",
            "SHOW DATABASES",
            "EXPLAIN SELECT 1"
        ].allSatisfy { DBSQLStatementKind.classify($0) == .readOnly }
        let dataWrites = [
            "UPDATE users SET name = 'x'",
            "WITH x AS (SELECT 1) DELETE FROM users WHERE id = 1",
            "SELECT 1; INSERT INTO audit_log(id) VALUES (1)"
        ].allSatisfy { DBSQLStatementKind.classify($0) == .dataMutation }
        let schemaWrites = [
            "DROP TABLE users",
            "SELECT 1; GRANT SELECT ON app.* TO user",
            "ALTER TABLE users ADD COLUMN note TEXT"
        ].allSatisfy { DBSQLStatementKind.classify($0) == .schemaOrPrivilegeMutation }

        let suiteName = "com.hansen.opsdeck.smoke.known-hosts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = KnownHostStore(defaults: defaults)
        let challenge = KnownHostChallenge(
            endpoint: "example.invalid:22",
            publicKey: "ssh-ed25519 AAAATEST",
            fingerprint: "SHA256:test",
            kind: .firstUse
        )
        store.trust(challenge)
        let trusted = store.records().first?.fingerprint == challenge.fingerprint
        let reloaded = KnownHostStore(defaults: defaults).records().first?.endpoint == challenge.endpoint
        store.remove(endpoint: challenge.endpoint)
        let removed = store.records().isEmpty
        defaults.removePersistentDomain(forName: suiteName)

        #if canImport(Citadel) && canImport(Crypto) && canImport(NIOSSH)
        let generated = Curve25519.Signing.PrivateKey()
        let privateKeyText = generated.makeSSHRepresentation()
        let privateKeyParses = (try? SSHAuthConfig.privateKey(
            username: "test",
            key: privateKeyText,
            passphrase: nil
        ).makeCitadelAuthMethod()) != nil
        let invalidKeyRejected: Bool
        do {
            _ = try SSHAuthConfig.privateKey(username: "test", key: "not-a-key", passphrase: nil)
                .makeCitadelAuthMethod()
            invalidKeyRejected = false
        } catch {
            invalidKeyRejected = true
        }
        #else
        let privateKeyParses = false
        let invalidKeyRejected = false
        #endif

        let passed = readOnly && dataWrites && schemaWrites && trusted && reloaded && removed
            && privateKeyParses && invalidKeyRejected
        print(
            "SMOKE_\(passed ? "OK" : "FAIL") security-logic "
            + "readOnly=\(readOnly) dataWrites=\(dataWrites) schemaWrites=\(schemaWrites) "
            + "trusted=\(trusted) reloaded=\(reloaded) removed=\(removed) "
            + "privateKey=\(privateKeyParses) invalidRejected=\(invalidKeyRejected)"
        )
    }

    private static func runPrivateKeySmoke(
        appState: AppState,
        passwordConfig: SSHConnectionConfig
    ) async throws {
        #if canImport(Citadel) && canImport(Crypto) && canImport(NIOSSH)
        let privateKey = Curve25519.Signing.PrivateKey()
        let privateKeyText = privateKey.makeSSHRepresentation()
        let publicKey = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: privateKey).publicKey)
        let marker = "opsdeck-smoke-\(UUID().uuidString)"
        let authorizedLine = "\(publicKey) \(marker)"
        let setup = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && printf '%s\\n' \(OpsShell.quote(authorizedLine)) >> ~/.ssh/authorized_keys"
        let cleanup = "tmp=$(mktemp ~/.ssh/authorized_keys.opsdeck.XXXXXX) && { grep -vF \(OpsShell.quote(marker)) ~/.ssh/authorized_keys > \"$tmp\" || true; } && chmod 600 \"$tmp\" && mv \"$tmp\" ~/.ssh/authorized_keys"

        _ = try await appState.sshService.executeCommand(setup, on: passwordConfig)
        do {
            let keyConfig = SSHConnectionConfig(
                host: passwordConfig.host,
                port: passwordConfig.port,
                authentication: .privateKey(
                    username: passwordConfig.authentication.username,
                    key: privateKeyText,
                    passphrase: nil
                ),
                connectTimeoutSeconds: passwordConfig.connectTimeoutSeconds
            )
            let result = try await appState.sshService.executeCommand(
                "printf 'private-key-ok'",
                on: keyConfig
            )
            _ = try await appState.sshService.executeCommand(cleanup, on: passwordConfig)
            let passed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "private-key-ok"
            print("SMOKE_\(passed ? "OK" : "FAIL") private-key authenticated=\(passed) cleanup=true")
        } catch {
            _ = try? await appState.sshService.executeCommand(cleanup, on: passwordConfig)
            throw error
        }
        #else
        throw SSHServiceError.citadelNotLinked
        #endif
    }

    private static func runRunbookCancellationSmoke(
        appState: AppState,
        config: SSHConnectionConfig
    ) async throws {
        let plan = RunbookPlan(
            kind: .dryRun,
            title: "Cancellation smoke",
            summary: "Temporary cancellation probe",
            targetDescription: config.displayName,
            risk: .readOnly,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: nil,
            steps: [
                RunbookStep(title: "Long read", command: "printf 'started\\n'; sleep 30; printf 'finished\\n'")
            ]
        )
        let started = Date()
        let task = Task {
            await appState.runbookService.execute(
                plan: plan,
                hostID: UUID(),
                config: config,
                sshService: appState.sshService
            )
        }
        try await Task.sleep(for: .milliseconds(700))
        task.cancel()
        let run = await task.value
        let elapsed = Date().timeIntervalSince(started)
        let passed = run.status == .cancelled && elapsed < 5
        print(
            "SMOKE_\(passed ? "OK" : "FAIL") runbook-cancel status=\(run.status.rawValue) "
            + "elapsed=\(String(format: "%.2f", elapsed))s "
            + "error=\(run.errorMessage ?? "none") step=\(run.steps.first?.output.suffix(160) ?? "")"
        )
    }

    /// Offline verification of the sidebar ordering: order is stable across a
    /// status bump (the old "list keeps reordering" bug), and drag-to-reorder
    /// persists.
    @MainActor
    private static func runHostOrderSmoke(appState: AppState) {
        while appState.hosts.count < 3 {
            var draft = HostEditorDraft()
            draft.name = "OrderTest-\(appState.hosts.count + 1)"
            draft.host = "10.1.0.\(appState.hosts.count + 1)"
            draft.username = "tester"
            draft.password = "x"
            appState.saveHostDraft(draft)
        }
        let ids0 = appState.hosts.map(\.id)

        // Drag the last host to the front; must take effect and survive reload.
        appState.moveHost(ids0.last!, before: ids0.first!)
        let movedToFront = appState.hosts.first?.id == ids0.last
        let orderAfterMove = appState.hosts.map(\.id)
        appState.reload()
        let persistsAfterReload = appState.hosts.map(\.id) == orderAfterMove

        // The original bug: connecting bumps updatedAt and reshuffled the list.
        // Now the order must be unchanged after a status bump.
        try? appState.storage.updateHostStatus(appState.hosts[1], status: "connected")
        appState.reload()
        let stableAfterStatusBump = appState.hosts.map(\.id) == orderAfterMove

        print("SMOKE_OK host-order movedToFront=\(movedToFront) persistsAfterReload=\(persistsAfterReload) stableAfterStatusBump=\(stableAfterStatusBump)")
        cleanupTestHosts(appState)
    }

    /// Offline verification of Finder-style remote selection. This exercises the
    /// same ServerSession methods used by row clicks and Command-A, without SSH or
    /// mutating the user's configured hosts.
    @MainActor
    private static func runFileSelectionSmoke(appState: AppState) {
        let host = HostProfile(name: "SelectionTest", host: "203.0.113.10", username: "tester")
        let session = ServerSession(host: host, app: appState)
        let items = ["alpha", "bravo", "charlie", "delta", "echo"].map { name in
            RemoteFileItem(
                path: "/tmp/\(name)",
                name: name,
                kind: .file,
                byteSize: 1,
                permissions: 0o644,
                modifiedAt: nil,
                longName: name
            )
        }
        session.remoteFiles = items

        session.selectRemoteFileItem(items[1])
        let plainClick = session.selectedRemoteFileIDs == [items[1].id]

        session.selectRemoteFileItem(items[3], modifiers: [.shift])
        let shiftRange = session.selectedRemoteFileIDs == Set(items[1...3].map(\.id))

        session.selectRemoteFileItem(items[0], modifiers: [.command])
        let commandAdds = session.selectedRemoteFileIDs == Set(items[0...3].map(\.id))
        session.selectRemoteFileItem(items[0], modifiers: [.command])
        let commandRemoves = session.selectedRemoteFileIDs == Set(items[1...3].map(\.id))

        session.selectRemoteFileItem(items[4], modifiers: [.command, .shift])
        let commandShiftExtends = session.selectedRemoteFileIDs == Set(items.map(\.id))

        session.clearRemoteFileSelection()
        session.selectAllRemoteFiles()
        let selectAll = session.selectedRemoteFileIDs == Set(items.map(\.id))

        session.prepareRemoteContextSelection(items[2])
        let contextPreservesGroup = session.selectedRemoteFileIDs.count == items.count
        session.clearRemoteFileSelection()
        session.selectRemoteFileItem(items[0])
        session.prepareRemoteContextSelection(items[2])
        let contextReplacesOutside = session.selectedRemoteFileIDs == [items[2].id]

        session.clearRemoteFileSelection()
        session.beginRemoteFileDragSelection(at: items[3])
        session.updateRemoteFileDragSelection(through: items[1])
        session.endRemoteFileDragSelection()
        let dragUpRange = session.selectedRemoteFileIDs == Set(items[1...3].map(\.id))

        session.beginRemoteFileDragSelection(at: items[4], modifiers: [.command])
        session.updateRemoteFileDragSelection(through: items[4])
        session.endRemoteFileDragSelection()
        let commandDragExtends = session.selectedRemoteFileIDs == Set(items[1...4].map(\.id))

        session.selectRemoteFileItem(items[1])
        session.beginRemoteFileDragSelection(at: items[3], modifiers: [.shift])
        session.updateRemoteFileDragSelection(through: items[4])
        session.endRemoteFileDragSelection()
        let shiftDragUsesAnchor = session.selectedRemoteFileIDs == Set(items[1...4].map(\.id))

        let passed = plainClick && shiftRange && commandAdds && commandRemoves
            && commandShiftExtends && selectAll && contextPreservesGroup && contextReplacesOutside
            && dragUpRange && commandDragExtends && shiftDragUsesAnchor
        print("SMOKE_\(passed ? "OK" : "FAIL") file-selection plain=\(plainClick) shiftRange=\(shiftRange) commandAdds=\(commandAdds) commandRemoves=\(commandRemoves) commandShift=\(commandShiftExtends) selectAll=\(selectAll) contextPreserves=\(contextPreservesGroup) contextReplaces=\(contextReplacesOutside) dragUp=\(dragUpRange) commandDrag=\(commandDragExtends) shiftDrag=\(shiftDragUsesAnchor)")
    }

    /// These offline tests run against the real store; remove any hosts they
    /// created so the user's sidebar stays clean.
    @MainActor
    private static func cleanupTestHosts(_ appState: AppState) {
        for host in appState.hosts where host.name.hasPrefix("SwapTest") || host.name.hasPrefix("OrderTest") {
            appState.deleteHost(host)
        }
    }

    /// Offline verification of the multi-server per-session model: switching hosts
    /// is a non-destructive SWAP (each host keeps its own live `ServerSession`
    /// state), sessions are independent, and the AppState facade forwards to the
    /// active session.
    @MainActor
    private static func runSessionSwapSmoke(appState: AppState) async {
        // Ensure at least two hosts exist.
        while appState.hosts.count < 2 {
            var draft = HostEditorDraft()
            draft.name = "SwapTest-\(appState.hosts.count + 1)"
            draft.host = "10.0.0.\(appState.hosts.count + 1)"
            draft.username = "tester"
            draft.password = "x"
            appState.saveHostDraft(draft)
        }
        let hostA = appState.hosts[0]
        let hostB = appState.hosts[1]

        appState.selectHost(hostA)
        guard let sessionA = appState.activeSession else {
            print("SMOKE_FAIL session-swap no active session for A"); return
        }
        sessionA.connectionStatus = .connected
        sessionA.selectedWorkbenchModuleID = "docker"
        sessionA.remoteDirectoryPath = "/var/www"
        sessionA.databases = [DatabaseTarget(
            kind: .mysql,
            serviceName: "mysql",
            installed: true,
            serviceInstalled: true,
            activeState: "active",
            version: "8.0"
        )]
        sessionA.hasLoadedDatabases = true

        appState.selectHost(hostB)
        guard let sessionB = appState.activeSession else {
            print("SMOKE_FAIL session-swap no active session for B"); return
        }
        let distinctSessions = sessionB !== sessionA
        let sessionLookupMatches = appState.session(for: hostA.id) === sessionA
            && appState.session(for: hostB.id) === sessionB
        // Selecting B must NOT have reset A, and B starts fresh (never touched).
        let bStartsFresh = sessionB.connectionStatus == .disconnected
            && sessionB.selectedWorkbenchModuleID == "services"
            && sessionB.remoteDirectoryPath == "."
            && !sessionB.hasLoadedDatabases
            && sessionB.databases.isEmpty
        sessionB.connectionStatus = .connecting

        // Switch back to A: same instance, state fully retained (no reset/reload).
        appState.selectHost(hostA)
        let backToSameA = appState.activeSession === sessionA
        let aRetained = sessionA.connectionStatus == .connected
            && sessionA.selectedWorkbenchModuleID == "docker"
            && sessionA.remoteDirectoryPath == "/var/www"
        let databaseStateScoped = sessionA.hasLoadedDatabases
            && sessionA.databases.map(\.kind) == [.mysql]
            && !sessionB.hasLoadedDatabases
            && sessionB.databases.isEmpty
        // Facade forwards to the active (A) session.
        let facadeForwardsActive = appState.selectedWorkbenchModuleID == "docker"
            && appState.remoteDirectoryPath == "/var/www"
            && appState.connectionStatus == .connected
        // B remained connected-in-progress even while A was displayed (isolation).
        let bIndependent = sessionB.connectionStatus == .connecting

        // Sidebar shows EACH host's own live status regardless of selection:
        // A stays connected (green) though B is displayed; B shows connecting.
        let sidebarPerHostStatus = appState.connectionState(for: hostA.id) == .connected
            && appState.connectionState(for: hostB.id) == .connecting

        print("SMOKE_OK session-swap distinct=\(distinctSessions) sessionLookupMatches=\(sessionLookupMatches) bStartsFresh=\(bStartsFresh) backToSameA=\(backToSameA) aRetained=\(aRetained) facadeForwardsActive=\(facadeForwardsActive) bIndependent=\(bIndependent) sidebarPerHostStatus=\(sidebarPerHostStatus) databaseStateScoped=\(databaseStateScoped)")
        cleanupTestHosts(appState)
    }

    @MainActor
    private static func runOperationRoutingSmoke(appState: AppState) async {
        let terminalBefore = appState.activeTerminalOutput
        appState.copyToolPath("/usr/bin/git")
        let latestNotice = appState.operationNotices.first
        let terminalUnchanged = appState.activeTerminalOutput == terminalBefore
        let noticeRecorded = latestNotice?.title == "已复制工具路径"
            && latestNotice?.detail == "/usr/bin/git"
        let initialLimit = appState.operationHistoryDisplayLimit
        appState.loadMoreOperationHistory()
        await Task.yield()
        let paginationAdvanced = appState.operationHistoryDisplayLimit == initialLimit + 10
        print("SMOKE_OK operation-routing terminalUnchanged=\(terminalUnchanged) noticeRecorded=\(noticeRecorded) paginationAdvanced=\(paginationAdvanced)")
    }

    @MainActor
    private static func runPlanGenerationSmoke(appState: AppState) async {
        let profile = ServerProfileSnapshot(
            osName: "Ubuntu 24.04 LTS",
            osID: "ubuntu",
            osVersionID: "24.04",
            architecture: "x86_64",
            username: "root",
            userID: "0",
            sudoStatus: .root,
            packageManager: .apt,
            initSystem: .systemd,
            tools: [],
            services: [],
            capturedAt: Date()
        )
        let catalog = appState.installerCatalogService.catalog()
        let nginxPlan = catalog.first(where: { $0.id == "nginx" }).map {
            appState.installerCatalogService.installPlan(tool: $0, profile: profile)
        }
        let gitPlan = catalog.first(where: { $0.id == "git" }).map {
            appState.installerCatalogService.installPlan(tool: $0, profile: profile)
        }
        let dockerPlan = catalog.first(where: { $0.id == "docker" }).map {
            appState.installerCatalogService.installPlan(tool: $0, profile: profile)
        }
        let service = ServiceUnit(
            name: "nginx",
            description: "Nginx",
            loadState: "loaded",
            activeState: "active",
            subState: "running",
            unitFileState: "enabled"
        )
        let stopPlan = appState.serviceManagerService.plan(action: .stop, service: service, profile: profile)
        let nginxCommands = nginxPlan?.steps.map(\.command).joined(separator: "\n") ?? ""
        let gitCommands = gitPlan?.steps.map(\.command).joined(separator: "\n") ?? ""
        let dockerCommands = dockerPlan?.steps.map(\.command).joined(separator: "\n") ?? ""
        let stopCommands = stopPlan.steps.map(\.command).joined(separator: "\n")
        let nginxStartIsVerified = nginxCommands.contains("systemctl enable 'nginx'")
            && nginxCommands.contains("systemctl start 'nginx'")
            && nginxCommands.contains("journalctl -u 'nginx'")
            && !nginxCommands.contains("enable --now")
        print(
            "SMOKE_OK plan-generation nginxStarts=\(nginxStartIsVerified) nginxVerifies=\(nginxCommands.contains("is-active")) gitCLIOnly=\(!gitCommands.contains("systemctl")) dockerDaemon=\(dockerCommands.contains("docker info")) stopVerifiesInactive=\(stopCommands.contains("= inactive"))"
        )

        // Regression guards for the resilient install/uninstall logic.
        let unknownProfile = ServerProfileSnapshot(
            osName: nil, osID: nil, osVersionID: nil, architecture: nil,
            username: "root", userID: "0", sudoStatus: .root,
            packageManager: .unknown, initSystem: .unknown,
            tools: [], services: [], capturedAt: Date()
        )
        let dockerUnknown = catalog.first(where: { $0.id == "docker" }).map {
            appState.installerCatalogService.installPlan(tool: $0, profile: unknownProfile)
                .steps.map(\.command).joined(separator: "\n")
        } ?? ""
        // Unknown package manager must auto-detect on the remote host, never hard-fail locally.
        let dockerAutoDetects = dockerUnknown.contains("command -v apt-get")
            && dockerUnknown.contains("update || exit $?")
            && !dockerUnknown.contains("暂无适配安装方式")
        let htopUninstall = catalog.first(where: { $0.id == "htop" }).map {
            appState.installerCatalogService.uninstallPlan(tool: $0, profile: profile)
                .steps.map(\.command).joined(separator: "\n")
        } ?? ""
        let uninstallRemoves = htopUninstall.contains("apt-get") && htopUninstall.contains("remove -y")
        let uninstallVerifies = htopUninstall.contains("已卸载")
        let dockerUninstallBlocked = catalog.first(where: { $0.id == "docker" })?.uninstallPolicy.isAllowed == false
        let htopUninstallAllowed = catalog.first(where: { $0.id == "htop" })?.uninstallPolicy.isAllowed == true
        // Dependency ordering: PM2 needs Node.js, so on a box without node the plan
        // must install node BEFORE `npm install -g pm2` (else npm: command not found).
        let pm2Steps = catalog.first(where: { $0.id == "pm2" }).map {
            appState.installerCatalogService.installPlan(tool: $0, profile: profile).steps.map(\.command)
        } ?? []
        let nodeIdx = pm2Steps.firstIndex(where: { $0.contains("nodejs") })
        let pm2Idx = pm2Steps.firstIndex(where: { $0.contains("install -g pm2") })
        let pm2DepsFirst = (nodeIdx != nil && pm2Idx != nil && nodeIdx! < pm2Idx!)
        // Preflight (环境前置条件) regression.
        let installer = appState.installerCatalogService
        func tdef(_ id: String) -> ToolDefinition? { catalog.first { $0.id == id } }
        let noRoot = ServerProfileSnapshot(osName: "Ubuntu", osID: "ubuntu", osVersionID: "24.04", architecture: "x86_64", username: "deploy", userID: "1000", sudoStatus: .unavailable, packageManager: .apt, initSystem: .systemd, tools: [], services: [], capturedAt: Date())
        let arm32 = ServerProfileSnapshot(osName: "Debian", osID: "debian", osVersionID: "12", architecture: "armv7l", username: "root", userID: "0", sudoStatus: .root, packageManager: .apt, initSystem: .systemd, tools: [], services: [], capturedAt: Date())
        let openrc = ServerProfileSnapshot(osName: "Alpine", osID: "alpine", osVersionID: "3.20", architecture: "x86_64", username: "root", userID: "0", sudoStatus: .root, packageManager: .apk, initSystem: .openrc, tools: [], services: [], capturedAt: Date())
        let preRootBlocks = tdef("git").map { installer.preflight(for: $0, profile: noRoot).contains { $0.severity == .blocker && $0.title.contains("root") } } ?? false
        let preUvNoRoot = tdef("uv").map { !installer.preflight(for: $0, profile: noRoot).contains { $0.title.contains("root") } } ?? false
        let preDockerArch = tdef("docker").map { installer.preflight(for: $0, profile: arm32).contains { $0.severity == .blocker && $0.title.contains("64") } } ?? false
        let preNginxSystemd = tdef("nginx").map { installer.preflight(for: $0, profile: openrc).contains { $0.title.contains("systemd") } } ?? false
        let preClean = tdef("git").map { installer.preflight(for: $0, profile: profile).isEmpty } ?? false
        // Caddy on apt must add the Cloudsmith repo before installing (not in default repos).
        let caddyPlan = tdef("caddy").map { installer.installPlan(tool: $0, profile: profile).steps.map(\.command).joined(separator: "\n") } ?? ""
        let caddyRepo = caddyPlan.contains("cloudsmith.io/public/caddy")
            && caddyPlan.contains("install -y 'caddy'")
        // Download-source policy fallback: mirrorOnly must drop the official
        // Cloudsmith source entirely (no wasted timeout); officialFirst tries
        // Cloudsmith before the GitHub-proxy mirror; mirrorFirst reverses.
        func caddyCmd(_ p: DownloadMirrorPolicy) -> String {
            tdef("caddy").map { installer.installPlan(tool: $0, profile: profile, policy: p).steps.map(\.command).joined(separator: "\n") } ?? ""
        }
        func before(_ s: String, _ a: String, _ b: String) -> Bool {
            guard let ra = s.range(of: a), let rb = s.range(of: b) else { return false }
            return ra.lowerBound < rb.lowerBound
        }
        let cOfficialFirst = caddyCmd(.officialFirst)
        let cMirrorOnly = caddyCmd(.mirrorOnly)
        let srcMirrorOnlyDropsOfficial = !cMirrorOnly.contains("cloudsmith") && cMirrorOnly.contains("ghfast.top")
        let srcOfficialFirst = before(cOfficialFirst, "cloudsmith", "ghfast.top")
        let srcMirrorFirst = before(caddyCmd(.mirrorFirst), "ghfast.top", "cloudsmith")
        // Deployment recipes (P1): every item references a real catalog tool, and
        // deployPlan composes ONE dependency-ordered runbook (pm2 needs node → node
        // installs first).
        let recipes = installer.deploymentRecipes()
        let catalogIDs = Set(catalog.map(\.id))
        let recipesValid = !recipes.isEmpty && recipes.allSatisfy { !$0.items.isEmpty && $0.items.allSatisfy { catalogIDs.contains($0.toolID) } }
        let pm2Deploy = installer.deployPlan(toolIDs: ["pm2"], profile: profile).steps.map(\.command).joined(separator: "\n")
        let deployDepOrder = before(pm2Deploy, "开始安装 Node.js", "开始安装 PM2")
        let multiDeploy = installer.deployPlan(toolIDs: ["nginx", "git"], profile: profile).steps.map(\.command).joined(separator: "\n")
        let deployOneRunbook = multiDeploy.contains("开始安装 Nginx") && multiDeploy.contains("开始安装 Git")
        // Tool→workbench-module mapping drives per-pane install-state attribution:
        // dedicated panes map to themselves, ufw remaps to the firewall pane, and
        // pane-less tools fall back to the installer.
        let moduleMap = (tdef("pm2")?.workbenchModuleID == "pm2")
            && (tdef("nginx")?.workbenchModuleID == "nginx")
            && (tdef("ufw")?.workbenchModuleID == "firewall")
            && (tdef("git")?.workbenchModuleID == "installer")
        // zsh plugins: catalog well-formed; the full-set plan checks preconditions,
        // git-clones the two zsh-users plugins with mirror fallback, installs the
        // autojump package, and enables all three with syntax-highlighting LAST.
        let zshCatalog = ShellPathService.zshPlugins
        let zshCatalogValid = zshCatalog.map(\.id).sorted() == ["autojump", "zsh-autosuggestions", "zsh-syntax-highlighting"]
        let zshPlan = appState.shellPathService.installZshPluginsPlan(
            pluginIDs: ["zsh-autosuggestions", "zsh-syntax-highlighting", "autojump"], profile: profile)
        let zshJoined = zshPlan.steps.map(\.command).joined(separator: "\n")
        let zshPrecheck = zshJoined.contains(".oh-my-zsh") && zshJoined.contains("command -v zsh")
        let zshMirrorFallback = zshJoined.contains("gitee.com/mirrors/zsh-autosuggestions")
            && zshJoined.contains("github.com/zsh-users/zsh-autosuggestions")
        let zshAutojumpPkg = zshJoined.contains("apt-get") && zshJoined.contains("install -y") && zshJoined.contains("autojump")
        // Enable step must append syntax-highlighting after autosuggestions/autojump.
        let enableCmd = zshPlan.steps.last?.command ?? ""
        let hlIdx = enableCmd.range(of: "for p in ").map { enableCmd.distance(from: enableCmd.startIndex, to: $0.upperBound) } ?? 0
        let enableList = String(enableCmd.dropFirst(hlIdx)).prefix(while: { $0 != "\n" })
        let zshHighlightLast = enableList.contains("zsh-syntax-highlighting")
            && (enableList.range(of: "zsh-autosuggestions").map { $0.lowerBound } ?? enableList.startIndex)
               < (enableList.range(of: "zsh-syntax-highlighting").map { $0.lowerBound } ?? enableList.startIndex)
        // mirrorOnly must drop the official github remote entirely.
        let zshMirrorOnly = appState.shellPathService.installZshPluginsPlan(
            pluginIDs: ["zsh-autosuggestions"], profile: profile, policy: .mirrorOnly)
            .steps.map(\.command).joined(separator: "\n")
        let zshMirrorOnlyDropsOfficial = !zshMirrorOnly.contains("github.com") && zshMirrorOnly.contains("gitee.com")
        // apt runbooks must stay unattended, and their failure summary must
        // preserve actionable dpkg causes instead of the final generic wrapper.
        let ufwAptCommands = tdef("ufw").map {
            installer.installPlan(tool: $0, profile: profile).steps.map(\.command)
                .filter { $0.contains("apt-get") }
        } ?? []
        let aptUnattended = !ufwAptCommands.isEmpty && ufwAptCommands.allSatisfy {
            $0.contains("DEBIAN_FRONTEND=noninteractive") && $0.contains("DPkg::Lock::Timeout=180")
        }
        let redisInstallCommands = tdef("redis").map {
            installer.installPlan(tool: $0, profile: profile).steps.map(\.command).joined(separator: "\n")
        } ?? ""
        let aptRestoresMissingConfig = redisInstallCommands.contains("dpkg --verify")
            && redisInstallCommands.contains("Dpkg::Options::=--force-confmiss")
            && !redisInstallCommands.contains("--force-confnew")
        let serviceFailureDiagnoses = redisInstallCommands.contains("systemctl status 'redis-server'")
            && redisInstallCommands.contains("journalctl -u 'redis-server'")
            && redisInstallCommands.contains("opsdeck_binary_rc")
            && !redisInstallCommands.contains("enable --now")
        let staleOverrideOutput = """
        dpkg: unrecoverable fatal error, aborting:
         unknown system user 'redis' in statoverride file; the system user got removed
        E: Sub-process /usr/bin/dpkg returned an error code (2)
        """
        let staleOverrideSummary = RunbookService.failureMessage(
            stepTitle: "Install package",
            output: staleOverrideOutput,
            exitCode: 100
        )
        let statoverrideCause = staleOverrideSummary.contains("unknown system user")
            && OpsErrorHint.hint(for: staleOverrideSummary)?.contains("dpkg-statoverride") == true
            && OpsErrorHint.hint(for: "unknown system group 'legacy' in statoverride file") != nil
        let commonDpkgHints = [
            "dpkg was interrupted",
            "Unable to acquire the dpkg frontend lock",
            "Unmet dependencies. Try --fix-broken install",
            "No space left on device",
            "Read-only file system",
            "held broken packages",
            "Hash Sum mismatch",
            "Failed to fetch https://mirror.example/package.deb",
            "NO_PUBKEY ABC123",
            "The repository 'https://bad.example stable Release' is not signed."
        ].allSatisfy { OpsErrorHint.hint(for: $0) != nil }
        print(
            "SMOKE_OK plan-generation-ext dockerAutoDetects=\(dockerAutoDetects) uninstallRemoves=\(uninstallRemoves) uninstallVerifies=\(uninstallVerifies) dockerUninstallBlocked=\(dockerUninstallBlocked) htopUninstallAllowed=\(htopUninstallAllowed) pm2DepsFirst=\(pm2DepsFirst) preRoot=\(preRootBlocks) preUvNoRoot=\(preUvNoRoot) preArch=\(preDockerArch) preSystemd=\(preNginxSystemd) preClean=\(preClean) caddyRepo=\(caddyRepo) caddyMirrorOnlyDropsOfficial=\(srcMirrorOnlyDropsOfficial) caddyOfficialFirst=\(srcOfficialFirst) caddyMirrorFirst=\(srcMirrorFirst) recipesValid=\(recipesValid) deployDepOrder=\(deployDepOrder) deployOneRunbook=\(deployOneRunbook) zshCatalogValid=\(zshCatalogValid) zshPrecheck=\(zshPrecheck) zshMirrorFallback=\(zshMirrorFallback) zshAutojumpPkg=\(zshAutojumpPkg) zshHighlightLast=\(zshHighlightLast) zshMirrorOnlyDropsOfficial=\(zshMirrorOnlyDropsOfficial) moduleMap=\(moduleMap) aptUnattended=\(aptUnattended) aptConfmiss=\(aptRestoresMissingConfig) serviceDiagnoses=\(serviceFailureDiagnoses) statoverrideCause=\(statoverrideCause) commonDpkgHints=\(commonDpkgHints) catalogCount=\(catalog.count)"
        )

        // Phase 3 — Docker operations & read-only DB inventory.
        let sampleContainer = DockerContainerSummary(id: "abc123", name: "web", image: "nginx:latest", status: "Up 2 hours", ports: "80/tcp")
        let removePlan = appState.dockerManagerService.removeContainerPlan(container: sampleContainer)
        let prunePlan = appState.dockerManagerService.prunePlan()
        let dfPlan = appState.dockerManagerService.diskUsagePlan()
        let dockerRemoveForces = removePlan.steps.contains { $0.command.contains("docker rm -f") } && removePlan.risk == .high
        let dfReadOnly = dfPlan.risk == .readOnly && dfPlan.steps.contains { $0.command.contains("system df") }
        let pruneHighRisk = prunePlan.risk == .high && prunePlan.steps.contains { $0.command.contains("system prune") }
        let sampleImage = DockerImageSummary(id: "sha256abc", repository: "nginx", tag: "latest", size: "142MB")
        let imageRemoveForces = appState.dockerManagerService.removeImagePlan(image: sampleImage).steps.contains { $0.command.contains("docker rmi") }
        let sampleDB = DatabaseTarget(kind: .postgresql, serviceName: "postgresql", installed: true, serviceInstalled: true, activeState: "active", version: nil)
        let dbInspect = appState.databaseManagerService.inspectPlan(database: sampleDB, profile: profile)
        let dbReadOnlyNoWrites = dbInspect.risk == .readOnly && dbInspect.steps.allSatisfy {
            let c = $0.command.uppercased()
            return !c.contains("DROP ") && !c.contains("DELETE ") && !c.contains("UPDATE ") && !c.contains("INSERT ")
        }
        // Regression: MySQL/Redis backups must escalate privileges (socket-auth
        // admin) or they hit permission-denied; Redis must hand ownership back so
        // the copy is downloadable over the non-root SFTP session.
        let nonRootProfile = ServerProfileSnapshot(
            osName: "Ubuntu 24.04 LTS", osID: "ubuntu", osVersionID: "24.04", architecture: "x86_64",
            username: "ubuntu", userID: "1000", sudoStatus: .passwordless, packageManager: .apt,
            initSystem: .systemd, tools: [], services: [], capturedAt: Date()
        )
        let mysqlDB = DatabaseTarget(kind: .mysql, serviceName: "mysql", installed: true, serviceInstalled: true, activeState: "active", version: nil)
        let redisDB = DatabaseTarget(kind: .redis, serviceName: "redis", installed: true, serviceInstalled: true, activeState: "active", version: nil)
        let mysqlBackup = appState.databaseManagerService.backupPlan(database: mysqlDB, profile: nonRootProfile).steps.map(\.command).joined(separator: "\n")
        let redisBackup = appState.databaseManagerService.backupPlan(database: redisDB, profile: nonRootProfile).steps.map(\.command).joined(separator: "\n")
        let dbBackupSudo = mysqlBackup.contains("sudo") && mysqlBackup.contains("mysqldump") && redisBackup.contains("sudo") && redisBackup.contains("chown")
        print(
            "SMOKE_OK plan-generation-docker dockerRemoveForces=\(dockerRemoveForces) dfReadOnly=\(dfReadOnly) pruneHighRisk=\(pruneHighRisk) imageRemoveForces=\(imageRemoveForces) dbReadOnlyNoWrites=\(dbReadOnlyNoWrites) dbBackupSudo=\(dbBackupSudo)"
        )

        // Database browser engine (Navicat-lite, P0): credentials never land on
        // argv (MySQL via --defaults-extra-file, Postgres via PGPASSWORD env), the
        // admin/no-cred path escalates correctly, and the batch parsers round-trip
        // (tab/escape + NULL for MySQL, control-byte + NULL sentinel for Postgres).
        let dbEngine = CLIDatabaseEngine()
        let dbCred = DBCredential(username: "root", password: "p'w\"x\\y", host: "127.0.0.1", port: nil)
        let myCmd = dbEngine.mysqlScript(sql: "SELECT * FROM `db`.`t` LIMIT 200 OFFSET 0", database: "db", credential: dbCred, adminSudo: "sudo -n ", header: true)
        let dbMyCredSafe = myCmd.contains("--defaults-extra-file=\"$CF\"") && myCmd.contains("password=") && !myCmd.contains("-p'p") && myCmd.contains(CLIDatabaseEngine.rcSentinel)
        let pgCmd = dbEngine.postgresScript(sql: "SELECT 1", database: "app", credential: dbCred, adminSudo: "sudo -n ", header: false)
        let dbPgCredSafe = pgCmd.contains("PGPASSWORD=") && pgCmd.contains("footer=off") && pgCmd.contains(" -t") && !pgCmd.contains("password ")
        let myAdmin = dbEngine.mysqlScript(sql: "SHOW DATABASES", database: nil, credential: nil, adminSudo: "sudo -n ", header: false)
        let pgAdmin = dbEngine.postgresScript(sql: "SELECT 1", database: nil, credential: nil, adminSudo: "", header: false)
        let dbAdminPath = myAdmin.contains("sudo -n mysql") && myAdmin.contains("--skip-column-names") && pgAdmin.contains("sudo -u postgres psql")
        let (dbSentOut, dbSentRC) = CLIDatabaseEngine.splitSentinel("line1\nline2\n\(CLIDatabaseEngine.rcSentinel)3\n")
        let dbSentinel = dbSentRC == 3 && dbSentOut == "line1\nline2"
        // MySQL: header + one row with an escaped tab in a cell and a NULL.
        let myParse = CLIDatabaseEngine.parseMySQL("id\tname\tnote\n1\ta\\tb\tNULL", hasHeader: true)
        let dbMyParse = myParse.columns == ["id", "name", "note"] && myParse.rows.count == 1
            && myParse.rows[0][1] == "a\tb" && myParse.rows[0][2] == nil
        // Postgres: control-byte separators, second cell is the NULL sentinel.
        let F = CLIDatabaseEngine.fieldSep, R = CLIDatabaseEngine.recordSep, N = CLIDatabaseEngine.nullToken
        let pgParse = CLIDatabaseEngine.parsePostgres("id\(F)name\(R)1\(F)\(N)\(R)", hasHeader: true)
        let dbPgParse = pgParse.columns == ["id", "name"] && pgParse.rows.count == 1
            && pgParse.rows[0][0] == "1" && pgParse.rows[0][1] == nil
        // Write SQL builders (P2): keyed on PK, values escaped, NULL handled.
        let myUpdate = dbEngine.buildUpdate(dialect: .mysql, database: "app", table: "users",
            pk: [("id", "7")], setColumn: "name", value: "O'Brien", isNull: false)
        let dbMyUpdate = myUpdate == "UPDATE `app`.`users` SET `name` = 'O''Brien' WHERE `id` = '7'"
        let myUpdateNull = dbEngine.buildUpdate(dialect: .mysql, database: "app", table: "users",
            pk: [("id", "7")], setColumn: "note", value: nil, isNull: true)
        let dbMyUpdateNull = myUpdateNull.hasSuffix("SET `note` = NULL WHERE `id` = '7'")
        let pgDelete = dbEngine.buildDelete(dialect: .postgres, database: "app", table: "users",
            rows: [[("id", "1")], [("id", "2")]])
        let dbPgDelete = pgDelete == "DELETE FROM \"users\" WHERE (\"id\" = '1') OR (\"id\" = '2')"
        let insFields = [
            DBInsertField(column: "id", dataType: "int", isPrimaryKey: true, nullable: false, useDefault: true),
            DBInsertField(column: "name", dataType: "text", isPrimaryKey: false, nullable: false, text: "Ann"),
            DBInsertField(column: "note", dataType: "text", isPrimaryKey: false, nullable: true, isNull: true)
        ]
        let myInsert = dbEngine.buildInsert(dialect: .mysql, database: "app", table: "users", fields: insFields)
        let dbMyInsert = myInsert == "INSERT INTO `app`.`users` (`name`, `note`) VALUES ('Ann', NULL)"
        let filter = DBFilter(column: "name", operation: .contains, value: "50%_off")
        let mySelect = dbEngine.buildSelect(
            dialect: .mysql, database: "app", table: "users", orderBy: "id", ascending: true,
            limit: 101, offset: 400, filter: filter, cursor: DBPageCursor(column: "id", value: "100")
        ).sql
        let dbKeysetFilter = mySelect.contains("CAST(`name` AS CHAR) LIKE")
            && mySelect.contains("`id` > '100'") && mySelect.contains("ORDER BY `id` ASC")
            && !mySelect.contains("OFFSET") && mySelect.hasSuffix("LIMIT 101")
        let pgSelect = dbEngine.buildSelect(
            dialect: .postgres, database: "app", table: "users", orderBy: nil, ascending: true,
            limit: 51, offset: 200, filter: DBFilter(column: "deleted_at", operation: .isNull, value: ""), cursor: nil
        )
        let dbOffsetFilter = pgSelect.database == "app" && pgSelect.sql.contains("\"deleted_at\" IS NULL")
            && pgSelect.sql.hasSuffix("LIMIT 51 OFFSET 200")
        let csv = DBCSVEncoder.encode(
            columns: ["id", "name", "note"],
            rows: [["1", "Ann, Lee", nil], ["2", "\"Bob\"", "line1\nline2"]]
        )
        let dbCSV = csv == "id,name,note\r\n1,\"Ann, Lee\",\r\n2,\"\"\"Bob\"\"\",\"line1\nline2\"\r\n"
        let decodedCSV = try? DBCSVDecoder.decode(csv)
        let dbCSVDecode = decodedCSV?.columns == ["id", "name", "note"]
            && decodedCSV?.rows == [["1", "Ann, Lee", ""], ["2", "\"Bob\"", "line1\nline2"]]
        let createRequest = DBCreateDatabaseRequest(
            name: "client`data",
            username: "client_user",
            password: "top'secret",
            mysqlCharacterSet: "utf8mb4",
            mysqlAccountHost: "10.%"
        )
        let mysqlCreate = try? dbEngine.databaseCreationPlan(dialect: .mysql, request: createRequest)
        let postgresCreate = try? dbEngine.databaseCreationPlan(dialect: .postgres, request: createRequest)
        let dbCreatePlans = mysqlCreate?.statements.first == "CREATE DATABASE `client``data` CHARACTER SET utf8mb4"
            && mysqlCreate?.statements.last == "GRANT ALL PRIVILEGES ON `client``data`.* TO 'client_user'@'10.%'"
            && mysqlCreate?.previewStatements.joined().contains("top'secret") == false
            && postgresCreate?.statements.last == "CREATE DATABASE \"client`data\" OWNER \"client_user\""
            && postgresCreate?.previewStatements.joined().contains("top'secret") == false
        let emptyCreateRejected = (try? dbEngine.databaseCreationPlan(
            dialect: .mysql,
            request: DBCreateDatabaseRequest(name: "", username: nil, password: nil, mysqlCharacterSet: nil)
        )) == nil
        let controlCreateRejected = (try? dbEngine.databaseCreationPlan(
            dialect: .postgres,
            request: DBCreateDatabaseRequest(name: "bad\nname", username: nil, password: nil, mysqlCharacterSet: nil)
        )) == nil
        let longCreateRejected = (try? dbEngine.databaseCreationPlan(
            dialect: .mysql,
            request: DBCreateDatabaseRequest(
                name: String(repeating: "a", count: 65),
                username: nil,
                password: nil,
                mysqlCharacterSet: nil
            )
        )) == nil
        let mysqlMultibyteLimitAccepted = (try? dbEngine.databaseCreationPlan(
            dialect: .mysql,
            request: DBCreateDatabaseRequest(
                name: String(repeating: "数", count: 64),
                username: nil,
                password: nil,
                mysqlCharacterSet: nil
            )
        )) != nil
        let unsupportedCharsetRejected = (try? dbEngine.databaseCreationPlan(
            dialect: .mysql,
            request: DBCreateDatabaseRequest(name: "valid", username: nil, password: nil, mysqlCharacterSet: "latin1")
        )) == nil
        let missingPasswordRejected = (try? dbEngine.databaseCreationPlan(
            dialect: .postgres,
            request: DBCreateDatabaseRequest(name: "valid", username: "app_user", password: "", mysqlCharacterSet: nil)
        )) == nil
        let invalidAccountHostRejected = (try? dbEngine.databaseCreationPlan(
            dialect: .mysql,
            request: DBCreateDatabaseRequest(
                name: "valid",
                username: "app_user",
                password: "test-only",
                mysqlCharacterSet: nil,
                mysqlAccountHost: "bad\nhost"
            )
        )) == nil
        let invalidCreateRejected = emptyCreateRejected && controlCreateRejected && longCreateRejected
            && unsupportedCharsetRejected && missingPasswordRejected && invalidAccountHostRejected
            && mysqlMultibyteLimitAccepted
        let escapedOptionValue = dbEngine.mysqlScript(
            sql: "SELECT 1",
            database: nil,
            credential: DBCredential(
                username: "line\nbreak",
                password: "tab\tvalue",
                host: "db\rhost",
                port: 3306
            ),
            adminSudo: "",
            header: false
        )
        let dbOptionFileEscaped = !escapedOptionValue.contains("line\nbreak")
            && !escapedOptionValue.contains("tab\tvalue")
            && !escapedOptionValue.contains("db\rhost")
            && escapedOptionValue.contains("line\\nbreak")
            && escapedOptionValue.contains("tab\\tvalue")
            && escapedOptionValue.contains("db\\rhost")
        let connectionProfile = DBConnectionProfile(
            id: "manual-test",
            name: "Reporting",
            dialect: .mysql,
            host: "10.0.0.8",
            port: 3307,
            username: "reporter",
            source: .manual
        )
        let profileJSON = (try? JSONEncoder().encode(connectionProfile)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let dbProfileSecretFree = profileJSON.contains("10.0.0.8") && !profileJSON.contains("top'secret")
        let testCredentialID = "opsdeck-db-stage-smoke-\(UUID().uuidString)"
        _ = try? appState.credentialStore.save("test-only", kind: .password, id: testCredentialID)
        let dbHost = HostProfile(
            name: "DBStageTest", host: "127.0.0.1", username: "tester", credentialID: testCredentialID
        )
        let dbSession = ServerSession(host: dbHost, app: appState)
        let stageTarget = DatabaseTarget(
            kind: .mysql, serviceName: "mysql", installed: true,
            serviceInstalled: true, activeState: "active", version: nil
        )
        dbSession.dbState.dbBrowserTarget = stageTarget
        if let stageConnection = DBConnectionProfile.detected(stageTarget) {
            dbSession.dbState.dbConnections = [stageConnection]
            dbSession.dbState.dbSelectedConnectionID = stageConnection.id
        }
        dbSession.dbState.dbSelectedDatabase = "app"
        dbSession.dbState.dbSelectedTable = "users"
        dbSession.dbState.dbColumns = [
            DBColumnInfo(name: "id", dataType: "int", nullable: false, isPrimaryKey: true, defaultValue: nil),
            DBColumnInfo(name: "name", dataType: "varchar", nullable: false, isPrimaryKey: false, defaultValue: nil)
        ]
        dbSession.dbState.dbRows = DBResultSet(columns: ["id", "name"], rows: [["1", "Before"]])
        dbSession.dbRequestUpdateCell(rowIndex: 0, column: "name", newValue: "After", isNull: false)
        let dbStageLocal = dbSession.dbState.dbRows.rows[0][1] == "After" && dbSession.dbState.dbStagedChanges.count == 1
            && dbSession.dbState.dbPendingWrite == nil
        dbSession.dbRequestApplyStagedChanges()
        let dbStageBatch = dbSession.dbState.dbPendingWrite?.sql.contains("START TRANSACTION;") == true
            && dbSession.dbState.dbPendingWrite?.sql.contains("UPDATE `app`.`users`") == true
            && dbSession.dbState.dbPendingWrite?.clearsStagedChanges == true
        dbSession.dbCancelPendingWrite()
        dbSession.dbDiscardStagedChanges()
        let dbStageRevert = dbSession.dbState.dbRows.rows[0][1] == "Before" && dbSession.dbState.dbStagedChanges.isEmpty
        try? appState.credentialStore.delete(id: testCredentialID)
        print(
            "SMOKE_OK db-engine myCredSafe=\(dbMyCredSafe) pgCredSafe=\(dbPgCredSafe) adminPath=\(dbAdminPath) sentinel=\(dbSentinel) myParse=\(dbMyParse) pgParse=\(dbPgParse) myUpdate=\(dbMyUpdate) myUpdateNull=\(dbMyUpdateNull) pgDelete=\(dbPgDelete) myInsert=\(dbMyInsert) keysetFilter=\(dbKeysetFilter) offsetFilter=\(dbOffsetFilter) csv=\(dbCSV) csvDecode=\(dbCSVDecode) createPlans=\(dbCreatePlans) invalidCreateRejected=\(invalidCreateRejected) optionFileEscaped=\(dbOptionFileEscaped) profileSecretFree=\(dbProfileSecretFree) stageLocal=\(dbStageLocal) stageBatch=\(dbStageBatch) stageRevert=\(dbStageRevert)"
        )

        // Phase 4 — guide catalog & read-only help lookup.
        let curatedTopics = appState.guideCatalogService.topics()
        let toolTopics = appState.guideCatalogService.toolTopics(from: catalog)
        let helpPlan = appState.guideCatalogService.helpPlan(binary: "htop", title: "htop")
        let helpReadOnly = helpPlan.risk == .readOnly && helpPlan.steps.allSatisfy { $0.command.contains("--help") }
        let curatedHaveContent = curatedTopics.allSatisfy { !$0.quickStart.isEmpty || !$0.sections.isEmpty }
        print(
            "SMOKE_OK plan-generation-guide curated=\(curatedTopics.count) tools=\(toolTopics.count) helpReadOnly=\(helpReadOnly) curatedHaveContent=\(curatedHaveContent)"
        )

        // Workbench registry & new managed-app modules (firewall / pm2 / certbot).
        let moduleIDs = WorkbenchRegistry.modules.map(\.id)
        let hasExpectedModules = ["services", "installer", "mirror", "shellpath", "nginx", "caddy", "docker", "database", "firewall", "fail2ban", "pm2", "certbot", "cron", "deployment"].allSatisfy { moduleIDs.contains($0) }
        let caddyValidateReadOnly = appState.caddyService.validatePlan(configPath: "/etc/caddy/Caddyfile").risk == .readOnly
        let f2bUnban = appState.fail2banService.unbanPlan(jail: "sshd", ip: "203.0.113.7", profile: profile).steps.contains { $0.command.contains("unbanip") }
        let aptMirror = appState.mirrorService.aptPlan(provider: .aliyun, profile: profile).steps.contains { $0.command.contains("mirrors.aliyun.com") }
        let obtainCert = appState.certbotService.obtainPlan(domains: ["a.example.com", "b.example.com"], method: .nginx, email: "me@example.com", staging: true, cloudflareToken: nil, profile: profile)
        let obtainOK = obtainCert.steps.first?.command.contains("certbot --nginx -d 'a.example.com' -d 'b.example.com'") == true
            && obtainCert.steps.first?.command.contains("--test-cert") == true
            && obtainCert.steps.first?.command.contains("-m 'me@example.com'") == true
        let cfCert = appState.certbotService.obtainPlan(domains: ["a.example.com"], method: .dnsCloudflare, email: nil, staging: false, cloudflareToken: "TOK", profile: profile)
        let cfOK = cfCert.steps.count == 3 && cfCert.steps.last?.command.contains("--dns-cloudflare --dns-cloudflare-credentials") == true
            && cfCert.steps.contains { $0.command.contains("dns_cloudflare_api_token") }
            && cfCert.steps.first?.command.contains("Dpkg::Options::=--force-confmiss") == true
            && cfCert.steps.first?.command.contains("| tail") == false
        let addPath = appState.shellPathService.addPathPlan(dir: "$HOME/.local/bin", shellPath: "/usr/bin/zsh")
        let addPathIdempotent = addPath.steps.contains { $0.command.contains("grep -qF") && $0.command.contains(".zshrc") }
        let fwOpen = appState.firewallService.addRulePlan(action: .allow, direction: .inbound, proto: "tcp", ports: "8080", source: "", comment: "", kind: .ufw, profile: profile)
        let fwOpensAndHighRisk = fwOpen.risk == .high && fwOpen.steps.contains { $0.command.contains("ufw allow") }
        // Rich rule: source + range + comment map to UFW extended syntax; delete by number; ping via sysctl.
        let fwRich = appState.firewallService.addRulePlan(action: .deny, direction: .inbound, proto: "tcp", ports: "6000:6100", source: "203.0.113.7", comment: "block scan", kind: .ufw, profile: profile)
        let fwRichOK = fwRich.steps.contains { $0.command.contains("ufw deny in from") && $0.command.contains("6000:6100") && $0.command.contains("comment") }
        let fwPingOK = appState.firewallService.setPingBlockedPlan(block: true, profile: profile).steps.contains { $0.command.contains("icmp_echo_ignore_all=1") }
        // Enabling the firewall must allow the connected SSH port BEFORE `ufw enable`
        // so it can't lock the user out (the port must appear in an earlier step).
        let fwEnable = appState.firewallService.togglePlan(enable: true, sshPort: 2222, kind: .ufw, profile: profile)
        let allowIdx = fwEnable.steps.firstIndex { $0.command.contains("ufw allow 2222/tcp") }
        let enableIdx = fwEnable.steps.firstIndex { $0.command.contains("ufw --force enable") }
        let fwEnableGuardsSsh = (allowIdx != nil && enableIdx != nil && allowIdx! < enableIdx!)
        let firewalldEnable = appState.firewallService.togglePlan(enable: true, sshPort: 2222, kind: .firewalld, profile: profile)
        let firewalldCommands = firewalldEnable.steps.map(\.command).joined(separator: "\n")
        let firewalldVerified = firewalldCommands.contains("systemctl enable 'firewalld'")
            && firewalldCommands.contains("systemctl start 'firewalld'")
            && firewalldCommands.contains("journalctl -u 'firewalld'")
            && !firewalldCommands.contains("enable --now")
        // Queued-rule (待生效) parsing from `ufw show added` + delete-by-spec.
        let addedRich = FirewallService.parseAddedRule("ufw deny from 203.0.113.7 to any port 19990:19995 proto tcp comment 'x'")
        let fwAddedParse = addedRich?.action == .deny && addedRich?.source.contains("203.0.113.7") == true && addedRich?.port == "19990:19995" && addedRich?.number == 0
        let fwAddedSimple = FirewallService.parseAddedRule("ufw allow 22/tcp")?.port == "22"
        let fwSpecDel = appState.firewallService.deleteRuleSpecPlan(spec: "allow 22/tcp", kind: .ufw, profile: profile).steps.contains { $0.command.contains("ufw delete allow 22/tcp") }
        // Edit = delete old (by spec, removes v4+v6) THEN add new, in order.
        let oldRule = FirewallRule(number: 0, action: .allow, direction: .inbound, proto: "tcp", port: "8080", source: "Anywhere", comment: "", isV6: false, raw: "allow 8080/tcp")
        let fwEdit = appState.firewallService.editRulePlan(old: oldRule, action: .deny, direction: .inbound, proto: "tcp", ports: "9090", source: "", comment: "edited", kind: .ufw, profile: profile)
        let delIdx = fwEdit.steps.firstIndex { $0.command.contains("ufw delete allow 8080/tcp") }
        let addIdx = fwEdit.steps.firstIndex { $0.command.contains("ufw deny") && $0.command.contains("9090") }
        let fwEditOK = (delIdx != nil && addIdx != nil && delIdx! < addIdx!)
        let pm2Sample = PM2Process(id: "0", name: "api", status: "online", cpu: "1%", memory: "40 MB", restarts: "2")
        let pm2Restart = appState.pm2Service.actionPlan(.restart, process: pm2Sample)
        let pm2RestartOK = pm2Restart.steps.contains { $0.command.contains("pm2 restart") }
        let certDry = appState.certbotService.renewPlan(certName: "example.com", dryRun: true, profile: profile)
        let certDryReadOnly = certDry.risk == .readOnly && certDry.steps.contains { $0.command.contains("--dry-run") }
        print(
            "SMOKE_OK plan-generation-workbench modules=\(moduleIDs.count) hasExpected=\(hasExpectedModules) fwOpenHighRisk=\(fwOpensAndHighRisk) fwRich=\(fwRichOK) fwPing=\(fwPingOK) fwEnableGuardsSsh=\(fwEnableGuardsSsh) firewalldVerified=\(firewalldVerified) fwAddedParse=\(fwAddedParse) fwAddedSimple=\(fwAddedSimple) fwSpecDel=\(fwSpecDel) fwEdit=\(fwEditOK) pm2Restart=\(pm2RestartOK) certDryReadOnly=\(certDryReadOnly) caddyValidateReadOnly=\(caddyValidateReadOnly) f2bUnban=\(f2bUnban) aptMirror=\(aptMirror) addPathIdempotent=\(addPathIdempotent) obtainCert=\(obtainOK) cfDnsCert=\(cfOK)"
        )
    }

    private static func runSSHSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let result = try await appState.sshService.runConnectionTest(config: config)
        let output = result.stdout
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print("SMOKE_OK ssh command=\(result.command) stdout=\(output)")
    }

    private static func runSSHStreamSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let startedAt = Date()
        let command = ProcessInfo.processInfo.environment["OPSDECK_SMOKE_COMMAND"]
            ?? "printf 'stream-one\\n'; sleep 1; printf 'stream-two\\n'"
        let stream = await appState.sshService.executeCommandStream(
            command,
            on: config,
            maxResponseSize: 16 * 1024
        )
        var chunks: [SSHCommandStreamChunk] = []
        var firstChunkDelay: TimeInterval?
        for try await chunk in stream {
            if firstChunkDelay == nil {
                firstChunkDelay = Date().timeIntervalSince(startedAt)
            }
            chunks.append(chunk)
        }
        let output = String(decoding: chunks.flatMap(\.bytes), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "|")
        print(
            "SMOKE_OK ssh-stream chunks=\(chunks.count) first=\(String(format: "%.2fs", firstChunkDelay ?? -1)) total=\(String(format: "%.2fs", Date().timeIntervalSince(startedAt))) output=\(output)"
        )
    }

    /// A database browse performs several short commands in sequence. The first
    /// command may pay for the SSH handshake; the second must reuse that transport.
    private static func runSSHReuseSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        do {
            let first = try await appState.sshService.executeCommand(
                "printf 'first'",
                on: config,
                maxResponseSize: 1_024
            )
            let second = try await appState.sshService.executeCommand(
                "printf 'second'",
                on: config,
                maxResponseSize: 1_024
            )
            await appState.sshService.disconnect(config: config)
            print(
                "SMOKE_OK ssh-reuse first=\(String(format: "%.3fs", first.duration)) second=\(String(format: "%.3fs", second.duration)) outputs=\(first.stdout),\(second.stdout)"
            )
        } catch {
            await appState.sshService.disconnect(config: config)
            throw error
        }
    }

    private static func runServerProfileSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let os = profile.osName ?? "unknown"
        let arch = profile.architecture ?? "unknown"
        let tools = profile.installedTools.prefix(8).map(\.name).joined(separator: ",")
        let services = profile.installedServices.prefix(6).map { "\($0.name):\($0.activeState ?? "unknown")" }.joined(separator: ",")
        print("SMOKE_OK server-profile os=\(os) arch=\(arch) pm=\(profile.packageManager.displayName) init=\(profile.initSystem.displayName) sudo=\(profile.sudoStatus.displayName) tools=\(tools) services=\(services)")
    }

    /// End-to-end write-path verification against a real server: install a safe
    /// tool, confirm it's detected, uninstall it, confirm it's gone — plus mirror
    /// and shell/PATH collection. Drives the actual app services/runbooks.
    private static func runWriteVerifySmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let hostID = UUID()
        let toolID = ProcessInfo.processInfo.environment["OPSDECK_SMOKE_TOOL"] ?? "tree"

        func exec(_ plan: RunbookPlan) async -> RunbookRun {
            await appState.runbookService.execute(plan: plan, hostID: hostID, config: config, sshService: appState.sshService)
        }
        func installed(_ profile: ServerProfileSnapshot, _ id: String) -> Bool {
            guard let tool = appState.installerCatalogService.catalog().first(where: { $0.id == id }) else { return false }
            return tool.installedTool(on: profile) != nil
        }

        let profile0 = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        guard let tool = appState.installerCatalogService.catalog().first(where: { $0.id == toolID }) else {
            print("SMOKE_FAIL write-verify no tool \(toolID)")
            return
        }

        let installRun = await exec(appState.installerCatalogService.installPlan(tool: tool, profile: profile0))
        let profileAfterInstall = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let isInstalled = installed(profileAfterInstall, toolID)

        // Service-tool specific checks post-install.
        var extra = ""
        if toolID == "nginx" {
            let n = try await appState.nginxManagerService.collect(config: config, sshService: appState.sshService)
            extra = " nginxInstalled=\(n.isInstalled) nginxConfig=\(n.configPath ?? "nil")"
        } else if toolID == "ufw" || toolID == "firewalld" {
            let f = try await appState.firewallService.collect(profile: profileAfterInstall, config: config, sshService: appState.sshService)
            extra = " fwKind=\(f.kind.rawValue) fwActive=\(f.active)"
        } else if toolID == "docker" {
            let d = try await appState.dockerManagerService.collect(config: config, sshService: appState.sshService)
            extra = " dockerInstalled=\(d.isInstalled) daemon=\(d.daemonReachable)"
        }
        if !extra.isEmpty { print("SMOKE_OK write-verify-extra\(extra)") }

        let uninstallRun = await exec(appState.installerCatalogService.uninstallPlan(tool: tool, profile: profileAfterInstall))
        let profileAfterUninstall = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let isGone = !installed(profileAfterUninstall, toolID)

        let mirror = try await appState.mirrorService.collect(config: config, sshService: appState.sshService)
        let shellPath = try await appState.shellPathService.collect(config: config, sshService: appState.sshService)

        func label(_ s: RunbookStatus) -> String { s == .succeeded ? "ok" : "FAIL(\(s.rawValue))" }
        print("SMOKE_OK write-verify tool=\(toolID) install=\(label(installRun.status)) detected=\(isInstalled) uninstall=\(label(uninstallRun.status)) gone=\(isGone) aptMirror=\(mirror.aptSource) npm=\(mirror.npmRegistry) shells=[\(shellPath.shells.map(\.name).joined(separator: ","))] loginShell=\((shellPath.loginShell as NSString).lastPathComponent) pathNeedsFix=\(shellPath.candidates.filter(\.needsFix).count)")
        if installRun.status != .succeeded {
            print("SMOKE_DETAIL install-fail: \(installRun.failureSummary ?? "?")")
        }
        if uninstallRun.status != .succeeded {
            print("SMOKE_DETAIL uninstall-fail: \(uninstallRun.failureSummary ?? "?")")
        }
    }

    /// Firewall: add a benign simple + rich rule, confirm the parser reads them
    /// back, delete by number, verify gone, and round-trip 禁ping. Only touches
    /// high test ports (never the SSH rule) so it can't lock the session out.
    private static func runFirewallVerifySmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let fw = appState.firewallService
        func snap() async throws -> FirewallSnapshot {
            try await fw.collect(profile: profile, config: config, sshService: appState.sshService)
        }
        func run(_ plan: RunbookPlan) async -> RunbookRun {
            await appState.runbookService.execute(plan: plan, hostID: UUID(), config: config, sshService: appState.sshService)
        }
        let sudo = OpsShell.sudoPrefix(for: profile)
        let s0 = try await snap()
        guard s0.kind == .ufw else { print("SMOKE_SKIP verify-firewall kind=\(s0.kind.rawValue)"); return }
        let wasActive = s0.active

        // --- Toggle: enable (22-guarded so we can't lock ourselves out) ---
        _ = await run(fw.addRulePlan(action: .allow, direction: .inbound, proto: "tcp", ports: "22", source: "", comment: "opsdeck-ssh-guard", kind: .ufw, profile: profile))
        _ = await run(fw.togglePlan(enable: true, sshPort: config.port, kind: .ufw, profile: profile))
        let enabledOK = (try? await snap())?.active == true

        // --- Add a battery covering every rule variation ---
        var addOK = true
        func add(_ a: FirewallAction, _ d: FirewallDirection, _ p: String, _ ports: String, _ src: String) async {
            let r = await run(fw.addRulePlan(action: a, direction: d, proto: p, ports: ports, source: src, comment: "opsdeck-test", kind: .ufw, profile: profile))
            if r.status != .succeeded { addOK = false }
        }
        await add(.allow, .inbound, "tcp", "19999", "")            // simple allow tcp
        await add(.deny, .inbound, "tcp", "19990:19995", "203.0.113.7") // deny + range + source
        await add(.allow, .outbound, "tcp", "19980", "")           // out direction
        await add(.allow, .inbound, "udp", "19970", "")            // udp
        await add(.allow, .inbound, "both", "19960", "")           // tcp+udp
        await add(.allow, .inbound, "tcp", "19950,19951", "")      // multi-port

        let s1 = try await snap()
        func has(_ pred: (FirewallRule) -> Bool) -> Bool { s1.rules.contains(where: pred) }
        let vAllow = has { $0.port == "19999" && $0.action == .allow && $0.proto == "tcp" }
        let vDenyRange = has { $0.port == "19990:19995" && $0.action == .deny && $0.source.contains("203.0.113.7") }
        let vOut = has { $0.port == "19980" && $0.direction == .outbound }
        let vUdp = has { $0.port == "19970" && $0.proto == "udp" }
        let vBoth = has { $0.port == "19960" }
        let vMulti = has { $0.port == "19950" } && has { $0.port == "19951" }

        // --- Delete every test rule by spec (removes both v4 and v6) ---
        for rule in s1.rules.filter({ $0.comment.contains("opsdeck-test") }) {
            _ = await run(fw.deleteRuleSpecPlan(spec: rule.raw, kind: .ufw, profile: profile))
        }
        // Belt-and-suspenders sweep for any leftover test rows.
        _ = try? await appState.sshService.executeCommand("for i in $(\(sudo)ufw status numbered | grep opsdeck-test | grep -oE '\\[ *[0-9]+' | grep -oE '[0-9]+' | sort -rn); do \(sudo)ufw --force delete $i; done", on: config, maxResponseSize: 4096)
        let s2 = try await snap()
        let deletedGone = !s2.rules.contains { $0.comment.contains("opsdeck-test") }
        let guard22 = s2.rules.first(where: { $0.comment.contains("opsdeck-ssh-guard") })?.raw

        // --- 禁ping round-trip ---
        _ = await run(fw.setPingBlockedPlan(block: true, profile: profile))
        let pingOn = (try? await snap())?.pingBlocked == true
        _ = await run(fw.setPingBlockedPlan(block: false, profile: profile))
        let pingOff = (try? await snap())?.pingBlocked == false

        // --- Restore original state: disable if it started inactive; drop the 22 guard ---
        if !wasActive { _ = await run(fw.togglePlan(enable: false, sshPort: config.port, kind: .ufw, profile: profile)) }
        if let g = guard22 { _ = await run(fw.deleteRuleSpecPlan(spec: g, kind: .ufw, profile: profile)) }
        _ = try? await appState.sshService.executeCommand("for i in $(\(sudo)ufw status numbered 2>/dev/null | grep opsdeck | grep -oE '\\[ *[0-9]+' | grep -oE '[0-9]+' | sort -rn); do \(sudo)ufw --force delete $i; done", on: config, maxResponseSize: 4096)
        let disabledOK: Bool
        if wasActive { disabledOK = true } else { disabledOK = (try? await snap())?.active == false }

        print("SMOKE_OK verify-firewall enable=\(enabledOK) allow=\(vAllow) denyRange=\(vDenyRange) out=\(vOut) udp=\(vUdp) both=\(vBoth) multi=\(vMulti) addOK=\(addOK) rulesSeen=\(s1.rules.count) delGone=\(deletedGone) pingOn=\(pingOn) pingOff=\(pingOff) disable=\(disabledOK)")
    }

    private static func exec(_ appState: AppState, _ config: SSHConnectionConfig, _ plan: RunbookPlan) async -> RunbookRun {
        await appState.runbookService.execute(plan: plan, hostID: UUID(), config: config, sshService: appState.sshService)
    }
    private static func ok(_ s: RunbookStatus) -> String { s == .succeeded ? "ok" : "FAIL(\(s.rawValue))" }

    /// apt mirror switch → verify apt update works with the new mirror → restore
    /// the original source from the backup so the box is left unchanged.
    private static func runMirrorVerifySmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let dump = try await appState.sshService.executeCommand(
            "ls -1 /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; echo '---'; grep -rEn 'URIs|deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -vE '^\\s*#' | head -12",
            on: config, maxResponseSize: 8 * 1024)
        print("SMOKE_DUMP apt-sources:\n\(dump.stdout)")
        let before = try await appState.mirrorService.collect(config: config, sshService: appState.sshService)
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let switchRun = await exec(appState, config, appState.mirrorService.aptPlan(provider: .aliyun, profile: profile))
        let after = try await appState.mirrorService.collect(config: config, sshService: appState.sshService)
        // Restore original sources from the .opsdeck-bak backups the plan made.
        let restore = RunbookPlan(
            kind: .audit, title: "还原 apt 源", summary: "恢复备份", targetDescription: "apt",
            risk: .medium, requiresSudo: true, backupDescription: nil, rollbackDescription: nil,
            steps: [RunbookStep(title: "还原", command: "for b in $(find /etc/apt -name '*.opsdeck-bak' 2>/dev/null); do sudo cp -a \"$b\" \"${b%.opsdeck-bak}\"; sudo rm -f \"$b\"; done; sudo apt-get update >/dev/null 2>&1; echo restored")]
        )
        let restoreRun = await exec(appState, config, restore)
        let restored = try await appState.mirrorService.collect(config: config, sshService: appState.sshService)
        print("SMOKE_OK verify-mirror before=\(before.aptSource) switch=\(ok(switchRun.status)) after=\(after.aptSource) switchedToAliyun=\(after.aptSource.contains("aliyun")) restore=\(ok(restoreRun.status)) restoredTo=\(restored.aptSource)")
        if switchRun.status != .succeeded { print("SMOKE_DETAIL mirror-switch: \(switchRun.failureSummary ?? "?")") }
    }

    /// Install zsh → chsh to zsh → verify login shell changed → chsh back to bash.
    private static func runShellVerifySmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        var installNote = "already"
        if let zshTool = appState.installerCatalogService.catalog().first(where: { $0.id == "zsh" }),
           profile.tool(named: "zsh")?.isInstalled != true {
            let r = await exec(appState, config, appState.installerCatalogService.installPlan(tool: zshTool, profile: profile))
            installNote = ok(r.status)
        }
        let sp0 = try await appState.shellPathService.collect(config: config, sshService: appState.sshService)
        guard let zsh = sp0.shells.first(where: { $0.name == "zsh" }) else {
            print("SMOKE_OK verify-shell zshInstall=\(installNote) result=FAIL(no-zsh-shell)")
            return
        }
        let toZsh = await exec(appState, config, appState.shellPathService.setDefaultShellPlan(shell: zsh, profile: profile))
        let sp1 = try await appState.shellPathService.collect(config: config, sshService: appState.sshService)
        let becameZsh = (sp1.loginShell as NSString).lastPathComponent == "zsh"
        var restoredToBash = false
        if let bash = sp1.shells.first(where: { $0.name == "bash" }) {
            _ = await exec(appState, config, appState.shellPathService.setDefaultShellPlan(shell: bash, profile: profile))
            let sp2 = try await appState.shellPathService.collect(config: config, sshService: appState.sshService)
            restoredToBash = (sp2.loginShell as NSString).lastPathComponent == "bash"
        }
        print("SMOKE_OK verify-shell zshInstall=\(installNote) chshToZsh=\(ok(toZsh.status)) loginBecameZsh=\(becameZsh) restoredToBash=\(restoredToBash)")
    }

    /// Install Node → install PM2 → verify PM2 collection sees it installed.
    private static func runPM2VerifySmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let catalog = appState.installerCatalogService.catalog()
        var nodeNote = "already"
        if profile.tool(named: "node")?.isInstalled != true, profile.tool(named: "nodejs")?.isInstalled != true,
           let node = catalog.first(where: { $0.id == "node" }) {
            let r = await exec(appState, config, appState.installerCatalogService.installPlan(tool: node, profile: profile))
            nodeNote = ok(r.status)
        }
        let profile1 = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        var pm2Note = "skip"
        if let pm2 = catalog.first(where: { $0.id == "pm2" }) {
            let r = await exec(appState, config, appState.installerCatalogService.installPlan(tool: pm2, profile: profile1))
            pm2Note = ok(r.status)
        }
        let snap = try await appState.pm2Service.collect(config: config, sshService: appState.sshService)
        print("SMOKE_OK verify-pm2 nodeInstall=\(nodeNote) pm2Install=\(pm2Note) pm2Installed=\(snap.installed) processes=\(snap.processes.count)")
    }

    /// Install PostgreSQL → verify DB detection → run the read-only inspect plan.
    private static func runDBVerifySmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        var pgNote = "already"
        if let pg = appState.installerCatalogService.catalog().first(where: { $0.id == "postgresql" }),
           profile.tool(named: "psql")?.isInstalled != true {
            let r = await exec(appState, config, appState.installerCatalogService.installPlan(tool: pg, profile: profile))
            pgNote = ok(r.status)
        }
        let profile1 = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let dbs = try await appState.databaseManagerService.collect(profile: profile1, config: config, sshService: appState.sshService)
        let pg = dbs.first(where: { $0.kind == .postgresql })
        var inspectNote = "skip"
        if let pg {
            let r = await exec(appState, config, appState.databaseManagerService.inspectPlan(database: pg, profile: profile1))
            inspectNote = ok(r.status)
        }

        let whoami = try await appState.sshService.executeCommand("id -un", on: config, maxResponseSize: 256)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clean prior backup output so ownership/listing checks are unambiguous.
        _ = try? await appState.sshService.executeCommand("rm -f $HOME/opsdeck-backups/*", on: config, maxResponseSize: 256)

        // Postgres backup (uses sudo -u postgres) — confirm it runs and the file
        // ends up owned by the SSH user (shell owns the `>` redirect).
        var pgBackup = "skip", pgOwned = "skip"
        if let pg {
            let r = await exec(appState, config, appState.databaseManagerService.backupPlan(database: pg, profile: profile1))
            pgBackup = ok(r.status)
            let owner = try await appState.sshService.executeCommand(
                "stat -c %U $HOME/opsdeck-backups/postgresql-*.sql 2>/dev/null | head -1",
                on: config, maxResponseSize: 256
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            pgOwned = owner == whoami ? "yes" : "NO(\(owner))"
        }

        // Redis backup — THE fix under test: sudo cp of the root-owned dump.rdb,
        // then chown back so the (non-root) SFTP session can download it.
        var redisInstall = "already", redisBackup = "skip", redisOwned = "skip", redisDownload = "skip"
        if profile1.tool(named: "redis-cli")?.isInstalled != true,
           let redis = appState.installerCatalogService.catalog().first(where: { $0.id == "redis" }) {
            let r = await exec(appState, config, appState.installerCatalogService.installPlan(tool: redis, profile: profile1))
            redisInstall = ok(r.status)
        }
        let profile2 = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let dbs2 = try await appState.databaseManagerService.collect(profile: profile2, config: config, sshService: appState.sshService)
        if let redis = dbs2.first(where: { $0.kind == .redis }) {
            let r = await exec(appState, config, appState.databaseManagerService.backupPlan(database: redis, profile: profile2))
            redisBackup = ok(r.status)
            let path = try await appState.sshService.executeCommand(
                "ls $HOME/opsdeck-backups/redis-*.rdb 2>/dev/null | head -1",
                on: config, maxResponseSize: 512
            ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty {
                redisOwned = "NO(missing)"
            } else {
                let owner = try await appState.sshService.executeCommand(
                    "stat -c %U \(OpsShell.quote(path))", on: config, maxResponseSize: 256
                ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                redisOwned = owner == whoami ? "yes" : "NO(\(owner))"
                // Prove downloadable over the non-root SFTP session.
                redisDownload = (try? await appState.sftpService.downloadTail(remotePath: path, maxBytes: 4096, config: config)) != nil ? "yes" : "NO"
            }
        }

        // Restore baseline: remove backups + uninstall the redis we added.
        _ = try? await appState.sshService.executeCommand("rm -rf $HOME/opsdeck-backups", on: config, maxResponseSize: 256)
        if redisInstall != "already",
           let redis = appState.installerCatalogService.catalog().first(where: { $0.id == "redis" }) {
            _ = await exec(appState, config, appState.installerCatalogService.uninstallPlan(tool: redis, profile: profile2))
        }

        print("SMOKE_OK verify-db pgInstall=\(pgNote) dbCount=\(dbs.count) pgActive=\(pg?.activeState ?? "nil") inspect=\(inspectNote) pgBackup=\(pgBackup) pgOwned=\(pgOwned) redisInstall=\(redisInstall) redisBackup=\(redisBackup) redisOwned=\(redisOwned) redisDownload=\(redisDownload)")
    }

    /// Re-run the real Redis install plan against a package whose conffile may
    /// have been deleted. The expected end state is a restored package-owned
    /// config, an active service and a working local PING. Nothing is removed.
    private static func runRedisRepairSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let profile = try await appState.serverProfileService.collect(
            config: config,
            sshService: appState.sshService
        )
        guard let redis = appState.installerCatalogService.catalog().first(where: { $0.id == "redis" }) else {
            throw NSError(domain: "OpsDeckSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Redis tool definition missing"])
        }
        let run = await exec(
            appState,
            config,
            appState.installerCatalogService.installPlan(tool: redis, profile: profile)
        )
        guard run.status == .succeeded else {
            throw NSError(
                domain: "OpsDeckSmoke",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: run.failureSummary ?? "Redis repair runbook failed"]
            )
        }
        let verification = try await appState.sshService.executeCommand(
            """
            set -e
            sudo -n test -f /etc/redis/redis.conf
            test "$(systemctl is-active redis-server)" = active
            test "$(redis-cli ping)" = PONG
            if sudo -n dpkg --verify redis-server 2>/dev/null | grep -Eq '^missing[[:space:]]+c[[:space:]]'; then exit 1; fi
            """,
            on: config,
            maxResponseSize: 4 * 1024
        )
        print("SMOKE_OK redis-repair runbook=ok config=true active=true ping=PONG verify=clean output=\(verification.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// Exercises the same bounded service used by the Redis UI against a real
    /// server. DB 15 and a UUID key keep the run isolated; cleanup is attempted
    /// on every exit path and no existing keys are enumerated or modified.
    private static func runRedisManagerSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let service = appState.redisManagerService
        let database = 15
        let key = "opsdeck:smoke:\(UUID().uuidString.lowercased())"
        let firstValue = "hello-redis"
        let updatedValue = "updated-redis"

        func cleanup() async {
            try? await service.deleteKey(
                database: database,
                key: key,
                credential: nil,
                config: config,
                sshService: appState.databaseSSHService
            )
        }

        await cleanup()
        do {
            let snapshot = try await service.loadSnapshot(
                credential: nil,
                config: config,
                sshService: appState.databaseSSHService
            )
            try await service.setString(
                database: database,
                key: key,
                value: firstValue,
                preserveTTL: false,
                credential: nil,
                config: config,
                sshService: appState.databaseSSHService
            )
            try await service.setTTL(
                database: database,
                key: key,
                seconds: 600,
                credential: nil,
                config: config,
                sshService: appState.databaseSSHService
            )
            let page = try await service.scanKeys(
                database: database,
                cursor: "0",
                pattern: key,
                credential: nil,
                config: config,
                sshService: appState.databaseSSHService
            )
            let firstDetail = try await service.loadKeyDetail(
                database: database,
                key: key,
                credential: nil,
                config: config,
                sshService: appState.databaseSSHService
            )
            try await service.setString(
                database: database,
                key: key,
                value: updatedValue,
                preserveTTL: true,
                credential: nil,
                config: config,
                sshService: appState.databaseSSHService
            )
            let updatedDetail = try await service.loadKeyDetail(
                database: database,
                key: key,
                credential: nil,
                config: config,
                sshService: appState.databaseSSHService
            )
            try await service.deleteKey(
                database: database,
                key: key,
                credential: nil,
                config: config,
                sshService: appState.databaseSSHService
            )
            let afterDelete = try await service.scanKeys(
                database: database,
                cursor: "0",
                pattern: key,
                credential: nil,
                config: config,
                sshService: appState.databaseSSHService
            )

            let snapshotOK = snapshot.version?.isEmpty == false
            let scanOK = page.keys.contains { $0.name == key && $0.type == "string" }
            let detailOK = firstDetail.entries.first?.value == firstValue && firstDetail.ttlSeconds > 0
            let updateOK = updatedDetail.entries.first?.value == updatedValue && updatedDetail.ttlSeconds > 0
            let cleanupOK = !afterDelete.keys.contains { $0.name == key }
            print("SMOKE_OK redis-manager snapshot=\(snapshotOK) scan=\(scanOK) detail=\(detailOK) ttlPreserved=\(updateOK) cleanup=\(cleanupOK)")
        } catch {
            await cleanup()
            throw error
        }
    }

    /// certbot (install + list, no issuance) + fail2ban (install + jails) +
    /// cron (read-only) + oh-my-zsh (install; may fail from CN networks).
    private static func runExtrasVerifySmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let catalog = appState.installerCatalogService.catalog()

        // certbot
        var certbotNote = "already"
        if profile.tool(named: "certbot")?.isInstalled != true, let c = catalog.first(where: { $0.id == "certbot" }) {
            certbotNote = ok(await exec(appState, config, appState.installerCatalogService.installPlan(tool: c, profile: profile)).status)
        }
        let certSnap = try await appState.certbotService.collect(profile: profile, config: config, sshService: appState.sshService)
        let renewDry = await exec(appState, config, appState.certbotService.renewPlan(certName: nil, dryRun: true, profile: profile))
        print("SMOKE_OK verify-certbot install=\(certbotNote) certbotInstalled=\(certSnap.installed) certs=\(certSnap.certificates.count) renewDryRun=\(ok(renewDry.status))")

        // fail2ban
        var f2bNote = "already"
        if profile.tool(named: "fail2ban-client")?.isInstalled != true, let f = catalog.first(where: { $0.id == "fail2ban" }) {
            f2bNote = ok(await exec(appState, config, appState.installerCatalogService.installPlan(tool: f, profile: profile)).status)
        }
        let f2bSnap = try await appState.fail2banService.collect(profile: profile, config: config, sshService: appState.sshService)
        let banned = f2bSnap.jails.reduce(0) { $0 + $1.currentlyBanned }
        print("SMOKE_OK verify-fail2ban install=\(f2bNote) installed=\(f2bSnap.installed) active=\(f2bSnap.active) jails=[\(f2bSnap.jails.map(\.name).joined(separator: ","))] banned=\(banned)")

        // cron (read-only)
        let cron = try await appState.cronService.collect(config: config, sshService: appState.sshService)
        print("SMOKE_OK verify-cron jobs=\(cron.jobs.count) sources=[\(Set(cron.jobs.map(\.source)).sorted().joined(separator: ","))]")

        // oh-my-zsh (install script from GitHub; likely slow/blocked from CN)
        let omz = await exec(appState, config, appState.shellPathService.installOhMyZshPlan())
        let omzCheck = try await appState.sshService.executeCommand("[ -d \"$HOME/.oh-my-zsh\" ] && echo yes || echo no", on: config, maxResponseSize: 1024)
        print("SMOKE_OK verify-omz exec=\(ok(omz.status)) installed=\(omzCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        if omz.status != .succeeded { print("SMOKE_DETAIL omz: \(omz.failureSummary ?? "?")") }
    }

    /// Remove everything the verification runs installed, returning the box to a
    /// near-clean state.
    private static func runCleanupSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let cmd = """
        opsdeck_cleanup_log="$(mktemp)"
        trap 'rm -f "$opsdeck_cleanup_log"' EXIT
        sudo systemctl stop fail2ban postgresql 2>/dev/null
        npm rm -g pm2 2>/dev/null
        sudo apt-get -o DPkg::Lock::Timeout=240 remove --purge -y zsh nodejs npm certbot python3-certbot-nginx fail2ban tree cowsay ufw nginx docker.io 'postgresql*' >"$opsdeck_cleanup_log" 2>&1
        opsdeck_cleanup_rc=$?
        tail -6 "$opsdeck_cleanup_log"
        if [ "$opsdeck_cleanup_rc" -ne 0 ]; then exit "$opsdeck_cleanup_rc"; fi
        sudo apt-get -o DPkg::Lock::Timeout=240 autoremove --purge -y >"$opsdeck_cleanup_log" 2>&1
        opsdeck_cleanup_rc=$?
        tail -3 "$opsdeck_cleanup_log"
        if [ "$opsdeck_cleanup_rc" -ne 0 ]; then exit "$opsdeck_cleanup_rc"; fi
        sudo rm -f /usr/local/bin/pm2 /usr/bin/pm2 "$HOME/.local/bin/pm2" 2>/dev/null
        sudo rm -rf /usr/local/lib/node_modules "$HOME/.pm2" 2>/dev/null
        sudo rm -rf /etc/letsencrypt /var/log/letsencrypt /etc/nginx 2>/dev/null
        rm -rf "$HOME/.oh-my-zsh" "$HOME/.local/bin/uv" "$HOME/.local/share/uv" 2>/dev/null
        for b in $(find /etc/apt -name '*.opsdeck-bak' 2>/dev/null); do sudo cp -a "$b" "${b%.opsdeck-bak}" 2>/dev/null; sudo rm -f "$b"; done
        echo CLEANUP_DONE
        """
        let plan = RunbookPlan(kind: .audit, title: "清理测试机", summary: "卸载验证期间安装的组件", targetDescription: "test box", risk: .high, requiresSudo: true, backupDescription: nil, rollbackDescription: nil, steps: [RunbookStep(title: "清理", command: cmd)])
        let run = await exec(appState, config, plan)
        print("SMOKE_DETAIL cleanup-output:\n\(String((run.steps.last?.output ?? "").suffix(600)))")
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let remaining = ["zsh", "node", "pm2", "psql", "certbot", "fail2ban-client", "tree", "docker", "nginx"].filter { profile.tool(named: $0)?.isInstalled == true }
        print("SMOKE_OK cleanup status=\(ok(run.status)) stillInstalled=[\(remaining.joined(separator: ","))]")
    }

    /// Real Let's Encrypt issuance against a domain pointed at this box: install
    /// nginx + certbot, run `certbot --nginx`, then confirm the app's certbot
    /// module lists the new cert and renew-dry-run works.
    private static func runCertbotIssueSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let domain = ProcessInfo.processInfo.environment["OPSDECK_SMOKE_DOMAIN"] ?? "test.liyunping.top"
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        if profile.tool(named: "nginx")?.isInstalled != true, let n = appState.installerCatalogService.catalog().first(where: { $0.id == "nginx" }) {
            _ = await exec(appState, config, appState.installerCatalogService.installPlan(tool: n, profile: profile))
        }
        let prep = RunbookPlan(kind: .install, title: "准备 certbot", summary: "", targetDescription: domain, risk: .medium, requiresSudo: true, backupDescription: nil, rollbackDescription: nil, steps: [
            RunbookStep(
                title: "装 certbot+nginx 插件",
                command: OpsShell.unattendedAptInstall(
                    packages: ["certbot", "python3-certbot-nginx"],
                    sudo: "sudo -n "
                ) + "\n" + OpsShell.systemdEnableAndStart(serviceName: "nginx", sudo: "sudo -n ")
            )
        ])
        _ = await exec(appState, config, prep)
        let issue = RunbookPlan(kind: .audit, title: "签发证书", summary: "", targetDescription: domain, risk: .medium, requiresSudo: true, backupDescription: nil, rollbackDescription: nil, steps: [
            RunbookStep(title: "certbot --nginx", command: "sudo certbot --nginx -d \(domain) --non-interactive --agree-tos --register-unsafely-without-email --redirect 2>&1 | tail -25")
        ])
        let issueRun = await exec(appState, config, issue)
        let certSnap = try? await appState.certbotService.collect(profile: profile, config: config, sshService: appState.sshService)
        let renewDry = await exec(appState, config, appState.certbotService.renewPlan(certName: nil, dryRun: true, profile: profile))
        print("SMOKE_OK certbot-issue domain=\(domain) issue=\(ok(issueRun.status)) certs=\(certSnap?.certificates.count ?? -1) names=[\(certSnap?.certificates.map(\.name).joined(separator: ",") ?? "collect-threw")] expiry=\(certSnap?.certificates.first?.validDays ?? "?")天 renewDry=\(ok(renewDry.status))")
        print("SMOKE_DETAIL certbot-output:\n\(String((issueRun.steps.last?.output ?? "").suffix(900)))")
    }

    /// Reproduce the "install succeeded but panel didn't refresh" bug: sit on
    /// the certbot module with a stale "not installed" snapshot, install certbot,
    /// then run the post-runbook refresh and confirm the panel flips to installed.
    @MainActor
    private static func runRefreshVerifySmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        appState.selectedWorkspaceMode = .tools
        appState.selectedWorkbenchModuleID = "certbot"
        appState.certbotSnapshot = CertbotSnapshot(installed: false, certificates: [])
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        if profile.tool(named: "certbot")?.isInstalled != true, let c = appState.installerCatalogService.catalog().first(where: { $0.id == "certbot" }) {
            _ = await exec(appState, config, appState.installerCatalogService.installPlan(tool: c, profile: profile))
        }
        let before = appState.certbotSnapshot?.installed ?? false
        await appState.refreshCurrentWorkbenchModuleData(config: config)
        let after = appState.certbotSnapshot?.installed ?? false
        print("SMOKE_OK verify-refresh beforeRefresh=\(before) afterRefresh=\(after) fixed=\(!before && after)")
    }

    private static func runOperationsReadSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let profile = try await appState.serverProfileService.collect(config: config, sshService: appState.sshService)
        let services = try await appState.serviceManagerService.collect(config: config, sshService: appState.sshService)
        let logs = try await appState.logDiscoveryService.discover(config: config, sshService: appState.sshService)
        let nginx = try await appState.nginxManagerService.collect(config: config, sshService: appState.sshService)
        let docker = try await appState.dockerManagerService.collect(config: config, sshService: appState.sshService)
        let databases = try await appState.databaseManagerService.collect(profile: profile, config: config, sshService: appState.sshService)
        let audit = try await appState.securityAuditService.collect(profile: profile, config: config, sshService: appState.sshService)
        let firstLog = logs.first.map(\.title) ?? "none"
        let firstLogBytes: Int
        if let first = logs.first {
            firstLogBytes = try await appState.logDiscoveryService.tail(source: first, config: config, sshService: appState.sshService).count
        } else {
            firstLogBytes = 0
        }
        let highRisk = audit.filter { $0.severity == .danger }.count
        print("SMOKE_OK operations-read services=\(services.count) logs=\(logs.count) firstLog=\(firstLog) firstLogBytes=\(firstLogBytes) nginx=\(nginx.isInstalled) sites=\(nginx.sites.count) dockerInstalled=\(docker.isInstalled) dockerDaemon=\(docker.daemonReachable) containers=\(docker.containers.count) databases=\(databases.count) audit=\(audit.count) danger=\(highRisk)")
    }

    private static func runSFTPReadSmoke(
        appState: AppState,
        config: SSHConnectionConfig,
        environment: [String: String]
    ) async throws {
        let path = environment["OPSDECK_SMOKE_PATH"] ?? "/root/.bashrc"
        let data = try await appState.sftpService.download(remotePath: path, config: config)
        let content = String(decoding: data, as: UTF8.self)
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let visibleCharacterCount = content.filter { !$0.isWhitespace }.count
        print("SMOKE_OK sftp-read bytes=\(data.count) characters=\(content.count) lines=\(lineCount) visibleCharacters=\(visibleCharacterCount)")
    }

    private static func runSFTPSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let list = try await appState.sftpService.listDirectory(path: "/tmp", config: config)
        let remotePath = "/tmp/opsdeck-app-smoke-\(Int(Date().timeIntervalSince1970)).txt"
        let uploadData = Data("opsdeck-sftp-smoke\n".utf8)
        _ = try await appState.sftpService.upload(data: uploadData, to: remotePath, config: config)
        let downloadData = try await appState.sftpService.download(remotePath: remotePath, config: config)
        try? await appState.sftpService.remove(remotePath: remotePath, config: config)
        let matched = downloadData == uploadData
        print("SMOKE_OK sftp path=\(list.path) entries=\(list.items.count) uploadDownloadMatch=\(matched)")
    }

    private static func runSFTPActionSmoke(appState: AppState, config: SSHConnectionConfig) async throws {
        let suffix = Int(Date().timeIntervalSince1970)
        let directoryPath = "/tmp/opsdeck-actions-\(suffix)"
        let originalPath = "\(directoryPath)/draft.txt"
        let renamedPath = "\(directoryPath)/renamed.txt"
        let uploadData = Data("opsdeck-actions-smoke\nline-two\n".utf8)
        let replacementData = Data("opsdeck-actions-smoke\nline-three\n".utf8)

        do {
            try await appState.sftpService.createDirectory(remotePath: directoryPath, config: config)
            _ = try await appState.sftpService.uploadReplacing(data: uploadData, to: originalPath, permissions: 0o755, config: config)
            _ = try await appState.sftpService.uploadReplacing(data: replacementData, to: originalPath, permissions: 0o755, config: config)
            try await appState.sftpService.rename(remotePath: originalPath, to: renamedPath, config: config)
            let tail = try await appState.sftpService.downloadTail(remotePath: renamedPath, maxBytes: 12, config: config)
            let downloadData = try await appState.sftpService.download(remotePath: renamedPath, config: config)
            try? await appState.sftpService.remove(remotePath: renamedPath, config: config)
            try? await appState.sftpService.rmdirForSmoke(remotePath: directoryPath, config: config)
            let tailText = String(decoding: tail.data, as: UTF8.self)
                .replacingOccurrences(of: "\n", with: "\\n")
            print("SMOKE_OK sftp-actions dir=\(directoryPath) uploadDownloadMatch=\(downloadData == replacementData) tail=\(tailText)")
        } catch {
            try? await appState.sftpService.remove(remotePath: renamedPath, config: config)
            try? await appState.sftpService.remove(remotePath: originalPath, config: config)
            try? await appState.sftpService.rmdirForSmoke(remotePath: directoryPath, config: config)
            throw error
        }
    }

    private static func readPasswordFromStandardInput() -> String {
        readLine(strippingNewline: true) ?? ""
    }
}

private extension SFTPService {
    func rmdirForSmoke(remotePath: String, config: SSHConnectionConfig) async throws {
        try await removeDirectory(remotePath: remotePath, config: config)
    }
}
#endif
