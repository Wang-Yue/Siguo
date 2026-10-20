import Foundation

/// 具備貝氏信念追蹤、靜態交換反擊評估（SEE）、鐵路最短步數導航與 2v2 同盟 Alpha-Beta 搜尋的四國軍棋 AI 引擎
public enum AIPlayer {
    /// 為指定 AI 座位選擇最佳合法走步（根據 `state.aiDifficulty` 自動切換搜尋深度與推理精度）
    public static func chooseMove(
        in state: GameState,
        for seat: Seat,
        graph: BoardGraph = .shared
    ) -> ValidMove? {
        guard state.phase == .playing, state.currentTurn == seat else {
            return nil
        }

        switch state.aiDifficulty {
        case .normal:
            return chooseNormalMove(in: state, for: seat, graph: graph)
        case .expert:
            return chooseExpertMove(in: state, for: seat, graph: graph)
        case .master:
            return chooseMasterMove(in: state, for: seat, graph: graph)
        }
    }

    /// 判斷 AI 是否在當前規則下合法得知某枚棋子的真實階級
    public static func canSeePieceRank(
        observer: Seat,
        target: Piece,
        mode: VisibilityMode
    ) -> Bool {
        if target.owner == observer || target.isPubliclyRevealed {
            return true
        }
        switch mode {
        case .allVisible:
            return true
        case .doubleVisible:
            return observer.isAlly(with: target.owner)
        case .fourDark:
            return false
        }
    }

    // MARK: - 1. 大師級 AI（貝氏信念追蹤 + SEE 反擊評估 + 2v2 同盟 Alpha-Beta 博弈樹搜尋）

    private static func chooseMasterMove(
        in state: GameState,
        for seat: Seat,
        graph: BoardGraph
    ) -> ValidMove? {
        let tracker = AIBeliefTracker(state: state, observer: seat, graph: graph)
        let scoredRootMoves = scoreAllMovesWithBeliefAndSEE(
            in: state,
            for: seat,
            tracker: tracker,
            includeRetaliationSEE: true,
            graph: graph
        )

        guard let bestImmediate = scoredRootMoves.first else {
            return nil
        }

        // 若僅有一種合法走法或第一名是直接拔除敵方軍旗的必勝步，立即回傳
        if scoredRootMoves.count == 1 || bestImmediate.score >= 35_000.0 {
            return bestImmediate.move
        }

        // 針對前 10 個高分候選步進行 2v2 同盟 Alpha-Beta 多層博弈樹搜尋
        let topCandidates = Array(scoredRootMoves.prefix(10))
        let determinizedBase = determinizeState(state, using: tracker)

        var bestMove = bestImmediate.move
        var bestCombinedScore = -Double.infinity
        var alpha = -Double.infinity
        let beta = Double.infinity

        for candidate in topCandidates {
            var nextState = determinizedBase
            guard GameEngine.applyMove(candidate.move, in: &nextState, graph: graph) != nil else {
                continue
            }

            // 進行深度 2（合計 3 層半步：己方 -> 下家敵方 -> 對家盟友/敵方回應）的同盟零和搜尋
            let lookaheadScore = alphaBeta(
                state: nextState,
                depth: 2,
                alpha: alpha,
                beta: beta,
                maximizingTeamOf: seat,
                graph: graph
            )

            // 結合「貝氏機率期望分（涵蓋炸彈/地雷風險分佈）」與「多層確定化博弈樹前瞻分」
            let combined = candidate.score * 0.65 + lookaheadScore * 0.35
            if combined > bestCombinedScore {
                bestCombinedScore = combined
                bestMove = candidate.move
            }
            alpha = max(alpha, combined)
        }

        return bestMove
    }

    // MARK: - 2. 高手級 AI（貝氏信念追蹤 + SEE 靜態反擊評估 + 鐵路圖導航）

