import Foundation
import Observation
import SiguoCore

/// 戰鬥視覺回饋事件
public struct CombatVisualEvent: Equatable, Sendable {
    public let id: UUID
    public let coord: BoardCoord
    public let outcome: CombatOutcome
    public let label: String

    public init(id: UUID = UUID(), coord: BoardCoord, outcome: CombatOutcome, label: String) {
        self.id = id
        self.coord = coord
        self.outcome = outcome
        self.label = label
    }
}

/// 牌局主視圖模型（遵循 Swift 6 `@MainActor` 與 `@Observable` 最佳實踐）
@MainActor
@Observable
public final class GameViewModel {
    /// 當前真實牌局狀態
    public private(set) var state: GameState
    /// 每一步的完整牌局快照（index 0 為開局初始狀態，index k 為第 k 步後的狀態）
    public private(set) var snapshots: [GameState] = []
    /// 復盤檢視索引（為 nil 時代表處於即時對局狀態）
    public var replayIndex: Int?
    /// 當前選中的棋盤座標
    public var selectedCoord: BoardCoord?
    /// 當前選中棋子的合法走步清單
    public private(set) var validMovesForSelected: [ValidMove] = []
    /// 是否開啟上帝透視視角（全明檢視）
    public var godModeEnabled: Bool = false
    /// 是否暫停 AI 自動行棋
    public var isAIPaused: Bool = false
    /// AI 每步思考延遲秒數
    public var aiThinkingDelay: Double = 0.50
    /// 頂部即時狀態提示訊息
    public var statusMessage: String = "請調整南方陣型（點擊兩枚己方棋子可互換位置），完成後點擊「開始對戰」。"
    /// 最近一次交戰的視覺特效
    public var latestCombatEvent: CombatVisualEvent?
    /// 玩家自訂儲存的陣型清單
    public private(set) var savedFormations: [SavedFormation] = []

    private var aiLoopTask: Task<Void, Never>?
    private static let savedFormationsKey = "com.siguo.savedFormations.v1"

    public init() {
        let initial = GameEngine.newGame()
        self.state = initial
        self.snapshots = [initial]
        loadSavedFormationsFromStorage()
    }

    /// 畫面當前應呈現的牌局狀態（支援復盤模式與即時模式）
    public var displayedState: GameState {
        if let replayIndex, snapshots.indices.contains(replayIndex) {
            return snapshots[replayIndex]
        }
        return state
    }

    /// 是否正處於復盤檢視模式
    public var isReplaying: Bool {
        replayIndex != nil
    }

    /// 畫面當前展示的最後一步紀錄
    public var displayedLastMove: MoveRecord? {
        displayedState.moveHistory.last
    }

    // MARK: - 開局與佈陣操作

    /// 重新開始新局（回到佈陣階段）
    public func resetToNewSetup(
        visibilityMode: VisibilityMode? = nil,
        mineRule: MineRule? = nil,
        preset: PresetFormation? = nil
    ) {
        cancelAITask()
        let nextVisibility = visibilityMode ?? state.visibilityMode
        let nextMineRule = mineRule ?? state.mineRule
        let nextPreset = preset ?? state.selectedPreset

        let currentSouthLayout = GameEngine.extractSouthLayout(from: state)
        let newState = GameEngine.newGame(
            visibilityMode: nextVisibility,
            mineRule: nextMineRule,
            southPreset: nextPreset,
            customSouthLayout: preset == nil ? currentSouthLayout : nil
        )
        self.state = newState
        self.snapshots = [newState]
        self.replayIndex = nil
        self.selectedCoord = nil
        self.validMovesForSelected = []
        self.godModeEnabled = false
        self.latestCombatEvent = nil
        self.statusMessage = "新局已備妥！點擊兩枚南方棋子可調換位置，或從右側選擇預設陣型。"
    }

    /// 變更視角模式
    public func setVisibilityMode(_ mode: VisibilityMode) {
        state.visibilityMode = mode
        if state.phase == .setup && !snapshots.isEmpty {
            snapshots[0] = state
        }
    }

    /// 變更地雷規則
    public func setMineRule(_ rule: MineRule) {
        state.mineRule = rule
        if state.phase == .setup && !snapshots.isEmpty {
            snapshots[0] = state
        }
    }

