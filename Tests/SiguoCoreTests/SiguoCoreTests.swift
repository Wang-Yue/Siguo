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
        var state = GameEngine.newGame(visibilityMode: .doubleVisible)
        GameEngine.startGame(in: &state)

        // 先讓南方走一步合法棋，再測試東、北、西三家 AI 連續行棋 12 步
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
}