    private static func chooseExpertMove(
        in state: GameState,
        for seat: Seat,
        graph: BoardGraph
    ) -> ValidMove? {
        let tracker = AIBeliefTracker(state: state, observer: seat, graph: graph)
        let scored = scoreAllMovesWithBeliefAndSEE(
            in: state,
            for: seat,
            tracker: tracker,
            includeRetaliationSEE: true,
            graph: graph
        )
        return scored.first?.move
    }

    // MARK: - 3. 普通級 AI（基礎啟發式評估）

    private static func chooseNormalMove(
        in state: GameState,
        for seat: Seat,
        graph: BoardGraph
    ) -> ValidMove? {
        let tracker = AIBeliefTracker(state: state, observer: seat, graph: graph)
        let scored = scoreAllMovesWithBeliefAndSEE(
            in: state,
            for: seat,
            tracker: tracker,
            includeRetaliationSEE: false,
            graph: graph
        )
        // 普通難度在前 3 名中帶一點隨機性
        let top = Array(scored.prefix(2))
        return top.first?.move
    }

    // MARK: - 2v2 同盟零和 Alpha-Beta 搜尋核心

    private static func alphaBeta(
        state: GameState,
        depth: Int,
        alpha: Double,
        beta: Double,
        maximizingTeamOf rootSeat: Seat,
        graph: BoardGraph
    ) -> Double {
        if state.phase == .finished || depth <= 0 {
            return evaluateBoardForAlliance(state: state, allianceOf: rootSeat, graph: graph)
        }

        let currentTurn = state.currentTurn
        let isMaximizing = currentTurn.isAlly(with: rootSeat)

        // 收集並快速排序當前行動方的候選走步（限制展開前 8 個最佳戰術步以保持極速回應）
        let orderedMoves = generateOrderedTacticalMoves(in: state, for: currentTurn, limit: 8, graph: graph)
        if orderedMoves.isEmpty {
            return evaluateBoardForAlliance(state: state, allianceOf: rootSeat, graph: graph)
        }

        var currentAlpha = alpha
        var currentBeta = beta

        if isMaximizing {
            var value = -Double.infinity
            for move in orderedMoves {
                var childState = state
                guard GameEngine.applyMove(move, in: &childState, graph: graph) != nil else { continue }
                let childScore = alphaBeta(
                    state: childState,
                    depth: depth - 1,
                    alpha: currentAlpha,
                    beta: currentBeta,
                    maximizingTeamOf: rootSeat,
                    graph: graph
                )
                value = max(value, childScore)
                currentAlpha = max(currentAlpha, value)
                if currentAlpha >= currentBeta {
                    break // Beta 剪枝
                }
            }
            return value == -Double.infinity
                ? evaluateBoardForAlliance(state: state, allianceOf: rootSeat, graph: graph)
                : value
        } else {
            var value = Double.infinity
            for move in orderedMoves {
                var childState = state
                guard GameEngine.applyMove(move, in: &childState, graph: graph) != nil else { continue }
                let childScore = alphaBeta(
                    state: childState,
                    depth: depth - 1,
                    alpha: currentAlpha,
                    beta: currentBeta,
                    maximizingTeamOf: rootSeat,
                    graph: graph
                )
                value = min(value, childScore)
                currentBeta = min(currentBeta, value)
                if currentBeta <= currentAlpha {
                    break // Alpha 剪枝
                }
            }
            return value == Double.infinity
                ? evaluateBoardForAlliance(state: state, allianceOf: rootSeat, graph: graph)
                : value
        }
    }

    /// 將未知暗棋以信念追蹤器的最可能階級（MAP）具現化，產生供博弈樹推演的確定化狀態
    private static func determinizeState(_ state: GameState, using tracker: AIBeliefTracker) -> GameState {
        var copy = state
        for (coord, var piece) in copy.pieces {
            if let belief = tracker.beliefsByCoord[coord] {
                piece = Piece(
                    id: piece.id,
                    owner: piece.owner,
                    rank: belief.mostLikelyRank,
                    isPubliclyRevealed: piece.isPubliclyRevealed,
                    hasMoved: piece.hasMoved,
                    turnedOnRailway: piece.turnedOnRailway,
                    killsCount: piece.killsCount,
                    suspicionTag: piece.suspicionTag
                )
                copy.pieces[coord] = piece
            }
        }
        return copy
    }

