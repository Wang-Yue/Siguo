import Foundation

/// 單枚棋子在 AI 視角下的信念與機率分佈模型
public struct PieceBelief: Sendable, Equatable {
    public let pieceID: UUID
    public let owner: Seat
    public let coord: BoardCoord
    /// 各階級的後驗機率分佈（總和為 1.0）
    public let probabilities: [PieceRank: Double]
    /// 若已 100% 確定階級，則回傳該階級
    public let confirmedRank: PieceRank?
    /// 推算的最小數值戰力下界（若必為普通戰力子）
    public let minCombatStrength: Int?

    public init(
        pieceID: UUID,
        owner: Seat,
        coord: BoardCoord,
        probabilities: [PieceRank: Double],
        confirmedRank: PieceRank?,
        minCombatStrength: Int?
    ) {
        self.pieceID = pieceID
        self.owner = owner
        self.coord = coord
        self.probabilities = probabilities
        self.confirmedRank = confirmedRank
        self.minCombatStrength = minCombatStrength
    }

    /// 查詢特定階級的機率
    public func probability(of rank: PieceRank) -> Double {
        probabilities[rank] ?? 0.0
    }

    /// 該棋子為炸彈的機率
    public var bombProbability: Double {
        probability(of: .bomb)
    }

    /// 該棋子為地雷的機率
    public var mineProbability: Double {
        probability(of: .mine)
    }

    /// 該棋子為軍旗的機率
    public var flagProbability: Double {
        probability(of: .flag)
    }

    /// 該棋子戰力期望價值（供 AI 評估吃子價值與威脅度）
    public var expectedTacticalValue: Double {
        if let confirmedRank {
            return Double(confirmedRank.tacticalValue)
        }
        var total = 0.0
        for (rank, prob) in probabilities {
            total += prob * Double(rank.tacticalValue)
        }
        return total
    }

    /// 最可能的階級（MAP 估計，供博弈樹確定化模擬使用）
    public var mostLikelyRank: PieceRank {
        if let confirmedRank {
            return confirmedRank
        }
        return probabilities.max(by: { a, b in
            if abs(a.value - b.value) > 1e-6 {
                return a.value < b.value
            }
            return a.key.tacticalValue < b.key.tacticalValue
        })?.key ?? .battalion
    }
}

/// 歷史交戰推理與全場暗棋信念追蹤器（嚴格遵守資訊集公平原則，不偷看暗棋）
public struct AIBeliefTracker: Sendable {
    public let observer: Seat
    public let beliefsByCoord: [BoardCoord: PieceBelief]
    public let beliefsByID: [UUID: PieceBelief]
    public let remainingPool: [Seat: [PieceRank: Int]]

