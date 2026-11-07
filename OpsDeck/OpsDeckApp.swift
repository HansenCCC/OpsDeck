import SwiftUI
import SwiftData
import AppKit

@main
struct OpsDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appDelegate.appState)
                .modelContainer(appDelegate.appState.storage.container)
                .onAppear {
                    appDelegate.appState.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建服务器") {
                    appDelegate.appState.openNewHostEditor()
                }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("刷新当前工作区") {
                    appDelegate.refreshCurrentWorkspace(nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("剪切") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x")

                Button("复制") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c")

                Button("粘贴") {
                    appDelegate.appState.pasteClipboardIntoActiveContext()
                }
                .keyboardShortcut("v")

                Button("全选") {
                    appDelegate.appState.selectAllInActiveContext()
                }
                .keyboardShortcut("a")
            }
            CommandGroup(replacing: .help) {
                Button("OpsDeck 使用指南") {
                    appDelegate.appState.showHelpGuide()
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
                Divider()
                Button("欢迎与快速入门") {
                    appDelegate.appState.showWelcomeGuide()
                }
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("清除终端显示") {
                    appDelegate.appState.clearActiveTerminalTranscript()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(!appDelegate.appState.isTerminalVisible || appDelegate.appState.selectedTerminalTabID == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}
