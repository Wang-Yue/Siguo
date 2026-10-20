import Foundation

/// 完整牌局狀態（純值型別，支援不可變快照、悔棋與復盤）
public struct GameState: Equatable, Codable, Sendable {
    public var phase: GamePhase
    public var visibilityMode: VisibilityMode
    public var mineRule: MineRule
    public var aiDifficulty: AIDifficulty
    public var currentTurn: Seat
    public var pieces: [BoardCoord: Piece]
    public var eliminatedSeats: Set<Seat>
    public var moveHistory: [MoveRecord]
    public var winner: WinningTeam?
    public var selectedPreset: PresetFormation

    public init(
        phase: GamePhase = .setup,
        visibilityMode: VisibilityMode = .doubleVisible,
        mineRule: MineRule = .classicSurvives,
        aiDifficulty: AIDifficulty = .master,
        currentTurn: Seat = .south,
        pieces: [BoardCoord: Piece] = [:],
        eliminatedSeats: Set<Seat> = [],
        moveHistory: [MoveRecord] = [],
        winner: WinningTeam? = nil,
        selectedPreset: PresetFormation = .balanced
    ) {
        self.phase = phase
        self.visibilityMode = visibilityMode
        self.mineRule = mineRule
        self.aiDifficulty = aiDifficulty
        self.currentTurn = currentTurn
        self.pieces = pieces
        self.eliminatedSeats = eliminatedSeats
        self.moveHistory = moveHistory
        self.winner = winner
        self.selectedPreset = selectedPreset
    }
}

/// 四國軍棋核心裁判與狀態演進引擎
public enum GameEngine {
    /// 建立新牌局（預設進入佈陣階段，四家皆載入合法陣型）
    public static func newGame(
        visibilityMode: VisibilityMode = .doubleVisible,
        mineRule: MineRule = .classicSurvives,
        aiDifficulty: AIDifficulty = .master,
        southPreset: PresetFormation = .balanced,
        customSouthLayout: [LocalCoord: PieceRank]? = nil
    ) -> GameState {
        var allPieces: [BoardCoord: Piece] = [:]

        // 南方（人類玩家）陣型
        let southLayout: [LocalCoord: PieceRank]
        if let customSouthLayout, FormationBuilder.isValidCompleteLayout(customSouthLayout) {
            southLayout = customSouthLayout
        } else {
            southLayout = FormationBuilder.localLayout(for: southPreset)
        }
        let southPieces = FormationBuilder.instantiatePieces(for: .south, localLayout: southLayout)
        for (coord, piece) in southPieces {
            allPieces[coord] = piece
        }

        // 東、北、西三家 AI 從預設陣型加上適度合法隨機微調產生，增加對局多樣性
        for seat in [Seat.east, Seat.north, Seat.west] {
            let randomPreset = PresetFormation.allCases.randomElement() ?? .balanced
            let aiLayout = mutatedLayout(from: FormationBuilder.localLayout(for: randomPreset))
            let seatPieces = FormationBuilder.instantiatePieces(for: seat, localLayout: aiLayout)
            for (coord, piece) in seatPieces {
                allPieces[coord] = piece
            }
        }

        return GameState(
            phase: .setup,
            visibilityMode: visibilityMode,
            mineRule: mineRule,
            aiDifficulty: aiDifficulty,
            currentTurn: .south,
            pieces: allPieces,
            eliminatedSeats: [],
            moveHistory: [],
            winner: nil,
            selectedPreset: southPreset
        )
    }

