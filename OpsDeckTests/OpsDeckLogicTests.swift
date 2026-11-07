import AppKit
import XCTest
@testable import OpsDeck

final class OpsDeckLogicTests: XCTestCase {
    func testAppVersionComparisonUsesNumericComponents() {
        XCTAssertTrue(AppVersion.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(AppVersion.isNewer("1.10", than: "1.9.9"))
        XCTAssertFalse(AppVersion.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(AppVersion.isNewer("1.2-beta", than: "1.1"))
        XCTAssertFalse(AppVersion.isNewer("", than: "1.0"))
    }

    func testAppUpdatePolicyRemindsDailyAndIgnoresOnlyExactVersion() throws {
        let suite = "OpsDeckLogicTests-Update-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(AppUpdatePolicy.shouldPerformAutomaticLookup(now: now, defaults: defaults))
        AppUpdatePolicy.recordLookupAttempt(at: now, defaults: defaults)
        XCTAssertFalse(
            AppUpdatePolicy.shouldPerformAutomaticLookup(
                now: now.addingTimeInterval(AppUpdatePolicy.automaticInterval - 1),
                defaults: defaults
            )
        )
        XCTAssertTrue(
            AppUpdatePolicy.shouldPerformAutomaticLookup(
                now: now.addingTimeInterval(AppUpdatePolicy.automaticInterval),
                defaults: defaults
            )
        )

        XCTAssertTrue(
            AppUpdatePolicy.shouldPresent(
                latestVersion: "1.2.0",
                currentVersion: "1.1.0",
                now: now,
                defaults: defaults
            )
        )
        AppUpdatePolicy.recordPresented(version: "1.2.0", at: now, defaults: defaults)
        XCTAssertFalse(
            AppUpdatePolicy.shouldPresent(
                latestVersion: "1.2.0",
                currentVersion: "1.1.0",
                now: now.addingTimeInterval(60),
                defaults: defaults
            )
        )
        XCTAssertTrue(
            AppUpdatePolicy.shouldPresent(
                latestVersion: "1.2.0",
                currentVersion: "1.1.0",
                now: now.addingTimeInterval(AppUpdatePolicy.automaticInterval),
                defaults: defaults
            )
        )

        AppUpdatePolicy.ignore(version: "1.2.0", defaults: defaults)
        XCTAssertFalse(
            AppUpdatePolicy.shouldPresent(
                latestVersion: "1.2.0",
                currentVersion: "1.1.0",
                now: now.addingTimeInterval(AppUpdatePolicy.automaticInterval * 2),
                defaults: defaults
            )
        )
        XCTAssertTrue(
            AppUpdatePolicy.shouldPresent(
                latestVersion: "1.3.0",
                currentVersion: "1.1.0",
                now: now.addingTimeInterval(60),
                defaults: defaults
            )
        )
    }

    func testAppStoreLookupResponseParsingOnlyAcceptsAppleURLs() throws {
        let valid = try XCTUnwrap(
            #"{"results":[{"version":"1.3.0","trackViewUrl":"https://apps.apple.com/app/id6792424131"}]}"#
                .data(using: .utf8)
        )
        let release = try XCTUnwrap(try AppUpdateService.decodeRelease(from: valid))
        XCTAssertEqual(release.version, "1.3.0")
        XCTAssertEqual(release.storeURL?.host, "apps.apple.com")

        let untrusted = try XCTUnwrap(
            #"{"results":[{"version":"1.3.0","trackViewUrl":"https://example.com/fake"}]}"#
                .data(using: .utf8)
        )
        XCTAssertNil(try AppUpdateService.decodeRelease(from: untrusted)?.storeURL)
    }

    @MainActor
    func testTerminalPanelDefaultHeightProvidesMoreWorkingRoom() {
        XCTAssertEqual(AppState.defaultTerminalPanelHeight, 360)
        XCTAssertGreaterThan(AppState.defaultTerminalPanelHeight, AppState.minTerminalPanelHeight)
        XCTAssertLessThan(AppState.defaultTerminalPanelHeight, AppState.maxTerminalPanelHeight)
    }

    func testWelcomePresentationOccursOncePerMarketingVersion() throws {
        let suite = "OpsDeckLogicTests-Welcome-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(WelcomePresentationPolicy.shouldPresent(version: "1.0", defaults: defaults))
        WelcomePresentationPolicy.markPresented(version: "1.0", defaults: defaults)
        XCTAssertFalse(WelcomePresentationPolicy.shouldPresent(version: "1.0", defaults: defaults))
        XCTAssertTrue(WelcomePresentationPolicy.shouldPresent(version: "1.1", defaults: defaults))
    }

    func testWorkspaceWindowSizingUsesLargeTargetsAndFitsSmallerScreens() {
        XCTAssertEqual(
            WorkspaceWindowSizing.mainContentSize(for: NSRect(x: 0, y: 0, width: 1_800, height: 1_100)),
            NSSize(width: 1_440, height: 900)
        )
        XCTAssertEqual(
            WorkspaceWindowSizing.databaseContentSize(for: NSRect(x: 0, y: 0, width: 1_800, height: 1_100)),
            NSSize(width: 1_360, height: 840)
        )

        let compact = WorkspaceWindowSizing.mainContentSize(
            for: NSRect(x: 0, y: 0, width: 1_200, height: 760)
        )
        XCTAssertEqual(compact.width, 1_152)
        XCTAssertEqual(compact.height, 712)
    }

    func testTerminalFontPreferenceDefaultsAndClamps() throws {
        let suite = "OpsDeckLogicTests-TerminalFont-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(TerminalFontPreference.load(from: defaults), 13)
        TerminalFontPreference.save(99, to: defaults)
        XCTAssertEqual(TerminalFontPreference.load(from: defaults), 22)
        TerminalFontPreference.save(1, to: defaults)
        XCTAssertEqual(TerminalFontPreference.load(from: defaults), 10)
    }

    func testAllRequestedAppLanguagesAreAvailable() {
        XCTAssertEqual(
            Set(AppLanguage.supportedLocaleIdentifiers),
            Set(["en", "ar", "de", "ru", "fr", "zh-Hant", "ko", "zh-Hans", "pt-BR", "ja", "tr", "es"])
        )
    }

    func testInspectorVisibilityDefaultsHiddenAndPersistsChoice() throws {
        let suite = "OpsDeckLogicTests-Inspector-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(InspectorVisibilityPreference.load(from: defaults))
        InspectorVisibilityPreference.save(true, to: defaults)
        XCTAssertTrue(InspectorVisibilityPreference.load(from: defaults))
        InspectorVisibilityPreference.save(false, to: defaults)
        XCTAssertFalse(InspectorVisibilityPreference.load(from: defaults))
    }

    func testServerLoadIsNormalizedByReportedCPUCount() {
        let snapshot = ServerStatusSnapshot(
            loadAverage: 2,
            cpuCount: 8,
            memoryUsedMB: 512,
            memoryTotalMB: 1_024,
            diskUsedPercent: 0.4,
            capturedAt: Date()
        )
        XCTAssertEqual(snapshot.normalizedLoad, 0.25)
        XCTAssertEqual(snapshot.memoryUsedPercent, 0.5)

        let unknownCPU = ServerStatusSnapshot(
            loadAverage: 2,
            cpuCount: nil,
            memoryUsedMB: nil,
            memoryTotalMB: nil,
            diskUsedPercent: nil,
            capturedAt: Date()
        )
        XCTAssertNil(unknownCPU.normalizedLoad)
    }

    func testRedisCredentialUsesEnvironmentInsteadOfPasswordArgument() {
        let command = RedisManagerService().cliCommand(
            credential: RedisCredential(username: "ops", password: "secret value")
        )

        XCTAssertTrue(command.contains("REDISCLI_AUTH="))
        XCTAssertTrue(command.contains("--user"))
        XCTAssertFalse(command.contains(" --pass "))
        XCTAssertFalse(command.contains(" -a "))
    }

    func testAptInstallRepairsOnlyMissingConffiles() {
        let command = OpsShell.unattendedAptInstall(
            packages: ["redis-server", "redis-tools"],
            sudo: "sudo -n "
        )

        XCTAssertTrue(command.contains("DEBIAN_FRONTEND=noninteractive"))
        XCTAssertTrue(command.contains("DPkg::Lock::Timeout=180"))
        XCTAssertTrue(command.contains("dpkg --verify"))
        XCTAssertTrue(command.contains("^missing[[:space:]]+c[[:space:]]"))
        XCTAssertTrue(command.contains("Dpkg::Options::=--force-confmiss"))
        XCTAssertTrue(command.contains("install --reinstall -y $opsdeck_missing_packages"))
        XCTAssertFalse(command.contains("--force-confnew"))
        XCTAssertFalse(command.contains("--force-confold"))
    }

    func testSystemdStartRequiresActiveStateAndIncludesDiagnostics() {
        let command = OpsShell.systemdEnableAndStart(
            serviceName: "redis-server",
            sudo: "sudo -n "
        )

        XCTAssertTrue(command.contains("systemctl enable 'redis-server'"))
        XCTAssertTrue(command.contains("systemctl start 'redis-server'"))
        XCTAssertFalse(command.contains("enable --now"))
        XCTAssertTrue(command.contains("is-active 'redis-server'"))
        XCTAssertTrue(command.contains("= active"))
        XCTAssertTrue(command.contains("systemctl status 'redis-server' --no-pager -l"))
        XCTAssertTrue(command.contains("journalctl -u 'redis-server' -n 40 --no-pager"))

        let output = """
        /usr/bin/redis-server
        Failed to start redis-server.service.
        Fatal error, can't open config file '/etc/redis/redis.conf': No such file or directory
        """
        let summary = RunbookService.failureMessage(
            stepTitle: "Start Redis",
            output: output,
            exitCode: 1
        )
        XCTAssertTrue(summary.contains("can't open config file"))
        XCTAssertTrue(OpsErrorHint.hint(for: output)?.contains("--force-confmiss") == true)
    }

    func testTerminalCallbacksAreDeferredAndCoalesced() {
        let dispatcher = TerminalViewCallbackDispatcher()
        let delivered = expectation(description: "Terminal callbacks delivered after the view update")
        delivered.expectedFulfillmentCount = 2
        var titles: [String] = []
        var sizes: [(Int, Int)] = []

        dispatcher.scheduleTitle("intermediate") { _ in
            XCTFail("An intermediate title must be coalesced")
        }
        dispatcher.scheduleTitle("final") { title in
            XCTAssertTrue(Thread.isMainThread)
            titles.append(title)
            delivered.fulfill()
        }
        dispatcher.scheduleResize(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 480) { _, _, _, _ in
            XCTFail("An intermediate resize must be coalesced")
        }
        dispatcher.scheduleResize(columns: 120, rows: 36, pixelWidth: 1_200, pixelHeight: 720) { columns, rows, _, _ in
            XCTAssertTrue(Thread.isMainThread)
            sizes.append((columns, rows))
            delivered.fulfill()
        }

        XCTAssertTrue(titles.isEmpty)
        XCTAssertTrue(sizes.isEmpty)
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(titles, ["final"])
        XCTAssertEqual(sizes.map { "\($0.0)x\($0.1)" }, ["120x36"])
    }

    func testSQLClassificationInspectsWholeBatch() {
        XCTAssertEqual(DBSQLStatementKind.classify("SELECT 1"), .readOnly)
        XCTAssertEqual(DBSQLStatementKind.classify("UPDATE users SET active = 1"), .dataMutation)
        XCTAssertEqual(
            DBSQLStatementKind.classify("SELECT 1; DROP TABLE users"),
            .schemaOrPrivilegeMutation
        )
        XCTAssertEqual(DBSQLStatementKind.classify("vendor_specific command"), .schemaOrPrivilegeMutation)
    }

    func testPackageRecoveryIsConservativeAndTargetsOnlyNamedPrincipal() throws {
        let factory = PackageRecoveryPlanFactory()
        let message = "unknown system user 'redis' in statoverride file; the system user got removed"

        XCTAssertEqual(factory.diagnosis(for: message), .missingStatoverrideUser("redis"))
        let plan = try XCTUnwrap(factory.plan(for: message, profile: nil))
        XCTAssertEqual(plan.risk, .high)
        XCTAssertTrue(plan.steps.contains { $0.command.contains("dpkg-statoverride --remove") })
        XCTAssertTrue(plan.steps.contains { $0.command.contains("redis") })

        XCTAssertNil(factory.plan(for: "Could not get lock /var/lib/dpkg/lock-frontend", profile: nil))
        XCTAssertNil(factory.plan(for: "unknown system user '../unsafe' in statoverride file", profile: nil))
    }

    func testDatabaseDDLGenerationQuotesIdentifiersAndRedactsPasswords() throws {
        let builder = DatabaseSchemaSQLBuilder()
        XCTAssertEqual(
            try builder.createTable(
                dialect: .mysql,
                database: "app_db",
                table: "events",
                firstColumn: "id",
                dataType: "bigint"
            ),
            "CREATE TABLE `app_db`.`events` (`id` BIGINT NOT NULL PRIMARY KEY);"
        )

        let account = try builder.createUser(
            dialect: .mysql,
            username: "reporter",
            host: "localhost",
            password: "secret'quote"
        )
        XCTAssertTrue(account.sql.contains("secret''quote"))
        XCTAssertFalse(account.preview.contains("secret"))
        XCTAssertTrue(account.preview.contains("••••••••"))

        XCTAssertThrowsError(
            try builder.dropTable(dialect: .postgres, database: "ignored", table: "bad-name")
        )
    }

    func testQueryWorkspacePersistenceIsScopedAndBounded() throws {
        let suite = "OpsDeckLogicTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = DatabaseQueryStore(defaults: defaults)
        let hostID = UUID()
        let tabs = (0..<13).map { DBQueryTab(sql: "SELECT \($0)") }
        let history = (0..<101).map { DBSavedQuery(sql: "SELECT \($0)") }
        let snapshot = DBQueryWorkspaceSnapshot(
            tabs: tabs,
            selectedTabID: tabs[0].id,
            history: history,
            favorites: history
        )

        store.save(snapshot, hostID: hostID, connectionID: "primary")
        let loaded = store.load(hostID: hostID, connectionID: "primary")
        XCTAssertEqual(loaded.tabs.count, 12)
        XCTAssertEqual(loaded.history.count, 100)
        XCTAssertEqual(loaded.favorites.count, 100)
        XCTAssertEqual(loaded.selectedTabID, tabs[0].id)

        let isolated = store.load(hostID: hostID, connectionID: "secondary")
        XCTAssertEqual(isolated.tabs.count, 1)
        XCTAssertTrue(isolated.history.isEmpty)
        XCTAssertTrue(isolated.favorites.isEmpty)
    }
}
