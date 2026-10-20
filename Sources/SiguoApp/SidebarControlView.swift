import SwiftUI
import SiguoCore

/// 右側戰術控制、佈陣管理、復盤與戰報面板
public struct SidebarControlView: View {
    @Bindable var viewModel: GameViewModel
    @State private var customFormationName: String = ""

    public init(viewModel: GameViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerStatusCard
                playerCountGrid

                if viewModel.state.phase == .setup {
                    setupControlsSection
                    savedFormationsSection
                } else {
                    matchControlsSection
                    replayTimelineSection
                }

                battleLogSection
            }
            .padding(14)
        }
        .frame(minWidth: 330, idealWidth: 360, maxWidth: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 頂部局勢卡片

    private var headerStatusCard: some View {
        let state = viewModel.displayedState
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("四國軍棋・統帥指揮部")
                    .font(.headline.weight(.bold))
                Spacer()
                Text(phaseBadgeTitle(state.phase))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(phaseBadgeColor(state.phase))
                    )
                    .foregroundStyle(.white)
            }

            if let winner = state.winner {
                HStack(spacing: 6) {
                    Image(systemName: winner == .southNorthAlliance ? "trophy.fill" : "xmark.octagon.fill")
                        .foregroundStyle(winner == .southNorthAlliance ? .yellow : .red)
                    Text(winner == .southNorthAlliance ? "南北同盟（玩家＆北家）獲勝！" : "東西同盟（敵方 AI）獲勝")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(winner == .southNorthAlliance ? .green : .red)
                }
            } else if state.phase == .playing {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.currentTurn == .south ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    Text("當前回合：\(state.currentTurn.displayName)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(state.visibilityMode.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - 四方兵力統計

    private var playerCountGrid: some View {
        let state = viewModel.displayedState
        let seats: [Seat] = [.south, .north, .west, .east]

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(seats, id: \.self) { seat in
                let count = state.pieces.values.filter { $0.owner == seat }.count
                let eliminated = state.eliminatedSeats.contains(seat)
                let isTurn = state.phase == .playing && state.currentTurn == seat

                HStack(spacing: 6) {
                    Circle()
                        .fill(seatDotColor(seat))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(seat.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(eliminated ? "已全軍覆沒" : "剩餘 \(count) 枚")
                            .font(.caption2)
                            .foregroundStyle(eliminated ? .red : .secondary)
                    }
                    Spacer()
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isTurn ? Color.yellow : Color.primary.opacity(0.08), lineWidth: isTurn ? 1.8 : 1.0)
                        )
                )
            }
        }
    }

    // MARK: - 佈陣階段控制面板

    private var setupControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("開局規則與佈陣設定")
                .font(.subheadline.weight(.bold))

            // 視角模式切換
            VStack(alignment: .leading, spacing: 4) {
                Text("視角模式")
                    .font(.caption.weight(.semibold))
                Picker("視角模式", selection: Binding(
                    get: { viewModel.state.visibilityMode },
                    set: { viewModel.setVisibilityMode($0) }
                )) {
                    ForEach(VisibilityMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(viewModel.state.visibilityMode.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // 地雷規則切換
            VStack(alignment: .leading, spacing: 4) {
                Text("地雷規則")
                    .font(.caption.weight(.semibold))
                Picker("地雷規則", selection: Binding(
                    get: { viewModel.state.mineRule },
                    set: { viewModel.setMineRule($0) }
                )) {
                    ForEach(MineRule.allCases, id: \.self) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .labelsHidden()
            }

            Divider()

            // 預設陣型選擇
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("經典預設陣型")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("🎲 隨機佈陣") {
                        viewModel.applyRandomSetup()
                    }
                    .controlSize(.small)
                }

                ForEach(PresetFormation.allCases) { preset in
                    Button {
                        viewModel.applyPreset(preset)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.rawValue)
                                    .font(.caption.weight(.bold))
                                Text(preset.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if viewModel.state.selectedPreset == preset {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                viewModel.startMatch()
            } label: {
                HStack {
                    Image(systemName: "flag.2.crossed.fill")
                    Text("開始四國對戰")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - 自訂陣型儲存與讀取

    private var savedFormationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自訂陣型庫")
                .font(.subheadline.weight(.bold))

            HStack(spacing: 6) {
                TextField("輸入陣型名稱...", text: $customFormationName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button("儲存當前陣型") {
                    viewModel.saveCurrentSouthFormation(named: customFormationName)
                    customFormationName = ""
                }
                .controlSize(.small)
            }

            if viewModel.savedFormations.isEmpty {
                Text("尚無已儲存的自訂陣型。可在棋盤上點擊互換棋子後儲存。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.savedFormations) { item in
                    HStack {
                        Text(item.name)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Button("載入") {
                            viewModel.loadSavedFormation(item)
                        }
                        .controlSize(.mini)
                        Button(role: .destructive) {
                            viewModel.deleteSavedFormation(item)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.mini)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - 對戰控制面板

    private var matchControlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("戰局控制與輔助")
                .font(.subheadline.weight(.bold))

            HStack(spacing: 8) {
                Button {
                    viewModel.undoToPreviousHumanTurn()
                } label: {
                    Label("悔棋", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!viewModel.canUndo)

                Button {
                    viewModel.toggleAIPause()
                } label: {
                    Label(viewModel.isAIPaused ? "繼續 AI" : "暫停 AI",
                          systemImage: viewModel.isAIPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.state.phase != .playing)
            }

            HStack(spacing: 8) {
                Toggle(isOn: $viewModel.godModeEnabled) {
                    Label("上帝視角（全明透視）", systemImage: "eye.fill")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                Button("新局佈陣") {
                    viewModel.resetToNewSetup()
                }
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("AI 思考節奏")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f 秒/步", viewModel.aiThinkingDelay))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $viewModel.aiThinkingDelay, in: 0.15...1.20, step: 0.05)
                    .controlSize(.small)
            }

            Text("💡 提示：對場上任意未知敵方暗棋「點擊滑鼠右鍵」，可標記疑似司令、炸彈、地雷、工兵等情報。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - 復盤回放時間軸

    private var replayTimelineSection: some View {
        let totalSteps = max(0, viewModel.snapshots.count - 1)
        let currentIndex = viewModel.replayIndex ?? totalSteps

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("復盤回放控制器")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("第 \(currentIndex) / \(totalSteps) 步")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(viewModel.isReplaying ? .orange : .secondary)
            }

            if totalSteps > 0 {
                Slider(
                    value: Binding(
                        get: { Double(currentIndex) },
                        set: { viewModel.seekReplay(to: Int($0.rounded())) }
                    ),
                    in: 0...Double(totalSteps),
                    step: 1
                )
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Button {
                    viewModel.seekReplay(to: 0)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(currentIndex <= 0)

                Button {
                    viewModel.seekReplay(to: max(0, currentIndex - 1))
                } label: {
                    Label("上一步", systemImage: "chevron.left")
                }
                .disabled(currentIndex <= 0)

                Button {
                    viewModel.seekReplay(to: min(totalSteps, currentIndex + 1))
                } label: {
                    Label("下一步", systemImage: "chevron.right")
                }
                .disabled(currentIndex >= totalSteps)

                Button {
                    viewModel.exitReplayMode()
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(!viewModel.isReplaying)
            }
            .controlSize(.small)

            if viewModel.isReplaying {
                Button {
                    viewModel.exitReplayMode()
                } label: {
                    Text("返回即時戰局")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - 戰報歷史列表

    private var battleLogSection: some View {
        let records = Array(viewModel.displayedState.moveHistory.reversed())

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("實時戰報紀錄（點擊可跳轉復盤）")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("共 \(records.count) 步")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if records.isEmpty {
                Text("尚無交戰紀錄。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(records) { rec in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(viewModel.formatMoveSummary(rec))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.primary)

                            ForEach(rec.specialAnnouncements, id: \.self) { note in
                                Text(note)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.seekReplay(to: rec.stepNumber)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - 輔助樣式

    private func phaseBadgeTitle(_ phase: GamePhase) -> String {
        switch phase {
        case .setup: return "佈陣階段"
        case .playing: return "激戰中"
        case .finished: return "已終局"
        }
    }

    private func phaseBadgeColor(_ phase: GamePhase) -> Color {
        switch phase {
        case .setup: return .blue
        case .playing: return .green
        case .finished: return .purple
        }
    }

    private func seatDotColor(_ seat: Seat) -> Color {
        switch seat {
        case .south: return Color(red: 0.85, green: 0.22, blue: 0.24)
        case .north: return Color(red: 0.15, green: 0.65, blue: 0.55)
        case .west: return Color(red: 0.58, green: 0.34, blue: 0.82)
        case .east: return Color(red: 0.88, green: 0.52, blue: 0.16)
        }
    }
}
