import Foundation

actor ServiceManagerService {
    func collect(config: SSHConnectionConfig, sshService: SSHService) async throws -> [ServiceUnit] {
        let result = try await sshService.executeCommand(serviceListCommand, on: config, maxResponseSize: 128 * 1024)
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { parseServiceLine(String($0)) }
    }

    nonisolated func plan(action: ServiceAction, service: ServiceUnit, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let command = "\(sudo)systemctl \(action.rawValue) \(OpsShell.quote(service.name))"
        let verify = verificationCommand(action: action, serviceName: service.name, sudo: sudo)
        return RunbookPlan(
            kind: .service,
            title: String(localized: "\(action.displayName) \(service.name)"),
            summary: String(localized: "对 systemd 服务执行 \(action.displayName)，执行后刷新服务状态。"),
            targetDescription: service.name,
            risk: action == .restart || action == .stop ? .high : .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "可通过相反服务动作恢复，例如 start/stop 或 enable/disable。"),
            steps: [
                RunbookStep(title: String(localized: "\(action.displayName) 服务"), command: command),
                RunbookStep(title: String(localized: "验证服务状态"), command: verify)
            ]
        )
    }

    private nonisolated func verificationCommand(action: ServiceAction, serviceName: String, sudo: String) -> String {
        let service = OpsShell.quote(serviceName)
        switch action {
        case .start, .restart, .reload:
            return OpsShell.systemdActiveVerification(serviceName: serviceName, sudo: sudo)
        case .stop:
            return "state=\"$(systemctl is-active \(service) 2>/dev/null || true)\"; printf '状态：%s\\n' \"$state\"; [ \"$state\" = inactive ]"
        case .enable:
            return "systemctl is-enabled --quiet \(service) && systemctl is-enabled \(service)"
        case .disable:
            return "state=\"$(systemctl is-enabled \(service) 2>/dev/null || true)\"; printf '开机状态：%s\\n' \"$state\"; [ \"$state\" = disabled ]"
        }
    }

    private var serviceListCommand: String {
        """
        if ! command -v systemctl >/dev/null 2>&1; then exit 0; fi
        # systemd's ActiveState is unreliable for SysV/LSB-wrapped services
        # (e.g. nginx started via /etc/init.d or `service`): it can report
        # inactive while the daemon is actually running. Cross-check the real
        # process so the UI reflects reality instead of systemd's bookkeeping.
        procnames() {
          case "$1" in
            nginx) echo nginx ;;
            caddy) echo caddy ;;
            docker) echo dockerd ;;
            redis|redis-server) echo redis-server redis ;;
            postgresql) echo postgres ;;
            mysql|mariadb) echo mysqld mariadbd ;;
            *) echo "$1" ;;
          esac
        }
        is_alive() {
          for p in $(procnames "$1"); do
            if pgrep -x "$p" >/dev/null 2>&1 || pidof "$p" >/dev/null 2>&1; then
              return 0
            fi
          done
          return 1
        }
        emitted=" "
        for svc in nginx caddy docker redis redis-server postgresql mysql mariadb; do
          load="$(systemctl show "$svc" -p LoadState --value 2>/dev/null || true)"
          if [ "$load" = "not-found" ] || [ -z "$load" ]; then continue; fi
          # Dedup aliases: redis/redis-server (and mysql/mariadb) can resolve to the
          # same canonical unit; skip a unit whose Id was already emitted.
          id="$(systemctl show "$svc" -p Id --value 2>/dev/null || true)"
          [ -z "$id" ] && id="$svc"
          case "$emitted" in *" $id "*) continue;; esac
          emitted="$emitted$id "
          active="$(systemctl show "$svc" -p ActiveState --value 2>/dev/null || true)"
          sub="$(systemctl show "$svc" -p SubState --value 2>/dev/null || true)"
          desc="$(systemctl show "$svc" -p Description --value 2>/dev/null || true)"
          enabled="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
          if [ "$active" != "active" ] && is_alive "$svc"; then
            active="active"
            sub="running"
          fi
          printf 'SERVICE=%s|%s|%s|%s|%s|%s\\n' "$svc" "$desc" "$load" "$active" "$sub" "$enabled"
        done
        # Failed units: `systemctl --failed` prefixes each line with a colored
        # `●` bullet, so a naive $1 would capture the bullet instead of the unit
        # name (empty/invisible row). Detect the bullet (first field with no dot,
        # second field looks like a unit), then read the real name + DESCRIPTION
        # column, and skip services already emitted by the loop above (dedup).
        systemctl --failed --plain --no-legend 2>/dev/null | awk '{
          i=1; if ($1 !~ /\\./ && $2 ~ /\\./) i=2;
          n=$i; b=n; sub(/\\.[^.]*$/, "", b);
          if (b=="nginx"||b=="caddy"||b=="docker"||b=="redis"||b=="redis-server"||b=="postgresql"||b=="mysql"||b=="mariadb") next;
          d=""; for (j=i+4; j<=NF; j++) d=d (j>i+4?" ":"") $j;
          if (d=="") d="启动失败的单元";
          print "SERVICE=" n "|" d "|loaded|failed|failed|unknown"
        }'
        """
    }

    private func parseServiceLine(_ line: String) -> ServiceUnit? {
        guard line.hasPrefix("SERVICE=") else { return nil }
        let payload = line.replacingOccurrences(of: "SERVICE=", with: "")
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6 else { return nil }
        // Never render a nameless / bullet-only row (defends against odd systemctl output).
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "●", name != "*" else { return nil }
        return ServiceUnit(
            name: parts[0],
            description: parts[1],
            loadState: parts[2],
            activeState: parts[3],
            subState: parts[4],
            unitFileState: parts[5]
        )
    }
}

