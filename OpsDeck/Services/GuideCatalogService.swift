import Foundation

/// Curated, beginner-friendly command guides plus an on-demand `--help`/`man`
/// fetch for any installed tool. Hybrid model: hand-written深度 topics for the
/// high-frequency tools, and a dynamic "tools" list derived from the installer
/// catalog so every tool is at least reachable.
struct GuideCatalogService {

    // MARK: Curated topics

    func topics() -> [GuideTopic] {
        [
            quickstartTopic,
            shellTopic,
            filesTopic,
            textSearchTopic,
            processTopic,
            networkTopic,
            permissionTopic,
            serviceTopic,
            nginxTopic,
            dockerTopic,
            gitTopic,
            databaseTopic
        ]
    }

    /// Build "已安装工具速查" cards from the installer catalog. Each maps to a
    /// `--help` lookup. Tools that already have a curated topic are skipped to
    /// avoid duplication.
    func toolTopics(from catalog: [ToolDefinition]) -> [GuideTopic] {
        let curatedToolIDs: Set<String> = ["nginx", "docker", "git"]
        return catalog
            .filter { !curatedToolIDs.contains($0.id) }
            .map { tool in
                GuideTopic(
                    id: "tool-\(tool.id)",
                    title: tool.name,
                    category: .tools,
                    summary: tool.description,
                    toolID: tool.id,
                    helpBinary: tool.binaryNames.first
                )
            }
    }

    /// Read-only plan that fetches a tool's own help text from the server.
    /// Tries `--help`, then `-h`, then `man`. Never modifies anything.
    func helpPlan(binary: String, title: String) -> RunbookPlan {
        let bin = OpsShell.quote(binary)
        let command = """
        if ! command -v \(bin) >/dev/null 2>&1; then
          echo \(OpsShell.quote(String(localized: "未在服务器上找到 \(binary)，可先到「工具」页安装。")))
          exit 1
        fi
        echo \(OpsShell.quote(String(localized: "===== \(binary) 帮助 =====")))
        # Branch on the command's own exit status — piping to `head` would mask it
        # and make the -h / man fallbacks dead code.
        out=""
        if o="$(\(bin) --help 2>&1)"; then out="$o"
        elif o="$(\(bin) -h 2>&1)"; then out="$o"
        fi
        if [ -n "$out" ]; then
          printf '%s\\n' "$out" | head -n 200
        else
          echo "===== man \(binary) ====="
          man \(bin) 2>/dev/null | col -b | head -n 200
        fi
        """
        return RunbookPlan(
            kind: .dryRun,
            title: String(localized: "\(title) 帮助"),
            summary: String(localized: "在服务器上读取 \(binary) 的 --help / man 文档（只读）。"),
            targetDescription: binary,
            risk: .readOnly,
            requiresSudo: false,
            backupDescription: nil,
            rollbackDescription: nil,
            steps: [RunbookStep(title: String(localized: "读取 \(binary) 帮助"), command: command)]
        )
    }

    // MARK: - Curated content

    private var quickstartTopic: GuideTopic {
        GuideTopic(
            id: "quickstart",
            title: String(localized: "第一次连上服务器"),
            category: .quickstart,
            summary: String(localized: "刚拿到一台 Linux 服务器，先搞清楚「我是谁、在哪、有什么」。下面几条命令是每次登录后最常用的。"),
            quickStart: [
                GuideCommand("whoami", String(localized: "显示当前登录的用户名。")),
                GuideCommand("pwd", String(localized: "显示当前所在目录（print working directory）。")),
                GuideCommand("ls -lah", String(localized: "列出当前目录下所有文件，含隐藏文件、权限和大小。")),
                GuideCommand("df -h", String(localized: "查看磁盘剩余空间（-h 用人类可读的 GB/MB 单位）。")),
                GuideCommand("free -h", String(localized: "查看内存使用情况。")),
                GuideCommand("uname -a", String(localized: "查看内核与系统架构信息。"))
            ],
            sections: [
                GuideSection(String(localized: "看清系统信息"), [
                    GuideCommand("cat /etc/os-release", String(localized: "查看发行版名称与版本（Ubuntu/CentOS 等）。")),
                    GuideCommand("uptime", String(localized: "系统已运行多久、当前负载。")),
                    GuideCommand("top", String(localized: "实时查看进程与资源占用，按 q 退出。"))
                ]),
                GuideSection(String(localized: "获取任何命令的帮助"), [
                    GuideCommand(String(localized: "<命令> --help"), String(localized: "绝大多数命令都支持，快速看用法。"), example: "ls --help"),
                    GuideCommand(String(localized: "man <命令>"), String(localized: "查看完整手册，按 q 退出、/关键词 搜索。"), example: "man tar")
                ])
            ]
        )
    }

