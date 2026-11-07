import Foundation

actor ServerProfileService {
    func collect(config: SSHConnectionConfig, sshService: SSHService) async throws -> ServerProfileSnapshot {
        let result = try await sshService.executeCommand(profileCommand, on: config, maxResponseSize: 96 * 1024)
        return parse(result.stdout)
    }

    private var profileCommand: String {
        """
        set +e
        # Include common user-bin dirs so tools installed there (uv→~/.local/bin,
        # cargo, go) are detected as installed even if the login shell hasn't
        # added them to PATH yet. The Shell/PATH module surfaces the missing dir.
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:/usr/local/go/bin:$HOME/bin:$PATH"
        if [ -r /etc/os-release ]; then . /etc/os-release; fi
        printf 'OS_NAME=%s\\n' "${PRETTY_NAME:-${NAME:-}}"
        printf 'OS_ID=%s\\n' "${ID:-}"
        printf 'OS_VERSION_ID=%s\\n' "${VERSION_ID:-}"
        printf 'ARCH=%s\\n' "$(uname -m 2>/dev/null || true)"
        printf 'USER_NAME=%s\\n' "$(whoami 2>/dev/null || true)"
        printf 'USER_ID=%s\\n' "$(id -u 2>/dev/null || true)"
        if [ "$(id -u 2>/dev/null)" = "0" ]; then
          printf 'SUDO=root\\n'
        elif command -v sudo >/dev/null 2>&1; then
          if sudo -n true >/dev/null 2>&1; then
            printf 'SUDO=passwordless\\n'
          else
            printf 'SUDO=requires_password\\n'
          fi
        else
          printf 'SUDO=unavailable\\n'
        fi
        pm=unknown
        for candidate in apt dnf yum pacman zypper apk; do
          if command -v "$candidate" >/dev/null 2>&1; then pm="$candidate"; break; fi
        done
        printf 'PACKAGE_MANAGER=%s\\n' "$pm"
        init=unknown
        if command -v systemctl >/dev/null 2>&1; then
          init=systemd
        elif command -v rc-service >/dev/null 2>&1; then
          init=openrc
        elif command -v service >/dev/null 2>&1; then
          init=service
        fi
        printf 'INIT_SYSTEM=%s\\n' "$init"
        for tool in git curl wget tar unzip zip rsync jq tmux htop tree ncdu lsof netstat ifconfig dig gpg zsh vim nano rg fzf cowsay gcc make cc node nodejs npm yarn pnpm pm2 python3 uv go java php docker nginx caddy certbot redis-server redis-cli psql mysql mariadb ufw firewall-cmd fail2ban-client; do
          path="$(command -v "$tool" 2>/dev/null || true)"
          printf 'TOOL=%s|%s\\n' "$tool" "$path"
          if [ -n "$path" ]; then
            allpaths="$(command -v -a "$tool" 2>/dev/null | tr '\\n' ',' 2>/dev/null || true)"
            if [ -z "$allpaths" ] && command -v which >/dev/null 2>&1; then
              allpaths="$(which -a "$tool" 2>/dev/null | tr '\\n' ',' 2>/dev/null || true)"
            fi
            ver="$("$tool" --version </dev/null 2>/dev/null || "$tool" -v </dev/null 2>/dev/null || "$tool" version </dev/null 2>/dev/null || true)"
            ver="$(printf '%s' "$ver" | head -n1 | tr -d '\\r' | cut -c1-80)"
            printf 'TOOLMETA=%s|%s|%s\\n' "$tool" "$ver" "$allpaths"
          fi
        done
        # systemd's is-active is unreliable for SysV/LSB-wrapped services (e.g.
        # nginx started via /etc/init.d or `service`): it can report inactive
        # while the daemon is actually running. Cross-check the real process so
        # the tools page and nginx panel reflect reality, not systemd bookkeeping.
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
        if [ "$init" = "systemd" ]; then
          for svc in nginx caddy docker redis redis-server postgresql mysql mariadb; do
            load="$(systemctl show "$svc" -p LoadState --value 2>/dev/null || true)"
            [ -n "$load" ] && [ "$load" != "not-found" ] || continue
            active="$(systemctl is-active "$svc" 2>/dev/null || true)"
            enabled="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
            if [ "$active" != "active" ] && is_alive "$svc"; then active="active"; fi
            printf 'SERVICE=%s|%s|%s\\n' "$svc" "$active" "$enabled"
          done
        fi
        """
    }

    private func parse(_ output: String) -> ServerProfileSnapshot {
        var values: [String: String] = [:]
        var tools: [ServerToolPresence] = []
        var toolIndexByName: [String: Int] = [:]
        var services: [ServerServicePresence] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.hasPrefix("TOOLMETA=") {
                let payload = text.replacingOccurrences(of: "TOOLMETA=", with: "")
                let parts = payload.split(separator: "|", omittingEmptySubsequences: false)
                guard let name = parts.first, let index = toolIndexByName[String(name)] else { continue }
                tools[index].version = parts.count > 1 ? String(parts[1]).nilIfBlank : nil
                if parts.count > 2 {
                    tools[index].allPaths = String(parts[2])
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            } else if text.hasPrefix("TOOL=") {
                let payload = text.replacingOccurrences(of: "TOOL=", with: "")
                let parts = payload.split(separator: "|", omittingEmptySubsequences: false)
                guard let name = parts.first else { continue }
                let path = parts.count > 1 ? String(parts[1]).nilIfBlank : nil
                toolIndexByName[String(name)] = tools.count
                tools.append(ServerToolPresence(name: String(name), path: path))
            } else if text.hasPrefix("SERVICE=") {
                let payload = text.replacingOccurrences(of: "SERVICE=", with: "")
                let parts = payload.split(separator: "|", omittingEmptySubsequences: false)
                guard let name = parts.first else { continue }
                services.append(ServerServicePresence(
                    name: String(name),
                    activeState: parts.count > 1 ? String(parts[1]).nilIfBlank : nil,
                    enabledState: parts.count > 2 ? String(parts[2]).nilIfBlank : nil
                ))
            } else if let equalsIndex = text.firstIndex(of: "=") {
                let key = String(text[..<equalsIndex])
                let value = String(text[text.index(after: equalsIndex)...])
                values[key] = value
            }
        }

        return ServerProfileSnapshot(
            osName: values["OS_NAME"]?.nilIfBlank,
            osID: values["OS_ID"]?.nilIfBlank,
            osVersionID: values["OS_VERSION_ID"]?.nilIfBlank,
            architecture: values["ARCH"]?.nilIfBlank,
            username: values["USER_NAME"]?.nilIfBlank,
            userID: values["USER_ID"]?.nilIfBlank,
            sudoStatus: ServerSudoStatus(rawValue: values["SUDO"] ?? "") ?? .unknown,
            packageManager: ServerPackageManager(rawValue: values["PACKAGE_MANAGER"] ?? "") ?? .unknown,
            initSystem: ServerInitSystem(rawValue: values["INIT_SYSTEM"] ?? "") ?? .unknown,
            tools: tools,
            services: services,
            capturedAt: Date()
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
