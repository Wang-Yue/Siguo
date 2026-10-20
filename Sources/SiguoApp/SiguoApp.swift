import AppKit
import SwiftUI
import SiguoCore

@main
struct SiguoApp: App {
    @State private var viewModel = GameViewModel()

    init() {
        // 確保以 `swift run` 啟動時能作為標準 macOS 視窗應用置前顯示
        Task { @MainActor in
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("四國軍棋 (Siguo Junqi)") {
            MainGameWindowView(viewModel: viewModel)
                .frame(minWidth: 1080, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1220, height: 860)
        .commands {
            CommandMenu("牌局操作") {
                Button("開啟新局（返回佈陣）") {
                    viewModel.resetToNewSetup()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("悔棋（退回玩家回合）") {
                    viewModel.undoToPreviousHumanTurn()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!viewModel.canUndo)

                Divider()

                Button(viewModel.godModeEnabled ? "關閉上帝透視視角" : "開啟上帝透視視角") {
                    viewModel.godModeEnabled.toggle()
                }
                .keyboardShortcut("g", modifiers: [.command])
            }
        }
    }
}

/// 主視窗佈局（左側 17x17 棋盤畫布 + 右側統帥控制面板）
struct MainGameWindowView: View {
    @Bindable var viewModel: GameViewModel

    var body: some View {
        HStack(spacing: 0) {
            BoardCanvasView(viewModel: viewModel)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            SidebarControlView(viewModel: viewModel)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