    /// 套用預設陣型
    public func applyPreset(_ preset: PresetFormation) {
        guard state.phase == .setup else { return }
        GameEngine.applySouthPreset(preset, in: &state)
        selectedCoord = nil
        snapshots = [state]
        statusMessage = "已套用「\(preset.rawValue)」：\(preset.description)"
    }

    /// 隨機佈陣
    public func applyRandomSetup() {
        guard state.phase == .setup else { return }
        GameEngine.applySouthRandomLayout(in: &state)
        selectedCoord = nil
        snapshots = [state]
        statusMessage = "已隨機產生合法的南方陣型。"
    }

    /// 正式開始對戰
    public func startMatch() {
        guard state.phase == .setup else { return }
        GameEngine.startGame(in: &state)
        selectedCoord = nil
        validMovesForSelected = []
        replayIndex = nil
        snapshots = [state]
        statusMessage = "戰局開始！輪到南方（玩家）行棋。"
        scheduleAITurnIfNeeded()
    }

    // MARK: - 棋盤點擊與走棋互動

    /// 處理玩家點擊棋盤節點
    public func handleNodeTap(_ coord: BoardCoord) {
        if isReplaying {
            statusMessage = "目前處於復盤檢視模式，點擊「返回即時戰局」即可繼續操作。"
            return
        }

        switch state.phase {
        case .setup:
            handleSetupTap(coord)
        case .playing:
            handlePlayingTap(coord)
        case .finished:
            statusMessage = "戰局已結束，可使用復盤控制器回放或開啟新局。"
        }
    }

    private func handleSetupTap(_ coord: BoardCoord) {
        guard let tappedPiece = state.pieces[coord], tappedPiece.owner == .south else {
            selectedCoord = nil
            statusMessage = "佈陣階段請點擊南方（下方）己方棋子進行位置調換。"
            return
        }

        guard let currentSelected = selectedCoord else {
            selectedCoord = coord
            statusMessage = "已選中「\(tappedPiece.rank.rawValue)」，請點擊另一枚綠色高亮的己方棋子交換位置。"
            return
        }

        if currentSelected == coord {
            selectedCoord = nil
            statusMessage = "已取消選中。"
            return
        }

        let firstName = state.pieces[currentSelected]?.rank.rawValue ?? ""
        let secondName = tappedPiece.rank.rawValue

        if GameEngine.swapSetupPieces(in: &state, coordA: currentSelected, coordB: coord) {
            selectedCoord = nil
            snapshots = [state]
            statusMessage = "已交換「\(firstName)」與「\(secondName)」的位置。"
        } else {
            statusMessage = "⚠️ 無法交換「\(firstName)」與「\(secondName)」（違反軍旗限大本營、地雷限後兩排或炸彈禁前排規則）。"
        }
    }

    private func handlePlayingTap(_ coord: BoardCoord) {
        guard state.currentTurn == .south else {
            statusMessage = "請稍候，目前輪到\(state.currentTurn.displayName)思考行棋..."
            return
        }

        // 1. 若已選中己方棋子，且點擊的是合法目標格 -> 執行移動或攻擊
        if let move = validMovesForSelected.first(where: { $0.to == coord }) {
            executeMove(move)
            return
        }

        // 2. 若點擊的是另一枚南方己方棋子 -> 切換選中
        if let piece = state.pieces[coord], piece.owner == .south {
            if selectedCoord == coord {
                clearSelection()
            } else {
                selectedCoord = coord
                validMovesForSelected = MoveGenerator.validMoves(from: coord, pieces: state.pieces)
                if validMovesForSelected.isEmpty {
                    statusMessage = "「\(piece.rank.rawValue)」目前無法移動（地雷、軍旗、大本營內或遭阻擋）。"
                } else {
                    statusMessage = "已選中「\(piece.rank.rawValue)」，共 \(validMovesForSelected.count) 個可走目標。"
                }
            }
            return
        }

        // 3. 點擊其他位置 -> 取消選中
        clearSelection()
    }

    /// 判斷在佈陣階段，某座標是否可與當前選中的南方棋子合法交換
    public func canSwapWithSelectedInSetup(_ coord: BoardCoord) -> Bool {
        guard state.phase == .setup,
              let selected = selectedCoord,
              selected != coord,
              let pieceA = state.pieces[selected],
              let pieceB = state.pieces[coord],
              pieceA.owner == .south,
              pieceB.owner == .south else {
            return false
        }
        return FormationBuilder.canSwap(
            rankA: pieceA.rank,
            coordA: selected,
            rankB: pieceB.rank,
            coordB: coord
        )
    }

