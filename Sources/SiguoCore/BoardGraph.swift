import Foundation

/// 四國軍棋 17x17 棋盤拓撲結構（執行緒安全、不可變值語義）
public struct BoardGraph: Sendable {
    public static let shared = BoardGraph()

    /// 全部 129 個有效節點（以座標查詢）
    public let nodes: [BoardCoord: BoardNode]
    /// 全部有效座標列表（依 row, col 排序）
    public let allCoords: [BoardCoord]
    /// 公路鄰接表（走一步可達的節點，含行營八方斜線與普通兵站連線）
    public let roadNeighbors: [BoardCoord: Set<BoardCoord>]
    /// 鐵路鄰接表（供工兵 BFS 任意轉彎尋路）
    public let railwayNeighbors: [BoardCoord: Set<BoardCoord>]
    /// 連續鐵路軌道列表（供非工兵棋子沿直線或外圍彎道直衝）
    public let railwayLines: [[BoardCoord]]
    /// 四條外圍彎道鐵路端點對（供視覺繪製弧線）
    public let outerCurvePairs: [(BoardCoord, BoardCoord)]
    /// 非工兵棋子在兩點間的理想最少移動回合數（考慮鐵路直線/外圍單彎一步直達）
    public let nonSapperTurnDistance: [BoardCoord: [BoardCoord: Int]]
    /// 工兵在兩點間的理想最少移動回合數（考慮全鐵路網一步飛棋）
    public let sapperTurnDistance: [BoardCoord: [BoardCoord: Int]]

    private init() {
        var nodesDict: [BoardCoord: BoardNode] = [:]
        var roadAdj: [BoardCoord: Set<BoardCoord>] = [:]
        var railAdj: [BoardCoord: Set<BoardCoord>] = [:]

        func addEdge(_ map: inout [BoardCoord: Set<BoardCoord>], _ a: BoardCoord, _ b: BoardCoord) {
            map[a, default: []].insert(b)
            map[b, default: []].insert(a)
        }

        // 1. 建立四方陣地節點（每方 6x5 = 30 個節點）
        for seat in Seat.allCases {
            for r in 0..<6 {
                for c in 0..<5 {
                    let local = LocalCoord(row: r, col: c)
                    let coord = Self.globalCoord(for: seat, local: local)
                    let type = Self.nodeType(for: local)
                    nodesDict[coord] = BoardNode(coord: coord, type: type, zone: seat, localCoord: local)
                }
            }
        }

        // 2. 建立中央九宮格節點（3x3 = 9 個節點）
        let centerIndices = [6, 8, 10]
        for r in centerIndices {
            for c in centerIndices {
                let coord = BoardCoord(row: r, col: c)
                nodesDict[coord] = BoardNode(coord: coord, type: .railway, zone: nil, localCoord: nil)
            }
        }

        // 3. 建立四方陣地內部的公路連線（非鐵路直線部分，以及行營八方斜線）
        for seat in Seat.allCases {
            for r in 0..<6 {
                for c in 0..<5 {
                    let localA = LocalCoord(row: r, col: c)
                    let coordA = Self.globalCoord(for: seat, local: localA)
                    let typeA = Self.nodeType(for: localA)

                    // 正交四方向鄰居
                    let orthoOffsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]
                    for (dr, dc) in orthoOffsets {
                        let nr = r + dr
                        let nc = c + dc
                        guard (0..<6).contains(nr), (0..<5).contains(nc) else { continue }
                        let localB = LocalCoord(row: nr, col: nc)
                        let coordB = Self.globalCoord(for: seat, local: localB)
                        // 若兩點同在鐵路軌道上，則由鐵路軌道負責連線；但一步移動也可視為相鄰，我們統一把非鐵路連線放入 roadAdj
                        if !Self.isInternalRailwayEdge(localA, localB) {
                            addEdge(&roadAdj, coordA, coordB)
                        }
                    }

                    // 若此節點為行營，則與周圍 8 格（含四個斜角）皆有公路相連
                    if typeA == .camp {
                        for dr in -1...1 {
                            for dc in -1...1 {
                                if dr == 0 && dc == 0 { continue }
                                let nr = r + dr
                                let nc = c + dc
                                guard (0..<6).contains(nr), (0..<5).contains(nc) else { continue }
                                let localB = LocalCoord(row: nr, col: nc)
                                let coordB = Self.globalCoord(for: seat, local: localB)
                                addEdge(&roadAdj, coordA, coordB)
                            }
                        }
                    }
                }
            }
        }

        // 4. 定義所有連續鐵路軌道（直線與外圍弧形彎道）
        var lines: [[BoardCoord]] = []

        // 4a. 各陣地內部橫向鐵路（第 0 排前線與第 4 排次底線，共 8 條）
        for seat in Seat.allCases {
            for localRow in [0, 4] {
                let line = (0..<5).map { col in
                    Self.globalCoord(for: seat, local: LocalCoord(row: localRow, col: col))
                }
                lines.append(line)
            }
        }

