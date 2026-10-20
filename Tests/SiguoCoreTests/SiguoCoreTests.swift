import Testing
@testable import SiguoCore

@Suite("四國軍棋核心引擎測試 (SiguoCoreTests)")
struct SiguoCoreTests {
    @Test("17x17 棋盤拓撲：共 129 個節點、8 個大本營、20 個行營")
    func boardGraphTopologyCounts() {
        let graph = BoardGraph.shared
        #expect(graph.nodes.count == 129)
        #expect(graph.allCoords.count == 129)

        let hqNodes = graph.nodes.values.filter { $0.type == .headquarters }
        let campNodes = graph.nodes.values.filter { $0.type == .camp }
        let centerNodes = graph.nodes.values.filter { $0.zone == nil }

        #expect(hqNodes.count == 8)
        #expect(campNodes.count == 20)
        #expect(centerNodes.count == 9)

        // 驗證四條外圍彎道鐵路皆已雙向連通
        for (a, b) in graph.outerCurvePairs {
            #expect(graph.railwayNeighbors[a]?.contains(b) == true)
            #expect(graph.railwayNeighbors[b]?.contains(a) == true)
        }
    }

    @Test("預設陣型與隨機陣型皆完全符合佈陣合法性約束")
    func presetAndRandomFormationsValidity() {
        for preset in PresetFormation.allCases {
            let layout = FormationBuilder.localLayout(for: preset)
            #expect(FormationBuilder.isValidCompleteLayout(layout), "預設陣型 \(preset.rawValue) 應合法")
        }

        for _ in 0..<10 {
            let randomLayout = FormationBuilder.randomLocalLayout()
            #expect(FormationBuilder.isValidCompleteLayout(randomLayout), "隨機陣型應合法")
        }
    }

    @Test("工兵鐵路 BFS 飛棋轉彎 vs 普通棋子直線/單彎限制")
    func railwayMovementSapperVsNormal() {
        let graph = BoardGraph.shared
        var pieces: [BoardCoord: Piece] = [:]

        let start = BoardCoord(row: 11, col: 6) // 南方左前線角點
        let turnedTarget = BoardCoord(row: 6, col: 8) // 中央九宮格上方中點（需經過轉彎）
        let straightTarget = BoardCoord(row: 6, col: 6) // 同在左縱線 col=6 上（直線可達）
        let curveTarget = BoardCoord(row: 10, col: 2) // 經由南-西外圍彎道直通西方下路鐵路

        // 1. 旅長（非工兵）：可走直線與外圍彎道，但不可在九宮格轉 90 度彎去 (6,8)
        pieces[start] = Piece(owner: .south, rank: .brigade)
        let brigadeMoves = MoveGenerator.validMoves(from: start, pieces: pieces, graph: graph)
        let brigadeTargets = Set(brigadeMoves.map(\.to))
        #expect(brigadeTargets.contains(straightTarget))
        #expect(brigadeTargets.contains(curveTarget))
        #expect(!brigadeTargets.contains(turnedTarget))

        // 2. 工兵：可透過 BFS 轉彎抵達 (6,8)，且標記 madeRailwayTurn == true
        pieces[start] = Piece(owner: .south, rank: .sapper)
        let sapperMoves = MoveGenerator.validMoves(from: start, pieces: pieces, graph: graph)
        let turnedMove = sapperMoves.first(where: { $0.to == turnedTarget })
        #expect(turnedMove != nil)
        #expect(turnedMove?.madeRailwayTurn == true)
    }

    @Test("行營保護機制與大本營不可移動限制")
    func campProtectionAndHeadquartersLock() {
        let graph = BoardGraph.shared
        var pieces: [BoardCoord: Piece] = [:]

        // 南方左前行營 (localRow 1, localCol 1) -> 全局 (12, 7)
        let southCamp = BoardGraph.globalCoord(for: .south, local: LocalCoord(row: 1, col: 1))
        let attackerCoord = BoardGraph.globalCoord(for: .south, local: LocalCoord(row: 0, col: 1)) // (11, 7)

        pieces[attackerCoord] = Piece(owner: .south, rank: .commander)
        // 當行營為空時，南方司令可以進入行營
        let movesWhenEmpty = MoveGenerator.validMoves(from: attackerCoord, pieces: pieces, graph: graph)
        #expect(movesWhenEmpty.contains(where: { $0.to == southCamp }))

        // 當行營內有敵方棋子時，行營受保護不可被攻擊
        pieces[southCamp] = Piece(owner: .east, rank: .platoon)
        let movesWhenOccupied = MoveGenerator.validMoves(from: attackerCoord, pieces: pieces, graph: graph)
        #expect(!movesWhenOccupied.contains(where: { $0.to == southCamp }))

        // 大本營內的棋子不可移動
        let hqCoord = BoardGraph.globalCoord(for: .south, local: LocalCoord(row: 5, col: 1))
        pieces[hqCoord] = Piece(owner: .south, rank: .corps)
        let hqMoves = MoveGenerator.validMoves(from: hqCoord, pieces: pieces, graph: graph)
        #expect(hqMoves.isEmpty)
    }

