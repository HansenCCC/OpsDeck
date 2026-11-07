import StoreKit
import SwiftUI

struct ProUnlockView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpsDeck Pro")
                        .font(Theme.Font.windowTitle)
                    Text("当前版本已默认开放全部功能。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ProFeatureRow(text: String(localized: "不限服务器数量"))
                ProFeatureRow(text: String(localized: "上传文件并保留传输历史"))
                ProFeatureRow(text: String(localized: "命令片段和最近命令记录"))
                ProFeatureRow(text: String(localized: "Touch ID 安全选项"))
            }

            Divider().overlay(Theme.Color.separator)

            if let message = appState.purchaseService.lastMessage {
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            HStack {
                Button {
                    appState.purchasePro()
                } label: {
                    Text(appState.purchaseService.lifetimeProduct?.displayPrice ?? String(localized: "已开放"))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.purchaseService.isLoading)

                Button("恢复购买") {
                    appState.restorePurchases()
                }
                .disabled(appState.purchaseService.isLoading)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 420)
        .task {
            await appState.purchaseService.loadProducts()
        }
    }
}

private struct ProFeatureRow: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Color.success)
            Text(text)
                .font(Theme.Font.body)
        }
    }
}
