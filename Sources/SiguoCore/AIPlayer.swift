import Foundation

/// 具備資訊集感知（不作弊偷看暗棋）與同盟協同意識的四國軍棋 AI 引擎
public enum AIPlayer {
    /// 為指定 AI 座位選擇最佳合法走步
    public static func chooseMove(
        in state: GameState,
        for seat: Seat,
        graph: BoardGraph = .shared
    ) -> ValidMove? {
        guard state.phase == .playing, state.currentTurn == seat else {
            return nil
        }

        var candidateMoves: [(move: ValidMove, score: Double)] = []
        let threatenedHQCoords = findThreatenedHQs(for: seat, in: state, graph: graph)
        let lastOwnMove = state.moveHistory.last(where: { $0.actor == seat })

        for (coord, piece) in state.pieces where piece.owner == seat {
            let moves = MoveGenerator.validMoves(from: coord, pieces: state.pieces, graph: graph)
            for move in moves {
                let score = evaluateMove(
                    move,
                    attacker: piece,
                    seat: seat,
                    state: state,
                    threatenedHQCoords: threatenedHQCoords,
                    lastOwnMove: lastOwnMove,
                    graph: graph
                )
                candidateMoves.append((move, score))
            }
        }

        guard !candidateMoves.isEmpty else {
            return nil
        }

        candidateMoves.sort { $0.score > $1.score }
        return candidateMoves.first?.move
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

    /// 評估單步走棋的綜合戰術分數
    private static func evaluateMove(
        _ move: ValidMove,
        attacker: Piece,
        seat: Seat,
        state: GameState,
        threatenedHQCoords: Set<BoardCoord>,
        lastOwnMove: MoveRecord?,
        graph: BoardGraph
    ) -> Double {
        var score: Double = 0.0

        guard let fromNode = graph.nodes[move.from],
              let toNode = graph.nodes[move.to] else {
            return -10_000
        }

        // 1. 若目標格有敵方棋子：評估交戰收益與風險
        if let defender = state.pieces[move.to] {
            score += evaluateCombat(
                attacker: attacker,
                defender: defender,
                targetNode: toNode,
                observer: seat,
                state: state
            )
        } else {
            // 2. 純移動位置評分
            score += evaluatePositionalMove(
                move: move,
                attacker: attacker,
                fromNode: fromNode,
                toNode: toNode,
                seat: seat,
                state: state,
                graph: graph
            )
        }

        // 3. 若己方或盟友大本營受到敵軍逼近威脅，優先攔截或吃掉入侵者
        for hqCoord in threatenedHQCoords {
            let distBefore = manhattanDistance(move.from, hqCoord)
            let distAfter = manhattanDistance(move.to, hqCoord)
            if state.pieces[move.to] != nil && distAfter <= 2 {
                // 直接吃掉大本營附近的敵軍
                score += 650.0
            } else if distAfter < distBefore && distAfter <= 2 {
                score += 180.0
            }
        }

        // 4. 避免無意義來回踱步
        if let lastOwnMove,
           lastOwnMove.from == move.to && lastOwnMove.to == move.from {
            score -= 160.0
        }

        // 5. 加入微小隨機擾動，讓同等分值的走法更自然多變
        score += Double.random(in: 0.0...12.0)

        return score
    }

    /// 評估攻擊敵方棋子的期望收益
    private static func evaluateCombat(
        attacker: Piece,
        defender: Piece,
        targetNode: BoardNode,
        observer: Seat,
        state: GameState
    ) -> Double {
        let knowsDefenderRank = canSeePieceRank(
            observer: observer,
            target: defender,
            mode: state.visibilityMode
        )

        // 情況 A：已知敵方棋子真實階級（全明模式、已亮出的軍旗、或轉過彎的工兵）
        if knowsDefenderRank {
            let outcome = GameEngine.resolveCombat(
                attacker: attacker.rank,
                defender: defender.rank,
                mineRule: state.mineRule
            )
            if defender.rank == .flag && (outcome == .attackerWins || outcome == .mutualDestruction) {
                return 50_000.0
            }
            switch outcome {
            case .attackerWins:
                return Double(defender.rank.tacticalValue) * 1.4 + 120.0
            case .mutualDestruction:
                // 用炸彈換司令/軍長/師長划算，但換連排長不划算
                if attacker.rank == .bomb {
                    if defender.rank == .commander || defender.rank == .corps || defender.rank == .division {
                        return Double(defender.rank.tacticalValue) * 1.25 - 200.0
                    } else if defender.rank == .mine {
                        return 80.0
                    } else {
                        return -380.0
                    }
                }
                return Double(defender.rank.tacticalValue - attacker.rank.tacticalValue)
            case .defenderWins, .moveOnly:
                return -Double(attacker.rank.tacticalValue) * 1.5 - 300.0
            }
        }

        // 情況 B：未知暗棋推論（不偷看 defender.rank）
        // B1. 目標位於敵方大本營：極可能是軍旗或假旗
        if targetNode.type == .headquarters {
            if attacker.rank == .bomb {
                return 2_200.0
            }
            return 3_500.0 - Double(attacker.rank.tacticalValue) * 0.3
        }

        // B2. 目標位於敵方陣地最後兩排且從未移動過：高度疑似地雷
        let isUnmovedBackRow = !defender.hasMoved &&
            (targetNode.localCoord?.row == 4 || targetNode.localCoord?.row == 5)

        if isUnmovedBackRow {
            if attacker.rank == .sapper {
                // 工兵主動去排雷！
                return 680.0
            }
            if attacker.rank == .platoon || attacker.rank == .company {
                // 小子必要時可探雷
                return 65.0
            }
            if attacker.rank == .bomb {
                // 炸彈可開路炸雷
                return 140.0
            }
            // 大子絕不輕易撞後兩排未知未動棋子（極易撞死在地雷上）
            return -Double(attacker.rank.tacticalValue) * 1.1
        }

        // B3. 敵棋已經連吃多子，推估為司令/軍長/師長等主力大子
        if defender.killsCount >= 2 {
            if attacker.rank == .bomb {
                // 派炸彈與敵方連殺主力同歸於盡！
                return 920.0 + Double(defender.killsCount * 120)
            }
            if attacker.rank == .commander {
                return 540.0
            }
            if attacker.rank == .corps {
                return 310.0
            }
            return -Double(attacker.rank.tacticalValue) * 0.9
        }

        // B4. 一般未知移動過或前中排敵棋
        if attacker.rank == .bomb {
            // 炸彈不隨便撞未知普通棋子，除非敵棋逼近己方腹地
            let inFriendlyZone = targetNode.zone.map { $0.isAlly(with: observer) } ?? false
            return inFriendlyZone ? 260.0 : -150.0
        }

        if attacker.rank == .sapper {
            // 工兵珍貴，盡量少與未知活動棋子硬碰硬
            return -180.0
        }

        let strength = attacker.rank.combatStrength ?? 33
        // 中高階棋子積極進攻未知前排敵棋，連排長也可主動探路換子
        let baseAggression = Double(strength - 31) * 42.0
        let probeBonus = (attacker.rank == .platoon || attacker.rank == .company) ? 145.0 : 0.0
        return baseAggression + probeBonus
    }

    /// 評估移動至空位的戰術價值
    private static func evaluatePositionalMove(
        move: ValidMove,
        attacker: Piece,
        fromNode: BoardNode,
        toNode: BoardNode,
        seat: Seat,
        state: GameState,
        graph: BoardGraph
    ) -> Double {
        var score = 0.0

        // 1. 絕不輕易把棋子走進大本營（進大本營後將永遠無法再移動）
        if toNode.type == .headquarters {
            return -2_000.0
        }

        // 2. 進駐空行營有保護加成，離開行營有輕微折損
        if toNode.type == .camp {
            score += 95.0
            if let zone = toNode.zone, !zone.isAlly(with: seat) {
                // 佔領敵方陣地內的行營極具戰略威脅
                score += 120.0
            }
        }
        if fromNode.type == .camp {
            score -= 35.0
        }

        // 3. 鼓勵可動戰力向敵方大本營方向推進
        let enemyHQs = enemyHeadquartersCoords(for: seat, in: state, graph: graph)
        if let nearestBefore = enemyHQs.map({ manhattanDistance(move.from, $0) }).min(),
           let nearestAfter = enemyHQs.map({ manhattanDistance(move.to, $0) }).min() {
            let progress = nearestBefore - nearestAfter
            if attacker.rank == .sapper {
                score += Double(progress) * 28.0
            } else if attacker.rank == .bomb {
                score += Double(progress) * 22.0
            } else {
                score += Double(progress) * 18.0
            }
        }

        // 4. 鼓勵大子與工兵站上鐵路保持高機動性
        if toNode.type == .railway && fromNode.type != .railway {
            score += 32.0
        }

        // 5. 若己方後排護旗大子在開局無威脅時，保留一定防守穩定性
        if fromNode.zone == seat,
           let local = fromNode.localCoord,
           local.row >= 4,
           state.moveHistory.count < 16 {
            score -= 25.0
        }

        return score
    }

    /// 找出目前存活敵方的所有大本營座標
    private static func enemyHeadquartersCoords(
        for seat: Seat,
        in state: GameState,
        graph: BoardGraph
    ) -> [BoardCoord] {
        var coords: [BoardCoord] = []
        for other in Seat.allCases where !seat.isAlly(with: other) && !state.eliminatedSeats.contains(other) {
            coords.append(contentsOf: graph.headquartersCoords(for: other))
        }
        return coords
    }

    /// 找出己方或盟友目前受到敵棋逼近的大本營座標
    private static func findThreatenedHQs(
        for seat: Seat,
        in state: GameState,
        graph: BoardGraph
    ) -> Set<BoardCoord> {
        var threatened: Set<BoardCoord> = []
        let friendlySeats = Seat.allCases.filter { seat.isAlly(with: $0) && !state.eliminatedSeats.contains($0) }
        let friendlyHQs = friendlySeats.flatMap { graph.headquartersCoords(for: $0) }

        for (coord, piece) in state.pieces where !seat.isAlly(with: piece.owner) {
            for hq in friendlyHQs {
                if manhattanDistance(coord, hq) <= 3 {
                    threatened.insert(hq)
                }
            }
        }
        return threatened
    }

    private static func manhattanDistance(_ a: BoardCoord, _ b: BoardCoord) -> Int {
        abs(a.row - b.row) + abs(a.col - b.col)
    }
}