        // 4b. 縱向貫穿南北與中央九宮格的 3 條主幹線
        // 左縱線 (col = 6)：北側翼 (1..5, 6) + 九宮格 (6,8,10, 6) + 南側翼 (11..15, 6)
        let verticalLeft = (1...5).map { BoardCoord(row: $0, col: 6) }
            + [BoardCoord(row: 6, col: 6), BoardCoord(row: 8, col: 6), BoardCoord(row: 10, col: 6)]
            + (11...15).map { BoardCoord(row: $0, col: 6) }
        lines.append(verticalLeft)

        // 中縱線 (col = 8)：北前線中點 (5, 8) + 九宮格 (6,8,10, 8) + 南前線中點 (11, 8)
        let verticalMid = [
            BoardCoord(row: 5, col: 8),
            BoardCoord(row: 6, col: 8),
            BoardCoord(row: 8, col: 8),
            BoardCoord(row: 10, col: 8),
            BoardCoord(row: 11, col: 8)
        ]
        lines.append(verticalMid)

        // 右縱線 (col = 10)：北側翼 (1..5, 10) + 九宮格 (6,8,10, 10) + 南側翼 (11..15, 10)
        let verticalRight = (1...5).map { BoardCoord(row: $0, col: 10) }
            + [BoardCoord(row: 6, col: 10), BoardCoord(row: 8, col: 10), BoardCoord(row: 10, col: 10)]
            + (11...15).map { BoardCoord(row: $0, col: 10) }
        lines.append(verticalRight)

        // 4c. 橫向貫穿東西與中央九宮格的 3 條主幹線
        // 上橫線 (row = 6)：西側翼 (6, 1..5) + 九宮格 (6, 6,8,10) + 東側翼 (6, 11..15)
        let horizontalTop = (1...5).map { BoardCoord(row: 6, col: $0) }
            + [BoardCoord(row: 6, col: 6), BoardCoord(row: 6, col: 8), BoardCoord(row: 6, col: 10)]
            + (11...15).map { BoardCoord(row: 6, col: $0) }
        lines.append(horizontalTop)

        // 中橫線 (row = 8)：西前線中點 (8, 5) + 九宮格 (8, 6,8,10) + 東前線中點 (8, 11)
        let horizontalMid = [
            BoardCoord(row: 8, col: 5),
            BoardCoord(row: 8, col: 6),
            BoardCoord(row: 8, col: 8),
            BoardCoord(row: 8, col: 10),
            BoardCoord(row: 8, col: 11)
        ]
        lines.append(horizontalMid)

        // 下橫線 (row = 10)：西側翼 (10, 1..5) + 九宮格 (10, 6,8,10) + 東側翼 (10, 11..15)
        let horizontalBottom = (1...5).map { BoardCoord(row: 10, col: $0) }
            + [BoardCoord(row: 10, col: 6), BoardCoord(row: 10, col: 8), BoardCoord(row: 10, col: 10)]
            + (11...15).map { BoardCoord(row: 10, col: $0) }
        lines.append(horizontalBottom)

        // 4d. 四條外圍弧形彎道鐵路（連通相鄰兩方的側翼鐵路，普通棋子可沿外圍彎道直衝）
        // 南-西外圍鐵路：(15..11, 6) -> (10, 5..1)
        let curveSouthWest = (11...15).reversed().map { BoardCoord(row: $0, col: 6) }
            + (1...5).reversed().map { BoardCoord(row: 10, col: $0) }
        lines.append(curveSouthWest)

        // 南-東外圍鐵路：(15..11, 10) -> (10, 11..15)
        let curveSouthEast = (11...15).reversed().map { BoardCoord(row: $0, col: 10) }
            + (11...15).map { BoardCoord(row: 10, col: $0) }
        lines.append(curveSouthEast)

        // 北-西外圍鐵路：(1..5, 6) -> (6, 5..1)
        let curveNorthWest = (1...5).map { BoardCoord(row: $0, col: 6) }
            + (1...5).reversed().map { BoardCoord(row: 6, col: $0) }
        lines.append(curveNorthWest)

        // 北-東外圍鐵路：(1..5, 10) -> (6, 11..15)
        let curveNorthEast = (1...5).map { BoardCoord(row: $0, col: 10) }
            + (11...15).map { BoardCoord(row: 6, col: $0) }
        lines.append(curveNorthEast)

        // 5. 從所有連續鐵路軌道建立鐵路鄰接表
        for line in lines {
            for idx in 0..<(line.count - 1) {
                addEdge(&railAdj, line[idx], line[idx + 1])
            }
        }

        let sortedAllCoords = nodesDict.keys.sorted {
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.col < $1.col
        }

        // 6. 預先計算 129x129 鐵路感知最短回合步數矩陣
        // 6a. 非工兵一步可達鄰接表（公路鄰居 + 同一條連續鐵路軌道上的所有點）
        var oneStepNonSapper: [BoardCoord: Set<BoardCoord>] = roadAdj
        for line in lines {
            for a in line {
                for b in line where a != b {
                    oneStepNonSapper[a, default: []].insert(b)
                }
            }
        }