    /// 博弈樹節點的快速走法生成與排序（Move Ordering：吃子、奪旗、進佔行營優先）
    private static func generateOrderedTacticalMoves(
        in state: GameState,
        for seat: Seat,
        limit: Int,
        graph: BoardGraph
    ) -> [ValidMove] {
        var scored: [(move: ValidMove, priority: Double)] = []
        let enemyFlags = findTargetableFlagCoords(for: seat, in: state, graph: graph)

        for (coord, piece) in state.pieces where piece.owner == seat {
            let moves = MoveGenerator.validMoves(from: coord, pieces: state.pieces, graph: graph)
            for move in moves {
                var p = 0.0
                if let defender = state.pieces[move.to] {
                    if defender.rank == .flag {
                        p += 50_000.0
                    } else {
                        let outcome = GameEngine.resolveCombat(
                            attacker: piece.rank,
                            defender: defender.rank,
                            mineRule: state.mineRule
                        )
                        switch outcome {
                        case .attackerWins:
                            p += Double(defender.rank.tacticalValue) * 1.4
                        case .mutualDestruction:
                            p += Double(defender.rank.tacticalValue - piece.rank.tacticalValue)
                        case .defenderWins, .moveOnly:
                            p -= Double(piece.rank.tacticalValue)
                        }
                    }
                } else {
                    if graph.nodes[move.to]?.type == .camp {
                        p += 85.0
                    }
                    if graph.nodes[move.to]?.type == .headquarters {
                        p -= 1_500.0
                    }
                    if let minAfter = enemyFlags.map({ graph.turnDistance(from: move.to, to: $0, isSapper: piece.rank == .sapper) }).min(),
                       let minBefore = enemyFlags.map({ graph.turnDistance(from: move.from, to: $0, isSapper: piece.rank == .sapper) }).min() {
                        p += Double(minBefore - minAfter) * 35.0
                    }
                }
                scored.append((move, p))
            }
        }

        scored.sort { $0.priority > $1.priority }
        return scored.prefix(limit).map(\.move)
    }

    /// 評估整個局面對於指定同盟（南北 vs 東西）的綜合分數
    private static func evaluateBoardForAlliance(
        state: GameState,
        allianceOf rootSeat: Seat,
        graph: BoardGraph
    ) -> Double {
        if let winner = state.winner {
            let rootIsSouthNorth = (rootSeat == .south || rootSeat == .north)
            if (winner == .southNorthAlliance && rootIsSouthNorth) ||
                (winner == .eastWestAlliance && !rootIsSouthNorth) {
                return 80_000.0
            } else {
                return -80_000.0
            }
        }

        var totalScore = 0.0

        // 1. 存活玩家優勢分（淘汰敵方一家獲得巨大優勢）
        for seat in Seat.allCases {
            let sign = seat.isAlly(with: rootSeat) ? 1.0 : -1.0
            if state.eliminatedSeats.contains(seat) {
                totalScore -= sign * 12_000.0
            }
        }

        // 2. 場上子力、位置、行營控制與亮旗懲罰
        for (coord, piece) in state.pieces {
            let sign = piece.owner.isAlly(with: rootSeat) ? 1.0 : -1.0
            var pieceScore = Double(piece.rank.tacticalValue)

            if let node = graph.nodes[coord] {
                if node.type == .camp {
                    pieceScore += 65.0
                } else if node.type == .railway && piece.rank.isMovableRank {
                    pieceScore += 22.0
                }
            }

            // 軍旗若已暴露，面臨極高被突襲風險
            if piece.rank == .flag && piece.isPubliclyRevealed {
                pieceScore -= 950.0
            }

            totalScore += sign * pieceScore
        }

        return totalScore
    }