actor LogDiscoveryService {
    func discover(config: SSHConnectionConfig, sshService: SSHService) async throws -> [LogSource] {
        // File/journal/docker discovery is best-effort. A non-zero exit (e.g. Docker
        // installed but with no containers) must NOT blank the always-available
        // security views, so swallow discovery errors and still return the curated
        // sources. The discovery script also ends with `exit 0` as defense in depth.
        var discovered: [LogSource] = []
        if let result = try? await sshService.executeCommand(discoveryCommand, on: config, maxResponseSize: 128 * 1024) {
            discovered = result.stdout
                .split(whereSeparator: \.isNewline)
                .compactMap { parseLogLine(String($0)) }
        }
        // Curated security views are always offered — built in Swift so their
        // piped commands don't clash with the discovery line delimiter.
        return securitySources + discovered
    }

    /// Attack-surface / intrusion views: failed & successful SSH logins, login
    /// history, and who's online now. Read-only; each falls back gracefully.
    private var securitySources: [LogSource] {
        [
            LogSource(
                title: String(localized: "🛡 SSH 登录失败（疑似攻击）"),
                detail: "Failed password / Invalid user",
                command: "{ journalctl _COMM=sshd -n 2000 --no-pager 2>/dev/null || cat /var/log/auth.log 2>/dev/null || cat /var/log/secure 2>/dev/null; } | grep -aiE 'Failed password|Invalid user|authentication failure|not allowed' | tail -n 300",
                kind: .journal,
                byteCount: nil
            ),
            LogSource(
                title: String(localized: "🛡 攻击来源 IP 排行"),
                detail: String(localized: "失败登录最多的 IP"),
                command: "{ journalctl _COMM=sshd --no-pager 2>/dev/null || cat /var/log/auth.log 2>/dev/null || cat /var/log/secure 2>/dev/null; } | grep -aiE 'Failed password|Invalid user' | grep -aoE 'from [0-9.]+' | awk '{print $2}' | sort | uniq -c | sort -rn | head -n 20",
                kind: .journal,
                byteCount: nil
            ),
            LogSource(
                title: String(localized: "🛡 SSH 成功登录"),
                detail: String(localized: "Accepted 记录"),
                command: "{ journalctl _COMM=sshd -n 2000 --no-pager 2>/dev/null || cat /var/log/auth.log 2>/dev/null || cat /var/log/secure 2>/dev/null; } | grep -ai 'Accepted' | tail -n 200",
                kind: .journal,
                byteCount: nil
            ),
            LogSource(
                title: String(localized: "🛡 近期登录历史 (last)"),
                detail: String(localized: "成功登录会话"),
                command: "last -n 80 2>/dev/null",
                kind: .journal,
                byteCount: nil
            ),
            LogSource(
                title: String(localized: "🛡 失败登录尝试 (lastb)"),
                detail: String(localized: "需要 root"),
                command: "sudo -n lastb -n 100 2>/dev/null || echo \(OpsShell.quote(String(localized: "需要 root 权限（passwordless sudo）才能查看 lastb。")))",
                kind: .journal,
                byteCount: nil
            ),
            LogSource(
                title: String(localized: "🛡 当前在线会话"),
                detail: "who / w",
                command: "echo '== who =='; who 2>/dev/null; echo; echo '== w =='; w 2>/dev/null",
                kind: .journal,
                byteCount: nil
            )
        ]
    }

    func tail(source: LogSource, config: SSHConnectionConfig, sshService: SSHService) async throws -> String {
        let result = try await sshService.executeCommand(source.command, on: config, maxResponseSize: 512 * 1024)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var discoveryCommand: String {
        // Emit stable ASCII title keys (localized in Swift by `localizedFileTitle`)
        // rather than baking Chinese into the shell output. Always `exit 0` so a
        // best-effort scan never surfaces as a hard command failure.
        """
        for item in \
          "syslog|/var/log/syslog" \
          "messages|/var/log/messages" \
          "authlog|/var/log/auth.log" \
          "nginx-error|/var/log/nginx/error.log" \
          "nginx-access|/var/log/nginx/access.log" \
          "caddy|/var/log/caddy/access.log"; do
          title="${item%%|*}"
          path="${item#*|}"
          if [ -r "$path" ]; then
            size="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
            printf 'LOG=file|%s|%s|%s\\n' "$title" "$path" "$size"
          fi
        done
        if command -v journalctl >/dev/null 2>&1; then
          printf 'LOG=journal|systemd Journal|journalctl -n 200 --no-pager|0\\n'
        fi
        if command -v docker >/dev/null 2>&1; then
          dprefix=""
          names="$(docker ps --format '{{.Names}}' 2>/dev/null)"
          if [ -z "$names" ]; then
            names="$(sudo -n docker ps --format '{{.Names}}' 2>/dev/null)"
            [ -n "$names" ] && dprefix="sudo -n "
          fi
          if [ -n "$names" ]; then
            printf '%s\\n' "$names" | head -n 12 | while read name; do
              [ -n "$name" ] && printf 'LOG=docker|Docker %s|%sdocker logs --tail 200 %s|0\\n' "$name" "$dprefix" "$name"
            done
          fi
        fi
        exit 0
        """
    }

    private func parseLogLine(_ line: String) -> LogSource? {
        guard line.hasPrefix("LOG=") else { return nil }
        let payload = line.replacingOccurrences(of: "LOG=", with: "")
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        let kind = LogSourceKind(rawValue: parts[0]) ?? .file
        let command: String
        let detail: String
        let title: String
        if kind == .file {
            detail = parts[2]
            command = "tail -n 200 \(OpsShell.quote(parts[2]))"
            title = localizedFileTitle(parts[1])
        } else {
            detail = parts[2]
            command = parts[2]
            title = parts[1]
        }
        return LogSource(
            title: title,
            detail: detail,
            command: command,
            kind: kind,
            byteCount: Int64(parts[3])
        )
    }

    /// Maps the discovery script's ASCII title keys to localized display titles.
    private func localizedFileTitle(_ key: String) -> String {
        switch key {
        case "syslog": return String(localized: "系统日志")
        case "messages": return String(localized: "消息日志")
        case "authlog": return String(localized: "认证日志")
        case "nginx-error": return String(localized: "Nginx 错误日志")
        case "nginx-access": return String(localized: "Nginx 访问日志")
        case "caddy": return String(localized: "Caddy 日志")
        default: return key
        }
    }
}

actor NginxManagerService {
    func collect(config: SSHConnectionConfig, sshService: SSHService) async throws -> NginxSnapshot {
        let result = try await sshService.executeCommand(nginxDiscoveryCommand, on: config, maxResponseSize: 256 * 1024)
        return parse(result.stdout)
    }

    nonisolated func testAndReloadPlan(profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        return RunbookPlan(
            kind: .nginx,
            title: String(localized: "测试并重载 Nginx"),
            summary: String(localized: "先执行 nginx -t，只有配置测试通过才 reload。"),
            targetDescription: "nginx",
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: String(localized: "不会直接修改配置。编辑保存配置时应先由编辑器创建备份。"),
            rollbackDescription: String(localized: "如果 reload 后异常，可恢复备份配置后重新执行 nginx -t 和 reload。"),
            steps: [
                RunbookStep(title: String(localized: "测试 Nginx 配置"), command: "\(sudo)nginx -t"),
                RunbookStep(title: String(localized: "重载 Nginx"), command: "\(sudo)systemctl reload nginx")
            ]
        )
    }

    /// Read-only syntax check (`nginx -t`) with no reload — lets users validate
    /// edits before committing to a reload.
    nonisolated func validatePlan(profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        return RunbookPlan(
            kind: .nginx,
            title: String(localized: "校验 Nginx 配置"),
            summary: String(localized: "仅执行 nginx -t 语法检查，不重载、不修改任何文件。"),
            targetDescription: "nginx",
            risk: .readOnly,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: nil,
            steps: [RunbookStep(title: String(localized: "测试 Nginx 配置"), command: "\(sudo)nginx -t")]
        )
    }

    /// Enable or disable a Debian/Ubuntu-style site by managing its sites-enabled
    /// symlink, validating with `nginx -t`, and reloading. On enable, a failed
    /// validation removes the just-created symlink so nginx stays reloadable.
    nonisolated func setSiteEnabledPlan(sitePath: String, enable: Bool, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let name = (sitePath as NSString).lastPathComponent
        let qTarget = OpsShell.quote(sitePath)
        let qLink = OpsShell.quote("/etc/nginx/sites-enabled/\(name)")
        let mRolledBack = OpsShell.quote(String(localized: "nginx -t 未通过，已撤销启用。"))
        let command: String
        if enable {
            command = """
            \(sudo)ln -sf \(qTarget) \(qLink)
            if \(sudo)nginx -t; then \(sudo)systemctl reload nginx; else \(sudo)rm -f \(qLink); echo \(mRolledBack); exit 1; fi
            """
        } else {
            command = """
            \(sudo)rm -f \(qLink)
            \(sudo)nginx -t && \(sudo)systemctl reload nginx
            """
        }
        return RunbookPlan(
            kind: .nginx,
            title: enable ? String(localized: "启用站点 \(name)") : String(localized: "停用站点 \(name)"),
            summary: enable
                ? String(localized: "软链到 sites-enabled 启用该站点，nginx -t 校验通过后 reload；校验不通过会自动撤销。")
                : String(localized: "删除 sites-enabled 里的软链停用该站点，再 nginx -t 并 reload。sites-available 里的配置文件保留。"),
            targetDescription: name,
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: enable
                ? String(localized: "删除 sites-enabled 里的同名软链即可停用。")
                : String(localized: "重新软链回 sites-enabled 即可再次启用。"),
            steps: [RunbookStep(title: enable ? String(localized: "启用并校验") : String(localized: "停用并校验"), command: command)]
        )
    }

    /// A minimal reverse-proxy server block template for creating a new site.
    nonisolated static func newSiteTemplate(serverName: String = "example.com", upstreamPort: Int = 3000) -> String {
        """
        server {
            listen 80;
            listen [::]:80;
            server_name \(serverName);

            # 反向代理到本机应用（按需修改端口/路径）
            location / {
                proxy_pass http://127.0.0.1:\(upstreamPort);
                proxy_http_version 1.1;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection "upgrade";
            }

            access_log /var/log/nginx/\(serverName).access.log;
            error_log  /var/log/nginx/\(serverName).error.log;
        }
        """
    }

    /// Generate a server block for the form-based site builder. `$var` tokens stay
    /// literal (they're written to the config, not expanded by the shell — see the
    /// quoted heredoc in `createSitePlan`).
    nonisolated static func siteConfig(domains: [String], type: NginxSiteType, upstreamPort: Int, staticRoot: String) -> String {
        let serverName = domains.joined(separator: " ")
        let primary = domains.first ?? "site"
        switch type {
        case .reverseProxy:
            return """
            server {
                listen 80;
                listen [::]:80;
                server_name \(serverName);

                location / {
                    proxy_pass http://127.0.0.1:\(upstreamPort);
                    proxy_http_version 1.1;
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header X-Forwarded-Proto $scheme;
                    proxy_set_header Upgrade $http_upgrade;
                    proxy_set_header Connection "upgrade";
                }

                access_log /var/log/nginx/\(primary).access.log;
                error_log  /var/log/nginx/\(primary).error.log;
            }
            """
        case .staticSite:
            return """
            server {
                listen 80;
                listen [::]:80;
                server_name \(serverName);

                root \(staticRoot);
                index index.html index.htm;

                location / {
                    try_files $uri $uri/ =404;
                }

                access_log /var/log/nginx/\(primary).access.log;
                error_log  /var/log/nginx/\(primary).error.log;
            }
            """
        }
    }

    /// Form-based site creation as one chained runbook: write config → (mkdir root)
    /// → enable → `nginx -t` (rolling back on failure) → reload → (optional) certbot.
    nonisolated func createSitePlan(domains: [String], type: NginxSiteType, upstreamPort: Int, staticRoot: String, createRoot: Bool, enable: Bool, requestSSL: Bool, email: String?, staging: Bool, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let primary = domains.first ?? "site"
        let confPath = "/etc/nginx/sites-available/\(primary).conf"
        let linkPath = "/etc/nginx/sites-enabled/\(primary).conf"
        let qConf = OpsShell.quote(confPath)
        let qLink = OpsShell.quote(linkPath)
        // certbot --nginx needs the server block loaded, so SSL implies enabling.
        let doEnable = enable || requestSSL
        let config = Self.siteConfig(domains: domains, type: type, upstreamPort: upstreamPort, staticRoot: staticRoot)
        let mOK = OpsShell.quote(String(localized: "站点已创建。"))
        let mRolledBack = OpsShell.quote(String(localized: "配置校验失败，已回滚，未改动 nginx。"))

        var lines: [String] = []
        lines.append("\(sudo)mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled")
        lines.append("\(sudo)tee \(qConf) >/dev/null <<'OPSDECK_NGINX_EOF'")
        lines.append(config)
        lines.append("OPSDECK_NGINX_EOF")
        if type == .staticSite && createRoot {
            lines.append("\(sudo)mkdir -p \(OpsShell.quote(staticRoot))")
        }
        if doEnable {
            lines.append("\(sudo)ln -sf \(qConf) \(qLink)")
        }
        let rollback = (doEnable ? "\(sudo)rm -f \(qLink); " : "") + "\(sudo)rm -f \(qConf)"
        let reload = doEnable ? "\(sudo)systemctl reload nginx && " : ""
        lines.append("if \(sudo)nginx -t; then \(reload)echo \(mOK); else \(rollback); echo \(mRolledBack); exit 1; fi")

        var steps = [RunbookStep(title: String(localized: "写入并校验站点配置"), command: lines.joined(separator: "\n"))]
        if requestSSL {
            let domainArgs = domains.map { "-d \(OpsShell.quote($0))" }.joined(separator: " ")
            let emailArg: String = {
                if let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty {
                    return "-m \(OpsShell.quote(email))"
                }
                return "--register-unsafely-without-email"
            }()
            let stagingArg = staging ? "--test-cert" : ""
            steps.append(RunbookStep(title: String(localized: "申请 SSL 证书"), command: "\(sudo)certbot --nginx \(domainArgs) --redirect --non-interactive --agree-tos \(emailArg) \(stagingArg) 2>&1"))
        }

        let typeSummary = type == .reverseProxy
            ? String(localized: "反向代理到 127.0.0.1:\(upstreamPort)")
            : String(localized: "静态站点，根目录 \(staticRoot)")
        return RunbookPlan(
            kind: .nginx,
            title: String(localized: "新建站点 \(primary)"),
            summary: String(localized: "为 \(domains.formatted(.list(type: .and, width: .narrow))) 创建 Nginx 站点（\(typeSummary)）。写入 sites-available，nginx -t 校验通过后启用并 reload；校验不通过自动回滚。\(requestSSL ? String(localized: "随后申请 SSL 证书（需域名已解析到本机、80 端口可达）。") : "")"),
            targetDescription: primary,
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "删除 \(confPath) 和 sites-enabled 里的同名软链即可移除。"),
            steps: steps
        )
    }

    private var nginxDiscoveryCommand: String {
        """
        if ! command -v nginx >/dev/null 2>&1; then
          printf 'INSTALLED=0\\n'
          exit 0
        fi
        printf 'INSTALLED=1\\n'
        printf 'VERSION=%s\\n' "$(nginx -v 2>&1)"
        conf=""
        for p in /etc/nginx/nginx.conf /usr/local/nginx/conf/nginx.conf /usr/local/etc/nginx/nginx.conf /opt/homebrew/etc/nginx/nginx.conf; do
          [ -f "$p" ] && { conf="$p"; break; }
        done
        [ -z "$conf" ] && conf="$(nginx -V 2>&1 | tr ' ' '\\n' | sed -n 's/^--conf-path=//p' | head -n1)"
        [ -z "$conf" ] && conf="$(nginx -t 2>&1 | sed -n 's/.*configuration file \\([^ ]*\\) .*/\\1/p' | head -n1)"
        [ -n "$conf" ] && printf 'CONFIG=%s\\n' "$conf"
        # Debian/Ubuntu: sites-available is the source of truth for ALL sites;
        # a site is "enabled" when a same-named entry exists in sites-enabled.
        if [ -d /etc/nginx/sites-available ]; then
          find /etc/nginx/sites-available -maxdepth 1 \\( -type f -o -type l \\) 2>/dev/null | while read path; do
            name="$(basename "$path")"
            en=0; [ -e "/etc/nginx/sites-enabled/$name" ] && en=1
            size="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
            modified="$(stat -c '%y' "$path" 2>/dev/null | cut -d'.' -f1)"
            printf 'SITE=%s|%s|%s|%s\\n' "$path" "$size" "$modified" "$en"
          done
        fi
        # Real files placed directly in sites-enabled (not symlinks into available).
        if [ -d /etc/nginx/sites-enabled ]; then
          find /etc/nginx/sites-enabled -maxdepth 1 -type f 2>/dev/null | while read path; do
            size="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
            modified="$(stat -c '%y' "$path" 2>/dev/null | cut -d'.' -f1)"
            printf 'SITE=%s|%s|%s|1\\n' "$path" "$size" "$modified"
          done
        fi
        # conf.d style (CentOS / setups without sites-available): always active.
        if [ -d /etc/nginx/conf.d ]; then
          find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf' 2>/dev/null | while read path; do
            size="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
            modified="$(stat -c '%y' "$path" 2>/dev/null | cut -d'.' -f1)"
            printf 'SITE=%s|%s|%s|1\\n' "$path" "$size" "$modified"
          done
        fi
        for path in /var/log/nginx/access.log /var/log/nginx/error.log; do
          [ -e "$path" ] && printf 'LOGPATH=%s\\n' "$path"
        done
        find /etc/letsencrypt/live -maxdepth 2 -name cert.pem 2>/dev/null | head -n 10 | while read cert; do
          printf 'CERT=%s\\n' "$cert"
        done
        """
    }

    private func parse(_ output: String) -> NginxSnapshot {
        var installed = false
        var version: String?
        var config: String?
        var sites: [NginxSiteConfig] = []
        var accessLog: String?
        var errorLog: String?
        var certs: [String] = []

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line == "INSTALLED=1" {
                installed = true
            } else if line.hasPrefix("VERSION=") {
                version = line.replacingOccurrences(of: "VERSION=", with: "")
            } else if line.hasPrefix("CONFIG=") {
                config = line.replacingOccurrences(of: "CONFIG=", with: "")
            } else if line.hasPrefix("SITE=") {
                let payload = line.replacingOccurrences(of: "SITE=", with: "")
                let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard let path = parts.first else { continue }
                // 4th field is the explicit enabled flag (1/0); fall back to path
                // heuristics for older payloads.
                let enabled: Bool
                if parts.count > 3 {
                    enabled = parts[3] == "1"
                } else {
                    enabled = path.contains("sites-enabled") || path.contains("conf.d")
                }
                sites.append(NginxSiteConfig(
                    path: path,
                    enabled: enabled,
                    byteCount: parts.count > 1 ? Int64(parts[1]) : nil,
                    modifiedAt: parts.count > 2 ? parts[2] : nil
                ))
            } else if line.hasPrefix("LOGPATH=") {
                let path = line.replacingOccurrences(of: "LOGPATH=", with: "")
                if path.contains("access") {
                    accessLog = path
                } else if path.contains("error") {
                    errorLog = path
                }
            } else if line.hasPrefix("CERT=") {
                certs.append(line.replacingOccurrences(of: "CERT=", with: ""))
            }
        }

        return NginxSnapshot(
            isInstalled: installed,
            version: version,
            configPath: config,
            sites: sites,
            accessLogPath: accessLog,
            errorLogPath: errorLog,
            certificateHints: certs
        )
    }
}