    private var shellTopic: GuideTopic {
        GuideTopic(
            id: "shell",
            title: String(localized: "Shell 基础导航"),
            category: .shell,
            summary: String(localized: "在终端里「走路」——切换目录、看当前位置、用快捷键提高效率。"),
            quickStart: [
                GuideCommand("cd /var/www", String(localized: "进入指定目录（change directory）。")),
                GuideCommand("cd ..", String(localized: "回到上一级目录。")),
                GuideCommand("cd ~", String(localized: "回到当前用户的家目录，等同于 cd 不带参数。")),
                GuideCommand("cd -", String(localized: "回到上一次所在的目录。")),
                GuideCommand("ls -lah", String(localized: "详细列出目录内容。"))
            ],
            sections: [
                GuideSection(String(localized: "路径与通配符"), [
                    GuideCommand(".", String(localized: "代表当前目录。")),
                    GuideCommand("..", String(localized: "代表上一级目录。")),
                    GuideCommand("~", String(localized: "代表家目录，如 ~/logs。")),
                    GuideCommand("*", String(localized: "通配任意字符，如 ls *.log 列出所有 .log 文件。"))
                ]),
                GuideSection(String(localized: "效率快捷键"), [
                    GuideCommand("Tab", String(localized: "自动补全命令或路径，最常用。")),
                    GuideCommand("Ctrl + C", String(localized: "中断当前正在运行的命令。")),
                    GuideCommand("Ctrl + R", String(localized: "反向搜索历史命令，输入关键字即可。")),
                    GuideCommand("history", String(localized: "查看执行过的命令历史。")),
                    GuideCommand("!!", String(localized: "重复执行上一条命令，常配 sudo：sudo !!"))
                ])
            ]
        )
    }

    private var filesTopic: GuideTopic {
        GuideTopic(
            id: "files",
            title: String(localized: "文件与目录操作"),
            category: .files,
            summary: String(localized: "增删改查文件、打包解压。删除操作不可撤销，务必看清路径。"),
            quickStart: [
                GuideCommand("mkdir -p a/b/c", String(localized: "创建目录，-p 会自动创建多级父目录。")),
                GuideCommand(String(localized: "cp -r 源 目标"), String(localized: "复制文件或目录（-r 递归复制目录）。")),
                GuideCommand(String(localized: "mv 源 目标"), String(localized: "移动或重命名文件。")),
                GuideCommand(String(localized: "rm 文件"), String(localized: "删除文件；rm -r 目录 删除目录（危险，不可恢复）。")),
                GuideCommand(String(localized: "cat 文件"), String(localized: "打印文件全部内容。"))
            ],
            sections: [
                GuideSection(String(localized: "查看文件内容"), [
                    GuideCommand(String(localized: "less 文件"), String(localized: "分页查看大文件，q 退出、/ 搜索。")),
                    GuideCommand(String(localized: "head -n 50 文件"), String(localized: "看开头 50 行。")),
                    GuideCommand(String(localized: "tail -n 50 文件"), String(localized: "看结尾 50 行。")),
                    GuideCommand(String(localized: "tail -f 文件"), String(localized: "实时跟随文件新增内容，看日志利器。"))
                ]),
                GuideSection(String(localized: "打包与压缩"), [
                    GuideCommand(String(localized: "tar -czvf out.tar.gz 目录"), String(localized: "把目录打包成 .tar.gz。")),
                    GuideCommand("tar -xzvf out.tar.gz", String(localized: "解压 .tar.gz。")),
                    GuideCommand(String(localized: "zip -r out.zip 目录"), String(localized: "打包成 zip。")),
                    GuideCommand("unzip out.zip", String(localized: "解压 zip。"))
                ]),
                GuideSection(String(localized: "查找文件与占用"), [
                    GuideCommand("find . -name '*.conf'", String(localized: "在当前目录递归查找 .conf 文件。")),
                    GuideCommand("du -sh *", String(localized: "查看每个文件/目录的大小。")),
                    GuideCommand("ncdu", String(localized: "交互式磁盘占用分析（需安装）。"))
                ])
            ]
        )
    }

