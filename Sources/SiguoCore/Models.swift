import Foundation

/// 四國軍棋的四個座位方位（逆時針行棋順序：南 -> 東 -> 北 -> 西）
public enum Seat: String, CaseIterable, Codable, Sendable, Hashable {
    case south = "SOUTH"
    case east = "EAST"
    case north = "NORTH"
    case west = "WEST"

    /// 逆時針下一位玩家
    public var nextSeat: Seat {
        switch self {
        case .south: return .east
        case .east: return .north
        case .north: return .west
        case .west: return .south
        }
    }

    /// 對家同盟方位（南北同盟，東西同盟）
    public var ally: Seat {
        switch self {
        case .south: return .north
        case .north: return .south
        case .east: return .west
        case .west: return .east
        }
    }

    /// 是否為同一陣營（自己或對家盟友）
    public func isAlly(with other: Seat) -> Bool {
        self == other || ally == other
    }

    /// 顯示名稱
    public var displayName: String {
        switch self {
        case .south: return "南方（玩家）"
        case .east: return "東方（敵軍）"
        case .north: return "北方（盟友）"
        case .west: return "西方（敵軍）"
        }
    }

    /// 簡稱
    public var shortName: String {
        switch self {
        case .south: return "南"
        case .east: return "東"
        case .north: return "北"
        case .west: return "西"
        }
    }
}

/// 遊戲視角模式
public enum VisibilityMode: String, CaseIterable, Codable, Sendable {
    /// 四國雙明：玩家與對家盟友互相可見，敵方暗置
    case doubleVisible = "DOUBLE_VISIBLE"
    /// 四國四暗：僅玩家自己的棋子可見，盟友與敵方皆暗置
    case fourDark = "FOUR_DARK"
    /// 四國全明：四家所有棋子皆公開可見
    case allVisible = "ALL_VISIBLE"

    public var title: String {
        switch self {
        case .doubleVisible: return "四國雙明"
        case .fourDark: return "四國四暗"
        case .allVisible: return "四國全明"
        }
    }

    public var subtitle: String {
        switch self {
        case .doubleVisible: return "與北方盟友共享視野，東西敵軍暗棋"
        case .fourDark: return "僅見南方己方棋子，盟友與敵軍皆為暗棋"
        case .allVisible: return "全場棋子明置，純粹戰術推演"
        }
    }
}

/// 地雷裁決規則
public enum MineRule: String, CaseIterable, Codable, Sendable {
    /// 經典規則：工兵挖雷存活、炸彈炸雷同歸、其他棋子撞雷時攻擊方陣亡且地雷保留
    case classicSurvives = "CLASSIC_SURVIVES"
    /// 同歸規則：工兵挖雷存活，任何其他棋子（含炸彈）撞雷皆與地雷同歸於盡
    case bothDestroy = "BOTH_DESTROY"

    public var title: String {
        switch self {
        case .classicSurvives: return "經典耐炸雷（僅工兵可挖、炸彈同歸）"
        case .bothDestroy: return "撞雷同歸（任意子撞雷皆同歸於盡）"
        }
    }
}

/// 17x17 全局棋盤座標
public struct BoardCoord: Hashable, Codable, Sendable, CustomStringConvertible {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    public var description: String {
        "(\(row),\(col))"
    }
}

/// 玩家自身陣地的局部座標（row: 0..5 由前線至底線，col: 0..4 由左至右）
public struct LocalCoord: Hashable, Codable, Sendable {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

/// 棋盤節點類型
public enum NodeType: String, Codable, Sendable {
    /// 普通兵站（公路）
    case normal
    /// 鐵路兵站
    case railway
    /// 行營（安全保護區，不可放初始棋子，八方連通）
    case camp
    /// 大本營（進入後不可再移動，軍旗所在地）
    case headquarters
}

/// 棋盤節點資訊
public struct BoardNode: Equatable, Hashable, Codable, Sendable {
    public let coord: BoardCoord
    public let type: NodeType
    public let zone: Seat?
    public let localCoord: LocalCoord?

