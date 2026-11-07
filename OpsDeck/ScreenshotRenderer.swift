#if DEBUG
import AppKit
import Foundation
import SwiftData
import SwiftUI

@MainActor
enum ScreenshotRenderer {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["OPSDECK_SCREENSHOT_MODE"] == "1"
    }

    /// 截图演示数据跟随 -AppleLanguages 输出对应语言（覆盖 12 个上架语言，缺失回退英文）。
    static var demoLang: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") {
            let traditional = preferred.contains("Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK")
            return traditional ? "zh-Hant" : "zh-Hans"
        }
        if preferred.hasPrefix("pt") { return "pt-BR" }
        for code in ["ar", "de", "ru", "fr", "ko", "ja", "tr", "es"] where preferred.hasPrefix(code) {
            return code
        }
        return "en"
    }

    private static var isChineseUI: Bool { demoLang.hasPrefix("zh") }

    /// 12 语言演示文案；缺失回退英文。
    private static func demo(_ table: [String: String]) -> String {
        table[demoLang] ?? table["en"] ?? ""
    }

    /// 旧双语调用（仅用于不进商店截图的预览，如 Runbook 演示）。
    private static func demo(_ zh: String, _ en: String) -> String {
        isChineseUI ? zh : en
    }

    /// 数据库预览的订单演示行：货币、支付渠道、客户名、状态按市场适配（12 语言）。
    private static func demoOrders() -> [[String]] {
        let lang = demoLang
        // 状态：已支付 / 待发货 / 已完成 / 配送中 / 已退款
        let statuses: [String: [String]] = [
            "en": ["Paid", "Awaiting shipment", "Completed", "In transit", "Refunded"],
            "zh-Hans": ["已支付", "待发货", "已完成", "配送中", "已退款"],
            "zh-Hant": ["已付款", "待出貨", "已完成", "配送中", "已退款"],
            "ar": ["مدفوع", "بانتظار الشحن", "مكتمل", "قيد التوصيل", "مسترد"],
            "de": ["Bezahlt", "Versand ausstehend", "Abgeschlossen", "Unterwegs", "Erstattet"],
            "ru": ["Оплачен", "Ожидает отправки", "Завершён", "В пути", "Возврат"],
            "fr": ["Payée", "En attente d'expédition", "Terminée", "En transit", "Remboursée"],
            "ko": ["결제 완료", "배송 대기", "완료", "배송 중", "환불됨"],
            "pt-BR": ["Pago", "Aguardando envio", "Concluído", "Em trânsito", "Reembolsado"],
            "ja": ["支払い済み", "発送待ち", "完了", "配送中", "返金済み"],
            "tr": ["Ödendi", "Kargo bekliyor", "Tamamlandı", "Yolda", "İade edildi"],
            "es": ["Pagado", "Pendiente de envío", "Completado", "En tránsito", "Reembolsado"],
        ]
        // 渠道：本土钱包 / 银行转账 / 第二渠道 / Apple Pay / 企业账户 / 门店终端
        let channels: [String: [String]] = [
            "en": ["Stripe", "Bank transfer", "PayPal", "Apple Pay", "Corporate account", "POS"],
            "zh-Hans": ["微信支付", "银行转账", "支付宝", "Apple Pay", "企业账户", "POS"],
            "zh-Hant": ["LINE Pay", "銀行轉帳", "信用卡", "Apple Pay", "企業帳戶", "POS"],
            "ar": ["مدى", "تحويل بنكي", "PayPal", "Apple Pay", "حساب شركة", "POS"],
            "de": ["Stripe", "Überweisung", "PayPal", "Apple Pay", "Firmenkonto", "POS"],
            "ru": ["Карта", "Банковский перевод", "СБП", "Apple Pay", "Корпоративный счёт", "POS"],
            "fr": ["CB", "Virement", "PayPal", "Apple Pay", "Compte pro", "TPE"],
            "ko": ["카카오페이", "계좌 이체", "네이버페이", "Apple Pay", "법인 계정", "POS"],
            "pt-BR": ["Pix", "Transferência", "PayPal", "Apple Pay", "Conta corporativa", "POS"],
            "ja": ["PayPay", "銀行振込", "クレジットカード", "Apple Pay", "法人口座", "POS"],
            "tr": ["Kredi kartı", "Havale", "PayPal", "Apple Pay", "Kurumsal hesap", "POS"],
            "es": ["Bizum", "Transferencia", "PayPal", "Apple Pay", "Cuenta corporativa", "TPV"],
        ]
        // 具名客户：旗舰店 / 企业客户 A / 零售店 / 北区伙伴 / 门店 07 / 体验店 / 分销商 ＋「会员」称谓
        let customers: [String: [String]] = [
            "en": ["East Bay flagship", "Enterprise client A", "Southside retail", "Northern partner", "Retail store 07", "Downtown showroom", "Midwest distributor", "Member"],
            "zh-Hans": ["华东旗舰店", "企业客户 A", "华南零售店", "北区合作伙伴", "线下门店 07", "西南体验店", "华北分销商", "会员"],
            "zh-Hant": ["台北旗艦店", "企業客戶 A", "高雄零售店", "北區合作夥伴", "門市 07", "台中體驗店", "桃園經銷商", "會員"],
            "ar": ["المتجر الرئيسي", "عميل شركات أ", "متجر التجزئة الجنوبي", "شريك المنطقة الشمالية", "فرع 07", "صالة العرض", "موزع المنطقة الوسطى", "عضو"],
            "de": ["Flagship-Store Mitte", "Firmenkunde A", "Einzelhandel Süd", "Partner Nord", "Filiale 07", "Showroom City", "Großhändler West", "Mitglied"],
            "ru": ["Флагманский магазин", "Корпоративный клиент А", "Розница Юг", "Партнёр Север", "Магазин 07", "Шоурум Центр", "Дистрибьютор Запад", "Клиент"],
            "fr": ["Boutique phare Paris", "Client entreprise A", "Boutique Sud", "Partenaire Nord", "Magasin 07", "Showroom Centre", "Distributeur Ouest", "Membre"],
            "ko": ["강남 플래그십", "기업 고객 A", "부산 리테일", "북부 파트너", "매장 07", "쇼룸 지점", "수도권 총판", "회원"],
            "pt-BR": ["Loja conceito SP", "Cliente corporativo A", "Varejo Zona Sul", "Parceiro Norte", "Loja 07", "Showroom Centro", "Distribuidor Sul", "Membro"],
            "ja": ["旗艦店 銀座", "法人顧客 A", "小売 大阪", "北部パートナー", "店舗 07", "ショールーム", "西日本代理店", "会員"],
            "tr": ["Amiral mağaza", "Kurumsal müşteri A", "Perakende Güney", "Kuzey iş ortağı", "Mağaza 07", "Showroom Merkez", "Distribütör Batı", "Üye"],
            "es": ["Tienda insignia", "Cliente corporativo A", "Retail Sur", "Socio Norte", "Tienda 07", "Showroom Centro", "Distribuidor Oeste", "Miembro"],
        ]
        let st = statuses[lang] ?? statuses["en"]!
        let ch = channels[lang] ?? channels["en"]!
        let cu = customers[lang] ?? customers["en"]!

        // 金额：同一组数值按各市场货币习惯格式化（千分位/小数位/符号位置）。
        func amount(_ base: String) -> String {
            switch lang {
            case "zh-Hans": return "¥ \(base).00"
            case "zh-Hant": return "NT$ \(base).00"
            case "ja": return "¥ \(base)"
            case "ko": return "₩ \(base),000"
            case "de", "tr": return "\(base.replacingOccurrences(of: ",", with: ".")),00 \(lang == "de" ? "€" : "₺")"
            case "es": return "\(base.replacingOccurrences(of: ",", with: ".")),00 €"
            case "fr": return "\(base.replacingOccurrences(of: ",", with: " ")),00 €"
            case "ru": return "\(base.replacingOccurrences(of: ",", with: " ")),00 ₽"
            case "pt-BR": return "R$ \(base.replacingOccurrences(of: ",", with: ".")),00"
            case "ar": return "\(base) ر.س"
            default: return "$ \(base).00"
            }
        }
        func member(_ id: String) -> String { "\(cu[7]) \(id)" }

        return [
            ["ORD-20260723-1842", cu[0], st[0], amount("1,299"), ch[0], "2026-07-23 10:42:18"],
            ["ORD-20260723-1841", cu[1], st[1], amount("8,640"), ch[1], "2026-07-23 10:39:05"],
            ["ORD-20260723-1840", cu[2], st[2], amount("358"), ch[2], "2026-07-23 10:35:47"],
            ["ORD-20260723-1839", member("10428"), st[0], amount("699"), ch[3], "2026-07-23 10:31:12"],
            ["ORD-20260723-1838", cu[3], st[3], amount("2,480"), ch[4], "2026-07-23 10:28:56"],
            ["ORD-20260723-1837", member("08316"), st[2], amount("189"), ch[0], "2026-07-23 10:24:33"],
            ["ORD-20260723-1836", cu[4], st[1], amount("4,920"), ch[5], "2026-07-23 10:18:41"],
            ["ORD-20260723-1835", member("12590"), st[4], amount("259"), ch[2], "2026-07-23 10:12:09"],
            ["ORD-20260723-1834", cu[5], st[2], amount("1,880"), ch[4], "2026-07-23 10:07:52"],
            ["ORD-20260723-1833", member("03172"), st[0], amount("429"), ch[3], "2026-07-23 10:03:27"],
            ["ORD-20260723-1832", cu[6], st[3], amount("6,280"), ch[1], "2026-07-23 09:58:10"],
            ["ORD-20260723-1831", member("11806"), st[2], amount("79"), ch[0], "2026-07-23 09:54:46"],
        ]
    }

    static func applyDemoState(to appState: AppState) {
        switch ProcessInfo.processInfo.environment["OPSDECK_APPEARANCE_PREVIEW"] {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            break
        }
        let now = Date()
        let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()
        let demoHost = HostProfile(
            id: hostID,
            name: "web-prod-01",
            host: "web-prod.example.test",
            username: "deploy",
            authType: .password,
            credentialID: nil,
            tags: ["web", "production"],
            note: "Sanitized screenshot profile.",
            lastConnectedAt: now,
            lastStatus: "connected"
        )
        let stagingHost = HostProfile(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFF1") ?? UUID(),
            name: "api-staging-01",
            host: "api-staging.example.test",
            username: "deploy",
            authType: .privateKey,
            credentialID: nil,
            tags: ["api", "staging"],
            note: "Sanitized screenshot profile.",
            lastConnectedAt: now.addingTimeInterval(-420),
            lastStatus: "connected"
        )
        let backupHost = HostProfile(
            id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFF2") ?? UUID(),
            name: "backup-nas",
            host: "backup.example.test",
            username: "ops",
            authType: .privateKey,
            credentialID: nil,
            tags: ["backup"],
            note: "Sanitized screenshot profile.",
            lastConnectedAt: now.addingTimeInterval(-3_600),
            lastStatus: "disconnected"
        )

        appState.hosts = [demoHost, stagingHost, backupHost]
        appState.selectedSidebarHostID = hostID
        appState.currentHostName = demoHost.name
        appState.connectionStatus = .connected
        appState.isInspectorVisible = true
        appState.selectedWorkspaceMode = .files
        appState.connectionSummary = "Ubuntu 24.04 LTS · nginx · docker · mysql"
        appState.remoteDirectoryPath = "/srv/apps/storefront/current"
        appState.remoteFiles = [
            RemoteFileItem(path: "/srv/apps/storefront/current/app", name: "app", kind: .directory, byteSize: nil, permissions: 0o755, modifiedAt: now.addingTimeInterval(-180), longName: ""),
            RemoteFileItem(path: "/srv/apps/storefront/current/config", name: "config", kind: .directory, byteSize: nil, permissions: 0o750, modifiedAt: now.addingTimeInterval(-1_800), longName: ""),
            RemoteFileItem(path: "/srv/apps/storefront/current/public", name: "public", kind: .directory, byteSize: nil, permissions: 0o755, modifiedAt: now.addingTimeInterval(-2_400), longName: ""),
            RemoteFileItem(path: "/srv/apps/storefront/current/storage", name: "storage", kind: .directory, byteSize: nil, permissions: 0o775, modifiedAt: now.addingTimeInterval(-420), longName: ""),
            RemoteFileItem(path: "/srv/apps/storefront/current/.env.example", name: ".env.example", kind: .file, byteSize: 3_584, permissions: 0o640, modifiedAt: now.addingTimeInterval(-7_200), longName: ""),
            RemoteFileItem(path: "/srv/apps/storefront/current/CHANGELOG.md", name: "CHANGELOG.md", kind: .file, byteSize: 18_432, permissions: 0o644, modifiedAt: now.addingTimeInterval(-5_400), longName: ""),
            RemoteFileItem(path: "/srv/apps/storefront/current/compose.yaml", name: "compose.yaml", kind: .file, byteSize: 7_168, permissions: 0o640, modifiedAt: now.addingTimeInterval(-3_600), longName: ""),
            RemoteFileItem(path: "/srv/apps/storefront/current/deploy.sh", name: "deploy.sh", kind: .file, byteSize: 6_144, permissions: 0o755, modifiedAt: now.addingTimeInterval(-2_100), longName: ""),
            RemoteFileItem(path: "/srv/apps/storefront/current/nginx.conf", name: "nginx.conf", kind: .file, byteSize: 8_704, permissions: 0o644, modifiedAt: now.addingTimeInterval(-4_800), longName: ""),
            RemoteFileItem(path: "/srv/apps/storefront/current/package.json", name: "package.json", kind: .file, byteSize: 4_832, permissions: 0o644, modifiedAt: now.addingTimeInterval(-900), longName: ""),
            RemoteFileItem(path: "/srv/apps/storefront/current/storage/logs/application.log", name: "application.log", kind: .file, byteSize: 1_867_776, permissions: 0o640, modifiedAt: now.addingTimeInterval(-45), longName: "")
        ]
        appState.selectedRemoteFileID = appState.remoteFiles.first?.id

        let localRoot = URL(fileURLWithPath: "/Users/demo/OpsDeck")
        appState.localRootDirectoryURL = localRoot
        appState.localDirectoryURL = localRoot.appendingPathComponent("release-bundle")
        appState.localFiles = [
            LocalFileItem(url: localRoot.appendingPathComponent("release-bundle/app.tar.gz"), name: "app.tar.gz", isDirectory: false, isPackage: false, byteSize: 1_248_000, modifiedAt: now.addingTimeInterval(-420)),
            LocalFileItem(url: localRoot.appendingPathComponent("release-bundle/nginx.conf"), name: "nginx.conf", isDirectory: false, isPackage: false, byteSize: 6_144, modifiedAt: now.addingTimeInterval(-1_200)),
            LocalFileItem(url: localRoot.appendingPathComponent("release-bundle/scripts"), name: "scripts", isDirectory: true, isPackage: false, byteSize: nil, modifiedAt: now.addingTimeInterval(-2_400))
        ]
        appState.selectedLocalFileID = appState.localFiles.first?.id

        appState.serverStatus = ServerStatusSnapshot(
            loadAverage: 0.42,
            cpuCount: 4,
            memoryUsedMB: 3_840,
            memoryTotalMB: 8_192,
            diskUsedPercent: 0.58,
            capturedAt: now
        )
        appState.transferTasks = [
            TransferTask(hostID: hostID, direction: .upload, localPath: "/Users/demo/OpsDeck/release-bundle/storefront-2026.07.23.tar.gz", remotePath: "/srv/releases/storefront-2026.07.23.tar.gz", status: .succeeded, progress: 1, bytesTransferred: 18_874_368, totalBytes: 18_874_368, startedAt: now.addingTimeInterval(-720), finishedAt: now.addingTimeInterval(-684)),
            TransferTask(hostID: hostID, direction: .upload, localPath: "/Users/demo/OpsDeck/release-bundle/nginx.conf", remotePath: "/etc/nginx/sites-available/storefront.conf", status: .succeeded, progress: 1, bytesTransferred: 8_704, totalBytes: 8_704, startedAt: now.addingTimeInterval(-540), finishedAt: now.addingTimeInterval(-536)),
            TransferTask(hostID: hostID, direction: .download, localPath: "/Users/demo/OpsDeck/logs/application.log", remotePath: "/srv/apps/storefront/current/storage/logs/application.log", status: .succeeded, progress: 1, bytesTransferred: 1_867_776, totalBytes: 1_867_776, startedAt: now.addingTimeInterval(-360), finishedAt: now.addingTimeInterval(-347)),
            TransferTask(hostID: hostID, direction: .download, localPath: "/Users/demo/OpsDeck/backups/nginx.conf", remotePath: "/etc/nginx/nginx.conf", status: .succeeded, progress: 1, bytesTransferred: 7_936, totalBytes: 7_936, startedAt: now.addingTimeInterval(-240), finishedAt: now.addingTimeInterval(-236))
        ]
        appState.commandRuns = [
            CommandRun(hostID: hostID, command: "git rev-parse --short HEAD", stdoutPreview: "8c2f11a", startedAt: now.addingTimeInterval(-660), duration: 0.18),
            CommandRun(hostID: hostID, command: "nginx -t", stdoutPreview: "syntax is ok · test is successful", startedAt: now.addingTimeInterval(-510), duration: 0.27),
            CommandRun(hostID: hostID, command: "systemctl reload nginx", stdoutPreview: "reload completed", startedAt: now.addingTimeInterval(-480), duration: 0.36),
            CommandRun(hostID: hostID, command: "docker compose ps", stdoutPreview: "api, worker, scheduler · running", startedAt: now.addingTimeInterval(-300), duration: 0.44),
            CommandRun(hostID: hostID, command: "df -h /srv", stdoutPreview: "/dev/vda1  96G  44G  48G  48% /srv", startedAt: now.addingTimeInterval(-180), duration: 0.32),
            CommandRun(hostID: hostID, command: "systemctl status storefront --no-pager", stdoutPreview: "active (running) · uptime 18d", startedAt: now.addingTimeInterval(-90), duration: 0.51)
        ]

        let tab = TerminalSessionTab(
            hostID: hostID,
            title: demoHost.name,
            output: """
            $ pwd
            /srv/apps/storefront/current
            $ ls -lh
            total 2.1M
            drwxr-xr-x  8 deploy www-data 4.0K app
            drwxrwxr-x  6 deploy www-data 4.0K storage
            -rw-r-----  1 deploy www-data 8.5K nginx.conf
            -rwxr-xr-x  1 deploy www-data 6.0K deploy.sh
            $ docker compose ps
            NAME                  STATUS          PORTS
            storefront-api       Up 18 days      127.0.0.1:8080->8080/tcp
            storefront-worker    Up 18 days
            $ tail -n 3 storage/logs/application.log
            [INFO] checkout.completed order=ORD-20260723-1842 duration=86ms
            [INFO] cache.hit key=catalog:featured duration=4ms
            [INFO] health.ok services=8 latency=21ms
            """,
            status: .idle,
            columns: 132,
            rows: 18
        )
        appState.terminalTabs = [tab]
        appState.selectedTerminalTabID = tab.id
        appState.terminalCommand = "df -h"
        if ProcessInfo.processInfo.environment["OPSDECK_TERMINAL_PREVIEW"] == "1" {
            appState.isTerminalVisible = true
        }
        if ProcessInfo.processInfo.environment["OPSDECK_OPERATION_HISTORY_PREVIEW"] == "1" {
            appState.selectedWorkspaceMode = .history
        }
        if ProcessInfo.processInfo.environment["OPSDECK_EDITOR_PREVIEW"] == "1" {
            let content = """
            #!/usr/bin/env bash

            set -euo pipefail

            cd /var/www/demo-app/current
            echo "Deploying release..."
            systemctl --user restart demo-app
            """
            appState.remoteTextDocument = RemoteTextDocument(
                path: "/var/www/demo-app/current/deploy.sh",
                title: "deploy.sh",
                content: content,
                originalContent: content,
                mode: .editable,
                byteCount: UInt64(content.utf8.count),
                loadedByteCount: UInt64(content.utf8.count),
                message: nil
            )
        } else {
            appState.remoteTextDocument = nil
        }
        appState.remoteFileError = nil
        appState.localFileError = nil
        appState.storageError = nil
        if ProcessInfo.processInfo.environment["OPSDECK_HOST_KEY_PREVIEW"] == "1" {
            let challenge = KnownHostChallenge(
                endpoint: "demo.example.internal:22",
                publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoSanitizedKey",
                fingerprint: "SHA256:Qn5QxK0mGm9fD8oT7N2sC4dP6rV1yZ3aL8uE0wHjK2M",
                kind: .firstUse
            )
            appState.pendingHostKeyChallenge = challenge
            DispatchQueue.main.async {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                window.title = String(localized: "确认服务器身份")
                window.identifier = NSUserInterfaceItemIdentifier("opsdeck.host-key-preview")
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(
                    rootView: HostKeyTrustView(challenge: challenge).environmentObject(appState)
                )
                window.center()
                window.makeKeyAndOrderFront(nil)
            }
        }
        if ProcessInfo.processInfo.environment["OPSDECK_LOG_LOADING_PREVIEW"] == "1" {
            appState.selectedWorkspaceMode = .logs
            appState.logSources = []
            appState.selectedLogSourceID = nil
            appState.logPreview = ""
            appState.isLogSourcesLoading = true
            appState.isLogPreviewLoading = false
        }
        if ProcessInfo.processInfo.environment["OPSDECK_EMPTY_LOG_PREVIEW"] == "1" {
            let source = LogSource(
                title: demo(["en": "Nginx access log", "zh-Hans": "Nginx 访问日志", "zh-Hant": "Nginx 存取記錄", "ar": "سجل وصول Nginx", "de": "Nginx-Zugriffsprotokoll", "ru": "Журнал доступа Nginx", "fr": "Journal d'accès Nginx", "ko": "Nginx 액세스 로그", "pt-BR": "Log de acesso do Nginx", "ja": "Nginx アクセスログ", "tr": "Nginx erişim günlüğü", "es": "Registro de acceso de Nginx"]),
                detail: "/var/log/nginx/access.log",
                command: "tail -n 200 /var/log/nginx/access.log",
                kind: .file,
                byteCount: 0
            )
            appState.selectedWorkspaceMode = .logs
            appState.logSources = [source]
            appState.selectedLogSourceID = source.id
            appState.logPreview = ""
            appState.isLogSourcesLoading = false
            appState.isLogPreviewLoading = false
            appState.operationsError = nil
        }
        if ProcessInfo.processInfo.environment["OPSDECK_LOG_FOLLOW_PREVIEW"] == "1" {
            let sources = [
                LogSource(
                    title: demo(["en": "Nginx access log", "zh-Hans": "Nginx 访问日志", "zh-Hant": "Nginx 存取記錄", "ar": "سجل وصول Nginx", "de": "Nginx-Zugriffsprotokoll", "ru": "Журнал доступа Nginx", "fr": "Journal d'accès Nginx", "ko": "Nginx 액세스 로그", "pt-BR": "Log de acesso do Nginx", "ja": "Nginx アクセスログ", "tr": "Nginx erişim günlüğü", "es": "Registro de acceso de Nginx"]),
                    detail: "/var/log/nginx/access.log",
                    command: "tail -n 200 /var/log/nginx/access.log",
                    kind: .file,
                    byteCount: 3_842_176
                ),
                LogSource(
                    title: demo(["en": "Storefront app log", "zh-Hans": "商城应用日志", "zh-Hant": "商城應用記錄", "ar": "سجل تطبيق المتجر", "de": "Storefront-App-Protokoll", "ru": "Журнал приложения магазина", "fr": "Journal de l'app boutique", "ko": "스토어 앱 로그", "pt-BR": "Log do app da loja", "ja": "ストアアプリログ", "tr": "Mağaza uygulama günlüğü", "es": "Registro de la app de la tienda"]),
                    detail: "/srv/apps/storefront/current/storage/logs/application.log",
                    command: "tail -n 200 /srv/apps/storefront/current/storage/logs/application.log",
                    kind: .file,
                    byteCount: 1_867_776
                ),
                LogSource(
                    title: demo(["en": "Nginx error log", "zh-Hans": "Nginx 错误日志", "zh-Hant": "Nginx 錯誤記錄", "ar": "سجل أخطاء Nginx", "de": "Nginx-Fehlerprotokoll", "ru": "Журнал ошибок Nginx", "fr": "Journal d'erreurs Nginx", "ko": "Nginx 오류 로그", "pt-BR": "Log de erros do Nginx", "ja": "Nginx エラーログ", "tr": "Nginx hata günlüğü", "es": "Registro de errores de Nginx"]),
                    detail: "/var/log/nginx/error.log",
                    command: "tail -n 200 /var/log/nginx/error.log",
                    kind: .file,
                    byteCount: 246_784
                ),
                LogSource(
                    title: "storefront.service",
                    detail: "systemd journal",
                    command: "journalctl -u storefront.service -n 200",
                    kind: .journal,
                    byteCount: nil
                ),
                LogSource(
                    title: "storefront-worker",
                    detail: "Docker container",
                    command: "docker logs --tail 200 storefront-worker",
                    kind: .docker,
                    byteCount: nil
                )
            ]
            appState.selectedWorkspaceMode = .logs
            appState.logSources = sources
            appState.selectedLogSourceID = sources.first?.id
            let routes = ["/api/health", "/api/catalog", "/api/orders", "/api/checkout", "/assets/app.js"]
            appState.logPreview = (1...30).map { index in
                let minute = String(format: "%02d", 10 + index)
                let route = routes[(index - 1) % routes.count]
                let status = index % 11 == 0 ? 304 : 200
                return "2026-07-23T10:\(minute):\(String(format: "%02d", index % 60))Z \(status) GET \(route) request_id=req-\(String(format: "%04d", index)) duration=\(12 + index * 2)ms"
            }.joined(separator: "\n")
            appState.isLogSourcesLoading = false
            appState.isLogPreviewLoading = false
            appState.activeSession?.isLogFollowing = true
            appState.activeSession?.isLogFollowPaused = false
            appState.operationsError = nil
        }
        if ProcessInfo.processInfo.environment["OPSDECK_TOOLS_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["OPSDECK_RUNBOOK_FAILURE_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["OPSDECK_RUNBOOK_RUNNING_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["OPSDECK_DOCKER_READY_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["OPSDECK_NGINX_INACTIVE_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["OPSDECK_DATABASE_STATES_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["OPSDECK_REDIS_MANAGER_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["OPSDECK_DEPLOYMENT_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["OPSDECK_STORE_SERVICES_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["OPSDECK_STORE_DATABASE_PREVIEW"] == "1" {
            appState.selectedWorkspaceMode = .tools
            appState.serverProfile = ServerProfileSnapshot(
                osName: "Ubuntu 24.04.4 LTS",
                osID: "ubuntu",
                osVersionID: "24.04",
                architecture: "x86_64",
                username: "root",
                userID: "0",
                sudoStatus: .root,
                packageManager: .apt,
                initSystem: .systemd,
                tools: [
                    ServerToolPresence(name: "curl", path: "/usr/bin/curl"),
                    ServerToolPresence(name: "git", path: "/usr/bin/git"),
                    ServerToolPresence(name: "htop", path: "/usr/bin/htop"),
                    ServerToolPresence(name: "jq", path: "/usr/bin/jq"),
                    ServerToolPresence(name: "mysql", path: "/usr/bin/mysql"),
                    ServerToolPresence(name: "nginx", path: "/usr/sbin/nginx"),
                    ServerToolPresence(name: "redis-cli", path: "/usr/bin/redis-cli"),
                    ServerToolPresence(name: "docker", path: "/usr/bin/docker"),
                    ServerToolPresence(name: "node", path: "/usr/bin/node"),
                    ServerToolPresence(name: "pm2", path: "/usr/local/bin/pm2")
                ],
                services: [
                    ServerServicePresence(name: "nginx", activeState: "active", enabledState: "enabled"),
                    ServerServicePresence(name: "docker", activeState: "active", enabledState: "enabled"),
                    ServerServicePresence(name: "mysql", activeState: "active", enabledState: "enabled"),
                    ServerServicePresence(name: "redis-server", activeState: "active", enabledState: "enabled"),
                    ServerServicePresence(name: "storefront", activeState: "active", enabledState: "enabled")
                ],
                capturedAt: now
            )
        }
        if ProcessInfo.processInfo.environment["OPSDECK_STORE_SERVICES_PREVIEW"] == "1" {
            appState.openWorkbenchModule("services")
            appState.serviceUnits = [
                ServiceUnit(name: "nginx", description: demo(["en": "High-performance web and reverse proxy server", "zh-Hans": "高性能 Web 与反向代理服务", "zh-Hant": "高效能 Web 與反向代理服務", "ar": "خادم ويب عالي الأداء ووكيل عكسي", "de": "Hochleistungs-Webserver und Reverse-Proxy", "ru": "Высокопроизводительный веб-сервер и обратный прокси", "fr": "Serveur web haute performance et proxy inverse", "ko": "고성능 웹 및 리버스 프록시 서버", "pt-BR": "Servidor web de alto desempenho e proxy reverso", "ja": "高性能 Web・リバースプロキシサーバー", "tr": "Yüksek performanslı web ve ters proxy sunucusu", "es": "Servidor web de alto rendimiento y proxy inverso"]), loadState: "loaded", activeState: "active", subState: "running", unitFileState: "enabled"),
                ServiceUnit(name: "docker", description: demo(["en": "Docker container runtime", "zh-Hans": "Docker 容器运行时", "zh-Hant": "Docker 容器執行環境", "ar": "بيئة تشغيل حاويات Docker", "de": "Docker-Container-Laufzeit", "ru": "Среда выполнения контейнеров Docker", "fr": "Environnement d'exécution des conteneurs Docker", "ko": "Docker 컨테이너 런타임", "pt-BR": "Runtime de contêineres Docker", "ja": "Docker コンテナランタイム", "tr": "Docker konteyner çalışma zamanı", "es": "Entorno de ejecución de contenedores Docker"]), loadState: "loaded", activeState: "active", subState: "running", unitFileState: "enabled"),
                ServiceUnit(name: "storefront", description: demo(["en": "Storefront API and background jobs", "zh-Hans": "商城 API 与后台任务", "zh-Hant": "商城 API 與背景工作", "ar": "واجهة API للمتجر والمهام الخلفية", "de": "Storefront-API und Hintergrundjobs", "ru": "API магазина и фоновые задачи", "fr": "API boutique et tâches d'arrière-plan", "ko": "스토어 API 및 백그라운드 작업", "pt-BR": "API da loja e tarefas em segundo plano", "ja": "ストア API とバックグラウンドジョブ", "tr": "Mağaza API'si ve arka plan görevleri", "es": "API de la tienda y tareas en segundo plano"]), loadState: "loaded", activeState: "active", subState: "running", unitFileState: "enabled"),
                ServiceUnit(name: "mysql", description: demo(["en": "MySQL 8.0 database server", "zh-Hans": "MySQL 8.0 数据库服务", "zh-Hant": "MySQL 8.0 資料庫服務", "ar": "خادم قاعدة بيانات MySQL 8.0", "de": "MySQL-8.0-Datenbankserver", "ru": "Сервер базы данных MySQL 8.0", "fr": "Serveur de base de données MySQL 8.0", "ko": "MySQL 8.0 데이터베이스 서버", "pt-BR": "Servidor de banco de dados MySQL 8.0", "ja": "MySQL 8.0 データベースサーバー", "tr": "MySQL 8.0 veritabanı sunucusu", "es": "Servidor de base de datos MySQL 8.0"]), loadState: "loaded", activeState: "active", subState: "running", unitFileState: "enabled"),
                ServiceUnit(name: "redis-server", description: demo(["en": "Redis cache and queue service", "zh-Hans": "Redis 缓存与队列服务", "zh-Hant": "Redis 快取與佇列服務", "ar": "خدمة التخزين المؤقت والطوابير Redis", "de": "Redis-Cache- und Queue-Dienst", "ru": "Сервис кэширования и очередей Redis", "fr": "Service de cache et de files d'attente Redis", "ko": "Redis 캐시 및 큐 서비스", "pt-BR": "Serviço de cache e filas Redis", "ja": "Redis キャッシュ・キューサービス", "tr": "Redis önbellek ve kuyruk hizmeti", "es": "Servicio de caché y colas Redis"]), loadState: "loaded", activeState: "active", subState: "running", unitFileState: "enabled"),
                ServiceUnit(name: "fail2ban", description: demo(["en": "Login protection and automatic banning", "zh-Hans": "登录防护与自动封禁", "zh-Hant": "登入防護與自動封鎖", "ar": "حماية تسجيل الدخول والحظر التلقائي", "de": "Login-Schutz und automatische Sperren", "ru": "Защита входа и автоматическая блокировка", "fr": "Protection des connexions et bannissement automatique", "ko": "로그인 보호 및 자동 차단", "pt-BR": "Proteção de login e banimento automático", "ja": "ログイン保護と自動ブロック", "tr": "Oturum açma koruması ve otomatik engelleme", "es": "Protección de inicio de sesión y bloqueo automático"]), loadState: "loaded", activeState: "active", subState: "running", unitFileState: "enabled"),
                ServiceUnit(name: "cron", description: demo(["en": "Scheduled task daemon", "zh-Hans": "系统定时任务调度", "zh-Hant": "系統排程工作服務", "ar": "خدمة المهام المجدولة", "de": "Dienst für geplante Aufgaben", "ru": "Планировщик системных задач", "fr": "Démon des tâches planifiées", "ko": "예약 작업 데몬", "pt-BR": "Daemon de tarefas agendadas", "ja": "定期タスクデーモン", "tr": "Zamanlanmış görev servisi", "es": "Demonio de tareas programadas"]), loadState: "loaded", activeState: "active", subState: "running", unitFileState: "enabled")
            ]
            appState.isServicesLoading = false
            appState.operationsError = nil
        }
        if ProcessInfo.processInfo.environment["OPSDECK_DEPLOYMENT_PREVIEW"] == "1" {
            appState.openWorkbenchModule("deployment")
        }
        if ProcessInfo.processInfo.environment["OPSDECK_NGINX_INACTIVE_PREVIEW"] == "1" {
            appState.openWorkbenchModule("services")
            appState.serverProfile?.services = [
                ServerServicePresence(name: "nginx", activeState: "inactive", enabledState: "enabled"),
                ServerServicePresence(name: "docker", activeState: "active", enabledState: "enabled")
            ]
            appState.serviceUnits = [
                ServiceUnit(
                    name: "nginx",
                    description: "A high performance web server",
                    loadState: "loaded",
                    activeState: "inactive",
                    subState: "dead",
                    unitFileState: "enabled"
                ),
                ServiceUnit(
                    name: "docker",
                    description: "Docker Application Container Engine",
                    loadState: "loaded",
                    activeState: "active",
                    subState: "running",
                    unitFileState: "enabled"
                )
            ]
            appState.nginxSnapshot = NginxSnapshot(
                isInstalled: true,
                version: "nginx/1.24.0",
                configPath: "/etc/nginx/nginx.conf",
                sites: [],
                accessLogPath: "/var/log/nginx/access.log",
                errorLogPath: "/var/log/nginx/error.log",
                certificateHints: []
            )
            appState.operationsError = nil
        }
        if ProcessInfo.processInfo.environment["OPSDECK_DATABASE_STATES_PREVIEW"] == "1" {
            let secondaryHost = HostProfile(
                id: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF") ?? UUID(),
                name: "api-staging",
                host: "api.example.internal",
                username: "deploy",
                authType: .password,
                credentialID: nil,
                tags: ["api"],
                note: "Sanitized secondary screenshot profile.",
                lastConnectedAt: now.addingTimeInterval(-90),
                lastStatus: "connected"
            )
            appState.hosts.insert(secondaryHost, at: 0)
            if let secondarySession = appState.ensureSession(for: secondaryHost.id) {
                secondarySession.connectionStatus = .connected
                secondarySession.databases = [
                    DatabaseTarget(
                        kind: .postgresql,
                        serviceName: "postgresql",
                        installed: true,
                        serviceInstalled: true,
                        activeState: "active",
                        version: "psql 16.2"
                    )
                ]
                secondarySession.hasLoadedDatabases = true
            }
            appState.openWorkbenchModule("database")
            appState.databases = [
                DatabaseTarget(
                    kind: .mysql,
                    serviceName: "mysql",
                    installed: true,
                    serviceInstalled: true,
                    activeState: "active",
                    version: "mysql Ver 8.0.42"
                ),
                DatabaseTarget(
                    kind: .redis,
                    serviceName: "redis-server",
                    installed: true,
                    serviceInstalled: true,
                    activeState: "inactive",
                    version: "redis-cli 7.0.15"
                ),
                DatabaseTarget(
                    kind: .postgresql,
                    serviceName: "postgresql",
                    installed: true,
                    serviceInstalled: false,
                    activeState: nil,
                    version: "psql 16.2"
                )
            ]
            appState.isDatabasesLoading = false
            appState.activeSession?.hasLoadedDatabases = true
            appState.operationsError = nil
        }
        if ProcessInfo.processInfo.environment["OPSDECK_REDIS_MANAGER_PREVIEW"] == "1" {
            appState.openWorkbenchModule("database")
            appState.databases = [RedisPreviewFixture.target]
            appState.isDatabasesLoading = false
            appState.activeSession?.hasLoadedDatabases = true
            appState.operationsError = nil
        }
        if ProcessInfo.processInfo.environment["OPSDECK_DATABASE_BROWSER_PERF_PREVIEW"] == "1",
           let session = appState.activeSession {
            let columns = (0..<40).map { $0 == 0 ? "id" : "column_\($0)" }
            let performanceTarget = DatabaseTarget(
                kind: .mysql,
                serviceName: "mysql",
                installed: true,
                serviceInstalled: true,
                activeState: "active",
                version: "MySQL performance fixture"
            )
            session.openWorkbenchModule("database")
            session.databases = [performanceTarget]
            session.hasLoadedDatabases = true
            session.isDatabasesLoading = false
            // Set the target after DatabasesPane is mounted so the screenshot
            // exercises the same onChange-driven window path as a sidebar click.
            session.dbState.dbBrowserTarget = nil
            if let connection = DBConnectionProfile.detected(performanceTarget) {
                let reportingConnection = DBConnectionProfile(
                    id: "preview-reporting",
                    name: "Reporting MySQL",
                    dialect: .mysql,
                    host: "127.0.0.1",
                    port: 3307,
                    username: "reporter",
                    source: .manual
                )
                let analyticsConnection = DBConnectionProfile(
                    id: "preview-analytics",
                    name: "Analytics PostgreSQL",
                    dialect: .postgres,
                    host: "10.0.0.18",
                    port: 5432,
                    username: "analytics",
                    source: .manual
                )
                session.dbState.dbConnections = [
                    connection,
                    reportingConnection,
                    analyticsConnection
                ]
                session.dbState.dbSelectedConnectionID = connection.id
                if ProcessInfo.processInfo.environment["OPSDECK_DATABASE_TREE_PREVIEW"] == "1" {
                    session.dbState.dbNavigatorSnapshots[reportingConnection.id] = DBNavigatorSnapshot(
                        databases: ["reporting"],
                        selectedDatabase: "reporting",
                        tablesByDatabase: [
                            "reporting": [
                                DBTableInfo(name: "daily_metrics", estimatedRows: 1_240, sizeMB: 2.4)
                            ]
                        ]
                    )
                }
            }
            session.dbState.dbDatabases = ["performance_fixture"]
            session.dbState.dbSelectedDatabase = "performance_fixture"
            session.dbState.dbTables = [DBTableInfo(name: "wide_table", estimatedRows: 50_000, sizeMB: 24.0)]
            session.dbState.dbSelectedTable = "wide_table"
            session.dbState.dbColumns = columns.enumerated().map { index, name in
                DBColumnInfo(
                    name: name,
                    dataType: index == 0 ? "bigint" : "varchar(255)",
                    nullable: index != 0,
                    isPrimaryKey: index == 0,
                    defaultValue: nil
                )
            }
            session.dbState.dbRows = DBResultSet(
                columns: columns,
                rows: (0..<200).map { row in
                    columns.indices.map { column in
                        column == 0 ? String(row + 1) : "row_\(row + 1)_value_\(column)"
                    }
                }
            )
            session.dbState.dbPageSize = 200
            session.dbState.dbFilterColumn = columns.first
            session.dbState.dbRowsVersion += 1
            if ProcessInfo.processInfo.environment["OPSDECK_DATABASE_SQL_PREVIEW"] == "1" {
                let firstTab = DBQueryTab(sql: "SELECT id, email, created_at\nFROM users\nORDER BY created_at DESC\nLIMIT 100;")
                let secondTab = DBQueryTab(sql: "SELECT COUNT(*) FROM events;")
                session.dbState.dbQueryTabs = [firstTab, secondTab]
                session.dbState.dbSelectedQueryTabID = firstTab.id
                session.dbState.dbSQLText = firstTab.sql
                session.dbState.dbQueryHistory = [
                    DBSavedQuery(sql: "SELECT * FROM users LIMIT 50;"),
                    DBSavedQuery(sql: "SHOW TABLES;")
                ]
                session.dbState.dbQueryFavorites = [
                    DBSavedQuery(sql: "SELECT COUNT(*) FROM events;")
                ]
                session.dbState.dbSQLResult = DBResultSet(
                    columns: ["id", "email", "created_at"],
                    rows: (1...12).map { [String($0), "demo\($0)@example.com", "2026-07-22 21:\(String(format: "%02d", $0)):00"] },
                    elapsed: 0.042,
                    transportElapsed: 0.038,
                    parseElapsed: 0.004,
                    responseBytes: 3_240
                )
                session.dbState.dbSQLResultVersion += 1
                session.dbState.dbTab = .sql
            }
            if ProcessInfo.processInfo.environment["OPSDECK_DATABASE_CREATE_PREVIEW"] == "1" {
                session.dbState.dbShowCreateDatabaseSheet = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                session.dbState.dbBrowserTarget = performanceTarget
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                session.dbState.dbRows.rows[0][1] = "staged-performance-value"
                session.dbState.dbStagedChanges = [DBStagedCellChange(
                    rowIndex: 0,
                    column: columns[1],
                    originalValue: "row_1_value_1",
                    newValue: "staged-performance-value",
                    sql: "UPDATE fixture"
                )]
                session.dbState.dbRowsVersion += 1
            }
        }
        if ProcessInfo.processInfo.environment["OPSDECK_STORE_DATABASE_PREVIEW"] == "1",
           let session = appState.activeSession {
            let target = DatabaseTarget(
                kind: .mysql,
                serviceName: "mysql",
                installed: true,
                serviceInstalled: true,
                activeState: "active",
                version: "MySQL 8.0.42"
            )
            let columns = ["order_no", "customer", "status", "amount", "channel", "created_at"]
            let tableNames: [(String, Int, Double)] = [
                ("orders", 18_426, 42.8),
                ("customers", 8_912, 18.6),
                ("products", 2_148, 12.4),
                ("inventory", 2_148, 6.8),
                ("payments", 17_903, 28.2),
                ("refunds", 286, 1.4),
                ("shipments", 16_774, 24.7),
                ("coupons", 342, 0.8),
                ("audit_events", 126_840, 94.1),
                ("job_runs", 48_219, 31.6)
            ]
            // 订单演示数据按市场适配（12 语言）：货币、支付渠道、客户名、状态均本地化，非逐字翻译。
            let orders = demoOrders()

            session.openWorkbenchModule("database")
            session.databases = [target]
            session.hasLoadedDatabases = true
            session.isDatabasesLoading = false
            session.dbState.dbBrowserTarget = nil
            if let detected = DBConnectionProfile.detected(target) {
                let analytics = DBConnectionProfile(
                    id: "store-preview-analytics",
                    name: "Analytics PostgreSQL",
                    dialect: .postgres,
                    host: "analytics.example.test",
                    port: 5432,
                    username: "analyst",
                    source: .manual
                )
                session.dbState.dbConnections = [detected, analytics]
                session.dbState.dbSelectedConnectionID = detected.id
            }
            session.dbState.dbDatabases = ["commerce_ops", "reporting", "information_schema"]
            session.dbState.dbSelectedDatabase = "commerce_ops"
            session.dbState.dbTables = tableNames.map {
                DBTableInfo(name: $0.0, estimatedRows: $0.1, sizeMB: $0.2)
            }
            session.dbState.dbSelectedTable = "orders"
            session.dbState.dbColumns = [
                DBColumnInfo(name: "order_no", dataType: "varchar(24)", nullable: false, isPrimaryKey: true, defaultValue: nil),
                DBColumnInfo(name: "customer", dataType: "varchar(120)", nullable: false, isPrimaryKey: false, defaultValue: nil),
                DBColumnInfo(name: "status", dataType: "varchar(24)", nullable: false, isPrimaryKey: false, defaultValue: nil),
                DBColumnInfo(name: "amount", dataType: "decimal(12,2)", nullable: false, isPrimaryKey: false, defaultValue: nil),
                DBColumnInfo(name: "channel", dataType: "varchar(32)", nullable: false, isPrimaryKey: false, defaultValue: nil),
                DBColumnInfo(name: "created_at", dataType: "datetime", nullable: false, isPrimaryKey: false, defaultValue: nil)
            ]
            session.dbState.dbRows = DBResultSet(columns: columns, rows: orders)
            session.dbState.dbRowsVersion += 1
            let query = DBQueryTab(sql: """
                SELECT order_no, customer, status, amount, channel, created_at
                FROM orders
                ORDER BY created_at DESC
                LIMIT 100;
                """)
            session.dbState.dbQueryTabs = [query]
            session.dbState.dbSelectedQueryTabID = query.id
            session.dbState.dbSQLText = query.sql
            session.dbState.dbQueryHistory = [
                DBSavedQuery(sql: "SELECT status, COUNT(*) FROM orders GROUP BY status;"),
                DBSavedQuery(sql: "SELECT * FROM payments WHERE status = 'pending';")
            ]
            session.dbState.dbQueryFavorites = [
                DBSavedQuery(sql: "SELECT * FROM audit_events ORDER BY created_at DESC LIMIT 100;")
            ]
            session.dbState.dbSQLResult = DBResultSet(
                columns: columns,
                rows: orders,
                elapsed: 0.036,
                transportElapsed: 0.031,
                parseElapsed: 0.005,
                responseBytes: 8_946
            )
            session.dbState.dbSQLResultVersion += 1
            session.dbState.dbTab = .sql
            session.operationsError = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                session.dbState.dbBrowserTarget = target
            }
        }
        if ProcessInfo.processInfo.environment["OPSDECK_DOCKER_READY_PREVIEW"] == "1" {
            appState.openWorkbenchModule("docker")
            appState.serverProfile?.tools.append(
                ServerToolPresence(name: "docker", path: "/usr/bin/docker")
            )
            appState.serverProfile?.services.append(
                ServerServicePresence(name: "docker", activeState: "active", enabledState: "enabled")
            )
            appState.dockerSnapshot = DockerSnapshot(
                isInstalled: true,
                daemonReachable: true,
                clientVersion: "Docker version 29.1.3",
                daemonError: nil,
                containers: []
            )
            appState.dockerContainers = []
            appState.isDockerLoading = false
            appState.operationsError = nil
        }
        if ProcessInfo.processInfo.environment["OPSDECK_RUNBOOK_RUNNING_PREVIEW"] == "1" {
            let plan = RunbookPlan(
                kind: .install,
                title: demo("安装 Docker", "Install Docker"),
                summary: demo("根据服务器画像推荐 apt 安装方式。", "Recommended apt install based on the server profile."),
                targetDescription: "Docker",
                risk: .medium,
                requiresSudo: false,
                backupDescription: nil,
                rollbackDescription: demo("可使用 apt 卸载软件包。", "Packages can be removed with apt."),
                steps: [
                    RunbookStep(title: demo("更新 apt 索引", "Update apt index"), command: "apt-get update"),
                    RunbookStep(title: demo("安装 Docker", "Install Docker"), command: "apt-get install -y docker.io"),
                    RunbookStep(title: demo("验证安装", "Verify installation"), command: "docker --version")
                ]
            )
            var run = RunbookRun(plan: plan, hostID: hostID)
            run.status = .running
            run.startedAt = now.addingTimeInterval(-18)
            run.steps[0].status = .succeeded
            run.steps[0].exitCode = 0
            run.steps[0].duration = 4.21
            run.steps[0].output = "Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease\nReading package lists... Done"
            run.steps[1].status = .running
            run.steps[1].output = "Reading package lists... Done\nBuilding dependency tree... Done\nUnpacking docker.io (26.1.3-0ubuntu1~24.04.1) ...\nSetting up containerd (1.7.24-0ubuntu1~24.04.2) ..."
            appState.activeRunbookRun = run
            appState.runbookRuns = []
            appState.operationsError = nil
            if ProcessInfo.processInfo.environment["OPSDECK_RUNBOOK_DETAIL_PREVIEW"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    appState.selectedRunbookRun = run
                }
            }
        }
        if ProcessInfo.processInfo.environment["OPSDECK_RUNBOOK_FAILURE_PREVIEW"] == "1" {
            let plan = RunbookPlan(
                kind: .install,
                title: demo("安装 Docker", "Install Docker"),
                summary: demo("根据服务器画像推荐 apt 安装方式。", "Recommended apt install based on the server profile."),
                targetDescription: "Docker",
                risk: .medium,
                requiresSudo: false,
                backupDescription: nil,
                rollbackDescription: demo("可使用 apt 卸载软件包。", "Packages can be removed with apt."),
                steps: [
                    RunbookStep(title: demo("更新 apt 索引", "Update apt index"), command: "apt-get update"),
                    RunbookStep(title: demo("安装软件包", "Install packages"), command: "apt-get install -y docker.io docker-compose-plugin"),
                    RunbookStep(title: demo("验证安装", "Verify installation"), command: "command -v docker")
                ]
            )
            var run = RunbookRun(plan: plan, hostID: hostID)
            run.status = .failed
            run.startedAt = now.addingTimeInterval(-8)
            run.finishedAt = now
            run.steps[0].status = .succeeded
            run.steps[0].exitCode = 0
            run.steps[0].duration = 1.24
            run.steps[0].output = "Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease"
            run.steps[1].status = .failed
            run.steps[1].exitCode = 100
            run.steps[1].duration = 0.41
            run.steps[1].output = "E: Unable to locate package docker-compose-plugin"
            run.errorMessage = demo("安装软件包失败（退出码 100）：E: Unable to locate package docker-compose-plugin",
                                    "Package install failed (exit code 100): E: Unable to locate package docker-compose-plugin")
            appState.runbookRuns = [run]
            appState.operationsError = run.errorMessage
            if ProcessInfo.processInfo.environment["OPSDECK_RUNBOOK_DETAIL_PREVIEW"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    appState.selectedRunbookRun = run
                }
            }
        }
        if ProcessInfo.processInfo.environment["OPSDECK_EMPTY_STATE_PREVIEW"] == "1" {
            appState.hosts = []
            appState.groups = []
            appState.selectedSidebarHostID = nil
            appState.currentHostName = "OpsDeck"
            appState.isTerminalVisible = false
        }
        if ProcessInfo.processInfo.environment["OPSDECK_HELP_PREVIEW"] == "1" {
            DispatchQueue.main.async {
                appState.showHelpGuide()
            }
        }
    }

    @discardableResult
    static func renderMainViewIfRequested(appState: AppState) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["OPSDECK_MAIN_RENDER_OUT"], !outputPath.isEmpty else {
            return false
        }
        let width = Double(environment["OPSDECK_SCREENSHOT_WIDTH"] ?? "1200") ?? 1_200
        let height = Double(environment["OPSDECK_SCREENSHOT_HEIGHT"] ?? "750") ?? 750
        let scale = Double(environment["OPSDECK_SCREENSHOT_SCALE"] ?? "1") ?? 1

        let content = MainWindow()
            .environmentObject(appState)
            .modelContainer(appState.storage.container)
            .frame(width: width, height: height)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let data = opaquePNGData(from: image) else {
            print("OpsDeck main renderer failed to create PNG data.")
            return true
        }
        do {
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            print("OpsDeck main renderer written: \(outputPath)")
        } catch {
            print("OpsDeck main renderer error: \(error.localizedDescription)")
        }
        return true
    }

    @discardableResult
    static func renderIfRequested(appState: AppState) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let outputRoot = environment["OPSDECK_SCREENSHOT_OUT"], !outputRoot.isEmpty else {
            return false
        }

        let language = environment["OPSDECK_SCREENSHOT_LANG"] ?? "en"
        let width = Double(environment["OPSDECK_SCREENSHOT_WIDTH"] ?? "2560") ?? 2_560
        let height = Double(environment["OPSDECK_SCREENSHOT_HEIGHT"] ?? "1600") ?? 1_600
        let scale = Double(environment["OPSDECK_SCREENSHOT_SCALE"] ?? "1") ?? 1
        let outputDirectory = URL(fileURLWithPath: outputRoot)
            .appendingPathComponent(language)
            .appendingPathComponent("raw")
        let outputURL = outputDirectory.appendingPathComponent("01-main.png")

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let content = ScreenshotSceneView(language: language)
                .frame(width: width, height: height)
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            renderer.scale = scale

            guard let image = renderer.cgImage else {
                print("OpsDeck screenshot renderer failed to create a CGImage.")
                return true
            }
            guard let data = opaquePNGData(from: image) else {
                print("OpsDeck screenshot renderer failed to encode PNG data.")
                return true
            }
            try data.write(to: outputURL, options: .atomic)
            print("OpsDeck screenshot written: \(outputURL.path(percentEncoded: false))")
        } catch {
            print("OpsDeck screenshot renderer error: \(error.localizedDescription)")
        }

        return true
    }

    @discardableResult
    static func captureEditorWindowIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["OPSDECK_EDITOR_CAPTURE_OUT"], !outputPath.isEmpty else {
            return false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let window = NSApp.windows.first(where: {
                $0.isVisible
                    && abs($0.frame.width - 760) < 4
                    && abs($0.frame.height - 560) < 4
            }), let contentView = window.contentView else {
                print("OpsDeck editor capture failed: editor window not found.")
                NSApp.terminate(nil)
                return
            }

            contentView.displayIfNeeded()
            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
                print("OpsDeck editor capture failed: bitmap could not be created.")
                NSApp.terminate(nil)
                return
            }
            contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                print("OpsDeck editor capture failed: PNG could not be encoded.")
                NSApp.terminate(nil)
                return
            }

            do {
                try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
                print("OpsDeck editor capture written: \(outputPath)")
            } catch {
                print("OpsDeck editor capture error: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
        return true
    }

    @discardableResult
    static func captureMainWindowIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["OPSDECK_MAIN_CAPTURE_OUT"], !outputPath.isEmpty else {
            return false
        }

        let prefersKeyWindow = environment["OPSDECK_CAPTURE_KEY_WINDOW"] == "1"
        let prefersDatabaseWindow = environment["OPSDECK_CAPTURE_DATABASE_WINDOW"] == "1"
        let prefersTerminalPreview = ProcessInfo.processInfo.environment["OPSDECK_TERMINAL_PREVIEW"] == "1"
        let captureDelay = (prefersKeyWindow || prefersDatabaseWindow || prefersTerminalPreview) ? 2.0 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) {
            let visibleWindows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            let targetWindow: NSWindow?
            if prefersDatabaseWindow {
                targetWindow = visibleWindows.first { $0.identifier?.rawValue == "opsdeck.database-browser" }
            } else if prefersKeyWindow {
                targetWindow = NSApp.keyWindow ?? visibleWindows.first
            } else {
                targetWindow = visibleWindows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            }
            guard let window = targetWindow,
                  let contentView = window.contentView else {
                print("OpsDeck main capture failed: main window not found.")
                NSApp.terminate(nil)
                return
            }

            if let widthText = environment["OPSDECK_CAPTURE_WIDTH"],
               let heightText = environment["OPSDECK_CAPTURE_HEIGHT"],
               let width = Double(widthText), let height = Double(heightText) {
                window.setContentSize(NSSize(width: width, height: height))
                window.center()
            }

            contentView.displayIfNeeded()
            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
                print("OpsDeck main capture failed: bitmap could not be created.")
                NSApp.terminate(nil)
                return
            }
            contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                print("OpsDeck main capture failed: PNG could not be encoded.")
                NSApp.terminate(nil)
                return
            }

            do {
                try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
                print("OpsDeck main capture written: \(outputPath)")
            } catch {
                print("OpsDeck main capture error: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private static func opaquePNGData(from image: CGImage) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(rect)
        context.draw(image, in: rect)
        guard let opaqueImage = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: opaqueImage)
        return bitmap.representation(using: .png, properties: [:])
    }
}