struct InstallerCatalogService {
    func catalog() -> [ToolDefinition] {
        [
            // 基础
            tool("git", "Git", .base, String(localized: "版本控制工具"), ["git"], packages: ["git"]),
            tool("curl", "curl", .base, String(localized: "HTTP 调试和下载工具"), ["curl"], packages: ["curl"]),
            tool("wget", "wget", .base, String(localized: "下载工具"), ["wget"], packages: ["wget"]),
            tool("unzip", "unzip", .base, String(localized: "解压 zip 文件"), ["unzip"], packages: ["unzip"]),
            tool("zip", "zip", .base, String(localized: "压缩 zip 文件"), ["zip"], packages: ["zip"]),
            tool("rsync", "rsync", .base, String(localized: "文件同步工具"), ["rsync"], packages: ["rsync"]),
            tool("jq", "jq", .base, String(localized: "JSON 命令行处理"), ["jq"], packages: ["jq"]),
            tool("tmux", "tmux", .base, String(localized: "终端复用工具"), ["tmux"], packages: ["tmux"]),
            tool("htop", "htop", .base, String(localized: "进程监控工具"), ["htop"], packages: ["htop"]),
            tool("tree", "tree", .base, String(localized: "目录树展示（可用于测试装卸载）"), ["tree"], packages: ["tree"]),
            tool("ncdu", "ncdu", .base, String(localized: "磁盘占用交互分析"), ["ncdu"], packages: ["ncdu"]),
            tool("lsof", "lsof", .base, String(localized: "查看进程打开的文件与端口"), ["lsof"], packages: ["lsof"]),
            tool("net-tools", "net-tools", .base, String(localized: "netstat/ifconfig 网络工具"), ["netstat", "ifconfig"], packages: ["net-tools"]),
            tool("dnsutils", String(localized: "dig / DNS 工具"), .base, String(localized: "dig/nslookup DNS 排查"), ["dig"], packages: ["dnsutils"],
                 overrides: [.dnf: ["bind-utils"], .yum: ["bind-utils"], .zypper: ["bind-utils"], .pacman: ["bind"], .apk: ["bind-tools"]]),
            tool("gnupg", "GnuPG", .base, String(localized: "加密与签名（gpg）"), ["gpg"], packages: ["gnupg"],
                 overrides: [.dnf: ["gnupg2"], .yum: ["gnupg2"], .zypper: ["gpg2"]]),
            tool("zsh", "Zsh", .base, String(localized: "Z Shell，常配 oh-my-zsh"), ["zsh"], packages: ["zsh"]),
            tool("vim", "Vim", .base, String(localized: "终端文本编辑器"), ["vim"], packages: ["vim"]),
            tool("nano", "nano", .base, String(localized: "轻量终端编辑器"), ["nano"], packages: ["nano"]),
            tool("ripgrep", "ripgrep", .base, String(localized: "极速代码搜索（rg）"), ["rg"], packages: ["ripgrep"]),
            tool("fzf", "fzf", .base, String(localized: "命令行模糊查找"), ["fzf"], packages: ["fzf"]),
            tool("cowsay", "cowsay", .base, String(localized: "趣味小工具（用于安全测试装卸载）"), ["cowsay"], packages: ["cowsay"]),
            tool("build-essential", String(localized: "编译工具链"), .base, String(localized: "gcc/make 等编译依赖"), ["gcc", "make", "cc"], packages: ["build-essential"],
                 overrides: [.dnf: ["gcc", "make"], .yum: ["gcc", "make"], .zypper: ["gcc", "make"], .pacman: ["base-devel"], .apk: ["build-base"]]),
            // Web
            tool("nginx", "Nginx", .web, String(localized: "Web 服务和反向代理"), ["nginx"], packages: ["nginx"], requirements: [.systemd]),
            tool("caddy", "Caddy", .web, String(localized: "自动 HTTPS Web 服务"), ["caddy"], packages: ["caddy"], requirements: [.systemd, .internet]),
            tool("certbot", "Certbot", .web, String(localized: "Let's Encrypt 证书工具"), ["certbot"], packages: ["certbot", "python3-certbot-nginx"],
                 overrides: [.pacman: ["certbot", "certbot-nginx"], .apk: ["certbot", "certbot-nginx"]], requirements: [.internet]),
            // 运行时
            tool("node", "Node.js", .runtime, String(localized: "JavaScript 运行时"), ["node", "nodejs"], packages: ["nodejs", "npm"]),
            tool("pnpm", "pnpm", .runtime, String(localized: "Node 项目包管理器"), ["pnpm"], packages: [], dependencies: ["node"], userLevelInstall: true, requirements: [.internet]),
            tool("yarn", "Yarn", .runtime, String(localized: "Node 项目包管理器"), ["yarn"], packages: [], dependencies: ["node"], userLevelInstall: true, requirements: [.internet]),
            tool("pm2", "PM2", .runtime, String(localized: "Node 进程管理器"), ["pm2"], packages: [], dependencies: ["node"], requirements: [.internet]),
            tool("python3", "Python 3", .runtime, String(localized: "Python 运行时与 pip"), ["python3"], packages: ["python3", "python3-pip"],
                 overrides: [.pacman: ["python", "python-pip"], .apk: ["python3", "py3-pip"]]),
            tool("uv", "Python uv", .runtime, String(localized: "Python 项目和包管理工具"), ["uv"], packages: [], userLevelInstall: true, requirements: [.internet]),
            tool("go", "Go", .runtime, String(localized: "Go 语言运行时与编译器"), ["go"], packages: ["golang-go"],
                 overrides: [.dnf: ["golang"], .yum: ["golang"], .zypper: ["go"], .pacman: ["go"], .apk: ["go"]]),
            // 容器
            tool("docker", "Docker", .container, String(localized: "容器运行时"), ["docker"], packages: ["docker.io", "docker-compose-plugin"], requirements: [.systemd, .arch64]),
            // 数据库
            tool("postgresql", "PostgreSQL", .database, String(localized: "关系数据库"), ["psql"], packages: ["postgresql"], requirements: [.systemd]),
            tool("mysql", "MySQL", .database, String(localized: "关系数据库"), ["mysql"], packages: ["mysql-server"], requirements: [.systemd]),
            tool("redis", "Redis", .database, String(localized: "缓存和键值数据库"), ["redis-server", "redis-cli"], packages: ["redis-server"], requirements: [.systemd]),
            // 安全
            tool("ufw", "UFW", .security, String(localized: "Ubuntu 防火墙工具"), ["ufw"], packages: ["ufw"]),
            tool("firewalld", "firewalld", .security, String(localized: "RHEL/Fedora 防火墙服务"), ["firewall-cmd"], packages: ["firewalld"], requirements: [.systemd]),
            tool("fail2ban", "Fail2ban", .security, String(localized: "登录暴力破解防护"), ["fail2ban-client"], packages: ["fail2ban"], requirements: [.systemd])
        ]
    }

    /// Core install steps for one tool (no dependency/service/verify wrapping).
    private func coreInstallSteps(for tool: ToolDefinition, profile: ServerProfileSnapshot?, sudo: String, policy: DownloadMirrorPolicy) -> [RunbookStep] {
        let manager = profile?.packageManager ?? .unknown
        let packages = tool.packagesByManager[manager] ?? []
        // A tool is package-manager based if it declares packages for any manager.
        // pnpm/yarn/pm2/uv declare none and are handled by runtimeSteps instead.
        let isPackageBased = tool.packagesByManager.values.contains { !$0.isEmpty }
        if tool.id == "docker", manager == .apt {
            return aptDockerInstallSteps(sudo: sudo)
        } else if tool.id == "caddy", manager == .apt {
            return aptCaddyInstallSteps(sudo: sudo, policy: policy)
        } else if tool.id == "caddy", manager == .dnf || (tool.id == "caddy" && manager == .yum) {
            return dnfCaddyInstallSteps(sudo: sudo)
        } else if !isPackageBased {
            return runtimeSteps(for: tool, sudo: sudo)
        } else if manager == .unknown || packages.isEmpty {
            // Package manager wasn't detected (no server profile / unresolved):
            // detect it on the remote host at run time instead of failing locally.
            return autoDetectInstallSteps(for: tool, sudo: sudo)
        } else {
            return packageInstallSteps(manager: manager, packages: packages, sudo: sudo)
        }
    }