    public init(coord: BoardCoord, type: NodeType, zone: Seat?, localCoord: LocalCoord?) {
        self.coord = coord
        self.type = type
        self.zone = zone
        self.localCoord = localCoord
    }
}

/// 軍棋階級
public enum PieceRank: String, CaseIterable, Codable, Sendable, Hashable {
    case commander = "司令"
    case corps = "軍長"
    case division = "師長"
    case brigade = "旅長"
    case regiment = "團長"
    case battalion = "營長"
    case company = "連長"
    case platoon = "排長"
    case sapper = "工兵"
    case bomb = "炸彈"
    case mine = "地雷"
    case flag = "軍旗"

    /// 數值戰力（僅適用於普通階級可動棋子）
    public var combatStrength: Int? {
        switch self {
        case .commander: return 40
        case .corps: return 39
        case .division: return 38
        case .brigade: return 37
        case .regiment: return 36
        case .battalion: return 35
        case .company: return 34
        case .platoon: return 33
        case .sapper: return 32
        case .bomb, .mine, .flag: return nil
        }
    }

    /// 每方標準配置的數量（合計 25 枚）
    public var standardCount: Int {
        switch self {
        case .commander: return 1
        case .corps: return 1
        case .division: return 2
        case .brigade: return 2
        case .regiment: return 2
        case .battalion: return 2
        case .company: return 3
        case .platoon: return 3
        case .sapper: return 3
        case .bomb: return 2
        case .mine: return 3
        case .flag: return 1
        }
    }

    /// 該棋子本身是否具備移動能力
    public var isMovableRank: Bool {
        switch self {
        case .mine, .flag:
            return false
        default:
            return true
        }
    }

    /// AI 估值基礎分
    public var tacticalValue: Int {
        switch self {
        case .flag: return 10_000
        case .commander: return 950
        case .corps: return 750
        case .bomb: return 620
        case .division: return 520
        case .brigade: return 400
        case .sapper: return 360
        case .regiment: return 290
        case .battalion: return 220
        case .mine: return 200
        case .company: return 150
        case .platoon: return 100
        }
    }
}

/// 玩家在暗棋上標記的猜測標籤
public enum SuspicionTag: String, CaseIterable, Codable, Sendable, Hashable {
    case commander = "司令"
    case corps = "軍長"
    case division = "師長"
    case brigade = "旅長"
    case bomb = "炸彈"
    case mine = "地雷"
    case sapper = "工兵"
    case majorPiece = "大子"
    case minorPiece = "小子"
    case unknown = "？"
}

/// 場上單枚棋子狀態
public struct Piece: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: UUID
    public let owner: Seat
    public let rank: PieceRank
    /// 是否因為己方司令陣亡或特殊事件而對全場公開身份（例如亮軍旗）
    public var isPubliclyRevealed: Bool
    /// 是否曾經移動過（供 AI 與紀錄推論：移動過必非地雷/軍旗）
    public var hasMoved: Bool
    /// 是否曾在鐵路上轉彎移動（供 AI 推論：必為工兵）
    public var turnedOnRailway: Bool
    /// 累計吃子數量
    public var killsCount: Int
    /// 玩家手動標記的猜測標籤
    public var suspicionTag: SuspicionTag?

    public init(
        id: UUID = UUID(),
        owner: Seat,
        rank: PieceRank,
        isPubliclyRevealed: Bool = false,
        hasMoved: Bool = false,
        turnedOnRailway: Bool = false,
        killsCount: Int = 0,
        suspicionTag: SuspicionTag? = nil
    ) {
        self.id = id
        self.owner = owner
        self.rank = rank
        self.isPubliclyRevealed = isPubliclyRevealed
        self.hasMoved = hasMoved
        self.turnedOnRailway = turnedOnRailway
        self.killsCount = killsCount
        self.suspicionTag = suspicionTag
    }