    @Test("戰鬥裁決：司令陣亡自動亮軍旗、扛旗直接滅國並清除餘子")
    func combatResolutionFlagRevealAndElimination() {
        var state = GameState(
            phase: .playing,
            visibilityMode: .doubleVisible,
            mineRule: .classicSurvives,
            currentTurn: .south
        )

        let southCmdPos = BoardCoord(row: 11, col: 6)
        let southCorpsPos = BoardGraph.globalCoord(for: .south, local: LocalCoord(row: 0, col: 2))
        let eastBombPos = BoardCoord(row: 10, col: 6)
        let eastBrigadePos = BoardGraph.globalCoord(for: .east, local: LocalCoord(row: 0, col: 0))
        let eastFlagPos = BoardGraph.globalCoord(for: .east, local: LocalCoord(row: 5, col: 1))
        let southFlagPos = BoardGraph.globalCoord(for: .south, local: LocalCoord(row: 5, col: 3))
        let northSafePos = BoardGraph.globalCoord(for: .north, local: LocalCoord(row: 0, col: 0))
        let northFlagPos = BoardGraph.globalCoord(for: .north, local: LocalCoord(row: 5, col: 1))
        let westFlagPos = BoardGraph.globalCoord(for: .west, local: LocalCoord(row: 5, col: 1))
        let westExtraPos = BoardGraph.globalCoord(for: .west, local: LocalCoord(row: 0, col: 0))

        state.pieces[southCmdPos] = Piece(owner: .south, rank: .commander)
        state.pieces[southCorpsPos] = Piece(owner: .south, rank: .corps)
        state.pieces[southFlagPos] = Piece(owner: .south, rank: .flag)
        state.pieces[eastBombPos] = Piece(owner: .east, rank: .bomb)
        state.pieces[eastBrigadePos] = Piece(owner: .east, rank: .brigade)
        state.pieces[eastFlagPos] = Piece(owner: .east, rank: .flag)
        state.pieces[northSafePos] = Piece(owner: .north, rank: .corps)
        state.pieces[northFlagPos] = Piece(owner: .north, rank: .flag)
        state.pieces[westFlagPos] = Piece(owner: .west, rank: .flag)
        state.pieces[westExtraPos] = Piece(owner: .west, rank: .division)

        // 1. 南方司令撞擊東方炸彈 -> 同歸於盡，且南方軍旗自動公開亮出！
        let move = ValidMove(from: southCmdPos, to: eastBombPos, path: [southCmdPos, eastBombPos])
        let record = GameEngine.applyMove(move, in: &state)
        #expect(record?.outcome == .mutualDestruction)
        #expect(state.pieces[southFlagPos]?.isPubliclyRevealed == true)

        // 2. 接著輪到東方：把東方旅長放在南方軍旗旁並直接拔旗 -> 南方立即淘汰，且南方軍長一併被移除
        let adjacentToSouthFlag = BoardGraph.globalCoord(for: .south, local: LocalCoord(row: 4, col: 3))
        state.pieces[adjacentToSouthFlag] = Piece(owner: .east, rank: .sapper)
        let captureFlagMove = ValidMove(
            from: adjacentToSouthFlag,
            to: southFlagPos,
            path: [adjacentToSouthFlag, southFlagPos]
        )
        let captureRecord = GameEngine.applyMove(captureFlagMove, in: &state)
        #expect(captureRecord?.outcome == .attackerWins)
        #expect(state.eliminatedSeats.contains(.south))
        #expect(state.pieces[southCorpsPos] == nil)
    }

