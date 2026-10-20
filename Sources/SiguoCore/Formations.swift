import Foundation

/// 預設陣型類型
public enum PresetFormation: String, CaseIterable, Codable, Sendable, Identifiable {
    case balanced = "均衡護旗陣"
    case blitz = "閃電強攻陣"
    case fortress = "鐵桶三角陣"
    case flankAmbush = "側翼奇襲陣"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .balanced:
            return "三角雷嚴密護旗，司令軍長鎮守兩翼要道，工兵二線隨時飛棋支援。"
        case .blitz:
            return "司令、軍長、師長前置於前排鐵路，炸彈緊隨其後，開局強勢壓制。"
        case .fortress:
            return "深藏主力大子於中後排，前線以中小子誘敵，後排地雷與炸彈密集防守。"
        case .flankAmbush:
            return "重兵集結左翼鐵路走廊，右翼以連排長與炸彈牽制敵方主力。"
        }
    }
}

/// 可儲存的自訂陣型資料結構
public struct SavedFormation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// 以 "row,col" 局部座標字串對應 PieceRank
    public var mapping: [String: PieceRank]

    public init(id: UUID = UUID(), name: String, mapping: [String: PieceRank]) {
        self.id = id
        self.name = name
        self.mapping = mapping
    }
}

/// 佈陣產生器與合法性驗證器
public enum FormationBuilder {
    /// 標準 25 枚棋子清單
    public static let standardPieceRanks: [PieceRank] = {
        var result: [PieceRank] = []
        for rank in PieceRank.allCases {
            for _ in 0..<rank.standardCount {
                result.append(rank)
            }
        }
        return result
    }()

    /// 全部 25 個可佈陣的局部座標（扣除 5 個行營）
    public static let deployableLocalCoords: [LocalCoord] = {
        var coords: [LocalCoord] = []
        for r in 0..<6 {
            for c in 0..<5 {
                let local = LocalCoord(row: r, col: c)
                if BoardGraph.nodeType(for: local) != .camp {
                    coords.append(local)
                }
            }
        }
        return coords
    }()

    /// 檢查某個階級的棋子是否可以部署在指定的局部座標
    public static func isValidPlacement(rank: PieceRank, at local: LocalCoord) -> Bool {
        let nodeType = BoardGraph.nodeType(for: local)
        // 行營不可放初始棋子
        if nodeType == .camp {
            return false
        }
        switch rank {
        case .flag:
            // 軍旗必須在大本營 (row == 5, col == 1 or 3)
            return nodeType == .headquarters
        case .mine:
            // 地雷只能放在最後兩排 (row == 4 or 5)
            return local.row == 4 || local.row == 5
        case .bomb:
            // 炸彈不能放在第一排 (row == 0)
            return local.row > 0
        default:
            return true
        }
    }

    /// 檢查指定全局座標上的兩枚同陣營棋子是否可以合法互換位置
    public static func canSwap(
        rankA: PieceRank,
        coordA: BoardCoord,
        rankB: PieceRank,
        coordB: BoardCoord,
        in graph: BoardGraph = .shared
    ) -> Bool {
        guard let nodeA = graph.nodes[coordA],
              let nodeB = graph.nodes[coordB],
              nodeA.zone != nil,
              nodeA.zone == nodeB.zone,
              let localA = nodeA.localCoord,
              let localB = nodeB.localCoord else {
            return false
        }
        return isValidPlacement(rank: rankA, at: localB) && isValidPlacement(rank: rankB, at: localA)
    }