    /// 對預設陣型做數次合法隨機互換，讓 AI 每局陣型既有戰術結構又不固定
    public static func mutatedLayout(from base: [LocalCoord: PieceRank], swaps: Int = 8) -> [LocalCoord: PieceRank] {
        var layout = base
        let coords = Array(layout.keys)
        guard coords.count >= 2 else { return layout }

        var remainingSwaps = swaps
        var attempts = 0
        while remainingSwaps > 0 && attempts < 60 {
            attempts += 1
            guard let coordA = coords.randomElement(),
                  let coordB = coords.randomElement(),
                  coordA != coordB,
                  let rankA = layout[coordA],
                  let rankB = layout[coordB] else {
                continue
            }
            // 不輕易移動軍旗與保護軍旗的地雷
            if rankA == .flag || rankB == .flag {
                continue
            }
            if FormationBuilder.isValidPlacement(rank: rankA, at: coordB) &&
                FormationBuilder.isValidPlacement(rank: rankB, at: coordA) {
                layout[coordA] = rankB
                layout[coordB] = rankA
                remainingSwaps -= 1
            }
        }
        return layout
    }

    /// 佈陣階段：交換南方玩家的兩枚棋子
    @discardableResult
    public static func swapSetupPieces(
        in state: inout GameState,
        coordA: BoardCoord,
        coordB: BoardCoord
    ) -> Bool {
        guard state.phase == .setup,
              coordA != coordB,
              let pieceA = state.pieces[coordA],
              let pieceB = state.pieces[coordB],
              pieceA.owner == .south,
              pieceB.owner == .south,
              FormationBuilder.canSwap(rankA: pieceA.rank, coordA: coordA, rankB: pieceB.rank, coordB: coordB) else {
            return false
        }
        state.pieces[coordA] = pieceB
        state.pieces[coordB] = pieceA
        return true
    }

    /// 佈陣階段：套用預設陣型至南方玩家
    public static func applySouthPreset(_ preset: PresetFormation, in state: inout GameState) {
        guard state.phase == .setup else { return }
        state.selectedPreset = preset
        let layout = FormationBuilder.localLayout(for: preset)
        replaceSouthPieces(with: layout, in: &state)
    }

    /// 佈陣階段：套用隨機合法陣型至南方玩家
    public static func applySouthRandomLayout(in state: inout GameState) {
        guard state.phase == .setup else { return }
        let layout = FormationBuilder.randomLocalLayout()
        replaceSouthPieces(with: layout, in: &state)
    }

    /// 佈陣階段：套用自訂陣型至南方玩家
    @discardableResult
    public static func applySouthCustomLayout(_ layout: [LocalCoord: PieceRank], in state: inout GameState) -> Bool {
        guard state.phase == .setup,
              FormationBuilder.isValidCompleteLayout(layout) else {
            return false
        }
        replaceSouthPieces(with: layout, in: &state)
        return true
    }

    /// 擷取南方玩家目前的局部陣型配置（供儲存自訂陣型使用）
    public static func extractSouthLayout(from state: GameState, graph: BoardGraph = .shared) -> [LocalCoord: PieceRank] {
        var result: [LocalCoord: PieceRank] = [:]
        for (coord, piece) in state.pieces where piece.owner == .south {
            if let local = graph.nodes[coord]?.localCoord {
                result[local] = piece.rank
            }
        }
        return result
    }

    private static func replaceSouthPieces(with layout: [LocalCoord: PieceRank], in state: inout GameState) {
        for coord in BoardGraph.shared.zoneCoords(for: .south) {
            state.pieces.removeValue(forKey: coord)
        }
        let newPieces = FormationBuilder.instantiatePieces(for: .south, localLayout: layout)
        for (coord, piece) in newPieces {
            state.pieces[coord] = piece
        }
    }

    /// 開始對戰
    public static func startGame(in state: inout GameState) {
        guard state.phase == .setup else { return }
        state.phase = .playing
        state.currentTurn = .south
    }

    /// 為場上某枚棋子設定或清除玩家的暗棋猜測標記
    public static func setSuspicionTag(
        _ tag: SuspicionTag?,
        at coord: BoardCoord,
        in state: inout GameState
    ) {
        guard var piece = state.pieces[coord] else { return }
        piece.suspicionTag = tag
        state.pieces[coord] = piece
    }