    @Test("AI 決策引擎在雙明與四暗模式下能穩定選出合法步數")
    func aiPlayerChoosesValidMoves() {
        var state = GameEngine.newGame(visibilityMode: .doubleVisible, aiDifficulty: .master)
        GameEngine.startGame(in: &state)

        // 先讓南方走一步合法棋，再測試東、北、西三家大師級 AI 連續行棋 12 步
        for _ in 0..<12 {
            guard state.phase == .playing else { break }
            let current = state.currentTurn
            let move = AIPlayer.chooseMove(in: state, for: current)
            #expect(move != nil, "\(current.displayName) 應能選出合法步數")
            if let move {
                let record = GameEngine.applyMove(move, in: &state)
                #expect(record != nil)
            }
        }
        #expect(state.moveHistory.count == 12)
    }

    @Test("129x129 鐵路感知最短步數矩陣：精確反映直線與工兵飛棋距離")
    func railwayTurnDistanceMatrix() {
        let graph = BoardGraph.shared
        let southFrontLeft = BoardCoord(row: 11, col: 6)
        let northBackLeft = BoardCoord(row: 1, col: 6)
        let eastTopFlank = BoardCoord(row: 6, col: 14)

        // 同一條左縱鐵路線上，相隔 10 格亦只需 1 步直達
        #expect(graph.turnDistance(from: southFrontLeft, to: northBackLeft, isSapper: false) == 1)

        // 需轉彎的跨翼鐵路：非工兵需 2 步，工兵飛棋只需 1 步
        #expect(graph.turnDistance(from: southFrontLeft, to: eastTopFlank, isSapper: false) == 2)
        #expect(graph.turnDistance(from: southFrontLeft, to: eastTopFlank, isSapper: true) == 1)
    }

    @Test("貝氏信念追蹤器 (AIBeliefTracker)：根據交戰歷史與陣亡牌池精準推算敵方暗棋階級")
    func beliefTrackerDeducesRankBounds() {
        var state = GameState(
            phase: .playing,
            visibilityMode: .doubleVisible,
            mineRule: .classicSurvives,
            aiDifficulty: .master,
            currentTurn: .east
        )

        let eastMysteryCoord = BoardCoord(row: 10, col: 6)
        let southDivisionCoord = BoardCoord(row: 11, col: 6)
        let southFlagCoord = BoardGraph.globalCoord(for: .south, local: LocalCoord(row: 5, col: 1))
        let southBackupCoord = BoardGraph.globalCoord(for: .south, local: LocalCoord(row: 4, col: 0))
        let eastFlagCoord = BoardGraph.globalCoord(for: .east, local: LocalCoord(row: 5, col: 1))
        let northFlagCoord = BoardGraph.globalCoord(for: .north, local: LocalCoord(row: 5, col: 1))
        let northSubCoord = BoardGraph.globalCoord(for: .north, local: LocalCoord(row: 0, col: 0))
        let westFlagCoord = BoardGraph.globalCoord(for: .west, local: LocalCoord(row: 5, col: 1))
        let westSubCoord = BoardGraph.globalCoord(for: .west, local: LocalCoord(row: 0, col: 0))

        // 東方一枚未知暗棋（實際為軍長）主動出擊吃掉南方師長 (38)
        state.pieces[eastMysteryCoord] = Piece(owner: .east, rank: .corps)
        state.pieces[southDivisionCoord] = Piece(owner: .south, rank: .division)
        state.pieces[southFlagCoord] = Piece(owner: .south, rank: .flag)
        state.pieces[southBackupCoord] = Piece(owner: .south, rank: .company)
        state.pieces[eastFlagCoord] = Piece(owner: .east, rank: .flag)
        state.pieces[northFlagCoord] = Piece(owner: .north, rank: .flag)
        state.pieces[northSubCoord] = Piece(owner: .north, rank: .brigade)
        state.pieces[westFlagCoord] = Piece(owner: .west, rank: .flag)
        state.pieces[westSubCoord] = Piece(owner: .west, rank: .brigade)

        let attackMove = ValidMove(
            from: eastMysteryCoord,
            to: southDivisionCoord,
            path: [eastMysteryCoord, southDivisionCoord]
        )
        GameEngine.applyMove(attackMove, in: &state)

        // 1. 從北方盟友（或南方）視角觀察剛才吃掉南方師長的東方暗棋：
        // 因為它主動吃掉師長(38)並存活，它只可能是司令(40)或軍長(39)！
        let trackerBeforeFlagReveal = AIBeliefTracker(state: state, observer: .north)
        let belief1 = trackerBeforeFlagReveal.beliefsByCoord[southDivisionCoord]
        #expect(belief1 != nil)
        #expect(belief1?.minCombatStrength == 39)
        #expect(belief1?.probability(of: .division) == 0.0)
        #expect(belief1?.probability(of: .bomb) == 0.0)
        #expect((belief1?.probability(of: .commander) ?? 0.0) > 0.0)
        #expect((belief1?.probability(of: .corps) ?? 0.0) > 0.0)

        // 2. 若東方軍旗已經公開亮出（代表東方司令已死），信念追蹤器應 100% 鎖定該暗棋必為「軍長」！
        state.pieces[eastFlagCoord]?.isPubliclyRevealed = true
        let trackerAfterFlagReveal = AIBeliefTracker(state: state, observer: .north)
        let belief2 = trackerAfterFlagReveal.beliefsByCoord[southDivisionCoord]
        #expect(belief2?.confirmedRank == .corps)
        #expect(belief2?.probability(of: .corps) == 1.0)
    }