private struct ScreenshotSceneView: View {
    let language: String

    private var copy: ScreenshotCopy {
        ScreenshotCopy(language: language)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.Color.separator)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 280)
                Divider().overlay(Theme.Color.separator)
                files
                    .frame(maxWidth: .infinity)
                Divider().overlay(Theme.Color.separator)
                status
                    .frame(width: 360)
            }
            Divider().overlay(Theme.Color.separator)
            terminal
                .frame(height: 260)
        }
        .background(Theme.Color.appBackground)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .foregroundStyle(Theme.Color.textSecondary)
                Text("demo-web-01")
                    .font(Theme.Font.windowTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .frame(width: 240, alignment: .leading)

            HStack(spacing: 8) {
                Circle().fill(Theme.Color.success).frame(width: 7, height: 7)
                Text("demo.example.internal:22")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Label("/var/www/demo-app/current", systemImage: "folder")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.Color.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

            Button(copy.connect) {}
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(Theme.Color.toolbarBackground)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(copy.servers, systemImage: "server.rack")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textSecondary)
            serverRow(name: "demo-web-01", detail: "deploy · demo.example.internal", selected: true)
            serverRow(name: "staging-box", detail: "ops · staging.example.internal", selected: false)
            serverRow(name: "home-nas", detail: "admin · lan only", selected: false)
            Spacer()
            Text(copy.privacy)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(3)
        }
        .padding(16)
        .background(Theme.Color.sidebarBackground)
    }

    private func serverRow(name: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(selected ? Theme.Color.success : Theme.Color.textTertiary.opacity(0.35))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(detail)
                    .font(Theme.Font.tiny)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(selected ? Theme.Color.rowSelected : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var files: some View {
        filePane(title: copy.remoteFiles, path: "/var/www/demo-app/current", rows: [
            ("releases", "folder · 15 min ago · 0755", "folder"),
            ("public", "folder · 30 min ago · 0755", "folder"),
            ("app.tar.gz", "1.2 MB · just now · 0644", "doc.zipper"),
            ("nginx.conf", "6 KB · 20 min ago · 0644", "doc.text"),
            (".env.example", "2 KB · 0640", "doc.text"),
            ("deploy.sh", "4 KB · executable · 0755", "terminal"),
            ("app.log", "512 KB · 2 min ago · 0644", "doc.text")
        ])
        .background(Theme.Color.surface)
    }

    private func filePane(title: String, path: String, rows: [(String, String, String)]) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack {
                    Text(title)
                        .font(Theme.Font.sectionTitle)
                    Spacer()
                    toolbarIcon("arrow.clockwise")
                    toolbarIcon("square.and.arrow.up")
                    toolbarIcon("square.and.arrow.down")
                    toolbarIcon("doc.text")
                }
                Text(path)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .background(Theme.Color.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .padding(.horizontal, 16)
            .frame(height: 66)
            Divider().overlay(Theme.Color.separator)
            HStack {
                Text(verbatim: copy.name)
                Spacer()
                Text(verbatim: copy.info).frame(width: 156, alignment: .trailing)
            }
            .font(Theme.Font.tiny.weight(.semibold))
            .foregroundStyle(Theme.Color.textTertiary)
            .padding(.horizontal, 16)
            .frame(height: 24)
            .background(Theme.Color.surfaceRaised.opacity(0.65))
            Divider().overlay(Theme.Color.separator)

            ForEach(rows, id: \.0) { row in
                HStack(spacing: 12) {
                    Image(systemName: row.2)
                        .foregroundStyle(row.2 == "folder" ? Theme.Color.fileAmber : Theme.Color.textSecondary)
                        .frame(width: 22)
                    Text(row.0)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Spacer()
                    Text(row.1)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .frame(width: 156, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .frame(height: 38)
                Divider().overlay(Theme.Color.separator.opacity(0.45))
            }
            Spacer()
        }
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.Color.textSecondary)
            .frame(width: 24, height: 24)
            .background(Theme.Color.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(copy.status)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Text("Ubuntu 24.04 LTS · nginx · demo data only")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            metric(copy.load, "11%")
            metric(copy.memory, "47%")
            metric(copy.disk, "58%")
            Divider().overlay(Theme.Color.separator)
            Text(copy.operationRecords)
                .font(Theme.Font.sectionTitle)
            compactRow("app.tar.gz", copy.uploadDone, "arrow.up.doc", Theme.Color.success)
            compactRow("app.log", copy.downloadDone, "arrow.down.doc", Theme.Color.success)
            command("df -h")
            command("systemctl status nginx --no-pager")
            Spacer()
        }
        .padding(22)
        .background(Theme.Color.surface)
        .foregroundStyle(Theme.Color.textPrimary)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(Theme.Font.caption)
                Spacer()
                Text(value).font(Theme.Font.monoSmall)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Color.separator)
                    Capsule().fill(title == copy.load ? Theme.Color.success : Theme.Color.accent)
                        .frame(width: proxy.size.width * metricValue(value))
                }
            }
            .frame(height: 8)
        }
    }

    private func compactRow(_ title: String, _ detail: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Font.caption)
                Text(detail).font(Theme.Font.tiny).foregroundStyle(Theme.Color.textTertiary)
            }
            Spacer()
        }
    }

    private func command(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.monoSmall)
            .foregroundStyle(Theme.Color.textSecondary)
            .lineLimit(1)
    }

    private var terminal: some View {
        VStack(spacing: 0) {
            HStack {
                Label(copy.terminal, systemImage: "terminal")
                    .font(Theme.Font.sectionTitle)
                Text("demo-web-01")
                    .font(Theme.Font.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.Color.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Spacer()
                Text("132 x 13")
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                Text(verbatim: copy.ready)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.success)
            }
            .padding(.horizontal, 22)
            .frame(height: 48)
            .background(Theme.Color.terminalChrome)
            Text("""
            $ pwd
            /var/www/demo-app/current
            $ ls -lh
            drwxr-xr-x  deploy www-data  releases
            -rwxr-xr-x  deploy www-data  deploy.sh
            -rw-r--r--  deploy www-data  app.log
            $ tail -n 5 storage/logs/app.log
            [INFO] demo request completed in 42ms
            [INFO] cache warmed for /dashboard
            """)
            .font(.system(size: 17, weight: .regular, design: .monospaced))
            .foregroundStyle(Theme.Color.terminalText)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(22)
            .background(Theme.Color.terminalBackground)
        }
    }

    private func metricValue(_ value: String) -> Double {
        (Double(value.replacingOccurrences(of: "%", with: "")) ?? 0) / 100
    }
}