    private var textSearchTopic: GuideTopic {
        GuideTopic(
            id: "text-search",
            title: String(localized: "文本查看与搜索"),
            category: .textSearch,
            summary: String(localized: "在文件和输出里找内容、做替换。grep 是每天都会用到的工具。"),
            quickStart: [
                GuideCommand(String(localized: "grep 关键字 文件"), String(localized: "在文件中搜索包含关键字的行。")),
                GuideCommand(String(localized: "grep -r 关键字 目录"), String(localized: "在整个目录递归搜索。")),
                GuideCommand(String(localized: "grep -i 关键字 文件"), String(localized: "忽略大小写搜索。")),
                GuideCommand(String(localized: "grep -n 关键字 文件"), String(localized: "显示匹配行的行号。"))
            ],
            sections: [
                GuideSection(String(localized: "管道组合"), [
                    GuideCommand(String(localized: "命令 | grep 关键字"), String(localized: "过滤前一个命令的输出。"), example: "ps aux | grep nginx"),
                    GuideCommand(String(localized: "命令 | less"), String(localized: "把长输出分页查看。")),
                    GuideCommand(String(localized: "命令 | wc -l"), String(localized: "统计输出有多少行。"))
                ]),
                GuideSection(String(localized: "更强的搜索"), [
                    GuideCommand(String(localized: "rg 关键字"), String(localized: "ripgrep，比 grep 快很多（需安装）。")),
                    GuideCommand(String(localized: "sed -n '10,20p' 文件"), String(localized: "只打印第 10–20 行。")),
                    GuideCommand(String(localized: "awk '{print $1}' 文件"), String(localized: "按列提取，打印每行第一列。"))
                ])
            ]
        )
    }

    private var processTopic: GuideTopic {
        GuideTopic(
            id: "process",
            title: String(localized: "进程与资源"),
            category: .process,
            summary: String(localized: "看什么在跑、占了多少 CPU/内存，必要时结束进程。"),
            quickStart: [
                GuideCommand("top", String(localized: "实时进程监控，按 q 退出。")),
                GuideCommand("htop", String(localized: "更友好的彩色进程监控（需安装）。")),
                GuideCommand(String(localized: "ps aux | grep 名字"), String(localized: "查找某个进程。")),
                GuideCommand("kill <PID>", String(localized: "结束指定进程；kill -9 <PID> 强制结束。"))
            ],
            sections: [
                GuideSection(String(localized: "定位资源占用"), [
                    GuideCommand("ps aux --sort=-%cpu | head", String(localized: "按 CPU 占用排序看前几名。")),
                    GuideCommand("ps aux --sort=-%mem | head", String(localized: "按内存占用排序。")),
                    GuideCommand("free -h", String(localized: "内存总量与剩余。"))
                ]),
                GuideSection(String(localized: "按名字结束进程"), [
                    GuideCommand(String(localized: "pkill 名字"), String(localized: "按进程名结束。")),
                    GuideCommand(String(localized: "pgrep -a 名字"), String(localized: "按名字查 PID 与命令行。"))
                ])
            ]
        )
    }