    /// 判斷在指定視角模式下，人類玩家（南方）是否能看到這枚棋子的真實階級
    public func isVisibleToHuman(mode: VisibilityMode, forceRevealAll: Bool = false) -> Bool {
        if forceRevealAll || isPubliclyRevealed {
            return true
        }
        switch mode {
        case .allVisible:
            return true
        case .doubleVisible:
            return owner == .south || owner == .north
        case .fourDark:
            return owner == .south
        }
    }
}

/// 戰鬥結果類型
public enum CombatOutcome: String, Codable, Sendable, Equatable {
    /// 純移動（目標格無棋子）
    case moveOnly
    /// 攻擊方勝（吃掉防守方）
    case attackerWins
    /// 防守方勝（攻擊方撞死）
    case defenderWins
    /// 同歸於盡（雙方同時消滅）
    case mutualDestruction
}

/// 合法行棋步與路徑
public struct ValidMove: Equatable, Hashable, Codable, Sendable {
    public let from: BoardCoord
    public let to: BoardCoord
    /// 包含起點與終點的完整經過節點序列（用於工兵轉彎飛棋或長距離鐵路動畫）
    public let path: [BoardCoord]
    /// 是否在鐵路上轉了彎（若是，代表公開暴露了工兵身份）
    public let madeRailwayTurn: Bool

    public init(from: BoardCoord, to: BoardCoord, path: [BoardCoord], madeRailwayTurn: Bool = false) {
        self.from = from
        self.to = to
        self.path = path
        self.madeRailwayTurn = madeRailwayTurn
    }
}

/// 單步歷史與戰報紀錄
public struct MoveRecord: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let stepNumber: Int
    public let actor: Seat
    public let from: BoardCoord
    public let to: BoardCoord
    public let path: [BoardCoord]
    public let attackerPiece: Piece
    public let defenderPiece: Piece?
    public let outcome: CombatOutcome
    public let specialAnnouncements: [String]

    public init(
        id: UUID = UUID(),
        stepNumber: Int,
        actor: Seat,
        from: BoardCoord,
        to: BoardCoord,
        path: [BoardCoord],
        attackerPiece: Piece,
        defenderPiece: Piece?,
        outcome: CombatOutcome,
        specialAnnouncements: [String] = []
    ) {
        self.id = id
        self.stepNumber = stepNumber
        self.actor = actor
        self.from = from
        self.to = to
        self.path = path
        self.attackerPiece = attackerPiece
        self.defenderPiece = defenderPiece
        self.outcome = outcome
        self.specialAnnouncements = specialAnnouncements
    }
}

/// 遊戲階段
public enum GamePhase: String, Codable, Sendable, Equatable {
    /// 開局佈陣階段
    case setup
    /// 對戰進行中
    case playing
    /// 遊戲結束
    case finished
}

/// AI 棋力難度等級
public enum AIDifficulty: String, CaseIterable, Codable, Sendable {
    case normal = "NORMAL"
    case expert = "EXPERT"
    case master = "MASTER"

    public var title: String {
        switch self {
        case .normal: return "普通"
        case .expert: return "高手"
        case .master: return "大師"
        }
    }

    public var subtitle: String {
        switch self {
        case .normal: return "基礎戰術直覺，適合輕鬆休閒對局"
        case .expert: return "具備交戰歷史記憶與反擊風險評估（SEE）"
        case .master: return "全牌池貝氏推理 + 鐵路圖導航 + 2v2 多層 Alpha-Beta 搜尋"
        }
    }
}

/// 勝利陣營
public enum WinningTeam: String, Codable, Sendable, Equatable {
    /// 南北同盟（玩家與北方盟友）獲勝
    case southNorthAlliance
    /// 東西同盟（敵方 AI）獲勝
    case eastWestAlliance
}