    func installPlan(tool: ToolDefinition, profile: ServerProfileSnapshot?, policy: DownloadMirrorPolicy = .default) -> RunbookPlan {
        let manager = profile?.packageManager ?? .unknown
        let sudo = OpsShell.sudoPrefix(for: profile)
        var steps: [RunbookStep] = []
        // Install missing dependencies first (e.g. PM2/pnpm/yarn need Node.js, so
        // `npm install -g pm2` doesn't fail with `npm: command not found`). When no
        // profile is available we can't tell, so install the dependency to be safe.
        var installedDeps: [String] = []
        for depID in tool.dependencies {
            guard let dep = catalog().first(where: { $0.id == depID }) else { continue }
            if profile == nil || !dep.isInstalled(on: profile) {
                steps.append(contentsOf: coreInstallSteps(for: dep, profile: profile, sudo: sudo, policy: policy))
                installedDeps.append(dep.name)
            }
        }
        steps.append(contentsOf: coreInstallSteps(for: tool, profile: profile, sudo: sudo, policy: policy))
        if let serviceName = tool.managedServiceName {
            steps.append(RunbookStep(
                title: String(localized: "启动 \(tool.name) 服务"),
                command: serviceStartCommand(serviceName: serviceName, profile: profile, sudo: sudo)
            ))
        }
        let baseSummary = installedDeps.isEmpty
            ? String(localized: "根据服务器画像推荐 \(manager.displayName) 安装方式。")
            : String(localized: "\(tool.name) 依赖 \(installedDeps.formatted(.list(type: .and, width: .narrow)))，将先安装依赖再安装 \(tool.name)。")
        // Fold preflight (环境前置条件) findings into the summary so the user sees
        // blockers/warnings on the confirmation sheet before executing.
        let issues = preflight(for: tool, profile: profile)
        let blockers = issues.filter { $0.severity == .blocker }
        let warnings = issues.filter { $0.severity == .warning }
        let summary: String
        if !blockers.isEmpty {
            summary = String(localized: "⚠️ 环境可能不满足：") + blockers.map(\.title).joined(separator: "；") + String(localized: "。仍可尝试，但很可能失败。\n") + baseSummary
        } else if !warnings.isEmpty {
            summary = String(localized: "注意：") + warnings.map(\.title).joined(separator: "；") + "。\n" + baseSummary
        } else {
            summary = baseSummary
        }
        return RunbookPlan(
            kind: .install,
            title: String(localized: "安装 \(tool.name)"),
            summary: summary,
            targetDescription: tool.name,
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "可使用系统包管理器卸载，OpsDeck 不会自动清理业务数据。"),
            steps: steps + [RunbookStep(
                title: tool.managedServiceName == nil ? String(localized: "验证安装") : String(localized: "验证安装与服务"),
                command: verificationCommand(for: tool, profile: profile, sudo: sudo)
            )]
        )
    }

    /// Curated deployment recipes — bundles of installer-catalog tools the user
    /// reviews, checks/unchecks, then installs in one runbook. Items reference
    /// catalog tool ids, so the whole install pipeline (deps/preflight/skip-installed
    /// /source-fallback) is reused. oh-my-zsh + zsh plugins aren't catalog tools
    /// (custom installs) — the Shell recipe covers zsh + CLI; oh-my-zsh and the
    /// zsh plugins (autosuggestions/syntax-highlighting/autojump) are one-click in
    /// the「Shell / PATH」module (ShellPathService.installZshPluginsPlan).
    func deploymentRecipes() -> [DeploymentRecipe] {
        func item(_ id: String, _ recommended: Bool = true) -> RecipeItem { RecipeItem(toolID: id, recommended: recommended) }
        return [
            DeploymentRecipe(id: "web-ssl", title: String(localized: "Web 反代 + SSL"),
                summary: String(localized: "Nginx 反向代理 + Let's Encrypt 证书；Caddy 为可选替代。"),
                systemImage: "globe", items: [item("nginx"), item("certbot"), item("caddy", false)]),
            DeploymentRecipe(id: "node-stack", title: String(localized: "Node 服务栈"),
                summary: String(localized: "Node.js + PM2 进程守护 + Nginx 反代，适合小型 Node 服务。"),
                systemImage: "server.rack", items: [item("node"), item("pm2"), item("pnpm", false), item("nginx")]),
            DeploymentRecipe(id: "python-stack", title: String(localized: "Python 栈"),
                summary: String(localized: "Python 3 + uv（快速包/虚拟环境管理器）。"),
                systemImage: "chevron.left.forwardslash.chevron.right", items: [item("python3"), item("uv")]),
            DeploymentRecipe(id: "container", title: String(localized: "容器基础"),
                summary: String(localized: "Docker + Compose，容器化部署基础。"),
                systemImage: "shippingbox", items: [item("docker")]),
            DeploymentRecipe(id: "database", title: String(localized: "数据库"),
                summary: String(localized: "按需选择数据库（均为可选）。"),
                systemImage: "cylinder.split.1x2", items: [item("postgresql", false), item("mysql", false), item("redis", false)]),
            DeploymentRecipe(id: "shell", title: String(localized: "Shell 体验 + 常用 CLI"),
                summary: String(localized: "zsh + 高频命令行工具，登录更顺手。oh-my-zsh 与插件可在「Shell / PATH」模块一键安装。"),
                systemImage: "terminal", items: [item("zsh"), item("git"), item("fzf"), item("tmux"), item("ripgrep", false), item("htop", false), item("ncdu", false)]),
            DeploymentRecipe(id: "cli", title: String(localized: "常用 CLI 工具"),
                summary: String(localized: "运维高频命令行工具合集。"),
                systemImage: "wrench.and.screwdriver", items: [item("git"), item("curl"), item("wget"), item("vim"), item("htop"), item("tree"), item("jq"), item("tmux", false), item("rsync", false), item("unzip", false)])
        ]
    }

    /// Build ONE runbook installing `toolIDs` (+ their dependencies) in dependency
    /// order, skipping tools already present on the server. Reuses per-tool install
    /// steps + the download-source mirror policy.
    func deployPlan(toolIDs: [String], profile: ServerProfileSnapshot?, policy: DownloadMirrorPolicy = .default) -> RunbookPlan {
        let byID = Dictionary(uniqueKeysWithValues: catalog().map { ($0.id, $0) })
        let sudo = OpsShell.sudoPrefix(for: profile)

        // Deps before dependents, deduped, skip already-installed.
        var ordered: [ToolDefinition] = []
        var seen = Set<String>()
        func visit(_ tool: ToolDefinition) {
            guard !seen.contains(tool.id) else { return }
            seen.insert(tool.id)
            for depID in tool.dependencies {
                if let dep = byID[depID] { visit(dep) }
            }
            if profile == nil || !tool.isInstalled(on: profile) {
                ordered.append(tool)
            }
        }
        toolIDs.compactMap { byID[$0] }.forEach { visit($0) }

        var steps: [RunbookStep] = []
        for tool in ordered {
            steps.append(RunbookStep(title: String(localized: "▸ 安装 \(tool.name)"),
                                     command: "echo \(OpsShell.quote(String(localized: "开始安装 \(tool.name)")))"))
            steps.append(contentsOf: coreInstallSteps(for: tool, profile: profile, sudo: sudo, policy: policy))
            if let serviceName = tool.managedServiceName {
                steps.append(RunbookStep(title: String(localized: "启动 \(tool.name) 服务"),
                                         command: serviceStartCommand(serviceName: serviceName, profile: profile, sudo: sudo)))
            }
        }
        if steps.isEmpty {
            steps = [RunbookStep(title: String(localized: "无需安装"), command: "echo \(OpsShell.quote(String(localized: "所选工具均已安装。"))); exit 0")]
        }

        func uniqueTitles(_ issues: [PreflightIssue]) -> [String] {
            var s = Set<String>()
            return issues.map(\.title).filter { s.insert($0).inserted }
        }
        let allIssues = ordered.flatMap { preflight(for: $0, profile: profile) }
        let blockers = uniqueTitles(allIssues.filter { $0.severity == .blocker })
        let warnings = uniqueTitles(allIssues.filter { $0.severity == .warning })
        let names = ordered.map(\.name).formatted(.list(type: .and, width: .narrow))
        var summary = ordered.isEmpty
            ? String(localized: "所选工具均已安装，无需部署。")
            : String(localized: "将按依赖顺序安装：\(names)。已安装的会自动跳过。")
        if !blockers.isEmpty {
            summary = String(localized: "⚠️ 环境可能不满足：") + blockers.joined(separator: "；") + "。\n" + summary
        } else if !warnings.isEmpty {
            summary = String(localized: "注意：") + warnings.joined(separator: "；") + "。\n" + summary
        }

        return RunbookPlan(
            kind: .install,
            title: ordered.isEmpty ? String(localized: "无需部署") : String(localized: "部署 \(ordered.count) 项"),
            summary: summary,
            targetDescription: names.isEmpty ? String(localized: "所选工具") : names,
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "可在安装器/各模块单独卸载，OpsDeck 不会自动清理业务数据。"),
            steps: steps
        )
    }

    /// Evaluate install-time environment conditions against the server profile.
    /// Blockers = install will almost certainly fail; warnings = may fail / degrade;
    /// info = heads-up. Dependencies are handled separately (auto-installed).
    func preflight(for tool: ToolDefinition, profile: ServerProfileSnapshot?) -> [PreflightIssue] {
        guard let profile else { return [] } // no profile yet → runtime auto-detect handles it
        var issues: [PreflightIssue] = []

        // Root / sudo — most installs need it; user-level tools (uv/pnpm/yarn) don't.
        if !tool.userLevelInstall {
            switch profile.sudoStatus {
            case .unavailable:
                issues.append(PreflightIssue(severity: .blocker, title: String(localized: "需要 root/sudo 权限"),
                    detail: String(localized: "安装 \(tool.name) 需要管理员权限，但当前账号（\(profile.username ?? "?")）没有可用的 sudo。请改用 root 账号连接，或让管理员为该账号配置 sudo。")))
            case .requiresPassword:
                issues.append(PreflightIssue(severity: .warning, title: String(localized: "sudo 需要密码"),
                    detail: String(localized: "OpsDeck 以 sudo -n（免密）执行命令，而当前账号的 sudo 需要密码，安装可能中途失败。建议为该账号配置免密 sudo，或改用 root 连接。")))
            case .root, .passwordless, .unknown:
                break
            }
        }

        // systemd — service tools enable/autostart through systemctl.
        if tool.requirements.contains(.systemd), profile.initSystem != .systemd, profile.initSystem != .unknown {
            issues.append(PreflightIssue(severity: .warning, title: String(localized: "非 systemd 环境"),
                detail: String(localized: "\(tool.name) 是服务型工具，当前 init 系统是 \(profile.initSystem.displayName)。OpsDeck 会尝试 openrc/service 兜底启停，但开机自启和运行状态检测可能不准。")))
        }

        // 64-bit CPU — e.g. Docker.
        if tool.requirements.contains(.arch64), let arch = profile.architecture, Self.is32Bit(arch) {
            issues.append(PreflightIssue(severity: .blocker, title: String(localized: "需要 64 位系统"),
                detail: String(localized: "\(tool.name) 不支持 32 位架构（当前 \(arch)）。")))
        }

        // Package manager unrecognized (only matters for package-based tools).
        if !tool.userLevelInstall, profile.packageManager == .unknown,
           tool.packagesByManager.values.contains(where: { !$0.isEmpty }) {
            issues.append(PreflightIssue(severity: .warning, title: String(localized: "未识别包管理器"),
                detail: String(localized: "没能识别服务器的包管理器，OpsDeck 会在远端探测 apt/dnf/yum/pacman 等再安装；若探测失败会报错。")))
        }

        // Internet reach — script / registry installs.
        if tool.requirements.contains(.internet) {
            issues.append(PreflightIssue(severity: .info, title: String(localized: "需要外网访问"),
                detail: String(localized: "\(tool.name) 安装会从外网拉取（安装脚本或包 registry）。若服务器不能直连外网，请先配置代理或换用国内镜像。")))
        }

        return issues
    }

    private static func is32Bit(_ arch: String) -> Bool {
        let a = arch.lowercased()
        if a.contains("64") { return false } // x86_64 / aarch64 / arm64 / ppc64
        return a.contains("i386") || a.contains("i686") || a.contains("armv7") || a.contains("armv6") || a.contains("armhf") || a == "arm"
    }

    /// Generate an uninstall plan. Uses the package manager's `remove` (not
    /// purge) so configuration files are preserved and the action stays
    /// reversible. Callers must gate this on `tool.uninstallPolicy.isAllowed`.
    func uninstallPlan(tool: ToolDefinition, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let manager = profile?.packageManager ?? .unknown
        let packages = tool.packagesByManager[manager] ?? []
        let sudo = OpsShell.sudoPrefix(for: profile)
        let isPackageBased = tool.packagesByManager.values.contains { !$0.isEmpty }
        var steps: [RunbookStep]
        if !isPackageBased {
            steps = runtimeUninstallSteps(for: tool, sudo: sudo)
        } else if manager == .unknown || packages.isEmpty {
            steps = autoDetectUninstallSteps(for: tool, sudo: sudo)
        } else {
            steps = packageUninstallSteps(manager: manager, packages: packages, sudo: sudo)
        }
        steps.append(RunbookStep(title: String(localized: "验证卸载"), command: uninstallVerificationCommand(for: tool)))
        return RunbookPlan(
            kind: .install,
            title: String(localized: "卸载 \(tool.name)"),
            summary: String(localized: "使用 \(manager.displayName) 的 remove 卸载（保留配置文件，不清理数据）。"),
            targetDescription: tool.name,
            risk: .high,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "如需恢复，可在工具页重新生成安装计划。"),
            steps: steps
        )
    }

    private func packageUninstallSteps(manager: ServerPackageManager, packages: [String], sudo: String) -> [RunbookStep] {
        let packageText = packages.map(OpsShell.quote).joined(separator: " ")
        switch manager {
        case .apt:
            // Remove only packages actually installed — a tool's package list may
            // include ones that were never installed (e.g. docker-compose-plugin
            // isn't in Ubuntu's repos, python3-pip may be absent), and a plain
            // `apt-get remove pkgA pkgB` aborts entirely if any is missing.
            let command = """
            for p in \(packageText); do
              if dpkg -s "$p" >/dev/null 2>&1; then
                \(OpsShell.unattendedAptGet(sudo: sudo)) remove -y "$p"
              else
                echo \(OpsShell.quote(String(localized: "跳过未安装的包：")))"$p"
              fi
            done
            """
            return [RunbookStep(title: String(localized: "卸载软件包"), command: command)]
        case .dnf:
            return [RunbookStep(title: String(localized: "卸载软件包"), command: "\(sudo)dnf remove -y \(packageText)")]
        case .yum:
            return [RunbookStep(title: String(localized: "卸载软件包"), command: "\(sudo)yum remove -y \(packageText)")]
        case .pacman:
            return [RunbookStep(title: String(localized: "卸载软件包"), command: "\(sudo)pacman -Rs --noconfirm \(packageText)")]
        case .zypper:
            return [RunbookStep(title: String(localized: "卸载软件包"), command: "\(sudo)zypper --non-interactive remove \(packageText)")]
        case .apk:
            return [RunbookStep(title: String(localized: "卸载软件包"), command: "\(sudo)apk del \(packageText)")]
        case .unknown:
            return [RunbookStep(title: String(localized: "无法自动卸载"), command: "echo \(OpsShell.quote(String(localized: "未识别包管理器，请手动卸载。"))); exit 1")]
        }
    }

    private func runtimeUninstallSteps(for tool: ToolDefinition, sudo: String) -> [RunbookStep] {
        switch tool.id {
        case "pnpm":
            return [RunbookStep(title: String(localized: "移除 pnpm"), command: "corepack disable pnpm 2>/dev/null || \(sudo)npm rm -g pnpm")]
        case "yarn":
            return [RunbookStep(title: String(localized: "移除 Yarn"), command: "corepack disable yarn 2>/dev/null || \(sudo)npm rm -g yarn")]
        case "pm2":
            return [RunbookStep(title: String(localized: "卸载 PM2"), command: "\(sudo)npm rm -g pm2")]
        case "uv":
            return [RunbookStep(title: String(localized: "卸载 uv"), command: "python3 -m pip uninstall -y uv 2>/dev/null || rm -f \"$HOME/.local/bin/uv\" \"$HOME/.cargo/bin/uv\"")]
        default:
            return [RunbookStep(title: String(localized: "无法自动卸载"), command: "echo \(OpsShell.quote(String(localized: "此工具暂无适配卸载方式。"))); exit 1")]
        }
    }

    private func autoDetectUninstallSteps(for tool: ToolDefinition, sudo: String) -> [RunbookStep] {
        func packageText(_ manager: ServerPackageManager) -> String {
            (tool.packagesByManager[manager] ?? []).map(OpsShell.quote).joined(separator: " ")
        }
        let command = """
        if command -v apt-get >/dev/null 2>&1; then
          \(OpsShell.unattendedAptGet(sudo: sudo)) remove -y \(packageText(.apt))
        elif command -v dnf >/dev/null 2>&1; then
          \(sudo)dnf remove -y \(packageText(.dnf))
        elif command -v yum >/dev/null 2>&1; then
          \(sudo)yum remove -y \(packageText(.yum))
        elif command -v pacman >/dev/null 2>&1; then
          \(sudo)pacman -Rs --noconfirm \(packageText(.pacman))
        elif command -v zypper >/dev/null 2>&1; then
          \(sudo)zypper --non-interactive remove \(packageText(.zypper))
        elif command -v apk >/dev/null 2>&1; then
          \(sudo)apk del \(packageText(.apk))
        else
          echo \(OpsShell.quote(String(localized: "未识别包管理器，请手动卸载。")))
          exit 1
        fi
        """
        return [RunbookStep(title: String(localized: "自动检测包管理器并卸载"), command: command)]
    }

    private func uninstallVerificationCommand(for tool: ToolDefinition) -> String {
        let checks = tool.binaryNames
            .map { "command -v \(OpsShell.quote($0)) >/dev/null 2>&1" }
            .joined(separator: " || ")
        return "if \(checks); then echo \(OpsShell.quote(String(localized: "仍检测到 \(tool.name)，卸载可能未完成"))); exit 1; else echo \(OpsShell.quote(String(localized: "\(tool.name) 已卸载"))); fi"
    }

    private func tool(
        _ id: String,
        _ name: String,
        _ category: ToolCategory,
        _ description: String,
        _ binaries: [String],
        packages: [String],
        overrides: [ServerPackageManager: [String]] = [:],
        dependencies: [String] = [],
        userLevelInstall: Bool = false,
        requirements: [ToolRequirement] = []
    ) -> ToolDefinition {
        var map: [ServerPackageManager: [String]] = [
            .apt: packages,
            .dnf: packages.map { $0 == "docker.io" ? "docker" : $0 },
            .yum: packages.map { $0 == "docker.io" ? "docker" : $0 },
            .pacman: packages.map { $0 == "redis-server" ? "redis" : $0 },
            .zypper: packages,
            .apk: packages.map { $0 == "docker.io" ? "docker" : $0 }
        ]
        for (manager, pkgs) in overrides {
            map[manager] = pkgs
        }
        return ToolDefinition(
            id: id,
            name: name,
            category: category,
            description: description,
            binaryNames: binaries,
            packagesByManager: map,
            dependencies: dependencies,
            userLevelInstall: userLevelInstall,
            requirements: requirements
        )
    }

    private func packageInstallSteps(manager: ServerPackageManager, packages: [String], sudo: String) -> [RunbookStep] {
        let packageText = packages.map(OpsShell.quote).joined(separator: " ")
        switch manager {
        case .apt:
            return [
                RunbookStep(title: String(localized: "更新 apt 索引"), command: "\(OpsShell.unattendedAptGet(sudo: sudo)) update"),
                RunbookStep(title: String(localized: "安装软件包"), command: OpsShell.unattendedAptInstall(packages: packages, sudo: sudo))
            ]
        case .dnf:
            return [RunbookStep(title: String(localized: "安装软件包"), command: "\(sudo)dnf install -y \(packageText)")]
        case .yum:
            return [RunbookStep(title: String(localized: "安装软件包"), command: "\(sudo)yum install -y \(packageText)")]
        case .pacman:
            return [RunbookStep(title: String(localized: "安装软件包"), command: "\(sudo)pacman -Sy --noconfirm \(packageText)")]
        case .zypper:
            return [RunbookStep(title: String(localized: "安装软件包"), command: "\(sudo)zypper --non-interactive install \(packageText)")]
        case .apk:
            return [RunbookStep(title: String(localized: "安装软件包"), command: "\(sudo)apk add \(packageText)")]
        case .unknown:
            return [RunbookStep(title: String(localized: "无法自动安装"), command: "echo \(OpsShell.quote(String(localized: "未识别包管理器，请手动安装。"))); exit 1")]
        }
    }

    private func aptComposeBlock(sudo: String) -> String {
        """
        if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
          \(OpsShell.unattendedAptGet(sudo: sudo)) install -y docker-compose-v2
        elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
          \(OpsShell.unattendedAptGet(sudo: sudo)) install -y docker-compose-plugin
        elif apt-cache show docker-compose >/dev/null 2>&1; then
          \(OpsShell.unattendedAptGet(sudo: sudo)) install -y docker-compose
        else
          echo \(OpsShell.quote(String(localized: "未发现可用的 Docker Compose 软件包，已跳过 Compose。")))
        fi
        """
    }

    private func aptDockerInstallSteps(sudo: String) -> [RunbookStep] {
        return [
            RunbookStep(title: String(localized: "更新 apt 索引"), command: "\(OpsShell.unattendedAptGet(sudo: sudo)) update"),
            RunbookStep(title: String(localized: "安装 Docker"), command: OpsShell.unattendedAptInstall(packages: ["docker.io"], sudo: sudo)),
            RunbookStep(title: String(localized: "安装 Docker Compose"), command: aptComposeBlock(sudo: sudo))
        ]
    }

    /// Caddy isn't in Debian/Ubuntu's default repos. Two install methods, ordered
    /// by the download-source policy:
    ///  - official: the maintainer's Cloudsmith apt repo (clean, systemd-managed)
    ///    — but `dl.cloudsmith.io` is often unreachable from mainland China.
    ///  - mirror: fetch the prebuilt static binary from GitHub via a proxy and
    ///    lay down a systemd unit ourselves — works where Cloudsmith is blocked.
    /// `.mirrorOnly` drops the official method entirely (no wasted timeout), so
    /// its script contains no cloudsmith URL at all.
    private func aptCaddyInstallSteps(sudo: String, policy: DownloadMirrorPolicy) -> [RunbookStep] {
        // Short curl timeouts so a blocked network fails fast, not after minutes.
        let curlOpts = "--connect-timeout 12 --max-time 90 -fsSL"
        // GitHub proxy for the mirror binary. This is the one tunable knob if the
        // proxy host rots — swap it for another (gh-proxy.com / ghproxy.net / …).
        let ghProxy = "https://ghfast.top/"

        let mInstalled = OpsShell.quote(String(localized: "Caddy 已安装。"))
        let mOfficial = OpsShell.quote(String(localized: "=== 尝试官方源（Cloudsmith apt）==="))
        let mMirror = OpsShell.quote(String(localized: "=== 尝试镜像（GitHub 代理二进制 + systemd）==="))
        let mDone = OpsShell.quote(String(localized: "Caddy 安装完成。"))
        let mFailed = OpsShell.quote(policy == .mirrorOnly
            ? String(localized: "Caddy 安装失败：镜像不可达（按设置未尝试官方源），可能需要代理。")
            : String(localized: "Caddy 安装失败：官方源与镜像均不可达，可能需要代理或换源。"))

        let officialFunc = """
        caddy_official() {
          \(OpsShell.unattendedAptInstall(packages: ["debian-keyring", "debian-archive-keyring", "apt-transport-https", "curl", "gnupg"], sudo: sudo)) || return 1
          curl \(curlOpts) 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \(sudo)gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg || return 1
          curl \(curlOpts) 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \(sudo)tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null || return 1
          \(OpsShell.unattendedAptGet(sudo: sudo)) update -o Acquire::Retries=1 -o Acquire::http::Timeout=20 || return 1
          \(OpsShell.unattendedAptInstall(packages: ["caddy"], sudo: sudo)) || return 1
        }
        """

        let mirrorFunc = """
        caddy_mirror() {
          arch=$(uname -m); case "$arch" in x86_64|amd64) a=amd64;; aarch64|arm64) a=arm64;; armv7l|armv7) a=armv7;; *) a=amd64;; esac
          ver=$(curl \(curlOpts) "\(ghProxy)https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name": *"v\\([^"]*\\)".*/\\1/p' | head -1)
          [ -z "$ver" ] && ver=2.8.4
          url="\(ghProxy)https://github.com/caddyserver/caddy/releases/download/v${ver}/caddy_${ver}_linux_${a}.tar.gz"
          curl \(curlOpts) "$url" -o /tmp/opsdeck-caddy.tgz 2>/dev/null || wget -qO /tmp/opsdeck-caddy.tgz "$url" || return 1
          tar -xzf /tmp/opsdeck-caddy.tgz -C /tmp caddy || return 1
          \(sudo)install -m 0755 /tmp/caddy /usr/bin/caddy || return 1
          \(sudo)groupadd --system caddy 2>/dev/null || true
          \(sudo)useradd --system --gid caddy --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null || true
          \(sudo)mkdir -p /etc/caddy /var/lib/caddy
          [ -f /etc/caddy/Caddyfile ] || printf ':80 {\\n\\trespond "Caddy OK"\\n}\\n' | \(sudo)tee /etc/caddy/Caddyfile >/dev/null
          printf '%s\\n' '[Unit]' 'Description=Caddy' 'After=network.target' '' '[Service]' 'User=caddy' 'Group=caddy' 'ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile' 'ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile' 'Restart=on-failure' 'LimitNOFILE=1048576' '' '[Install]' 'WantedBy=multi-user.target' | \(sudo)tee /etc/systemd/system/caddy.service >/dev/null || return 1
          \(sudo)systemctl daemon-reload || return 1
        }
        """

        // Emit ONLY the methods the policy uses (mirrorOnly → no cloudsmith text),
        // and attempt them in order, skipping once caddy is present.
        var funcs = ""
        var attempts = ""
        for method in policy.order(official: "official", mirror: "mirror") {
            if method == "official" {
                funcs += officialFunc + "\n\n"
                attempts += "if ! command -v caddy >/dev/null 2>&1; then echo \(mOfficial); caddy_official || true; fi\n"
            } else {
                funcs += mirrorFunc + "\n\n"
                attempts += "if ! command -v caddy >/dev/null 2>&1; then echo \(mMirror); caddy_mirror || true; fi\n"
            }
        }

        let command = """
        if command -v caddy >/dev/null 2>&1; then echo \(mInstalled); exit 0; fi

        \(funcs)\(attempts)
        if command -v caddy >/dev/null 2>&1; then echo \(mDone); else echo \(mFailed); exit 1; fi
        """
        return [RunbookStep(title: String(localized: "安装 Caddy（带源兜底）"), command: command)]
    }

    /// Caddy on Fedora/RHEL comes from the maintainer's COPR repo.
    private func dnfCaddyInstallSteps(sudo: String) -> [RunbookStep] {
        return [
            RunbookStep(title: String(localized: "启用 COPR 支持"), command: "\(sudo)dnf install -y 'dnf-command(copr)'"),
            RunbookStep(title: String(localized: "启用 Caddy COPR"), command: "\(sudo)dnf copr enable -y @caddy/caddy"),
            RunbookStep(title: String(localized: "安装 Caddy"), command: "\(sudo)dnf install -y caddy")
        ]
    }

    /// Emitted when the server profile did not resolve a package manager.
    /// Detects apt/dnf/yum/pacman/zypper/apk on the remote host and installs
    /// this tool's packages for whichever one is present.
    private func autoDetectInstallSteps(for tool: ToolDefinition, sudo: String) -> [RunbookStep] {
        func packageText(_ manager: ServerPackageManager) -> String {
            (tool.packagesByManager[manager] ?? []).map(OpsShell.quote).joined(separator: " ")
        }
        // Docker on apt needs docker.io + a Compose package; other managers ship
        // a single "docker" package, so the generic branches cover them.
        let aptBody: String
        let aptPackages = tool.packagesByManager[.apt] ?? []
        let aptInstall = OpsShell.unattendedAptInstall(packages: aptPackages, sudo: sudo)
            .split(separator: "\n")
            .map { "  " + $0 }
            .joined(separator: "\n")
        if tool.id == "docker" {
            aptBody = """
              \(OpsShell.unattendedAptGet(sudo: sudo)) update || exit $?
            \(aptInstall) || exit $?
            \(aptComposeBlock(sudo: sudo).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
            """
        } else {
            aptBody = """
              \(OpsShell.unattendedAptGet(sudo: sudo)) update || exit $?
            \(aptInstall) || exit $?
            """
        }
        let command = """
        if command -v apt-get >/dev/null 2>&1; then
        \(aptBody)
        elif command -v dnf >/dev/null 2>&1; then
          \(sudo)dnf install -y \(packageText(.dnf))
        elif command -v yum >/dev/null 2>&1; then
          \(sudo)yum install -y \(packageText(.yum))
        elif command -v pacman >/dev/null 2>&1; then
          \(sudo)pacman -Sy --noconfirm \(packageText(.pacman))
        elif command -v zypper >/dev/null 2>&1; then
          \(sudo)zypper --non-interactive install \(packageText(.zypper))
        elif command -v apk >/dev/null 2>&1; then
          \(sudo)apk add \(packageText(.apk))
        else
          echo \(OpsShell.quote(String(localized: "未识别包管理器，请手动安装。")))
          exit 1
        fi
        """
        return [RunbookStep(title: String(localized: "自动检测包管理器并安装"), command: command)]
    }

    private func runtimeSteps(for tool: ToolDefinition, sudo: String) -> [RunbookStep] {
        switch tool.id {
        case "pnpm":
            return [RunbookStep(title: String(localized: "启用 pnpm"), command: "corepack enable && corepack prepare pnpm@latest --activate")]
        case "yarn":
            return [RunbookStep(title: String(localized: "启用 Yarn"), command: "corepack enable && corepack prepare yarn@stable --activate")]
        case "pm2":
            return [RunbookStep(title: String(localized: "安装 PM2"), command: "\(sudo)npm install -g pm2")]
        case "uv":
            // Ubuntu 24.04 ships python3 without pip, so prefer uv's official
            // installer (lands in ~/.local/bin); fall back to pip if present.
            return [RunbookStep(title: String(localized: "安装 uv"), command: "curl -LsSf https://astral.sh/uv/install.sh | sh || wget -qO- https://astral.sh/uv/install.sh | sh || python3 -m pip install --user uv")]
        default:
            return [RunbookStep(title: String(localized: "无法自动安装"), command: "echo \(OpsShell.quote(String(localized: "此工具暂无适配安装方式。"))); exit 1")]
        }
    }

    private func verificationCommand(
        for tool: ToolDefinition,
        profile: ServerProfileSnapshot?,
        sudo: String
    ) -> String {
        if tool.id == "docker" {
            return "docker --version && \(sudo)docker info --format 'Docker Server {{.ServerVersion}}'"
        }
        // Include user-bin dirs so tools like uv (~/.local/bin) verify even
        // before the user adds them to their shell PATH.
        let pathPrefix = "export PATH=\"$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$PATH\"; "
        let binaryCheck = pathPrefix + tool.binaryNames
            .map { "command -v \(OpsShell.quote($0))" }
            .joined(separator: " || ")
        guard let serviceName = tool.managedServiceName else {
            return binaryCheck
        }
        return """
        \(binaryCheck)
        opsdeck_binary_rc=$?
        if [ "$opsdeck_binary_rc" -ne 0 ]; then exit "$opsdeck_binary_rc"; fi
        \(serviceVerificationCommand(serviceName: serviceName, profile: profile, sudo: sudo))
        """
    }

    private func serviceStartCommand(
        serviceName: String,
        profile: ServerProfileSnapshot?,
        sudo: String
    ) -> String {
        let service = OpsShell.quote(serviceName)
        switch profile?.initSystem {
        case .systemd:
            return OpsShell.systemdEnableAndStart(serviceName: serviceName, sudo: sudo)
        case .openrc:
            return "\(sudo)rc-update add \(service) default && \(sudo)rc-service \(service) start"
        case .service:
            return "\(sudo)service \(service) start"
        case .unknown, nil:
            return """
            if command -v systemctl >/dev/null 2>&1; then
              \(OpsShell.systemdEnableAndStart(serviceName: serviceName, sudo: sudo))
            elif command -v rc-service >/dev/null 2>&1; then
              \(sudo)rc-update add \(service) default && \(sudo)rc-service \(service) start
            elif command -v service >/dev/null 2>&1; then
              \(sudo)service \(service) start
            else
              echo \(OpsShell.quote(String(localized: "未识别服务管理器，无法自动启动 \(serviceName)。")))
              exit 1
            fi
            """
        }
    }

    private func serviceVerificationCommand(
        serviceName: String,
        profile: ServerProfileSnapshot?,
        sudo: String
    ) -> String {
        let service = OpsShell.quote(serviceName)
        switch profile?.initSystem {
        case .systemd:
            return OpsShell.systemdActiveVerification(serviceName: serviceName, sudo: sudo)
        case .openrc:
            return "rc-service \(service) status"
        case .service:
            return "service \(service) status"
        case .unknown, nil:
            return """
            if command -v systemctl >/dev/null 2>&1; then
              \(OpsShell.systemdActiveVerification(serviceName: serviceName, sudo: sudo))
            elif command -v rc-service >/dev/null 2>&1; then
              rc-service \(service) status
            elif command -v service >/dev/null 2>&1; then
              service \(service) status
            else
              echo \(OpsShell.quote(String(localized: "未识别服务管理器，无法验证 \(serviceName) 运行状态。")))
              exit 1
            fi
            """
        }
    }
}