        // 6b. 工兵一步可達鄰接表（公路鄰居 + 全鐵路連通網）
        let allRailwayCoords = Set(railAdj.keys)
        var oneStepSapper: [BoardCoord: Set<BoardCoord>] = roadAdj
        for a in allRailwayCoords {
            for b in allRailwayCoords where a != b {
                oneStepSapper[a, default: []].insert(b)
            }
        }

        func computeAllPairsBFS(adjacency: [BoardCoord: Set<BoardCoord>]) -> [BoardCoord: [BoardCoord: Int]] {
            var matrix: [BoardCoord: [BoardCoord: Int]] = [:]
            for start in sortedAllCoords {
                var dist: [BoardCoord: Int] = [start: 0]
                var queue: [BoardCoord] = [start]
                var head = 0
                while head < queue.count {
                    let current = queue[head]
                    head += 1
                    let d = dist[current] ?? 0
                    if let nextSet = adjacency[current] {
                        for next in nextSet where dist[next] == nil {
                            dist[next] = d + 1
                            queue.append(next)
                        }
                    }
                }
                matrix[start] = dist
            }
            return matrix
        }

        self.nodes = nodesDict
        self.allCoords = sortedAllCoords
        self.roadNeighbors = roadAdj
        self.railwayNeighbors = railAdj
        self.railwayLines = lines
        self.outerCurvePairs = [
            (BoardCoord(row: 11, col: 6), BoardCoord(row: 10, col: 5)),
            (BoardCoord(row: 11, col: 10), BoardCoord(row: 10, col: 11)),
            (BoardCoord(row: 5, col: 6), BoardCoord(row: 6, col: 5)),
            (BoardCoord(row: 5, col: 10), BoardCoord(row: 6, col: 11))
        ]
        self.nonSapperTurnDistance = computeAllPairsBFS(adjacency: oneStepNonSapper)
        self.sapperTurnDistance = computeAllPairsBFS(adjacency: oneStepSapper)
    }

    /// 查詢從 from 到 to 的鐵路感知最短回合步數
    public func turnDistance(from start: BoardCoord, to target: BoardCoord, isSapper: Bool = false) -> Int {
        if start == target { return 0 }
        if isSapper {
            return sapperTurnDistance[start]?[target] ?? 12
        } else {
            return nonSapperTurnDistance[start]?[target] ?? 12
        }
    }

    /// 將某方的局部座標 (row: 0..5, col: 0..4) 轉換為 17x17 全局座標
    public static func globalCoord(for seat: Seat, local: LocalCoord) -> BoardCoord {
        switch seat {
        case .south:
            return BoardCoord(row: 11 + local.row, col: 6 + local.col)
        case .north:
            return BoardCoord(row: 5 - local.row, col: 10 - local.col)
        case .west:
            return BoardCoord(row: 6 + local.col, col: 5 - local.row)
        case .east:
            return BoardCoord(row: 10 - local.col, col: 11 + local.row)
        }
    }

    /// 根據局部座標決定節點類型
    public static func nodeType(for local: LocalCoord) -> NodeType {
        // 大本營：第 5 排（底線）第 1、3 列
        if local.row == 5 && (local.col == 1 || local.col == 3) {
            return .headquarters
        }
        // 行營：5 個位置
        if (local.row == 1 && (local.col == 1 || local.col == 3)) ||
            (local.row == 2 && local.col == 2) ||
            (local.row == 3 && (local.col == 1 || local.col == 3)) {
            return .camp
        }
        // 鐵路：前線 (row 0)、次底線 (row 4)、以及左右兩側邊線 (col 0, col 4 且 row <= 4)
        if local.row == 0 || local.row == 4 || (local.row <= 4 && (local.col == 0 || local.col == 4)) {
            return .railway
        }
        return .normal
    }

    /// 判斷同一陣地內的兩個相鄰局部座標是否為鐵路連線
    private static func isInternalRailwayEdge(_ a: LocalCoord, _ b: LocalCoord) -> Bool {
        guard nodeType(for: a) == .railway, nodeType(for: b) == .railway else {
            return false
        }
        if a.row == b.row && (a.row == 0 || a.row == 4) && abs(a.col - b.col) == 1 {
            return true
        }
        if a.col == b.col && (a.col == 0 || a.col == 4) && a.row <= 4 && b.row <= 4 && abs(a.row - b.row) == 1 {
            return true
        }
        return false
    }

    /// 取得某個座位全部 30 個陣地座標
    public func zoneCoords(for seat: Seat) -> [BoardCoord] {
        var result: [BoardCoord] = []
        result.reserveCapacity(30)
        for r in 0..<6 {
            for c in 0..<5 {
                result.append(Self.globalCoord(for: seat, local: LocalCoord(row: r, col: c)))
            }
        }
        return result
    }

    /// 取得某個座位的兩個大本營座標
    public func headquartersCoords(for seat: Seat) -> [BoardCoord] {
        [
            Self.globalCoord(for: seat, local: LocalCoord(row: 5, col: 1)),
            Self.globalCoord(for: seat, local: LocalCoord(row: 5, col: 3))
        ]
    }
}