    @Test("大師級 AI 靜態反擊評估 (SEE)：司令不會貪吃受敵方炸彈保護的誘餌小子")
    func masterAIAvoidsBombAndCommanderTrap() {
        var state = GameState(
            phase: .playing,
            visibilityMode: .allVisible,
            mineRule: .classicSurvives,
            aiDifficulty: .master,
            currentTurn: .south
        )

        let southCommanderPos = BoardCoord(row: 11, col: 6)
        let southPlatoonPos = BoardCoord(row: 11, col: 10)
        let eastBaitPlatoonPos = BoardCoord(row: 10, col: 6)
        let eastBombAmbushPos = BoardCoord(row: 8, col: 6) // 同在 col=6 鐵路線上，隨時可一步炸掉 (10,6)
        let eastEasyTargetPos = BoardCoord(row: 10, col: 10)

        let southFlagPos = BoardGraph.globalCoord(for: .south, local: LocalCoord(row: 5, col: 1))
        let eastFlagPos = BoardGraph.globalCoord(for: .east, local: LocalCoord(row: 5, col: 1))
        let northFlagPos = BoardGraph.globalCoord(for: .north, local: LocalCoord(row: 5, col: 1))
        let northSubPos = BoardGraph.globalCoord(for: .north, local: LocalCoord(row: 0, col: 2))
        let westFlagPos = BoardGraph.globalCoord(for: .west, local: LocalCoord(row: 5, col: 1))
        let westSubPos = BoardGraph.globalCoord(for: .west, local: LocalCoord(row: 0, col: 2))

        state.pieces[southCommanderPos] = Piece(owner: .south, rank: .commander)
        state.pieces[southPlatoonPos] = Piece(owner: .south, rank: .brigade)
        state.pieces[eastBaitPlatoonPos] = Piece(owner: .east, rank: .platoon)
        state.pieces[eastBombAmbushPos] = Piece(owner: .east, rank: .bomb)
        state.pieces[eastEasyTargetPos] = Piece(owner: .east, rank: .platoon)

        state.pieces[southFlagPos] = Piece(owner: .south, rank: .flag)
        state.pieces[eastFlagPos] = Piece(owner: .east, rank: .flag)
        state.pieces[northFlagPos] = Piece(owner: .north, rank: .flag)
        state.pieces[northSubPos] = Piece(owner: .north, rank: .company)
        state.pieces[westFlagPos] = Piece(owner: .west, rank: .flag)
        state.pieces[westSubPos] = Piece(owner: .west, rank: .company)

        let chosenMove = AIPlayer.chooseMove(in: state, for: .south)
        #expect(chosenMove != nil)
        // 大師級 AI 絕不應該讓司令去吃 (10,6) 的誘餌排長而被 (8,6) 的炸彈白白炸死
        let blunderedCommanderIntoTrap = (chosenMove?.from == southCommanderPos && chosenMove?.to == eastBaitPlatoonPos)
        #expect(!blunderedCommanderIntoTrap)
    }
}