actor DockerManagerService {
    func collect(config: SSHConnectionConfig, sshService: SSHService) async throws -> DockerSnapshot {
        let command = """
        if ! command -v docker >/dev/null 2>&1; then
          printf 'DOCKER_STATE=missing\\n'
          exit 0
        fi
        printf 'DOCKER_STATE=installed\\n'
        printf 'DOCKER_VERSION=%s\\n' "$(docker --version 2>/dev/null | head -n 1)"
        DK=docker
        output="$(docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>&1)"
        status=$?
        if [ "$status" -ne 0 ]; then
          # Non-root users aren't in the docker group by default, so the socket
          # is permission-denied even when the daemon is running. Retry via sudo.
          sudo_output="$(sudo -n docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>&1)"
          if [ $? -eq 0 ]; then
            output="$sudo_output"; status=0; DK="sudo -n docker"
            printf 'DOCKER_NEEDS_SUDO=1\\n'
          fi
        fi
        if [ "$status" -eq 0 ]; then
          printf 'DOCKER_DAEMON=reachable\\n'
          [ -n "$output" ] && printf '%s\\n' "$output"
          $DK images --format 'IMAGE={{.ID}}|{{.Repository}}|{{.Tag}}|{{.Size}}' 2>/dev/null | head -n 100
        else
          printf 'DOCKER_DAEMON=unreachable\\n'
          printf 'DOCKER_ERROR=%s\\n' "$(printf '%s' "$output" | tail -n 2 | tr '\\n' ' ')"
        fi
        exit 0
        """
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 128 * 1024)
        var isInstalled = false
        var daemonReachable = false
        var clientVersion: String?
        var daemonError: String?
        var containers: [DockerContainerSummary] = []
        var images: [DockerImageSummary] = []
        for rawLine in result.stdout.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line == "DOCKER_STATE=installed" {
                isInstalled = true
            } else if line == "DOCKER_DAEMON=reachable" {
                daemonReachable = true
            } else if line.hasPrefix("DOCKER_VERSION=") {
                clientVersion = String(line.dropFirst("DOCKER_VERSION=".count))
            } else if line.hasPrefix("DOCKER_ERROR=") {
                daemonError = String(line.dropFirst("DOCKER_ERROR=".count))
            } else if line.hasPrefix("IMAGE=") {
                let parts = String(line.dropFirst("IMAGE=".count)).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 4 else { continue }
                images.append(DockerImageSummary(id: parts[0], repository: parts[1], tag: parts[2], size: parts[3]))
            } else {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 5 else { continue }
                containers.append(
                    DockerContainerSummary(id: parts[0], name: parts[1], image: parts[2], status: parts[3], ports: parts[4])
                )
            }
        }
        return DockerSnapshot(
            isInstalled: isInstalled,
            daemonReachable: daemonReachable,
            clientVersion: clientVersion,
            daemonError: daemonError,
            containers: containers,
            images: images
        )
    }

    nonisolated func plan(action: ServiceAction, container: DockerContainerSummary) -> RunbookPlan {
        let dockerAction: String
        switch action {
        case .start:
            dockerAction = "start"
        case .stop:
            dockerAction = "stop"
        case .restart, .reload:
            dockerAction = "restart"
        case .enable, .disable:
            dockerAction = "ps"
        }
        return RunbookPlan(
            kind: .docker,
            title: String(localized: "\(action.displayName)容器 \(container.name)"),
            summary: String(localized: "通过 Docker CLI 操作单个容器。"),
            targetDescription: container.name,
            risk: dockerAction == "stop" || dockerAction == "restart" ? .high : .medium,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "可执行相反容器动作恢复。"),
            steps: [
                RunbookStep(title: String(localized: "\(action.displayName)容器"), command: "docker \(dockerAction) \(OpsShell.quote(container.name))"),
                RunbookStep(title: String(localized: "查看容器状态"), command: "docker ps -a --filter name=\(OpsShell.quote(container.name))")
            ]
        )
    }

    nonisolated func removeContainerPlan(container: DockerContainerSummary) -> RunbookPlan {
        let name = OpsShell.quote(container.name)
        return RunbookPlan(
            kind: .docker,
            title: String(localized: "删除容器 \(container.name)"),
            summary: String(localized: "强制删除该容器（docker rm -f）。容器内未持久化的数据会丢失。"),
            targetDescription: container.name,
            risk: .high,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "删除不可恢复；如需重建请用原镜像重新 run。"),
            steps: [
                RunbookStep(title: String(localized: "删除容器"), command: "docker rm -f \(name)"),
                RunbookStep(title: String(localized: "确认已删除"), command: "docker ps -a --filter name=\(name)")
            ]
        )
    }

    nonisolated func inspectContainerPlan(container: DockerContainerSummary) -> RunbookPlan {
        let name = OpsShell.quote(container.name)
        return RunbookPlan(
            kind: .docker,
            title: String(localized: "检查容器 \(container.name)"),
            summary: String(localized: "只读查看容器详情、端口映射与进程列表。"),
            targetDescription: container.name,
            risk: .readOnly,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: nil,
            steps: [
                RunbookStep(title: String(localized: "容器摘要"), command: "docker ps -a --filter name=\(name) --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}'"),
                RunbookStep(title: String(localized: "端口映射"), command: "docker port \(name) 2>/dev/null || echo \(OpsShell.quote(String(localized: "(无端口映射)")))"),
                RunbookStep(title: String(localized: "容器内进程"), command: "docker top \(name) 2>/dev/null || echo \(OpsShell.quote(String(localized: "(容器未运行)")))")
            ]
        )
    }

    nonisolated func diskUsagePlan() -> RunbookPlan {
        RunbookPlan(
            kind: .docker,
            title: String(localized: "Docker 磁盘占用"),
            summary: String(localized: "只读查看镜像/容器/卷/构建缓存占用（docker system df）。"),
            targetDescription: "docker",
            risk: .readOnly,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: nil,
            steps: [RunbookStep(title: String(localized: "磁盘占用"), command: "docker system df -v")]
        )
    }

    nonisolated func prunePlan() -> RunbookPlan {
        RunbookPlan(
            kind: .docker,
            title: String(localized: "清理 Docker 无用资源"),
            summary: String(localized: "删除已停止容器、悬空镜像、未使用网络与构建缓存（docker system prune -f）。不会删除正在使用的资源，但请确认。"),
            targetDescription: "docker",
            risk: .high,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "被清理的资源不可恢复，请确认无重要停止态容器/悬空镜像。"),
            steps: [
                RunbookStep(title: String(localized: "清理前占用"), command: "docker system df"),
                RunbookStep(title: String(localized: "执行清理"), command: "docker system prune -f"),
                RunbookStep(title: String(localized: "清理后占用"), command: "docker system df")
            ]
        )
    }

    nonisolated func removeImagePlan(image: DockerImageSummary) -> RunbookPlan {
        let ref = OpsShell.quote(image.repository == "<none>" ? image.id : "\(image.repository):\(image.tag)")
        return RunbookPlan(
            kind: .docker,
            title: String(localized: "删除镜像 \(image.displayName)"),
            summary: String(localized: "删除该镜像（docker rmi）。若有容器在使用会删除失败。"),
            targetDescription: image.displayName,
            risk: .high,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "删除后需重新 pull/build。"),
            steps: [
                RunbookStep(title: String(localized: "删除镜像"), command: "docker rmi \(ref)"),
                RunbookStep(title: String(localized: "确认镜像列表"), command: "docker images")
            ]
        )
    }

    nonisolated func startDaemonPlan(profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let startCommand = """
        if command -v systemctl >/dev/null 2>&1; then
          \(OpsShell.systemdEnableAndStart(serviceName: "docker", sudo: sudo))
        elif command -v service >/dev/null 2>&1; then
          \(sudo)service docker start
        else
          echo \(OpsShell.quote(String(localized: "未识别服务管理器，无法自动启动 Docker。")))
          exit 1
        fi
        """
        return RunbookPlan(
            kind: .docker,
            title: String(localized: "启动 Docker 服务"),
            summary: String(localized: "启动 Docker daemon，并验证客户端可以连接服务端。"),
            targetDescription: "docker.service",
            risk: .medium,
            requiresSudo: !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: String(localized: "如需停止，可在服务页停止 docker.service。"),
            steps: [
                RunbookStep(title: String(localized: "启动 Docker 服务"), command: startCommand),
                RunbookStep(title: String(localized: "验证 Docker 服务"), command: "\(sudo)docker info --format 'Docker Server {{.ServerVersion}}'")
            ]
        )
    }

    nonisolated func pullImagePlan(reference: String) -> RunbookPlan {
        let image = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        return RunbookPlan(
            kind: .docker,
            title: String(localized: "拉取镜像 \(image)"),
            summary: String(localized: "从当前 Docker registry 拉取镜像，不创建容器。"),
            targetDescription: image,
            risk: .low,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "不再需要时可在镜像列表中删除。"),
            steps: [
                RunbookStep(title: String(localized: "拉取镜像"), command: "docker pull \(OpsShell.quote(image))"),
                RunbookStep(title: String(localized: "验证镜像"), command: "docker image inspect \(OpsShell.quote(image)) --format '{{.Id}} {{.RepoTags}}'")
            ]
        )
    }

    nonisolated func runContainerPlan(name: String, image: String, portMapping: String, restartPolicy: String) -> RunbookPlan {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanImage = image.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPort = portMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let portArgument = cleanPort.isEmpty ? "" : " -p \(OpsShell.quote(cleanPort))"
        let restartArgument = restartPolicy == "no" ? "" : " --restart \(OpsShell.quote(restartPolicy))"
        let command = "docker run -d --name \(OpsShell.quote(cleanName))\(restartArgument)\(portArgument) \(OpsShell.quote(cleanImage))"
        return RunbookPlan(
            kind: .docker,
            title: String(localized: "创建容器 \(cleanName)"),
            summary: String(localized: "从 \(cleanImage) 创建并启动容器。执行前请确认端口不会占用现有服务。"),
            targetDescription: cleanName,
            risk: .medium,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "可执行 docker rm -f \(cleanName) 删除容器；持久化卷不会自动删除。"),
            steps: [
                RunbookStep(title: String(localized: "确认镜像"), command: "docker image inspect \(OpsShell.quote(cleanImage)) >/dev/null 2>&1 || docker pull \(OpsShell.quote(cleanImage))"),
                RunbookStep(title: String(localized: "创建并启动容器"), command: command),
                RunbookStep(title: String(localized: "验证容器"), command: "docker ps -a --filter name=\(OpsShell.quote(cleanName))")
            ]
        )
    }

    nonisolated func execPlan(container: DockerContainerSummary, command: String) -> RunbookPlan {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return RunbookPlan(
            kind: .docker,
            title: String(localized: "在 \(container.name) 中执行命令"),
            summary: String(localized: "通过 docker exec 在运行中的容器内执行 shell 命令。"),
            targetDescription: container.name,
            risk: .medium,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "命令产生的容器内变更需按命令内容自行回滚。"),
            steps: [
                RunbookStep(title: String(localized: "执行容器命令"), command: "docker exec \(OpsShell.quote(container.name)) sh -lc \(OpsShell.quote(value))")
            ]
        )
    }
}

