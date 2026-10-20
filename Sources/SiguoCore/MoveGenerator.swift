import Foundation

/// 行棋路徑與合法步數產生器
public enum MoveGenerator {
    /// 計算指定座標上棋子的所有合法移動步
    public static func validMoves(
        from start: BoardCoord,
        pieces: [BoardCoord: Piece],
        graph: BoardGraph = .shared
    ) -> [ValidMove] {
        guard let piece = pieces[start],
              let startNode = graph.nodes[start] else {
            return []
        }

        // 地雷、軍旗、以及已進入大本營的棋子皆不可移動
        if !piece.rank.isMovableRank || startNode.type == .headquarters {
            return []
        }

        var movesByTarget: [BoardCoord: ValidMove] = [:]

        // 1. 公路一步移動
        if let roadSet = graph.roadNeighbors[start] {
            for target in roadSet {
                if canLand(attacker: piece, on: target, pieces: pieces, graph: graph) {
                    movesByTarget[target] = ValidMove(
                        from: start,
                        to: target,
                        path: [start, target],
                        madeRailwayTurn: false
                    )
                }
            }
        }

        // 2. 鐵路移動
        if startNode.type == .railway {
            // 先計算不轉彎（直線或外圍單彎軌道）可達的鐵路目標
            let straightMoves = straightRailwayMoves(from: start, attacker: piece, pieces: pieces, graph: graph)
            for move in straightMoves {
                movesByTarget[move.to] = move
            }

            // 若為工兵，可透過 BFS 沿任意無阻擋鐵路轉彎飛棋
            if piece.rank == .sapper {
                let straightTargets = Set(straightMoves.map(\.to))
                let sapperMoves = sapperBFSRailwayMoves(
                    from: start,
                    attacker: piece,
                    pieces: pieces,
                    straightTargets: straightTargets,
                    graph: graph
                )
                for move in sapperMoves where movesByTarget[move.to] == nil {
                    movesByTarget[move.to] = move
                }
            }
        }

        return movesByTarget.values.sorted {
            if $0.to.row != $1.to.row { return $0.to.row < $1.to.row }
            return $0.to.col < $1.to.col
        }
    }

    /// 檢查某玩家是否還有任何一枚可移動的合法步數（若無則判定無子可動淘汰）
    public static func hasAnyValidMove(
        for seat: Seat,
        pieces: [BoardCoord: Piece],
        graph: BoardGraph = .shared
    ) -> Bool {
        for (coord, piece) in pieces where piece.owner == seat {
            if !validMoves(from: coord, pieces: pieces, graph: graph).isEmpty {
                return true
            }
        }
        return false
    }

    /// 判斷攻擊方是否可落子於目標座標（空位，或非行營內的敵方棋子）
    public static func canLand(
        attacker: Piece,
        on target: BoardCoord,
        pieces: [BoardCoord: Piece],
        graph: BoardGraph = .shared
    ) -> Bool {
        guard let targetNode = graph.nodes[target] else {
            return false
        }
        guard let defender = pieces[target] else {
            // 空位皆可進入
            return true
        }
        // 同陣營（自己或對家盟友）不可互吃
        if attacker.owner.isAlly(with: defender.owner) {
            return false
        }
        // 行營內的棋子受保護，不可被攻擊
        if targetNode.type == .camp {
            return false
        }
        return true
    }

    /// 非工兵（或工兵直線段）在連續鐵路軌道上的滑行步數
    private static func straightRailwayMoves(
        from start: BoardCoord,
        attacker: Piece,
        pieces: [BoardCoord: Piece],
        graph: BoardGraph
    ) -> [ValidMove] {
        var results: [BoardCoord: ValidMove] = [:]

        for line in graph.railwayLines {
            guard let startIndex = line.firstIndex(of: start) else { continue }

            // 往正向延伸
            if startIndex + 1 < line.count {
                var currentPath: [BoardCoord] = [start]
                for idx in (startIndex + 1)..<line.count {
                    let target = line[idx]
                    currentPath.append(target)
                    if pieces[target] == nil {
                        if results[target] == nil || currentPath.count < (results[target]?.path.count ?? Int.max) {
                            results[target] = ValidMove(
                                from: start,
                                to: target,
                                path: currentPath,
                                madeRailwayTurn: false
                            )
                        }
                    } else {
                        if canLand(attacker: attacker, on: target, pieces: pieces, graph: graph) {
                            if results[target] == nil || currentPath.count < (results[target]?.path.count ?? Int.max) {
                                results[target] = ValidMove(
                                    from: start,
                                    to: target,
                                    path: currentPath,
                                    madeRailwayTurn: false
                                )
                            }
                        }
                        break
                    }
                }
            }

            // 往反向延伸
            if startIndex > 0 {
                var currentPath: [BoardCoord] = [start]
                for idx in (0..<startIndex).reversed() {
                    let target = line[idx]
                    currentPath.append(target)
                    if pieces[target] == nil {
                        if results[target] == nil || currentPath.count < (results[target]?.path.count ?? Int.max) {
                            results[target] = ValidMove(
                                from: start,
                                to: target,
                                path: currentPath,
                                madeRailwayTurn: false
                            )
                        }
                    } else {
                        if canLand(attacker: attacker, on: target, pieces: pieces, graph: graph) {
                            if results[target] == nil || currentPath.count < (results[target]?.path.count ?? Int.max) {
                                results[target] = ValidMove(
                                    from: start,
                                    to: target,
                                    path: currentPath,
                                    madeRailwayTurn: false
                                )
                            }
                        }
                        break
                    }
                }
            }
        }

        return Array(results.values)
    }

    /// 工兵在鐵路網上的廣度優先搜尋（BFS），支援任意轉彎
    private static func sapperBFSRailwayMoves(
        from start: BoardCoord,
        attacker: Piece,
        pieces: [BoardCoord: Piece],
        straightTargets: Set<BoardCoord>,
        graph: BoardGraph
    ) -> [ValidMove] {
        var visited: Set<BoardCoord> = [start]
        var queue: [(coord: BoardCoord, path: [BoardCoord])] = [(start, [start])]
        var queueIndex = 0
        var results: [ValidMove] = []

        while queueIndex < queue.count {
            let (current, currentPath) = queue[queueIndex]
            queueIndex += 1

            guard let neighbors = graph.railwayNeighbors[current] else { continue }
            let sortedNeighbors = neighbors.sorted {
                if $0.row != $1.row { return $0.row < $1.row }
                return $0.col < $1.col
            }

            for next in sortedNeighbors where !visited.contains(next) {
                visited.insert(next)
                let nextPath = currentPath + [next]

                if pieces[next] == nil {
                    let turned = !straightTargets.contains(next)
                    results.append(ValidMove(
                        from: start,
                        to: next,
                        path: nextPath,
                        madeRailwayTurn: turned
                    ))
                    // 空鐵路節點可繼續向外擴展
                    queue.append((next, nextPath))
                } else if canLand(attacker: attacker, on: next, pieces: pieces, graph: graph) {
                    let turned = !straightTargets.contains(next)
                    results.append(ValidMove(
                        from: start,
                        to: next,
                        path: nextPath,
                        madeRailwayTurn: turned
                    ))
                    // 有棋子阻擋，不可穿過該棋子繼續擴展
                }
            }
        }

        return results
    }
}
