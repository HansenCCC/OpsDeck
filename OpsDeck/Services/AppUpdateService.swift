import Foundation

struct AppStoreRelease: Equatable, Sendable {
    let version: String
    let storeURL: URL?
}

enum AppVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateParts = numericParts(candidate),
              let currentParts = numericParts(current) else { return false }

        let componentCount = max(candidateParts.count, currentParts.count)
        for index in 0..<componentCount {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    private static func numericParts(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        let parts = components.compactMap { component -> Int? in
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber) else { return nil }
            return Int(component)
        }
        return parts.count == components.count ? parts : nil
    }
}

enum AppUpdatePolicy {
    static let automaticInterval: TimeInterval = 24 * 60 * 60
    static let ignoredVersionKey = "appUpdate.ignoredVersion.v1"
    static let lastPromptVersionKey = "appUpdate.lastPromptVersion.v1"
    static let lastPromptDateKey = "appUpdate.lastPromptDate.v1"
    static let lastLookupDateKey = "appUpdate.lastLookupDate.v1"

    static func shouldPerformAutomaticLookup(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let lastLookup = defaults.object(forKey: lastLookupDateKey) as? Date else {
            return true
        }
        return now.timeIntervalSince(lastLookup) >= automaticInterval
    }

    static func recordLookupAttempt(
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        defaults.set(date, forKey: lastLookupDateKey)
    }

    static func shouldPresent(
        latestVersion: String,
        currentVersion: String,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard AppVersion.isNewer(latestVersion, than: currentVersion),
              defaults.string(forKey: ignoredVersionKey) != latestVersion else {
            return false
        }

        guard defaults.string(forKey: lastPromptVersionKey) == latestVersion,
              let lastPrompt = defaults.object(forKey: lastPromptDateKey) as? Date else {
            return true
        }
        return now.timeIntervalSince(lastPrompt) >= automaticInterval
    }

    static func recordPresented(
        version: String,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        defaults.set(version, forKey: lastPromptVersionKey)
        defaults.set(date, forKey: lastPromptDateKey)
    }

    static func ignore(version: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: ignoredVersionKey)
    }
}

actor AppUpdateService {
    enum LookupError: Error {
        case invalidResponse
    }

    private struct LookupResponse: Decodable {
        let results: [LookupResult]
    }

    private struct LookupResult: Decodable {
        let version: String
        let trackViewUrl: String?
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    func latestRelease(appID: String) async throws -> AppStoreRelease? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "id", value: appID),
            URLQueryItem(name: "entity", value: "macSoftware"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else { throw LookupError.invalidResponse }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LookupError.invalidResponse
        }

        return try Self.decodeRelease(from: data)
    }

    static func decodeRelease(from data: Data) throws -> AppStoreRelease? {
        guard let result = try JSONDecoder().decode(LookupResponse.self, from: data).results.first else {
            return nil
        }
        return AppStoreRelease(
            version: result.version,
            storeURL: validAppStoreURL(result.trackViewUrl)
        )
    }

    private static func validAppStoreURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "apple.com" || host.hasSuffix(".apple.com") else {
            return nil
        }
        return url
    }
}