    /// 裁決兩枚棋子交戰結果
    public static func resolveCombat(
        attacker: PieceRank,
        defender: PieceRank,
        mineRule: MineRule
    ) -> CombatOutcome {
        // 1. 炸彈與任何棋子碰撞皆同歸於盡
        if attacker == .bomb || defender == .bomb {
            return .mutualDestruction
        }

        // 2. 攻擊軍旗（非炸彈）：攻擊方直接扛旗獲勝
        if defender == .flag {
            return .attackerWins
        }

        // 3. 攻擊地雷（非炸彈）：工兵挖雷獲勝；其餘依地雷規則裁決
        if defender == .mine {
            if attacker == .sapper {
                return .attackerWins
            }
            switch mineRule {
            case .classicSurvives:
                return .defenderWins
            case .bothDestroy:
                return .mutualDestruction
            }
        }

        // 4. 一般階級戰力比大小
        guard let attackPower = attacker.combatStrength,
              let defendPower = defender.combatStrength else {
            return .mutualDestruction
        }

        if attackPower > defendPower {
            return .attackerWins
        } else if attackPower < defendPower {
            return .defenderWins
        } else {
            return .mutualDestruction
        }
    }

    /// 執行一步合法走棋並更新牌局狀態
    @discardableResult
    public static func applyMove(
        _ move: ValidMove,
        in state: inout GameState,
        graph: BoardGraph = .shared
    ) -> MoveRecord? {
        guard state.phase == .playing,
              var attacker = state.pieces[move.from],
              attacker.owner == state.currentTurn else {
            return nil
        }

        let validCandidates = MoveGenerator.validMoves(from: move.from, pieces: state.pieces, graph: graph)
        guard let verifiedMove = validCandidates.first(where: { $0.to == move.to }) else {
            return nil
        }

        let defender = state.pieces[verifiedMove.to]
        attacker.hasMoved = true
        if verifiedMove.madeRailwayTurn {
            attacker.turnedOnRailway = true
            // 一旦在鐵路上轉彎，全員皆知此子必為工兵
            attacker.isPubliclyRevealed = true
        }

        state.pieces.removeValue(forKey: verifiedMove.from)

        var announcements: [String] = []
        let outcome: CombatOutcome

        if let defender {
            outcome = resolveCombat(attacker: attacker.rank, defender: defender.rank, mineRule: state.mineRule)
            switch outcome {
            case .attackerWins:
                attacker.killsCount += 1
                state.pieces[verifiedMove.to] = attacker
            case .defenderWins:
                var survivingDefender = defender
                survivingDefender.killsCount += 1
                state.pieces[verifiedMove.to] = survivingDefender
            case .mutualDestruction:
                state.pieces.removeValue(forKey: verifiedMove.to)
            case .moveOnly:
                state.pieces[verifiedMove.to] = attacker
            }

            // 檢查是否有司令陣亡 -> 亮出該方軍旗
            let attackerDied = (outcome == .defenderWins || outcome == .mutualDestruction)
            let defenderDied = (outcome == .attackerWins || outcome == .mutualDestruction)

            if attackerDied && attacker.rank == .commander {
                if revealFlag(for: attacker.owner, in: &state) {
                    announcements.append("⚠️ \(attacker.owner.displayName)司令陣亡，亮出軍旗！")
                }
            }
            if defenderDied && defender.rank == .commander {
                if revealFlag(for: defender.owner, in: &state) {
                    announcements.append("⚠️ \(defender.owner.displayName)司令陣亡，亮出軍旗！")
                }
            }

            // 檢查防守方軍旗是否被拔除
            if defenderDied && defender.rank == .flag {
                eliminateSeat(
                    defender.owner,
                    reason: "🏳️ \(defender.owner.displayName)軍旗被拔除，全軍覆沒！",
                    in: &state,
                    announcements: &announcements
                )
            }
        } else {
            outcome = .moveOnly
            state.pieces[verifiedMove.to] = attacker
        }

        // 檢查各存活方是否已經失去所有可動棋子（全殲）
        for seat in Seat.allCases where !state.eliminatedSeats.contains(seat) {
            if !hasRemainingMovablePiece(for: seat, in: state, graph: graph) {
                eliminateSeat(
                    seat,
                    reason: "💥 \(seat.displayName)已無可動兵力，全軍覆沒！",
                    in: &state,
                    announcements: &announcements
                )
            }
        }

        // 檢查勝負與推進下一回合
        updateWinnerOrAdvanceTurn(in: &state, announcements: &announcements, graph: graph)

        let record = MoveRecord(
            stepNumber: state.moveHistory.count + 1,
            actor: attacker.owner,
            from: verifiedMove.from,
            to: verifiedMove.to,
            path: verifiedMove.path,
            attackerPiece: attacker,
            defenderPiece: defender,
            outcome: outcome,
            specialAnnouncements: announcements
        )
        state.moveHistory.append(record)
        return record
    }