    private var networkTopic: GuideTopic {
        GuideTopic(
            id: "network",
            title: String(localized: "网络排查"),
            category: .network,
            summary: String(localized: "查端口、测连通、看谁占用了端口。部署 Web 服务时高频使用。"),
            quickStart: [
                GuideCommand("ss -tulnp", String(localized: "查看所有监听中的端口和对应进程。")),
                GuideCommand("curl -I http://localhost", String(localized: "只看 HTTP 响应头，测本地服务是否起来。")),
                GuideCommand("ping -c 4 host", String(localized: "测试到某主机的连通性，发 4 个包。")),
                GuideCommand(String(localized: "dig 域名"), String(localized: "查询域名解析（需 dnsutils）。"))
            ],
            sections: [
                GuideSection(String(localized: "端口与占用"), [
                    GuideCommand("ss -tlnp | grep :80", String(localized: "看 80 端口被谁占用。")),
                    GuideCommand("lsof -i :3000", String(localized: "看 3000 端口的进程（需 lsof）。")),
                    GuideCommand("netstat -tulnp", String(localized: "老牌端口查看（需 net-tools）。"))
                ]),
                GuideSection(String(localized: "下载与测试"), [
                    GuideCommand("curl -O URL", String(localized: "下载文件保留原名。")),
                    GuideCommand("wget URL", String(localized: "下载文件。")),
                    GuideCommand("curl -v URL", String(localized: "显示完整请求/响应过程，排查连接问题。"))
                ])
            ]
        )
    }

    private var permissionTopic: GuideTopic {
        GuideTopic(
            id: "permission",
            title: String(localized: "权限与用户"),
            category: .permission,
            summary: String(localized: "Linux 用「读/写/执行」三种权限管理文件。权限不对是新手最常见的报错来源。"),
            quickStart: [
                GuideCommand("ls -l", String(localized: "查看文件权限，如 -rw-r--r--。")),
                GuideCommand(String(localized: "chmod +x 脚本"), String(localized: "给文件加可执行权限。")),
                GuideCommand(String(localized: "chmod 644 文件"), String(localized: "设为「所有者可读写、其他人只读」。")),
                GuideCommand(String(localized: "chown user:group 文件"), String(localized: "修改文件所有者与组。"))
            ],
            sections: [
                GuideSection(String(localized: "sudo 提权"), [
                    GuideCommand(String(localized: "sudo 命令"), String(localized: "以管理员权限执行单条命令。")),
                    GuideCommand("sudo -i", String(localized: "切换到 root 交互式会话（谨慎）。")),
                    GuideCommand("sudo !!", String(localized: "用 sudo 重跑上一条因权限失败的命令。"))
                ]),
                GuideSection(String(localized: "权限数字含义"), [
                    GuideCommand("7 = rwx", String(localized: "读(4)+写(2)+执行(1)。")),
                    GuideCommand("6 = rw-", String(localized: "读+写，无执行，常用于普通文件。")),
                    GuideCommand("5 = r-x", String(localized: "读+执行，常用于目录/脚本。"))
                ])
            ]
        )
    }

    private var serviceTopic: GuideTopic {
        GuideTopic(
            id: "service",
            title: String(localized: "systemd 服务管理"),
            category: .service,
            summary: String(localized: "现代 Linux 用 systemctl 管理服务（nginx、docker、数据库等）的启停与开机自启。"),
            quickStart: [
                GuideCommand("systemctl status nginx", String(localized: "查看服务状态与最近日志。")),
                GuideCommand("sudo systemctl start nginx", String(localized: "启动服务。")),
                GuideCommand("sudo systemctl restart nginx", String(localized: "重启服务。")),
                GuideCommand("sudo systemctl enable nginx && sudo systemctl start nginx && systemctl is-active nginx", String(localized: "设为开机自启并立即启动。"))
            ],
            sections: [
                GuideSection(String(localized: "常用操作"), [
                    GuideCommand(String(localized: "sudo systemctl stop 服务"), String(localized: "停止服务。")),
                    GuideCommand(String(localized: "sudo systemctl reload 服务"), String(localized: "热重载配置（不中断，nginx 常用）。")),
                    GuideCommand(String(localized: "systemctl is-active 服务"), String(localized: "只返回 active/inactive。")),
                    GuideCommand("systemctl list-units --type=service", String(localized: "列出所有服务。"))
                ]),
                GuideSection(String(localized: "查服务日志"), [
                    GuideCommand("journalctl -u nginx -n 100", String(localized: "看某服务最近 100 行日志。")),
                    GuideCommand("journalctl -u nginx -f", String(localized: "实时跟随服务日志。")),
                    GuideCommand("journalctl -p err -b", String(localized: "只看本次启动以来的错误。"))
                ])
            ]
        )
    }