    private func clearSelection() {
        selectedCoord = nil
        validMovesForSelected = []
    }

    /// 執行單步走棋並記錄快照
    private func executeMove(_ move: ValidMove) {
        clearSelection()
        guard let record = GameEngine.applyMove(move, in: &state) else {
            return
        }
        snapshots.append(state)
        updateCombatVisualAndStatus(for: record)

        if state.phase == .playing {
            scheduleAITurnIfNeeded()
        }
    }

    private func updateCombatVisualAndStatus(for record: MoveRecord) {
        switch record.outcome {
        case .moveOnly:
            latestCombatEvent = nil
        case .attackerWins:
            latestCombatEvent = CombatVisualEvent(
                coord: record.to,
                outcome: .attackerWins,
                label: "⚔️ \(record.actor.shortName)方勝"
            )
        case .defenderWins:
            latestCombatEvent = CombatVisualEvent(
                coord: record.to,
                outcome: .defenderWins,
                label: "🛡️ 防守勝"
            )
        case .mutualDestruction:
            latestCombatEvent = CombatVisualEvent(
                coord: record.to,
                outcome: .mutualDestruction,
                label: "💥 同歸於盡"
            )
        }

        if let important = record.specialAnnouncements.last {
            statusMessage = important
        } else {
            statusMessage = formatMoveSummary(record)
        }
    }

    /// 格式化單步戰報文字（嚴格遵守暗棋保密原則）
    public func formatMoveSummary(_ record: MoveRecord) -> String {
        let revealAll = godModeEnabled || state.phase == .finished
        let attackerVisible = record.attackerPiece.isVisibleToHuman(
            mode: state.visibilityMode,
            forceRevealAll: revealAll
        )
        let attackerName = attackerVisible ? record.attackerPiece.rank.rawValue : "暗棋"

        guard let defender = record.defenderPiece else {
            let turnTag = record.path.count > 2 ? "（鐵路推進 \(record.path.count - 1) 格）" : ""
            return "#\(record.stepNumber) [\(record.actor.shortName)] \(attackerName) \(record.from) → \(record.to) \(turnTag)"
        }

        let defenderVisible = defender.isVisibleToHuman(
            mode: state.visibilityMode,
            forceRevealAll: revealAll
        )
        let defenderName = defenderVisible ? defender.rank.rawValue : "暗棋"

        let outcomeText: String
        switch record.outcome {
        case .attackerWins:
            outcomeText = "擊破 [\(defender.owner.shortName)] \(defenderName)"
        case .defenderWins:
            outcomeText = "撞上 [\(defender.owner.shortName)] \(defenderName) 陣亡"
        case .mutualDestruction:
            outcomeText = "與 [\(defender.owner.shortName)] \(defenderName) 同歸於盡"
        case .moveOnly:
            outcomeText = "移動"
        }

        return "#\(record.stepNumber) [\(record.actor.shortName)] \(attackerName) \(record.from)→\(record.to) \(outcomeText)"
    }

    // MARK: - AI 非阻塞回合排程 (Swift 6 Structured Concurrency)

    public func toggleAIPause() {
        isAIPaused.toggle()
        if isAIPaused {
            cancelAITask()
            statusMessage = "已暫停 AI 思考。"
        } else {
            statusMessage = "已恢復 AI 行棋。"
            scheduleAITurnIfNeeded()
        }
    }

    private func cancelAITask() {
        aiLoopTask?.cancel()
        aiLoopTask = nil
    }