    // MARK: - 單步貝氏期望評分 + SEE 靜態反擊評估

    private static func scoreAllMovesWithBeliefAndSEE(
        in state: GameState,
        for seat: Seat,
        tracker: AIBeliefTracker,
        includeRetaliationSEE: Bool,
        graph: BoardGraph
    ) -> [(move: ValidMove, score: Double)] {
        var results: [(move: ValidMove, score: Double)] = []
        let urgentDefenseTargets = findUrgentDefenseTargets(for: seat, in: state, graph: graph)
        let targetableEnemyFlags = findTargetableFlagCoords(for: seat, in: state, tracker: tracker, graph: graph)
        let lastOwnMove = state.moveHistory.last(where: { $0.actor == seat })

        for (coord, piece) in state.pieces where piece.owner == seat {
            let moves = MoveGenerator.validMoves(from: coord, pieces: state.pieces, graph: graph)
            for move in moves {
                let score = evaluateSingleMoveWithBelief(
                    move: move,
                    attacker: piece,
                    seat: seat,
                    state: state,
                    tracker: tracker,
                    urgentDefenseTargets: urgentDefenseTargets,
                    targetableEnemyFlags: targetableEnemyFlags,
                    lastOwnMove: lastOwnMove,
                    includeRetaliationSEE: includeRetaliationSEE,
                    graph: graph
                )
                results.append((move, score))
            }
        }

        results.sort { $0.score > $1.score }
        return results
    }

    private static func evaluateSingleMoveWithBelief(
        move: ValidMove,
        attacker: Piece,
        seat: Seat,
        state: GameState,
        tracker: AIBeliefTracker,
        urgentDefenseTargets: Set<BoardCoord>,
        targetableEnemyFlags: [BoardCoord],
        lastOwnMove: MoveRecord?,
        includeRetaliationSEE: Bool,
        graph: BoardGraph
    ) -> Double {
        guard let fromNode = graph.nodes[move.from],
              let toNode = graph.nodes[move.to] else {
            return -20_000.0
        }

        var score = 0.0
        var survivalProbability = 1.0

        // 1. 交戰期望收益評估（對未知暗棋的所有可能階級進行貝氏期望值積分）
        if let defender = state.pieces[move.to],
           let defenderBelief = tracker.beliefsByCoord[move.to] {
            let (combatScore, winProb) = evaluateExpectedCombat(
                attacker: attacker,
                defender: defender,
                defenderBelief: defenderBelief,
                targetNode: toNode,
                mineRule: state.mineRule
            )
            score += combatScore
            survivalProbability = winProb
        } else {
            // 2. 空位戰術推進與鐵路圖導航評分
            score += evaluatePositionalNavigation(
                move: move,
                attacker: attacker,
                fromNode: fromNode,
                toNode: toNode,
                seat: seat,
                state: state,
                tracker: tracker,
                targetableEnemyFlags: targetableEnemyFlags,
                graph: graph
            )
        }

        // 3. 緊急救旗與攔截加成：若敵棋已逼近己方或盟友軍旗 1 步可達範圍，最高優先級消滅該入侵者！
        if urgentDefenseTargets.contains(move.to) && survivalProbability >= 0.45 {
            score += 4_500.0 * survivalProbability
        }

        // 4. 靜態反擊風險評估（SEE：Static Exchange Evaluation）
        // 預判走到 move.to 並存活後，敵方兩家下一步能否在 move.to 直接吃掉或炸掉我方棋子
        if includeRetaliationSEE && survivalProbability > 0.15 && toNode.type != .camp {
            let retaliationPenalty = computeRetaliationRisk(
                after: move,
                survivingAttacker: attacker,
                in: state,
                tracker: tracker,
                graph: graph
            )
            score -= retaliationPenalty * survivalProbability
        }

        // 5. 避免無意義重複來回走步
        if let lastOwnMove,
           lastOwnMove.from == move.to && lastOwnMove.to == move.from {
            score -= 220.0
        }

        // 6. 微小平手擾動
        score += Double.random(in: 0.0...4.0)
        return score
    }

