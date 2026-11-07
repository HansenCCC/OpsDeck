import SwiftUI

struct HostKeyTrustView: View {
    @EnvironmentObject private var appState: AppState
    let challenge: KnownHostChallenge

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Image(systemName: isChanged ? "exclamationmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(isChanged ? Theme.Color.danger : Theme.Color.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(isChanged ? String(localized: "服务器身份已变化") : String(localized: "确认服务器身份"))
                        .font(Theme.Font.windowTitle)
                    Text(summary)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                keyValue(String(localized: "服务器"), challenge.endpoint)
                if case .changed(let previousFingerprint) = challenge.kind {
                    keyValue(String(localized: "原指纹"), previousFingerprint)
                }
                keyValue(String(localized: "当前指纹"), challenge.fingerprint)
            }
            .padding(Theme.Space.md)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.panel).fill(Theme.Color.surfaceRaised))

            if isChanged {
                Label(
                    String(localized: "Host Key 变化可能来自服务器重装，也可能表示连接被劫持。请先通过可信渠道核对指纹。"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.danger)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("OpsDeck 会把这个指纹保存在本机。以后指纹不一致时会自动阻止连接。")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") {
                    appState.rejectPendingHostKey()
                }
                .keyboardShortcut(.cancelAction)
                Button(isChanged ? String(localized: "替换并继续") : String(localized: "信任并继续"), role: isChanged ? .destructive : nil) {
                    appState.trustPendingHostKey()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        .background(Theme.Color.surface)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
    }

    private var isChanged: Bool {
        if case .changed = challenge.kind { return true }
        return false
    }

    private var summary: String {
        if isChanged {
            return String(localized: "为保护连接，OpsDeck 已阻止继续认证。只有在确认服务器确实更换过 SSH Host Key 后才能替换记录。")
        }
        return String(localized: "这是 OpsDeck 第一次连接这台服务器。请核对下面的 SHA-256 指纹。")
    }

    private func keyValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(Theme.Font.monoSmall)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