actor DatabaseManagerService {
    func collect(profile: ServerProfileSnapshot?, config: SSHConnectionConfig, sshService: SSHService) async throws -> [DatabaseTarget] {
        let command = """
        # Cross-check the real daemon process: systemd's is-active is unreliable
        # for SysV/LSB-wrapped database services and can report inactive while
        # the daemon is actually running.
        db_procnames() {
          case "$1" in
            redis-server) echo redis-server redis ;;
            postgresql) echo postgres ;;
            mysql|mariadb) echo mysqld mariadbd ;;
            *) echo "$1" ;;
          esac
        }
        db_is_alive() {
          for p in $(db_procnames "$1"); do
            if pgrep -x "$p" >/dev/null 2>&1 || pidof "$p" >/dev/null 2>&1; then
              return 0
            fi
          done
          return 1
        }
        for db in postgresql mysql mariadb redis; do
          case "$db" in
            postgresql) bin=psql; svc=postgresql ;;
            mysql) bin=mysql; svc=mysql ;;
            mariadb) bin=mariadb; svc=mariadb ;;
            redis) bin=redis-cli; svc=redis-server ;;
          esac
          bin_path="$(command -v "$bin" 2>/dev/null || true)"
          service_installed=0
          active=""
          if command -v systemctl >/dev/null 2>&1; then
            load="$(systemctl show "$svc" -p LoadState --value 2>/dev/null || true)"
            if [ -n "$load" ] && [ "$load" != "not-found" ]; then
              service_installed=1
              active="$(systemctl is-active "$svc" 2>/dev/null || true)"
              if [ "$active" != "active" ] && db_is_alive "$svc"; then active="active"; fi
            fi
          elif [ -x "/etc/init.d/$svc" ]; then
            service_installed=1
            if command -v rc-service >/dev/null 2>&1; then
              rc-service "$svc" status >/dev/null 2>&1 && active=active || active=inactive
            else
              service "$svc" status >/dev/null 2>&1 && active=active || active=inactive
            fi
          fi
          if [ -n "$bin_path" ] || [ "$service_installed" -eq 1 ]; then
            version="$($bin --version 2>/dev/null | head -n 1)"
            printf 'DB=%s|%s|%s|%s|%s\\n' "$db" "$svc" "$service_installed" "$active" "$version"
          fi
        done
        """
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 128 * 1024)
        return result.stdout.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = String(line).replacingOccurrences(of: "DB=", with: "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5, let kind = DatabaseKind(rawValue: parts[0]) else { return nil }
            return DatabaseTarget(
                kind: kind,
                serviceName: parts[1],
                installed: true,
                serviceInstalled: parts[2] == "1",
                activeState: parts[3].isEmpty ? nil : parts[3],
                version: parts[4].isEmpty ? nil : parts[4]
            )
        }
    }

    /// Read-only inventory: list databases and basic server status. Uses local
    /// socket/peer auth (sudo -u postgres / root socket) which works on typical
    /// single-host setups; if credentials are required the step surfaces the error.
    /// Deliberately no write access — this is a "运维视角", not a SQL editor.
    nonisolated func inspectPlan(database: DatabaseTarget, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let steps: [RunbookStep]
        var needsSudo = false
        switch database.kind {
        case .postgresql:
            // PostgreSQL uses peer auth: must run as the postgres OS user.
            // Always via `sudo -u postgres` (works whether we log in as root or
            // a sudo user); the generic sudo prefix would drop the -u for root.
            let psql = "sudo -u postgres psql"
            needsSudo = true
            // Column aliases are shown to the user, so they're localized. PostgreSQL
            // quotes identifiers with double quotes; the whole SQL is then wrapped in
            // a shell-safe single-quoted string so those quotes stay literal.
            let pgDbCol = String(localized: "数据库")
            let pgSizeCol = String(localized: "大小")
            let pgSizeQuery = "SELECT datname AS \"\(pgDbCol)\", pg_size_pretty(pg_database_size(datname)) AS \"\(pgSizeCol)\" FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC;"
            steps = [
                RunbookStep(title: String(localized: "服务器版本"), command: "\(psql) -tAc 'SELECT version();'"),
                RunbookStep(title: String(localized: "数据库列表（含大小）"), command: "\(psql) -c \(OpsShell.quote(pgSizeQuery))"),
                RunbookStep(title: String(localized: "连接数"), command: "\(psql) -tAc 'SELECT count(*) FROM pg_stat_activity;'")
            ]
        case .mysql, .mariadb:
            // Ubuntu/Debian MySQL & MariaDB root often uses unix_socket auth, so
            // `sudo mysql` connects without a password. But if root was given a
            // password (mysql_native_password), no-password auth fails — detect
            // that up front and give a readable hint instead of a raw error dump.
            let mysql = "\(sudo)mysql"
            needsSudo = true
            // Localized column aliases (shown to the user). MySQL quotes identifiers
            // with backticks; ORDER BY references the same aliased column.
            let myDbCol = String(localized: "数据库")
            let mySizeCol = String(localized: "大小MB")
            let sizeQuery = "SELECT table_schema AS `\(myDbCol)`, ROUND(SUM(data_length+index_length)/1024/1024,1) AS `\(mySizeCol)` FROM information_schema.tables WHERE table_schema IS NOT NULL GROUP BY table_schema ORDER BY `\(mySizeCol)` DESC;"
            let command = """
            if ! \(mysql) -e 'SELECT 1' >/dev/null 2>&1; then
              echo \(OpsShell.quote(String(localized: "无法免密连接 MySQL/MariaDB。")))
              echo \(OpsShell.quote(String(localized: "原因通常是：root 账号设置了独立密码，或未启用 unix_socket 认证。")))
              echo \(OpsShell.quote(String(localized: "可在服务器上手动连接：mysql -u root -p")))
              echo \(OpsShell.quote(String(localized: "或为 OpsDeck 配置一个只读账号后再查询。")))
              exit 0
            fi
            echo \(OpsShell.quote(String(localized: "===== 版本 =====")))
            \(mysql) -e 'SELECT VERSION();'
            echo \(OpsShell.quote(String(localized: "===== 数据库列表 =====")))
            \(mysql) -e 'SHOW DATABASES;'
            echo \(OpsShell.quote(String(localized: "===== 各库大小（MB） =====")))
            \(mysql) -e \(OpsShell.quote(sizeQuery))
            """
            steps = [RunbookStep(title: String(localized: "查询 MySQL（只读）"), command: command)]
        case .redis:
            steps = [
                RunbookStep(title: String(localized: "服务器信息"), command: "redis-cli INFO server 2>&1 | grep -E 'redis_version|uptime_in_days|os:'"),
                RunbookStep(title: String(localized: "键空间"), command: "redis-cli INFO keyspace 2>&1"),
                RunbookStep(title: String(localized: "内存占用"), command: "redis-cli INFO memory 2>&1 | grep -E 'used_memory_human|maxmemory_human'")
            ]
        }
        return RunbookPlan(
            kind: .database,
            title: String(localized: "查看 \(database.kind.displayName)（只读）"),
            summary: String(localized: "只读查询：版本、数据库/键空间列表与大小。不修改任何数据。MySQL/PostgreSQL 通过本机 socket 以管理员身份连接；若你的 root 设了独立密码或禁用了 socket 认证，可能需要在服务器侧改用带密码的连接。"),
            targetDescription: database.kind.displayName,
            risk: .readOnly,
            requiresSudo: needsSudo && !sudo.isEmpty,
            backupDescription: nil,
            rollbackDescription: nil,
            steps: steps
        )
    }

    nonisolated func backupPlan(database: DatabaseTarget, profile: ServerProfileSnapshot?) -> RunbookPlan {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let dir = "$HOME/opsdeck-backups"
        let stamp = "$(date +%Y%m%d-%H%M%S)"
        let command: String
        let postgresDump = profile?.sudoStatus == .root ? "sudo -u postgres pg_dumpall" : "\(sudo)-u postgres pg_dumpall"
        switch database.kind {
        case .postgresql:
            command = "mkdir -p \(dir) && \(postgresDump) > \(dir)/postgresql-\(stamp).sql"
        case .mysql, .mariadb:
            // mysqldump needs admin (Debian/Ubuntu root uses unix_socket auth). The
            // shell (not sudo) owns the `>` redirect, so the output file stays owned
            // by the SSH user and remains downloadable.
            command = "mkdir -p \(dir) && \(sudo)mysqldump --all-databases > \(dir)/\(database.kind.rawValue)-\(stamp).sql"
        case .redis:
            // Ask the running instance where its dump file actually is (dir +
            // dbfilename are both configurable) instead of assuming
            // /var/lib/redis/dump.rdb. Copy as admin, then hand ownership back so
            // the file can be downloaded over the (non-root) SFTP session.
            let out = "\(dir)/redis-\(stamp).rdb"
            command = "mkdir -p \(dir) && \(sudo)redis-cli SAVE && RDBDIR=$(\(sudo)redis-cli CONFIG GET dir | tail -1) && RDBFILE=$(\(sudo)redis-cli CONFIG GET dbfilename | tail -1) && \(sudo)cp \"$RDBDIR/$RDBFILE\" \(out) && \(sudo)chown \"$(id -u):$(id -g)\" \(out)"
        }
        return RunbookPlan(
            kind: .database,
            title: String(localized: "备份 \(database.kind.displayName)"),
            summary: String(localized: "在远端生成备份文件，完成后可到文件工作区下载。"),
            targetDescription: database.kind.displayName,
            risk: .medium,
            requiresSudo: database.kind == .postgresql || !sudo.isEmpty,
            backupDescription: String(localized: "备份输出到 ~/opsdeck-backups。"),
            rollbackDescription: String(localized: "备份不修改数据库；恢复需要单独确认。"),
            steps: [
                RunbookStep(title: String(localized: "生成备份"), command: command),
                RunbookStep(title: String(localized: "列出备份文件"), command: "ls -lh \(dir)")
            ]
        )
    }
}

