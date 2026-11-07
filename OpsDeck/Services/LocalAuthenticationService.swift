import Foundation
import LocalAuthentication

enum LocalAuthenticationServiceError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return String(
                format: String(localized: "Touch ID 当前不可用：%@"),
                detail
            )
        case .cancelled:
            return String(localized: "已取消 Touch ID 验证。")
        case .failed(let detail):
            return String(
                format: String(localized: "Touch ID 验证失败：%@"),
                detail
            )
        }
    }
}

final class LocalAuthenticationService: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAuthenticatedAt: Date?
    private let reuseInterval: TimeInterval = 5 * 60

    func availability() -> (available: Bool, detail: String) {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if available {
            return (true, String(localized: "可用；解锁后 5 分钟内不重复验证。"))
        }
        return (false, Self.humanReadable(error))
    }

    func authenticate(reason: String, force: Bool = false) async throws {
        if !force, hasReusableAuthentication() { return }

        let context = LAContext()
        context.localizedCancelTitle = String(localized: "取消")
        context.touchIDAuthenticationAllowableReuseDuration = reuseInterval
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &availabilityError) else {
            throw LocalAuthenticationServiceError.unavailable(Self.humanReadable(availabilityError))
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            guard success else {
                throw LocalAuthenticationServiceError.failed(String(localized: "系统没有确认身份。"))
            }
            lock.withLock {
                lastAuthenticatedAt = Date()
            }
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                throw LocalAuthenticationServiceError.cancelled
            default:
                throw LocalAuthenticationServiceError.failed(Self.humanReadable(error as NSError))
            }
        } catch let error as LocalAuthenticationServiceError {
            throw error
        } catch {
            throw LocalAuthenticationServiceError.failed(error.localizedDescription)
        }
    }

    func invalidateReuse() {
        lock.withLock {
            lastAuthenticatedAt = nil
        }
    }

    private func hasReusableAuthentication() -> Bool {
        lock.withLock {
            guard let lastAuthenticatedAt else { return false }
            return Date().timeIntervalSince(lastAuthenticatedAt) < reuseInterval
        }
    }

    private static func humanReadable(_ error: NSError?) -> String {
        guard let error else { return String(localized: "这台 Mac 没有可用的生物识别。") }
        switch LAError.Code(rawValue: error.code) {
        case .biometryNotAvailable:
            return String(localized: "这台 Mac 没有可用的 Touch ID。")
        case .biometryNotEnrolled:
            return String(localized: "请先在系统设置中录入 Touch ID。")
        case .biometryLockout:
            return String(localized: "Touch ID 已锁定，请先用系统密码解锁。")
        case .passcodeNotSet:
            return String(localized: "请先设置系统登录密码。")
        default:
            return error.localizedDescription
        }
    }
}