    private var nginxTopic: GuideTopic {
        GuideTopic(
            id: "nginx",
            title: String(localized: "Nginx 常用运维"),
            category: .nginx,
            summary: String(localized: "Web 服务器与反向代理。改配置后一定先 nginx -t 测试再 reload，避免线上中断。"),
            quickStart: [
                GuideCommand("sudo nginx -t", String(localized: "测试配置语法是否正确，改配置后必做。")),
                GuideCommand("sudo systemctl reload nginx", String(localized: "热重载配置，不中断现有连接。")),
                GuideCommand("sudo nginx -s reload", String(localized: "同上，直接通过 nginx 命令重载。")),
                GuideCommand("nginx -v", String(localized: "查看 Nginx 版本。"))
            ],
            sections: [
                GuideSection(String(localized: "配置文件位置"), [
                    GuideCommand("/etc/nginx/nginx.conf", String(localized: "主配置文件。")),
                    GuideCommand("/etc/nginx/sites-available/", String(localized: "站点配置（Debian/Ubuntu）。")),
                    GuideCommand("/etc/nginx/sites-enabled/", String(localized: "已启用站点，通常是 available 的软链。")),
                    GuideCommand("/etc/nginx/conf.d/", String(localized: "另一种站点/片段目录（CentOS 常用）。"))
                ]),
                GuideSection(String(localized: "启用一个新站点"), [
                    GuideCommand("sudo ln -s /etc/nginx/sites-available/x /etc/nginx/sites-enabled/", String(localized: "软链到 enabled 目录启用站点。")),
                    GuideCommand("sudo nginx -t && sudo systemctl reload nginx", String(localized: "测试并重载，一步到位。")),
                    GuideCommand("tail -f /var/log/nginx/error.log", String(localized: "实时看错误日志排查 502/404。"))
                ])
            ],
            toolID: "nginx",
            externalDoc: "https://nginx.org/en/docs/"
        )
    }

    private var dockerTopic: GuideTopic {
        GuideTopic(
            id: "docker",
            title: String(localized: "Docker 常用命令"),
            category: .docker,
            summary: String(localized: "容器化运行应用。镜像是「模板」，容器是「运行中的实例」。"),
            quickStart: [
                GuideCommand("docker ps", String(localized: "查看运行中的容器；docker ps -a 含已停止的。")),
                GuideCommand("docker images", String(localized: "列出本地镜像。")),
                GuideCommand(String(localized: "docker logs -f 容器名"), String(localized: "实时查看容器日志。")),
                GuideCommand(String(localized: "docker exec -it 容器名 sh"), String(localized: "进入容器内部的 shell。"))
            ],
            sections: [
                GuideSection(String(localized: "容器生命周期"), [
                    GuideCommand("docker run -d -p 8080:80 nginx", String(localized: "后台运行并映射端口（宿主 8080→容器 80）。")),
                    GuideCommand(String(localized: "docker stop / start / restart 容器"), String(localized: "停止/启动/重启容器。")),
                    GuideCommand(String(localized: "docker rm -f 容器"), String(localized: "强制删除容器。")),
                    GuideCommand(String(localized: "docker inspect 容器"), String(localized: "查看容器详细配置。"))
                ]),
                GuideSection(String(localized: "镜像与清理"), [
                    GuideCommand(String(localized: "docker pull 镜像:标签"), String(localized: "拉取镜像。")),
                    GuideCommand(String(localized: "docker rmi 镜像"), String(localized: "删除镜像。")),
                    GuideCommand("docker system df", String(localized: "查看磁盘占用。")),
                    GuideCommand("docker system prune -f", String(localized: "清理停止的容器、悬空镜像、无用网络。"))
                ]),
                GuideSection("Docker Compose", [
                    GuideCommand("docker compose up -d", String(localized: "按 compose 文件后台启动整套服务。")),
                    GuideCommand("docker compose down", String(localized: "停止并移除整套服务。")),
                    GuideCommand("docker compose logs -f", String(localized: "跟随所有服务日志。"))
                ])
            ],
            toolID: "docker",
            externalDoc: "https://docs.docker.com/"
        )
    }