    public init(state: GameState, observer: Seat, graph: BoardGraph = .shared) {
        self.observer = observer

        // 1. 初始化四家標準 25 枚棋子池
        var pool: [Seat: [PieceRank: Int]] = [:]
        for seat in Seat.allCases {
            var seatCounts: [PieceRank: Int] = [:]
            for rank in PieceRank.allCases {
                seatCounts[rank] = rank.standardCount
            }
            pool[seat] = seatCounts
        }

        // 2. 掃描歷史交戰紀錄，扣除已確認陣亡的已知階級棋子（以及透過亮旗推知的陣亡司令與同歸炸彈）
        for record in state.moveHistory {
            let attackerDied = (record.outcome == .defenderWins || record.outcome == .mutualDestruction)
            let defenderDied = (record.outcome == .attackerWins || record.outcome == .mutualDestruction)

            if attackerDied {
                if let knownRank = Self.knownHistoricalRank(
                    of: record.attackerPiece,
                    record: record,
                    isAttacker: true,
                    observer: observer,
                    mode: state.visibilityMode
                ) {
                    Self.decrementPool(&pool, seat: record.attackerPiece.owner, rank: knownRank)
                }
            }

            if defenderDied, let defender = record.defenderPiece {
                if let knownRank = Self.knownHistoricalRank(
                    of: defender,
                    record: record,
                    isAttacker: false,
                    observer: observer,
                    mode: state.visibilityMode
                ) {
                    Self.decrementPool(&pool, seat: defender.owner, rank: knownRank)
                }
            }
        }

        // 若某方軍旗已公開亮出，代表該方司令必定已陣亡（若場上沒有已公開的該方司令）
        for seat in Seat.allCases where !state.eliminatedSeats.contains(seat) {
            let flagRevealed = state.pieces.values.contains {
                $0.owner == seat && $0.rank == .flag && $0.isPubliclyRevealed
            }
            if flagRevealed {
                pool[seat]?[.commander] = 0
            }
        }

        // 3. 先鎖定場上所有對 observer 而言已知身份的存活棋子，並從未知牌池扣除
        var confirmedByCoord: [BoardCoord: PieceRank] = [:]
        for (coord, piece) in state.pieces {
            if AIPlayer.canSeePieceRank(observer: observer, target: piece, mode: state.visibilityMode) {
                confirmedByCoord[coord] = piece.rank
                Self.decrementPool(&pool, seat: piece.owner, rank: piece.rank)
            }
        }

        // 4. 針對每一枚未知暗棋建立硬約束候選集 (Hard Constraints)
        var candidatesByCoord: [BoardCoord: Set<PieceRank>] = [:]
        for (coord, piece) in state.pieces where confirmedByCoord[coord] == nil {
            var candidates = Set(PieceRank.allCases.filter { (pool[piece.owner]?[$0] ?? 0) > 0 })
            let node = graph.nodes[coord]

            // 4a. 移動與地形約束
            if piece.hasMoved {
                candidates.remove(.flag)
                candidates.remove(.mine)
            }
            if node?.type != .headquarters {
                candidates.remove(.flag)
            }
            if piece.turnedOnRailway {
                candidates = [.sapper]
            }

            // 4b. 若從未移動過，必遵守開局佈陣規則
            if !piece.hasMoved, let node, node.zone == piece.owner, let local = node.localCoord {
                if local.row == 0 {
                    candidates.remove(.bomb)
                    candidates.remove(.mine)
                    candidates.remove(.flag)
                } else if local.row < 4 {
                    candidates.remove(.mine)
                    candidates.remove(.flag)
                }
            }

            // 4c. 掃描該棋子參與過的所有交戰紀錄，推演戰力下界與排除集合
            for record in state.moveHistory {
                if record.attackerPiece.id == piece.id && record.outcome == .attackerWins {
                    // 作為主動攻擊方獲勝：必非炸彈、地雷、軍旗
                    candidates.remove(.bomb)
                    candidates.remove(.mine)
                    candidates.remove(.flag)

                    if let defender = record.defenderPiece,
                       let defRank = Self.knownRankIfVisible(defender, observer: observer, mode: state.visibilityMode) {
                        if defRank == .mine {
                            // 能主動挖掉地雷並存活的只有工兵！
                            candidates = [.sapper]
                        } else if let defStrength = defRank.combatStrength {
                            // 戰力必嚴格大於被吃掉的已知棋子
                            candidates = candidates.filter { rank in
                                guard let s = rank.combatStrength else { return false }
                                return s > defStrength
                            }
                        }
                    }
                } else if record.defenderPiece?.id == piece.id && record.outcome == .defenderWins {
                    // 作為防守方獲勝：必非炸彈、軍旗
                    candidates.remove(.bomb)
                    candidates.remove(.flag)

                    let attacker = record.attackerPiece
                    if let attRank = Self.knownRankIfVisible(attacker, observer: observer, mode: state.visibilityMode) {
                        if attRank == .sapper {
                            // 工兵撞死在該棋子上：該棋子必非地雷（否則會被工兵挖掉），且戰力 > 工兵(32)
                            candidates.remove(.mine)
                            candidates = candidates.filter { rank in
                                guard let s = rank.combatStrength else { return false }
                                return s > 32
                            }
                        } else if attRank == .commander {
                            // 司令撞死在該棋子上：全場沒有比司令更大的活子，該棋子 100% 是地雷！
                            candidates = [.mine]
                        } else if let attStrength = attRank.combatStrength {
                            // 可能是地雷（若未動過且在後兩排），或是戰力嚴格大於攻擊方的活子
                            candidates = candidates.filter { rank in
                                if rank == .mine { return true }
                                guard let s = rank.combatStrength else { return false }
                                return s > attStrength
                            }
                        }
                    }
                }
            }

            candidatesByCoord[coord] = candidates
        }

        // 5. 大本營唯一軍旗約束：若某敵方只有一個大本營內有未移動過的棋子，該棋子 100% 為軍旗
        for seat in Seat.allCases where !state.eliminatedSeats.contains(seat) {
            let hqCoords = graph.headquartersCoords(for: seat)
            let unmovedHQCoords = hqCoords.filter { coord in
                guard let p = state.pieces[coord] else { return false }
                return p.owner == seat && !p.hasMoved
            }
            if unmovedHQCoords.count == 1, let soleHQ = unmovedHQCoords.first {
                confirmedByCoord[soleHQ] = .flag
                candidatesByCoord.removeValue(forKey: soleHQ)
                for otherCoord in candidatesByCoord.keys where state.pieces[otherCoord]?.owner == seat {
                    candidatesByCoord[otherCoord]?.remove(.flag)
                }
            }
        }

        // 6. 單一候選收斂傳播（Constraint Propagation）
        var changed = true
        while changed {
            changed = false
            for (coord, candidates) in candidatesByCoord {
                guard let piece = state.pieces[coord] else { continue }
                if candidates.count == 1, let soleRank = candidates.first {
                    confirmedByCoord[coord] = soleRank
                    candidatesByCoord.removeValue(forKey: coord)
                    Self.decrementPool(&pool, seat: piece.owner, rank: soleRank)

                    // 若該階級在該玩家的剩餘牌池已歸零，從同陣營其他未知棋子候選中移除
                    if (pool[piece.owner]?[soleRank] ?? 0) <= 0 {
                        for otherCoord in candidatesByCoord.keys where state.pieces[otherCoord]?.owner == piece.owner {
                            if candidatesByCoord[otherCoord]?.remove(soleRank) != nil {
                                changed = true
                            }
                        }
                    }
                    changed = true
                    break
                }
            }
        }

        // 7. 計算每枚棋子的最終後驗機率分佈 PieceBelief
        var byCoord: [BoardCoord: PieceBelief] = [:]
        var byID: [UUID: PieceBelief] = [:]

        for (coord, piece) in state.pieces {
            if let confirmed = confirmedByCoord[coord] {
                let belief = PieceBelief(
                    pieceID: piece.id,
                    owner: piece.owner,
                    coord: coord,
                    probabilities: [confirmed: 1.0],
                    confirmedRank: confirmed,
                    minCombatStrength: confirmed.combatStrength
                )
                byCoord[coord] = belief
                byID[piece.id] = belief
                continue
            }

            let candidates = candidatesByCoord[coord] ?? Set(PieceRank.allCases)
            let node = graph.nodes[coord]
            var rawWeights: [PieceRank: Double] = [:]

            for rank in candidates {
                let baseCount = max(1, pool[piece.owner]?[rank] ?? 1)
                var weight = Double(baseCount)

                // 位置與行為啟發式似然加權 (Bayesian Likelihood)
                if node?.type == .headquarters && !piece.hasMoved {
                    if rank == .flag {
                        weight *= 6.0
                    } else if rank == .platoon || rank == .company {
                        weight *= 2.2
                    } else {
                        weight *= 0.25
                    }
                } else if !piece.hasMoved, let local = node?.localCoord, local.row >= 4 {
                    if rank == .mine {
                        weight *= 2.8
                    }
                }

                // 若曾吃過未知棋子，大子與高階棋子似然提升
                if piece.killsCount > 0 {
                    if let s = rank.combatStrength {
                        let boost = Double(max(1, s - 31)) * (1.0 + Double(piece.killsCount) * 0.45)
                        weight *= boost
                    }
                }

                rawWeights[rank] = weight
            }

            let sum = rawWeights.values.reduce(0.0, +)
            var normalized: [PieceRank: Double] = [:]
            if sum > 0 {
                for (r, w) in rawWeights {
                    normalized[r] = w / sum
                }
            } else {
                normalized[.battalion] = 1.0
            }

            let nonMineStrengths = candidates.compactMap(\.combatStrength)
            let minStrength = (!candidates.contains(.mine) && !candidates.contains(.bomb) && !candidates.contains(.flag))
                ? nonMineStrengths.min()
                : nil

            let belief = PieceBelief(
                pieceID: piece.id,
                owner: piece.owner,
                coord: coord,
                probabilities: normalized,
                confirmedRank: nil,
                minCombatStrength: minStrength
            )
            byCoord[coord] = belief
            byID[piece.id] = belief
        }

        self.beliefsByCoord = byCoord
        self.beliefsByID = byID
        self.remainingPool = pool
    }