    /// 根據 `PieceBelief` 後驗機率分佈計算攻擊該敵棋的精確期望價值與存活率
    private static func evaluateExpectedCombat(
        attacker: Piece,
        defender: Piece,
        defenderBelief: PieceBelief,
        targetNode: BoardNode,
        mineRule: MineRule
    ) -> (expectedScore: Double, survivalProbability: Double) {
        var expectedScore = 0.0
        var winProbability = 0.0

        for (defRank, prob) in defenderBelief.probabilities where prob > 0 {
            let outcome = GameEngine.resolveCombat(
                attacker: attacker.rank,
                defender: defRank,
                mineRule: mineRule
            )

            // 若能拔除敵方軍旗，給予決定性高分
            if defRank == .flag && (outcome == .attackerWins || outcome == .mutualDestruction) {
                expectedScore += prob * 55_000.0
                if outcome == .attackerWins {
                    winProbability += prob
                }
                continue
            }

            switch outcome {
            case .attackerWins:
                winProbability += prob
                var winReward = Double(defRank.tacticalValue) * 1.40 + 115.0
                // 工兵成功挖雷額外獎勵
                if attacker.rank == .sapper && defRank == .mine {
                    winReward += 420.0
                }
                expectedScore += prob * winReward

            case .mutualDestruction:
                if attacker.rank == .bomb {
                    // 炸彈專門用來炸敵方司令、軍長、師長，或炸開阻擋軍旗的地雷
                    if defRank == .commander || defRank == .corps || defRank == .division {
                        expectedScore += prob * (Double(defRank.tacticalValue) * 1.45 - 120.0)
                    } else if defRank == .mine {
                        expectedScore += prob * 110.0
                    } else {
                        expectedScore -= prob * 420.0
                    }
                } else {
                    var tradeDelta = Double(defRank.tacticalValue - attacker.rank.tacticalValue)
                    // 己方司令同歸於盡會導致亮出己方軍旗，除非對方也是司令否則略虧
                    if attacker.rank == .commander && defRank != .commander {
                        tradeDelta -= 650.0
                    }
                    expectedScore += prob * tradeDelta
                }

            case .defenderWins, .moveOnly:
                var lossPenalty = Double(attacker.rank.tacticalValue) * 1.50 + 240.0
                // 己方司令撞死會直接暴露軍旗，給予嚴厲懲罰
                if attacker.rank == .commander {
                    lossPenalty += 1_100.0
                }
                // 但若用排長/連長去探明未知的高危敵棋（且敵棋尚未確認身份），給予情報探路補償
                if defenderBelief.confirmedRank == nil && (attacker.rank == .platoon || attacker.rank == .company) {
                    lossPenalty -= 190.0
                }
                expectedScore -= prob * lossPenalty
            }
        }

        return (expectedScore, winProbability)
    }