    private var gitTopic: GuideTopic {
        GuideTopic(
            id: "git",
            title: String(localized: "Git 基础"),
            category: .git,
            summary: String(localized: "版本控制。在服务器上多用于拉取和更新代码。"),
            quickStart: [
                GuideCommand("git clone URL", String(localized: "克隆一个仓库到本地。")),
                GuideCommand("git pull", String(localized: "拉取并合并远端最新代码。")),
                GuideCommand("git status", String(localized: "查看当前改动。")),
                GuideCommand("git log --oneline -10", String(localized: "看最近 10 条提交。"))
            ],
            sections: [
                GuideSection(String(localized: "提交改动"), [
                    GuideCommand("git add .", String(localized: "把所有改动加入暂存区。")),
                    GuideCommand(String(localized: "git commit -m '说明'"), String(localized: "提交暂存的改动。")),
                    GuideCommand("git push", String(localized: "推送到远端。"))
                ]),
                GuideSection(String(localized: "分支"), [
                    GuideCommand("git branch", String(localized: "列出本地分支。")),
                    GuideCommand(String(localized: "git checkout -b 新分支"), String(localized: "创建并切换到新分支。")),
                    GuideCommand(String(localized: "git switch 分支"), String(localized: "切换分支（较新写法）。"))
                ])
            ],
            toolID: "git",
            externalDoc: "https://git-scm.com/doc"
        )
    }

    private var databaseTopic: GuideTopic {
        GuideTopic(
            id: "database",
            title: String(localized: "数据库客户端"),
            category: .database,
            summary: String(localized: "在服务器上连接常见数据库做只读查询与排查。生产环境改数据前务必备份。"),
            quickStart: [
                GuideCommand("sudo -u postgres psql", String(localized: "以 postgres 用户进入 PostgreSQL 交互终端。")),
                GuideCommand("mysql -u root -p", String(localized: "连接 MySQL/MariaDB（会提示输入密码）。")),
                GuideCommand("redis-cli", String(localized: "进入 Redis 交互终端。")),
                GuideCommand("redis-cli INFO", String(localized: "查看 Redis 运行信息。"))
            ],
            sections: [
                GuideSection(String(localized: "PostgreSQL 常用"), [
                    GuideCommand("\\l", String(localized: "列出所有数据库（在 psql 内）。")),
                    GuideCommand(String(localized: "\\c 数据库"), String(localized: "切换到某个数据库。")),
                    GuideCommand("\\dt", String(localized: "列出当前库的所有表。")),
                    GuideCommand("\\q", String(localized: "退出 psql。"))
                ]),
                GuideSection(String(localized: "MySQL 常用"), [
                    GuideCommand("SHOW DATABASES;", String(localized: "列出所有数据库。")),
                    GuideCommand(String(localized: "USE 数据库;"), String(localized: "选择数据库。")),
                    GuideCommand("SHOW TABLES;", String(localized: "列出当前库的表。")),
                    GuideCommand(String(localized: "SELECT * FROM 表 LIMIT 10;"), String(localized: "预览表数据前 10 行。"))
                ]),
                GuideSection(String(localized: "安全提醒"), [
                    GuideCommand(String(localized: "先备份再改"), String(localized: "UPDATE/DELETE 前先 mysqldump / pg_dump 备份。")),
                    GuideCommand(String(localized: "加 WHERE + LIMIT"), String(localized: "避免全表误删/误改。"))
                ])
            ]
        )
    }
}