    // MARK: - 輔助推論方法

    private static func knownRankIfVisible(
        _ piece: Piece,
        observer: Seat,
        mode: VisibilityMode
    ) -> PieceRank? {
        if AIPlayer.canSeePieceRank(observer: observer, target: piece, mode: mode) {
            return piece.rank
        }
        return nil
    }

    /// 判斷歷史戰報中某枚陣亡棋子是否能被 observer 確知階級
    private static func knownHistoricalRank(
        of deadPiece: Piece,
        record: MoveRecord,
        isAttacker: Bool,
        observer: Seat,
        mode: VisibilityMode
    ) -> PieceRank? {
        if AIPlayer.canSeePieceRank(observer: observer, target: deadPiece, mode: mode) {
            return deadPiece.rank
        }
        // 若該步觸發了該座位的「司令陣亡，亮出軍旗」公告，代表陣亡者必為司令
        let commanderNote = "\(deadPiece.owner.displayName)司令陣亡"
        if record.specialAnnouncements.contains(where: { $0.contains(commanderNote) }) {
            return .commander
        }
        // 若雙方同歸於盡，且另一方是我方已知的司令(40)，而對方並未觸發「司令陣亡」公告，代表對方必為炸彈（或同歸地雷）
        if record.outcome == .mutualDestruction {
            let otherPiece = isAttacker ? record.defenderPiece : record.attackerPiece
            if let otherPiece,
               AIPlayer.canSeePieceRank(observer: observer, target: otherPiece, mode: mode),
               otherPiece.rank == .commander,
               !record.specialAnnouncements.contains(where: { $0.contains(commanderNote) }) {
                if deadPiece.hasMoved || isAttacker {
                    return .bomb
                }
            }
        }
        return nil
    }

    private static func decrementPool(
        _ pool: inout [Seat: [PieceRank: Int]],
        seat: Seat,
        rank: PieceRank
    ) {
        if let current = pool[seat]?[rank], current > 0 {
            pool[seat]?[rank] = current - 1
        }
    }
}