    /// 亮出指定座位的軍旗
    @discardableResult
    private static func revealFlag(for seat: Seat, in state: inout GameState) -> Bool {
        for (coord, var piece) in state.pieces where piece.owner == seat && piece.rank == .flag {
            if !piece.isPubliclyRevealed {
                piece.isPubliclyRevealed = true
                state.pieces[coord] = piece
                return true
            }
        }
        return false
    }

    /// 宣告某方淘汰並清除其場上所有剩餘棋子
    private static func eliminateSeat(
        _ seat: Seat,
        reason: String,
        in state: inout GameState,
        announcements: inout [String]
    ) {
        guard !state.eliminatedSeats.contains(seat) else { return }
        state.eliminatedSeats.insert(seat)
        announcements.append(reason)

        let coordsToRemove = state.pieces.compactMap { coord, piece in
            piece.owner == seat ? coord : nil
        }
        for coord in coordsToRemove {
            state.pieces.removeValue(forKey: coord)
        }
    }

    /// 檢查某座位是否仍擁有至少一枚不在大本營內的可移動棋子
    public static func hasRemainingMovablePiece(
        for seat: Seat,
        in state: GameState,
        graph: BoardGraph = .shared
    ) -> Bool {
        for (coord, piece) in state.pieces where piece.owner == seat {
            guard piece.rank.isMovableRank,
                  let node = graph.nodes[coord],
                  node.type != .headquarters else {
                continue
            }
            return true
        }
        return false
    }

    /// 更新勝負狀態，或推進至下一位有合法步數的存活玩家
    private static func updateWinnerOrAdvanceTurn(
        in state: inout GameState,
        announcements: inout [String],
        graph: BoardGraph
    ) {
        if checkVictory(in: &state, announcements: &announcements) {
            return
        }

        var candidate = state.currentTurn.nextSeat
        var CheckedCount = 0

        while CheckedCount < 4 {
            CheckedCount += 1
            if !state.eliminatedSeats.contains(candidate) {
                if MoveGenerator.hasAnyValidMove(for: candidate, pieces: state.pieces, graph: graph) {
                    state.currentTurn = candidate
                    return
                } else {
                    // 輪到該玩家但全軍被困死無子可動 -> 判負淘汰
                    eliminateSeat(
                        candidate,
                        reason: "🚫 \(candidate.displayName)無子可動，判負出局！",
                        in: &state,
                        announcements: &announcements
                    )
                    if checkVictory(in: &state, announcements: &announcements) {
                        return
                    }
                }
            }
            candidate = candidate.nextSeat
        }
    }

    /// 檢查是否有一方同盟已經全部淘汰
    private static func checkVictory(in state: inout GameState, announcements: inout [String]) -> Bool {
        let eastWestDead = state.eliminatedSeats.contains(.east) && state.eliminatedSeats.contains(.west)
        let southNorthDead = state.eliminatedSeats.contains(.south) && state.eliminatedSeats.contains(.north)

        if eastWestDead {
            state.winner = .southNorthAlliance
            state.phase = .finished
            announcements.append("🏆 南北同盟（玩家與北方盟友）獲得最終勝利！")
            return true
        }
        if southNorthDead {
            state.winner = .eastWestAlliance
            state.phase = .finished
            announcements.append("💀 南北同盟全軍覆沒，東西敵軍獲勝。")
            return true
        }
        return false
    }
}