    /// 計算走完 `move` 後，敵方在下一輪能夠直接反擊 `move.to` 的最大期望損失（SEE）
    private static func computeRetaliationRisk(
        after move: ValidMove,
        survivingAttacker: Piece,
        in state: GameState,
        tracker: AIBeliefTracker,
        graph: BoardGraph
    ) -> Double {
        // 模擬移動後的棋盤佔位
        var postPieces = state.pieces
        postPieces.removeValue(forKey: move.from)
        var placedAttacker = survivingAttacker
        placedAttacker.hasMoved = true
        if move.madeRailwayTurn {
            placedAttacker.turnedOnRailway = true
        }
        postPieces[move.to] = placedAttacker

        let attackerValue = Double(survivingAttacker.rank.tacticalValue)
        let extraCommanderPenalty = (survivingAttacker.rank == .commander) ? 850.0 : 0.0
        var maxExpectedLoss = 0.0

        // 檢查所有敵方棋子是否有一歩直達 move.to 的合法攻擊步
        for (enemyCoord, enemyPiece) in postPieces where !survivingAttacker.owner.isAlly(with: enemyPiece.owner) {
            guard enemyPiece.rank.isMovableRank else { continue }
            // 快速距離過濾：若鐵路感知步數 > 1，則不可能一步反擊到 move.to
            let minSteps = graph.turnDistance(
                from: enemyCoord,
                to: move.to,
                isSapper: true
            )
            if minSteps > 1 {
                continue
            }

            let enemyMoves = MoveGenerator.validMoves(from: enemyCoord, pieces: postPieces, graph: graph)
            guard enemyMoves.contains(where: { $0.to == move.to }),
                  let enemyBelief = tracker.beliefsByID[enemyPiece.id] else {
                continue
            }

            // 計算這枚敵棋反擊我方 survivingAttacker 時，對我方造成的期望淨損失
            var expectedLossFromThisEnemy = 0.0
            for (enemyRank, prob) in enemyBelief.probabilities where prob > 0 && enemyRank.isMovableRank {
                let outcome = GameEngine.resolveCombat(
                    attacker: enemyRank,
                    defender: placedAttacker.rank,
                    mineRule: state.mineRule
                )
                switch outcome {
                case .attackerWins:
                    // 敵方無傷吃掉我方棋子
                    expectedLossFromThisEnemy += prob * (attackerValue + extraCommanderPenalty)
                case .mutualDestruction:
                    // 敵方用炸彈或同階子換掉我方棋子
                    let enemyVal = Double(enemyRank.tacticalValue)
                    if attackerValue + extraCommanderPenalty > enemyVal {
                        expectedLossFromThisEnemy += prob * (attackerValue + extraCommanderPenalty - enemyVal * 0.65)
                    }
                case .defenderWins, .moveOnly:
                    break
                }
            }

            if expectedLossFromThisEnemy > maxExpectedLoss {
                maxExpectedLoss = expectedLossFromThisEnemy
            }
        }

        return maxExpectedLoss * 0.85
    }

    /// 評估空位移動的戰術位置與鐵路圖最短步數導航
    private static func evaluatePositionalNavigation(
        move: ValidMove,
        attacker: Piece,
        fromNode: BoardNode,
        toNode: BoardNode,
        seat: Seat,
        state: GameState,
        tracker: AIBeliefTracker,
        targetableEnemyFlags: [BoardCoord],
        graph: BoardGraph
    ) -> Double {
        var score = 0.0

        // 1. 絕不把可動戰力走進大本營自鎖
        if toNode.type == .headquarters {
            return -3_500.0
        }

        // 2. 行營價值：佔領敵方腹地行營與前線行營極具保護與威懾力
        if toNode.type == .camp {
            score += 105.0
            if let zone = toNode.zone, !zone.isAlly(with: seat) {
                score += 140.0
            }
        }
        if fromNode.type == .camp {
            score -= 40.0
        }

        // 3. 使用 129x129 鐵路感知最短步數矩陣導航向敵方大本營/軍旗推進
        let isSapper = (attacker.rank == .sapper)
        if let distBefore = targetableEnemyFlags.map({ graph.turnDistance(from: move.from, to: $0, isSapper: isSapper) }).min(),
           let distAfter = targetableEnemyFlags.map({ graph.turnDistance(from: move.to, to: $0, isSapper: isSapper) }).min() {
            let stepGain = distBefore - distAfter
            if attacker.rank == .sapper {
                score += Double(stepGain) * 58.0
            } else if attacker.rank == .bomb {
                score += Double(stepGain) * 46.0
            } else {
                score += Double(stepGain) * 38.0
            }
        }

        // 4. 炸彈追擊敵方已確認或高機率的大子（司令/軍長/師長）
        if attacker.rank == .bomb {
            let highValueEnemyCoords = tracker.beliefsByCoord.compactMap { coord, belief -> BoardCoord? in
                guard !seat.isAlly(with: belief.owner) else { return nil }
                let highRankProb = belief.probability(of: .commander)
                    + belief.probability(of: .corps)
                    + belief.probability(of: .division)
                return highRankProb >= 0.55 ? coord : nil
            }
            if let before = highValueEnemyCoords.map({ graph.turnDistance(from: move.from, to: $0, isSapper: false) }).min(),
               let after = highValueEnemyCoords.map({ graph.turnDistance(from: move.to, to: $0, isSapper: false) }).min() {
                score += Double(before - after) * 75.0
            }
        }

        // 5. 工兵主動前往敵方後兩排疑似地雷區排雷開路
        if attacker.rank == .sapper {
            let suspectedMineCoords = tracker.beliefsByCoord.compactMap { coord, belief -> BoardCoord? in
                guard !seat.isAlly(with: belief.owner) else { return nil }
                return belief.mineProbability >= 0.35 ? coord : nil
            }
            if let before = suspectedMineCoords.map({ graph.turnDistance(from: move.from, to: $0, isSapper: true) }).min(),
               let after = suspectedMineCoords.map({ graph.turnDistance(from: move.to, to: $0, isSapper: true) }).min() {
                score += Double(before - after) * 65.0
            }
        }

        // 6. 鐵路控場加成
        if toNode.type == .railway && fromNode.type != .railway {
            score += 35.0
        }

        return score
    }