    /// 根據預設陣型產生局部座標配置
    public static func localLayout(for preset: PresetFormation) -> [LocalCoord: PieceRank] {
        // 每個陣型明確指定 25 個非行營座標 (row 0..5, col 0..4)
        // 行營位置：(1,1), (1,3), (2,2), (3,1), (3,3)
        let rows: [[PieceRank?]]
        switch preset {
        case .balanced:
            rows = [
                [.brigade, .company, .division, .platoon, .corps],        // row 0 (前線)
                [.commander, nil, .bomb, nil, .division],                 // row 1
                [.regiment, .sapper, nil, .sapper, .brigade],             // row 2
                [.battalion, nil, .bomb, nil, .regiment],                 // row 3
                [.company, .platoon, .sapper, .mine, .battalion],         // row 4
                [.company, .platoon, .mine, .flag, .mine]                 // row 5 (底線，(5,1) 與 (5,3) 為大本營)
            ]
        case .blitz:
            rows = [
                [.commander, .brigade, .division, .brigade, .corps],      // row 0
                [.bomb, nil, .division, nil, .bomb],                      // row 1
                [.regiment, .sapper, nil, .sapper, .regiment],            // row 2
                [.battalion, nil, .sapper, nil, .battalion],              // row 3
                [.company, .mine, .company, .platoon, .company],          // row 4
                [.platoon, .flag, .mine, .platoon, .mine]                 // row 5
            ]
        case .fortress:
            rows = [
                [.platoon, .company, .battalion, .company, .platoon],     // row 0
                [.regiment, nil, .sapper, nil, .regiment],                // row 1
                [.division, .bomb, nil, .bomb, .division],                // row 2
                [.corps, nil, .commander, nil, .brigade],                 // row 3
                [.sapper, .brigade, .mine, .mine, .sapper],               // row 4
                [.company, .platoon, .battalion, .flag, .mine]            // row 5
            ]
        case .flankAmbush:
            rows = [
                [.commander, .corps, .company, .platoon, .brigade],       // row 0
                [.division, nil, .regiment, nil, .bomb],                  // row 1
                [.bomb, .division, nil, .sapper, .regiment],              // row 2
                [.brigade, nil, .battalion, nil, .company],               // row 3
                [.sapper, .mine, .sapper, .battalion, .platoon],          // row 4
                [.mine, .flag, .mine, .platoon, .company]                 // row 5
            ]
        }

        var result: [LocalCoord: PieceRank] = [:]
        for r in 0..<6 {
            for c in 0..<5 {
                if let rank = rows[r][c] {
                    result[LocalCoord(row: r, col: c)] = rank
                }
            }
        }
        return result
    }

    /// 產生合法的隨機陣型
    public static func randomLocalLayout() -> [LocalCoord: PieceRank] {
        var layout: [LocalCoord: PieceRank] = [:]
        var available = Set(deployableLocalCoords)

        // 1. 放置軍旗於其中一個大本營
        let hqs = [LocalCoord(row: 5, col: 1), LocalCoord(row: 5, col: 3)]
        if let chosenHQ = hqs.randomElement() {
            layout[chosenHQ] = .flag
            available.remove(chosenHQ)
        }

        // 2. 放置 3 枚地雷於後兩排 (row 4, 5)
        let mineCandidates = available.filter { $0.row == 4 || $0.row == 5 }.shuffled()
        for coord in mineCandidates.prefix(3) {
            layout[coord] = .mine
            available.remove(coord)
        }

        // 3. 放置 2 枚炸彈於非第一排 (row 1..5)
        let bombCandidates = available.filter { $0.row > 0 }.shuffled()
        for coord in bombCandidates.prefix(2) {
            layout[coord] = .bomb
            available.remove(coord)
        }

        // 4. 放置剩餘 19 枚普通棋子
        let remainingRanks = standardPieceRanks.filter {
            $0 != .flag && $0 != .mine && $0 != .bomb
        }.shuffled()
        let remainingCoords = Array(available).shuffled()

        for (coord, rank) in zip(remainingCoords, remainingRanks) {
            layout[coord] = rank
        }

        return layout
    }

    /// 將某方的局部陣型轉換為全局棋盤上的 Piece 字典
    public static func instantiatePieces(
        for seat: Seat,
        localLayout: [LocalCoord: PieceRank]
    ) -> [BoardCoord: Piece] {
        var boardPieces: [BoardCoord: Piece] = [:]
        for (local, rank) in localLayout {
            guard isValidPlacement(rank: rank, at: local) else { continue }
            let global = BoardGraph.globalCoord(for: seat, local: local)
            boardPieces[global] = Piece(owner: seat, rank: rank)
        }
        return boardPieces
    }

    /// 驗證一整套 25 枚局部陣型是否完全合法
    public static func isValidCompleteLayout(_ layout: [LocalCoord: PieceRank]) -> Bool {
        guard layout.count == 25 else { return false }
        var counts: [PieceRank: Int] = [:]
        for (local, rank) in layout {
            guard isValidPlacement(rank: rank, at: local) else { return false }
            counts[rank, default: 0] += 1
        }
        for rank in PieceRank.allCases {
            if counts[rank, default: 0] != rank.standardCount {
                return false
            }
        }
        return true
    }
}