private struct ScreenshotCopy {
    let language: String

    var isChinese: Bool { language.hasPrefix("zh") }
    var connected: String { isChinese ? "已连接" : "Connected" }
    var files: String { isChinese ? "文件" : "Files" }
    var terminal: String { isChinese ? "终端" : "Terminal" }
    var metrics: String { isChinese ? "状态" : "Metrics" }
    var connect: String { isChinese ? "连接" : "Connect" }
    var servers: String { isChinese ? "服务器" : "Servers" }
    var privacy: String { isChinese ? "演示数据已脱敏，不包含真实 IP、密钥或生产日志。" : "Sanitized demo data. No real IPs, keys, or production logs." }
    var local: String { isChinese ? "本地" : "Local" }
    var remote: String { isChinese ? "远程" : "Remote" }
    var remoteFiles: String { isChinese ? "远程文件" : "Remote Files" }
    var status: String { isChinese ? "服务器状态" : "Server Status" }
    var load: String { isChinese ? "负载" : "Load" }
    var memory: String { isChinese ? "内存" : "Memory" }
    var disk: String { isChinese ? "磁盘" : "Disk" }
    var operationRecords: String { isChinese ? "操作记录" : "Activity" }
    var uploadDone: String { isChinese ? "上传完成" : "Upload complete" }
    var downloadDone: String { isChinese ? "下载完成" : "Download complete" }
    var ready: String { isChinese ? "就绪" : "Ready" }
    var name: String { isChinese ? "名称" : "Name" }
    var info: String { isChinese ? "信息" : "Info" }
}
#endif