    private func scheduleAITurnIfNeeded() {
        cancelAITask()
        guard state.phase == .playing,
              !isAIPaused,
              !isReplaying,
              state.currentTurn != .south else {
            return
        }

        aiLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.state.phase == .playing,
                      !self.isAIPaused,
                      !self.isReplaying,
                      self.state.currentTurn != .south else {
                    break
                }

                let aiSeat = self.state.currentTurn
                let delayNanoseconds = UInt64(max(0.12, self.aiThinkingDelay) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                if Task.isCancelled { break }

                guard self.state.phase == .playing,
                      !self.isAIPaused,
                      !self.isReplaying,
                      self.state.currentTurn == aiSeat else {
                    break
                }

                let snapshotForAI = self.state
                if let chosenMove = AIPlayer.chooseMove(in: snapshotForAI, for: aiSeat) {
                    self.executeMove(chosenMove)
                } else {
                    break
                }
            }
        }
    }

    // MARK: - 暗棋標記系統

    public func setTag(_ tag: SuspicionTag?, for coord: BoardCoord) {
        GameEngine.setSuspicionTag(tag, at: coord, in: &state)
        if !snapshots.isEmpty {
            snapshots[snapshots.count - 1] = state
        }
        if let tag {
            statusMessage = "已將座標 \(coord) 的棋子標記為「\(tag.rawValue)」。"
        } else {
            statusMessage = "已清除座標 \(coord) 的標記。"
        }
    }

    // MARK: - 悔棋（Undo）與復盤回放（Replay）

    /// 是否可悔棋（至少已經走過一步玩家回合）
    public var canUndo: Bool {
        guard state.phase == .playing || state.phase == .finished else { return false }
        return snapshots.dropLast().contains(where: { $0.currentTurn == .south && $0.phase == .playing })
    }

    /// 悔棋：退回至玩家上一次出手前的狀態
    public func undoToPreviousHumanTurn() {
        cancelAITask()
        replayIndex = nil
        clearSelection()

        guard snapshots.count > 1 else { return }
        // 移除當前狀態後，往回尋找最近一個輪到南方玩家的快照
        snapshots.removeLast()
        while snapshots.count > 1, snapshots.last?.currentTurn != .south {
            snapshots.removeLast()
        }

        if let restored = snapshots.last {
            state = restored
            latestCombatEvent = nil
            statusMessage = "已悔棋退回至第 \(state.moveHistory.count) 步（輪到玩家行棋）。"
        }
    }

    /// 跳轉至指定的復盤步數
    public func seekReplay(to index: Int) {
        guard snapshots.indices.contains(index) else { return }
        cancelAITask()
        clearSelection()
        if index == snapshots.count - 1 {
            replayIndex = nil
            statusMessage = "已返回最新戰局狀態。"
            scheduleAITurnIfNeeded()
        } else {
            replayIndex = index
            statusMessage = "復盤檢視：第 \(index) / \(snapshots.count - 1) 步。"
        }
    }

    /// 結束復盤並返回即時對戰
    public func exitReplayMode() {
        replayIndex = nil
        statusMessage = "已返回即時戰局。"
        scheduleAITurnIfNeeded()
    }

    // MARK: - 自訂陣型儲存與載入

    public func saveCurrentSouthFormation(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "自訂陣型 \(savedFormations.count + 1)" : trimmed
        let localLayout = GameEngine.extractSouthLayout(from: state)

        var stringMapping: [String: PieceRank] = [:]
        for (local, rank) in localLayout {
            stringMapping["\(local.row),\(local.col)"] = rank
        }

        let item = SavedFormation(name: finalName, mapping: stringMapping)
        savedFormations.insert(item, at: 0)
        persistSavedFormations()
        statusMessage = "已儲存陣型「\(finalName)」。"
    }

    public func loadSavedFormation(_ formation: SavedFormation) {
        guard state.phase == .setup else {
            statusMessage = "只能在開局佈陣階段載入自訂陣型。"
            return
        }
        var localLayout: [LocalCoord: PieceRank] = [:]
        for (key, rank) in formation.mapping {
            let parts = key.split(separator: ",")
            if parts.count == 2,
               let r = Int(parts[0]),
               let c = Int(parts[1]) {
                localLayout[LocalCoord(row: r, col: c)] = rank
            }
        }
        if GameEngine.applySouthCustomLayout(localLayout, in: &state) {
            selectedCoord = nil
            snapshots = [state]
            statusMessage = "已載入自訂陣型「\(formation.name)」。"
        } else {
            statusMessage = "⚠️ 載入陣型失敗：陣型資料不完整。"
        }
    }

    public func deleteSavedFormation(_ formation: SavedFormation) {
        savedFormations.removeAll { $0.id == formation.id }
        persistSavedFormations()
    }

    private func loadSavedFormationsFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedFormationsKey),
              let decoded = try? JSONDecoder().decode([SavedFormation].self, from: data) else {
            return
        }
        self.savedFormations = decoded
    }

    private func persistSavedFormations() {
        guard let data = try? JSONEncoder().encode(savedFormations) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedFormationsKey)
    }
}