enum RedisManagerError: LocalizedError, Equatable, Sendable {
    case authenticationRequired(String)
    case permissionDenied(String)
    case unavailable(String)
    case malformedResponse
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired(let detail):
            return detail.isEmpty
                ? String(localized: "Redis 需要认证，请填写 ACL 用户名和密码。")
                : String(localized: "Redis 认证失败：\(detail)")
        case .permissionDenied(let detail):
            return String(localized: "当前 Redis 账号没有执行此操作的权限：\(detail)")
        case .unavailable(let detail):
            return String(localized: "无法连接 Redis：\(detail)")
        case .malformedResponse:
            return String(localized: "Redis 返回了无法识别的数据，请刷新后重试。")
        case .invalidInput(let detail):
            return detail
        }
    }
}

/// Redis is key/value, so it deliberately has a separate service instead of
/// being forced through the SQL table browser. Reads use SCAN (never KEYS) and
/// bounded Lua projections, keeping both Redis and the Mac UI responsive even
/// when the selected logical database contains many keys.
actor RedisManagerService {
    static let pageSize = 100

    nonisolated func cliCommand(credential: RedisCredential?) -> String {
        guard let credential else { return "redis-cli" }
        let user = credential.normalizedUsername.map { " --user \(OpsShell.quote($0))" } ?? ""
        // REDISCLI_AUTH keeps the secret out of argv / ps output. The full command
        // is used only by the direct SSH query path and is never placed in a
        // RunbookPlan, copied diagnostics, or operation history.
        return "REDISCLI_AUTH=\(OpsShell.quote(credential.password)) redis-cli\(user)"
    }

    func loadSnapshot(
        credential: RedisCredential?,
        config: SSHConnectionConfig,
        sshService: SSHService
    ) async throws -> RedisServerSnapshot {
        let cli = cliCommand(credential: credential)
        let command = """
        opsdeck_ping=$(\(cli) --raw PING 2>&1)
        if [ "$opsdeck_ping" != "PONG" ]; then
          printf '__OPSDECK_REDIS_ERROR__\\n%s\\n' "$opsdeck_ping"
          exit 0
        fi
        printf '__OPSDECK_REDIS_INFO__\\n'
        \(cli) --raw INFO 2>&1
        printf '__OPSDECK_REDIS_CONFIG__\\n'
        \(cli) --raw CONFIG GET databases 2>/dev/null || true
        """
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 256 * 1024)
        try Self.throwIfRedisError(result.stdout)

        guard let infoRange = result.stdout.range(of: "__OPSDECK_REDIS_INFO__\n") else {
            throw RedisManagerError.malformedResponse
        }
        let afterInfo = result.stdout[infoRange.upperBound...]
        let pieces = afterInfo.components(separatedBy: "__OPSDECK_REDIS_CONFIG__\n")
        let info = Self.parseInfo(pieces[0])
        let configValues = pieces.count > 1 ? Self.parseConfig(pieces[1]) : [:]

        let databases = info.compactMap { key, value -> RedisDatabaseSummary? in
            guard key.hasPrefix("db"), let index = Int(key.dropFirst(2)) else { return nil }
            let fields = Dictionary(uniqueKeysWithValues: value.split(separator: ",").compactMap { field -> (String, String)? in
                let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                return pair.count == 2 ? (pair[0], pair[1]) : nil
            })
            return RedisDatabaseSummary(
                index: index,
                keyCount: Int(fields["keys"] ?? "0") ?? 0,
                expiringKeyCount: Int(fields["expires"] ?? "0") ?? 0,
                averageTTL: Int(fields["avg_ttl"] ?? "0") ?? 0
            )
        }.sorted { $0.index < $1.index }

        return RedisServerSnapshot(
            version: info["redis_version"],
            mode: info["redis_mode"],
            uptimeDays: Int(info["uptime_in_days"] ?? "0") ?? 0,
            connectedClients: Int(info["connected_clients"] ?? "0") ?? 0,
            blockedClients: Int(info["blocked_clients"] ?? "0") ?? 0,
            usedMemory: info["used_memory_human"],
            peakMemory: info["used_memory_peak_human"],
            maxMemory: info["maxmemory_human"] ?? configValues["maxmemory"],
            maxMemoryPolicy: info["maxmemory_policy"] ?? configValues["maxmemory-policy"],
            totalConnections: Int(info["total_connections_received"] ?? "0") ?? 0,
            totalCommands: Int(info["total_commands_processed"] ?? "0") ?? 0,
            keyspaceHits: Int(info["keyspace_hits"] ?? "0") ?? 0,
            keyspaceMisses: Int(info["keyspace_misses"] ?? "0") ?? 0,
            rdbLastSaveTime: Int(info["rdb_last_save_time"] ?? "").map { Date(timeIntervalSince1970: TimeInterval($0)) },
            rdbLastSaveStatus: info["rdb_last_bgsave_status"],
            aofEnabled: info["aof_enabled"] == "1" || configValues["appendonly"] == "yes",
            persistenceBusy: info["rdb_bgsave_in_progress"] == "1" || info["aof_rewrite_in_progress"] == "1",
            configuredDatabaseCount: min(256, max(1, Int(configValues["databases"] ?? "16") ?? 16)),
            databases: databases
        )
    }

    func scanKeys(
        database: Int,
        cursor: String,
        pattern: String,
        credential: RedisCredential?,
        config: SSHConnectionConfig,
        sshService: SSHService
    ) async throws -> RedisKeyPage {
        guard (0...255).contains(database) else {
            throw RedisManagerError.invalidInput(String(localized: "Redis 数据库编号无效。"))
        }
        guard cursor.allSatisfy(\.isNumber), !cursor.isEmpty else {
            throw RedisManagerError.invalidInput(String(localized: "Redis 游标无效。"))
        }
        let match = pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "*" : pattern
        let lua = """
        local function hex(s)
          local out = {}
          for i = 1, string.len(s) do out[#out + 1] = string.format('%02x', string.byte(s, i)) end
          return table.concat(out)
        end
        local result = redis.call('SCAN', ARGV[1], 'MATCH', ARGV[2], 'COUNT', ARGV[3])
        local out = { result[1] }
        for _, key in ipairs(result[2]) do
          local kind = redis.call('TYPE', key).ok
          local ttl = redis.call('TTL', key)
          local memory = redis.pcall('MEMORY', 'USAGE', key)
          if type(memory) == 'table' then memory = -1 end
          out[#out + 1] = hex(key)
          out[#out + 1] = kind
          out[#out + 1] = tostring(ttl)
          out[#out + 1] = tostring(memory)
        end
        return out
        """
        let cli = cliCommand(credential: credential)
        let command = "\(cli) --raw -n \(database) EVAL \(OpsShell.quote(lua)) 0 \(OpsShell.quote(cursor)) \(OpsShell.quote(match)) \(Self.pageSize) 2>&1"
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 256 * 1024)
        try Self.throwIfRedisError(result.stdout)
        var lines = Self.linesPreservingEmpty(result.stdout)
        guard let nextCursor = lines.first, nextCursor.allSatisfy(\.isNumber) else {
            throw RedisManagerError.malformedResponse
        }
        lines.removeFirst()
        var keys: [RedisKeySummary] = []
        for offset in stride(from: 0, to: lines.count, by: 4) {
            guard offset + 3 < lines.count,
                  let name = Self.decodeHex(lines[offset]),
                  let ttl = Int(lines[offset + 2]) else { continue }
            let rawMemory = Int(lines[offset + 3])
            keys.append(RedisKeySummary(
                name: name,
                type: lines[offset + 1],
                ttlSeconds: ttl,
                memoryBytes: rawMemory.flatMap { $0 >= 0 ? $0 : nil }
            ))
        }
        return RedisKeyPage(keys: keys, nextCursor: nextCursor)
    }

    func loadKeyDetail(
        database: Int,
        key: String,
        credential: RedisCredential?,
        config: SSHConnectionConfig,
        sshService: SSHService
    ) async throws -> RedisKeyDetail {
        let lua = """
        local function hex(s)
          local out = {}
          for i = 1, string.len(s) do out[#out + 1] = string.format('%02x', string.byte(s, i)) end
          return table.concat(out)
        end
        local key = KEYS[1]
        local response = redis.call('TYPE', key)
        local kind = response.ok
        if kind == 'none' then return { 'none', '-2', '0' } end
        local ttl = redis.call('TTL', key)
        local out = { kind, tostring(ttl), '0' }
        if kind == 'string' then
          local value = redis.call('GET', key)
          out[3] = tostring(redis.call('STRLEN', key))
          out[#out + 1] = hex(value or '')
        elseif kind == 'hash' then
          local values = redis.call('HSCAN', key, '0', 'COUNT', '100')[2]
          out[3] = tostring(redis.call('HLEN', key))
          for _, value in ipairs(values) do out[#out + 1] = hex(value) end
        elseif kind == 'list' then
          local values = redis.call('LRANGE', key, '0', '99')
          out[3] = tostring(redis.call('LLEN', key))
          for _, value in ipairs(values) do out[#out + 1] = hex(value) end
        elseif kind == 'set' then
          local values = redis.call('SSCAN', key, '0', 'COUNT', '100')[2]
          out[3] = tostring(redis.call('SCARD', key))
          for _, value in ipairs(values) do out[#out + 1] = hex(value) end
        elseif kind == 'zset' then
          local values = redis.call('ZRANGE', key, '0', '99', 'WITHSCORES')
          out[3] = tostring(redis.call('ZCARD', key))
          for _, value in ipairs(values) do out[#out + 1] = hex(value) end
        elseif kind == 'stream' then
          out[3] = tostring(redis.call('XLEN', key))
          out[#out + 1] = hex(cjson.encode(redis.call('XRANGE', key, '-', '+', 'COUNT', '30')))
        end
        return out
        """
        let cli = cliCommand(credential: credential)
        let command = "\(cli) --raw -n \(database) EVAL \(OpsShell.quote(lua)) 1 \(OpsShell.quote(key)) 2>&1"
        let result = try await sshService.executeCommand(command, on: config, maxResponseSize: 512 * 1024)
        try Self.throwIfRedisError(result.stdout)
        let lines = Self.linesPreservingEmpty(result.stdout)
        guard lines.count >= 3, let ttl = Int(lines[1]), let logicalSize = Int(lines[2]) else {
            throw RedisManagerError.malformedResponse
        }
        let type = lines[0]
        let decoded = lines.dropFirst(3).map { Self.decodeHex($0) ?? String(localized: "<二进制数据>") }
        var entries: [RedisKeyDetailEntry] = []
        switch type {
        case "string":
            entries = [RedisKeyDetailEntry(id: "value", label: String(localized: "值"), value: decoded.first ?? "")]
        case "hash", "zset":
            for offset in stride(from: 0, to: decoded.count, by: 2) {
                guard offset + 1 < decoded.count else { break }
                entries.append(RedisKeyDetailEntry(id: "\(offset)", label: decoded[offset], value: decoded[offset + 1]))
            }
        case "list", "set":
            entries = decoded.enumerated().map {
                RedisKeyDetailEntry(id: "\($0.offset)", label: type == "list" ? "[\($0.offset)]" : "•", value: $0.element)
            }
        case "stream":
            entries = [RedisKeyDetailEntry(id: "messages", label: String(localized: "消息预览"), value: decoded.first ?? "[]")]
        default:
            entries = []
        }
        return RedisKeyDetail(key: key, type: type, ttlSeconds: ttl, logicalSize: logicalSize, entries: entries)
    }

    func setString(
        database: Int,
        key: String,
        value: String,
        preserveTTL: Bool,
        credential: RedisCredential?,
        config: SSHConnectionConfig,
        sshService: SSHService
    ) async throws {
        guard !key.isEmpty else { throw RedisManagerError.invalidInput(String(localized: "键名不能为空。")) }
        guard key.utf8.count <= 512 else {
            throw RedisManagerError.invalidInput(String(localized: "键名不能超过 512 字节。"))
        }
        guard value.utf8.count <= 256 * 1024 else {
            throw RedisManagerError.invalidInput(String(localized: "String 值不能超过 256 KB；更大的值请使用 redis-cli。"))
        }
        let lua = """
        local ttl = redis.call('PTTL', KEYS[1])
        redis.call('SET', KEYS[1], ARGV[1])
        if ARGV[2] == '1' and ttl > 0 then redis.call('PEXPIRE', KEYS[1], ttl) end
        return 'OK'
        """
        try await runMutation(
            "EVAL \(OpsShell.quote(lua)) 1 \(OpsShell.quote(key)) \(OpsShell.quote(value)) \(preserveTTL ? "1" : "0")",
            database: database, credential: credential, config: config, sshService: sshService
        )
    }

    func deleteKey(
        database: Int,
        key: String,
        credential: RedisCredential?,
        config: SSHConnectionConfig,
        sshService: SSHService
    ) async throws {
        try await runMutation(
            "DEL \(OpsShell.quote(key))", database: database,
            credential: credential, config: config, sshService: sshService
        )
    }

    func setTTL(
        database: Int,
        key: String,
        seconds: Int?,
        credential: RedisCredential?,
        config: SSHConnectionConfig,
        sshService: SSHService
    ) async throws {
        if let seconds, !(1...315_360_000).contains(seconds) {
            throw RedisManagerError.invalidInput(String(localized: "TTL 必须在 1 秒到 10 年之间。"))
        }
        let operation = seconds.map { "EXPIRE \(OpsShell.quote(key)) \($0)" }
            ?? "PERSIST \(OpsShell.quote(key))"
        try await runMutation(operation, database: database, credential: credential, config: config, sshService: sshService)
    }

    private func runMutation(
        _ operation: String,
        database: Int,
        credential: RedisCredential?,
        config: SSHConnectionConfig,
        sshService: SSHService
    ) async throws {
        let cli = cliCommand(credential: credential)
        let result = try await sshService.executeCommand(
            "\(cli) --raw -n \(database) \(operation) 2>&1",
            on: config,
            maxResponseSize: 64 * 1024
        )
        try Self.throwIfRedisError(result.stdout)
        let response = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == "OK" || response == "1" else {
            if response == "0" {
                throw RedisManagerError.unavailable(String(localized: "目标键已不存在，请刷新键空间。"))
            }
            throw RedisManagerError.unavailable(response.isEmpty ? String(localized: "Redis 未返回操作结果。") : response)
        }
    }

    private nonisolated static func parseInfo(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: ":") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return values
    }

    private nonisolated static func parseConfig(_ text: String) -> [String: String] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var values: [String: String] = [:]
        for offset in stride(from: 0, to: lines.count, by: 2) where offset + 1 < lines.count {
            values[lines[offset]] = lines[offset + 1]
        }
        return values
    }

    private nonisolated static func linesPreservingEmpty(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        return lines
    }

    private nonisolated static func decodeHex(_ value: String) -> String? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func throwIfRedisError(_ output: String) throws {
        let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = body.lowercased()
        if lowered.contains("noauth") || lowered.contains("wrongpass") || lowered.contains("invalid username-password") {
            let detail = body.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw RedisManagerError.authenticationRequired(detail)
        }
        if lowered.contains("noperm") || lowered.contains("permission denied") {
            throw RedisManagerError.permissionDenied(body)
        }
        if body.hasPrefix("__OPSDECK_REDIS_ERROR__") || lowered.contains("connection refused")
            || lowered.contains("could not connect") {
            let detail = body.replacingOccurrences(of: "__OPSDECK_REDIS_ERROR__", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RedisManagerError.unavailable(detail)
        }
        if body.hasPrefix("ERR ") || body.hasPrefix("(error)") {
            throw RedisManagerError.unavailable(body)
        }
    }
}

