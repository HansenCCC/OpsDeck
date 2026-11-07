import CryptoKit
import Foundation
#if canImport(Citadel) && canImport(NIO) && canImport(NIOSSH)
import Citadel
import NIO
@preconcurrency import NIOSSH
#endif

struct KnownHostRecord: Codable, Identifiable, Equatable, Sendable {
    var endpoint: String
    var publicKey: String
    var fingerprint: String
    var trustedAt: Date

    var id: String { endpoint }
}

struct KnownHostChallenge: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case firstUse
        case changed(previousFingerprint: String)
    }

    var endpoint: String
    var publicKey: String
    var fingerprint: String
    var kind: Kind

    var id: String { "\(endpoint)#\(fingerprint)" }
}

private struct KnownHostValidationFailure: Error, Sendable {}

/// A small OpenSSH-style trust-on-first-use store.
///
/// Host-key validation runs synchronously on a NIO event loop, so this store is
/// deliberately lock-backed rather than actor-backed. The first unknown key (or
/// a changed key) is rejected and captured as a challenge. The UI must explicitly
/// trust that challenge before the next connection can succeed.
final class KnownHostStore: @unchecked Sendable {
    static let shared = KnownHostStore()

    private let defaultsKey = "knownHosts.v1"
    private let lock = NSLock()
    private var recordsByEndpoint: [String: KnownHostRecord]
    private var pendingByEndpoint: [String: KnownHostChallenge] = [:]

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: defaultsKey),
           let records = try? JSONDecoder().decode([KnownHostRecord].self, from: data) {
            recordsByEndpoint = Dictionary(uniqueKeysWithValues: records.map { ($0.endpoint, $0) })
        } else {
            recordsByEndpoint = [:]
        }
        self.defaults = defaults
    }

    private let defaults: UserDefaults

    func records() -> [KnownHostRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsByEndpoint.values.sorted { $0.endpoint.localizedStandardCompare($1.endpoint) == .orderedAscending }
    }

    func pendingChallenge(host: String, port: Int) -> KnownHostChallenge? {
        pendingChallenge(endpoint: Self.endpoint(host: host, port: port))
    }

    func pendingChallenge(endpoint: String) -> KnownHostChallenge? {
        lock.lock()
        defer { lock.unlock() }
        return pendingByEndpoint[endpoint]
    }

    func trust(_ challenge: KnownHostChallenge) {
        lock.lock()
        recordsByEndpoint[challenge.endpoint] = KnownHostRecord(
            endpoint: challenge.endpoint,
            publicKey: challenge.publicKey,
            fingerprint: challenge.fingerprint,
            trustedAt: Date()
        )
        pendingByEndpoint[challenge.endpoint] = nil
        persistLocked()
        lock.unlock()
    }

    func reject(_ challenge: KnownHostChallenge) {
        lock.lock()
        if pendingByEndpoint[challenge.endpoint]?.fingerprint == challenge.fingerprint {
            pendingByEndpoint[challenge.endpoint] = nil
        }
        lock.unlock()
    }

    func remove(endpoint: String) {
        lock.lock()
        recordsByEndpoint[endpoint] = nil
        pendingByEndpoint[endpoint] = nil
        persistLocked()
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        recordsByEndpoint.removeAll()
        pendingByEndpoint.removeAll()
        persistLocked()
        lock.unlock()
    }

    #if canImport(Citadel) && canImport(NIO) && canImport(NIOSSH)
    func validator(host: String, port: Int) -> SSHHostKeyValidator {
        let endpoint = Self.endpoint(host: host, port: port)
        lock.lock()
        pendingByEndpoint[endpoint] = nil
        lock.unlock()
        return .custom(KnownHostValidator(store: self, endpoint: endpoint))
    }

    fileprivate func validate(
        hostKey: NIOSSHPublicKey,
        endpoint: String,
        promise: EventLoopPromise<Void>
    ) {
        let publicKey = String(openSSHPublicKey: hostKey)
        let fingerprint = Self.fingerprint(forOpenSSHKey: publicKey)

        lock.lock()
        let existing = recordsByEndpoint[endpoint]
        if existing?.publicKey == publicKey {
            pendingByEndpoint[endpoint] = nil
            lock.unlock()
            promise.succeed(())
            return
        }

        let kind: KnownHostChallenge.Kind
        if let existing {
            kind = .changed(previousFingerprint: existing.fingerprint)
        } else {
            kind = .firstUse
        }
        pendingByEndpoint[endpoint] = KnownHostChallenge(
            endpoint: endpoint,
            publicKey: publicKey,
            fingerprint: fingerprint,
            kind: kind
        )
        lock.unlock()
        promise.fail(KnownHostValidationFailure())
    }
    #endif

    private func persistLocked() {
        let records = Array(recordsByEndpoint.values)
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    private static func endpoint(host: String, port: Int) -> String {
        "\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(port)"
    }

    private static func fingerprint(forOpenSSHKey key: String) -> String {
        let parts = key.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let payload = Data(base64Encoded: String(parts[1])) else {
            return "SHA256:unknown"
        }
        let digest = SHA256.hash(data: payload)
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }
}

#if canImport(Citadel) && canImport(NIO) && canImport(NIOSSH)
private final class KnownHostValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let store: KnownHostStore
    private let endpoint: String

    init(store: KnownHostStore, endpoint: String) {
        self.store = store
        self.endpoint = endpoint
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        store.validate(hostKey: hostKey, endpoint: endpoint, promise: validationCompletePromise)
    }
}
#endif
