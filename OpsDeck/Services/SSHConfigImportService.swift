import Foundation

struct SSHConfigEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var alias: String
    var hostname: String
    var port: Int
    var username: String
    var identityFile: String?
    var privateKeyText: String?

    init(
        id: UUID = UUID(),
        alias: String,
        hostname: String,
        port: Int = 22,
        username: String,
        identityFile: String? = nil,
        privateKeyText: String? = nil
    ) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.privateKeyText = privateKeyText
    }
}

enum SSHConfigImportError: LocalizedError {
    case unreadable
    case noConcreteHosts

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "无法读取 SSH Config 文件。")
        case .noConcreteHosts:
            return String(localized: "没有发现可导入的具体 Host；通配符配置不会作为服务器导入。")
        }
    }
}

struct SSHConfigImportService {
    private struct Block {
        var patterns: [String]
        var values: [String: String]
    }

    func parse(url: URL) throws -> [SSHConfigEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw SSHConfigImportError.unreadable
        }
        let parsed = parse(text: text)
        guard !parsed.isEmpty else { throw SSHConfigImportError.noConcreteHosts }
        return parsed
    }

    func parse(text: String) -> [SSHConfigEntry] {
        var blocks: [Block] = [Block(patterns: ["*"], values: [:])]
        var currentIndex = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = tokenize(line)
            guard let key = parts.first?.lowercased(), parts.count > 1 else { continue }
            if key == "host" {
                blocks.append(Block(patterns: Array(parts.dropFirst()), values: [:]))
                currentIndex = blocks.count - 1
                continue
            }
            let joined = parts.dropFirst().joined(separator: " ")
            if blocks[currentIndex].values[key] == nil { blocks[currentIndex].values[key] = joined }
        }

        let aliases = blocks.flatMap(\.patterns).filter(isConcrete)
        let output = aliases.map { alias -> SSHConfigEntry in
            var resolved: [String: String] = [:]
            for block in blocks where matches(alias: alias, patterns: block.patterns) {
                // OpenSSH resolves the first value obtained for each parameter.
                for (key, value) in block.values where resolved[key] == nil {
                    resolved[key] = value
                }
            }
            let hostname = resolved["hostname"] ?? alias
            let port = Int(resolved["port"] ?? "22") ?? 22
            let username = resolved["user"] ?? NSUserName()
            let identity = resolved["identityfile"].map(expandIdentityPath)
            let keyText = identity.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            return SSHConfigEntry(
                alias: alias,
                hostname: hostname,
                port: port,
                username: username,
                identityFile: identity,
                privateKeyText: keyText
            )
        }

        var seen = Set<String>()
        return output.filter { entry in
            let key = "\(entry.username.lowercased())@\(entry.hostname.lowercased()):\(entry.port)"
            return seen.insert(key).inserted
        }
    }

    private func isConcrete(_ alias: String) -> Bool {
        !alias.hasPrefix("!") && !alias.contains("*") && !alias.contains("?")
    }

    private func matches(alias: String, patterns: [String]) -> Bool {
        var positiveMatch = false
        for rawPattern in patterns {
            let isNegative = rawPattern.hasPrefix("!")
            let pattern = isNegative ? String(rawPattern.dropFirst()) : rawPattern
            guard wildcardMatch(alias, pattern: pattern) else { continue }
            if isNegative { return false }
            positiveMatch = true
        }
        return positiveMatch
    }

    private func wildcardMatch(_ value: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(escaped)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func expandIdentityPath(_ path: String) -> String {
        let unquoted = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "%d", with: NSHomeDirectory())
        if unquoted == "~" { return NSHomeDirectory() }
        if unquoted.hasPrefix("~/") {
            return NSHomeDirectory() + String(unquoted.dropFirst())
        }
        if unquoted.hasPrefix("/") { return unquoted }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(unquoted).path
    }

    private func stripComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote ?? character)
            } else if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote ?? character)
            } else if character.isWhitespace, quote == nil {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