    /// 找出正在直接威脅己方或對家盟友大本營（距離 1 步以內）的敵方棋子座標
    private static func findUrgentDefenseTargets(
        for seat: Seat,
        in state: GameState,
        graph: BoardGraph
    ) -> Set<BoardCoord> {
        var criticalEnemyCoords: Set<BoardCoord> = []
        let friendlySeats = Seat.allCases.filter { seat.isAlly(with: $0) && !state.eliminatedSeats.contains($0) }

        // 找出己方與盟友真正的軍旗座標（或兩個大本營座標）
        var protectedCoords: Set<BoardCoord> = []
        for fSeat in friendlySeats {
            for hq in graph.headquartersCoords(for: fSeat) {
                if let p = state.pieces[hq], p.rank == .flag {
                    protectedCoords.insert(hq)
                } else {
                    protectedCoords.insert(hq)
                }
            }
        }

        for (enemyCoord, enemyPiece) in state.pieces where !seat.isAlly(with: enemyPiece.owner) {
            let enemyMoves = MoveGenerator.validMoves(from: enemyCoord, pieces: state.pieces, graph: graph)
            for em in enemyMoves {
                if protectedCoords.contains(em.to) {
                    criticalEnemyCoords.insert(enemyCoord)
                }
            }
            for hq in protectedCoords {
                if graph.turnDistance(from: enemyCoord, to: hq, isSapper: false) <= 1 {
                    criticalEnemyCoords.insert(enemyCoord)
                }
            }
        }

        return criticalEnemyCoords
    }

    /// 找出敵方可能是軍旗的大本營座標
    private static func findTargetableFlagCoords(
        for seat: Seat,
        in state: GameState,
        tracker: AIBeliefTracker? = nil,
        graph: BoardGraph
    ) -> [BoardCoord] {
        var result: [BoardCoord] = []
        for other in Seat.allCases where !seat.isAlly(with: other) && !state.eliminatedSeats.contains(other) {
            let hqs = graph.headquartersCoords(for: other)
            for hq in hqs {
                if let tracker, let belief = tracker.beliefsByCoord[hq] {
                    if belief.flagProbability > 0.05 {
                        result.append(hq)
                    }
                } else if state.pieces[hq] != nil {
                    result.append(hq)
                }
            }
        }
        return result
    }
}