struct DeploymentTemplateService {
    func templates() -> [DeploymentTemplate] {
        [
            DeploymentTemplate(
                id: "static-nginx",
                title: String(localized: "静态站点 + Nginx"),
                summary: String(localized: "准备目录、提示上传静态文件、生成 Nginx 测试计划。"),
                kind: .deployment,
                steps: [
                    RunbookStep(title: String(localized: "准备站点目录"), command: "mkdir -p /var/www/opsdeck-site && ls -ld /var/www/opsdeck-site"),
                    RunbookStep(title: String(localized: "测试 Nginx"), command: "nginx -t")
                ]
            ),
            DeploymentTemplate(
                id: "node-pm2-nginx",
                title: String(localized: "Node + PM2 + Nginx"),
                summary: String(localized: "检查 Node/PM2/Nginx，适合小型 Node 服务部署。"),
                kind: .deployment,
                steps: [
                    RunbookStep(title: String(localized: "检查 Node"), command: "node -v && npm -v"),
                    RunbookStep(title: String(localized: "检查 PM2"), command: "pm2 -v"),
                    RunbookStep(title: String(localized: "测试 Nginx"), command: "nginx -t")
                ]
            ),
            DeploymentTemplate(
                id: "docker-compose",
                title: String(localized: "Docker Compose 应用"),
                summary: String(localized: "检测 compose 文件并执行 docker compose 状态检查。"),
                kind: .deployment,
                steps: [
                    RunbookStep(title: String(localized: "检查 Docker"), command: "docker version"),
                    RunbookStep(title: String(localized: "检查 Compose 文件"), command: "test -f docker-compose.yml -o -f compose.yml"),
                    RunbookStep(title: String(localized: "查看 Compose 状态"), command: "docker compose ps")
                ]
            )
        ]
    }

    func plan(template: DeploymentTemplate) -> RunbookPlan {
        RunbookPlan(
            kind: .deployment,
            title: template.title,
            summary: template.summary,
            targetDescription: template.title,
            risk: .medium,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: String(localized: "模板只生成基础计划，不自动修改防火墙。"),
            steps: template.steps
        )
    }
}

actor SecurityAuditService {
    func collect(profile: ServerProfileSnapshot?, config: SSHConnectionConfig, sshService: SSHService) async throws -> [AuditFinding] {
        let sudo = OpsShell.sudoPrefix(for: profile)
        let result = try await sshService.executeCommand(auditCommand(sudo: sudo), on: config, maxResponseSize: 128 * 1024)
        return parse(result.stdout, profile: profile)
    }

    private func auditCommand(sudo: String) -> String {
        """
        sshd="$(\(sudo)sshd -T 2>/dev/null || true)"
        printf 'ROOT_LOGIN=%s\\n' "$(printf '%s\\n' "$sshd" | awk '/^permitrootlogin/{print $2; exit}')"
        printf 'PASSWORD_AUTH=%s\\n' "$(printf '%s\\n' "$sshd" | awk '/^passwordauthentication/{print $2; exit}')"
        printf 'FIREWALL_UFW=%s\\n' "$(\(sudo)ufw status 2>/dev/null | head -n 1)"
        printf 'FIREWALLD=%s\\n' "$(firewall-cmd --state 2>/dev/null || true)"
        printf 'FAIL2BAN=%s\\n' "$(command -v fail2ban-client >/dev/null 2>&1 && echo installed || echo missing)"
        printf 'DISK_ROOT=%s\\n' "$(df -P / 2>/dev/null | awk 'NR==2{print $5}')"
        printf 'FAILED_UNITS=%s\\n' "$(systemctl --failed --no-legend 2>/dev/null | wc -l | tr -d ' ')"
        printf 'WORLD_WRITABLE=%s\\n' "$(find /etc/nginx /var/www -maxdepth 2 -type d -perm -0002 2>/dev/null | head -n 5 | paste -sd ',' -)"
        """
    }

    private func parse(_ output: String, profile: ServerProfileSnapshot?) -> [AuditFinding] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let index = line.firstIndex(of: "=") else { continue }
            values[String(line[..<index])] = String(line[line.index(after: index)...])
        }

        var findings: [AuditFinding] = []
        let sudo = OpsShell.sudoPrefix(for: profile)
        // If the current OpsDeck session itself logs in as root, disabling root
        // SSH login would lock the user out on the next connection. Never offer
        // a one-click fix in that case — only warn.
        let connectedAsRoot = profile?.userID == "0" || profile?.username == "root"
        let rootLogin = values["ROOT_LOGIN"] ?? ""
        // Empty = couldn't read sshd config (even with sudo, or sshd -T unavailable).
        // Don't raise a false "root login allowed" warning in that case.
        let rootLoginOpen = !rootLogin.isEmpty && rootLogin != "no"
        findings.append(AuditFinding(
            id: "root-login",
            title: String(localized: "SSH root 登录"),
            detail: {
                if rootLogin == "no" { return String(localized: "root 登录已关闭。") }
                if rootLogin.isEmpty { return String(localized: "无法读取 sshd 配置（可能权限不足或 sshd -T 不可用），已跳过判断。") }
                if connectedAsRoot {
                    return String(localized: "当前允许 root 登录，且你正以 root 身份连接。关闭前必须先配置好其他 sudo 用户 + 密钥登录，否则会把自己锁在门外——因此这里未提供一键修复。")
                }
                return String(localized: "当前允许 root 登录，生产服务器建议关闭。")
            }(),
            severity: rootLoginOpen ? .warning : .safe,
            evidence: rootLogin.isEmpty ? String(localized: "未识别") : rootLogin,
            fixPlan: (rootLoginOpen && !connectedAsRoot) ? RunbookPlan(
                kind: .audit,
                title: String(localized: "关闭 SSH root 登录"),
                summary: String(localized: "备份 sshd_config 后关闭 PermitRootLogin，并重载 SSH 服务。确认你有其他可登录的 sudo 账号再执行。"),
                targetDescription: "/etc/ssh/sshd_config",
                risk: .high,
                requiresSudo: !sudo.isEmpty,
                backupDescription: String(localized: "复制 /etc/ssh/sshd_config 到 .opsdeck-bak。"),
                rollbackDescription: String(localized: "恢复备份文件后重载 sshd。"),
                steps: [
                    RunbookStep(title: String(localized: "备份 SSH 配置"), command: "\(sudo)cp /etc/ssh/sshd_config /etc/ssh/sshd_config.opsdeck-bak"),
                    RunbookStep(title: String(localized: "关闭 root 登录"), command: "\(sudo)sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config"),
                    RunbookStep(title: String(localized: "测试 SSH 配置"), command: "\(sudo)sshd -t"),
                    RunbookStep(title: String(localized: "重载 SSH 服务"), command: "\(sudo)systemctl reload sshd || \(sudo)systemctl reload ssh")
                ]
            ) : nil
        ))

        let passwordAuth = values["PASSWORD_AUTH"] ?? ""
        let passwordAuthOpen = !passwordAuth.isEmpty && passwordAuth != "no"
        findings.append(AuditFinding(
            id: "password-auth",
            title: String(localized: "SSH 密码登录"),
            detail: {
                if passwordAuth == "no" { return String(localized: "密码登录已关闭。") }
                if passwordAuth.isEmpty { return String(localized: "无法读取 sshd 配置（可能权限不足），已跳过判断。") }
                return String(localized: "当前允许密码登录，建议改用私钥后关闭。")
            }(),
            severity: passwordAuthOpen ? .warning : .safe,
            evidence: passwordAuth.isEmpty ? String(localized: "未识别") : passwordAuth,
            fixPlan: nil
        ))

        let failedUnits = Int(values["FAILED_UNITS"] ?? "0") ?? 0
        findings.append(AuditFinding(
            id: "failed-units",
            title: String(localized: "失败服务"),
            detail: failedUnits == 0 ? String(localized: "没有 failed systemd units。") : String(localized: "存在 \(failedUnits) 个 failed 服务，需要查看服务页。"),
            severity: failedUnits == 0 ? .safe : .danger,
            evidence: "\(failedUnits)",
            fixPlan: nil
        ))

        let diskText = (values["DISK_ROOT"] ?? "0").replacingOccurrences(of: "%", with: "")
        let disk = Int(diskText) ?? 0
        findings.append(AuditFinding(
            id: "disk-root",
            title: String(localized: "根分区磁盘"),
            detail: disk >= 85 ? String(localized: "根分区使用率较高。") : String(localized: "根分区空间正常。"),
            severity: disk >= 90 ? .danger : (disk >= 85 ? .warning : .safe),
            evidence: "\(disk)%",
            fixPlan: nil
        ))

        let fail2ban = values["FAIL2BAN"] ?? "missing"
        findings.append(AuditFinding(
            id: "fail2ban",
            title: "Fail2ban",
            detail: fail2ban == "installed" ? String(localized: "Fail2ban 已安装。") : String(localized: "未检测到 Fail2ban，可在工具页安装。"),
            severity: fail2ban == "installed" ? .safe : .warning,
            evidence: fail2ban,
            fixPlan: nil
        ))

        let worldWritable = values["WORLD_WRITABLE"] ?? ""
        findings.append(AuditFinding(
            id: "world-writable",
            title: String(localized: "世界可写目录"),
            detail: worldWritable.isEmpty ? String(localized: "未发现常见配置/站点目录世界可写。") : String(localized: "发现世界可写目录，请检查权限。"),
            severity: worldWritable.isEmpty ? .safe : .danger,
            evidence: worldWritable.isEmpty ? String(localized: "无") : worldWritable,
            fixPlan: nil
        ))
        return findings
    }
}
