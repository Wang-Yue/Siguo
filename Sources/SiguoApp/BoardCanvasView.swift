import SwiftUI
import SiguoCore

/// 四國軍棋 17x17 棋盤畫布與棋子互動視圖
public struct BoardCanvasView: View {
    @Bindable var viewModel: GameViewModel

    private let graph = BoardGraph.shared

    public init(viewModel: GameViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let margin = max(28.0, side * 0.042)
            let usable = max(100.0, side - margin * 2.0)
            let step = usable / 16.0
            let originX = (proxy.size.width - usable) / 2.0
            let originY = (proxy.size.height - usable) / 2.0

            ZStack {
                // 1. 棋盤底圖、陣地色塊、公路、鐵路與行營/大本營標記
                Canvas { context, _ in
                    drawBoardZones(context: &context, originX: originX, originY: originY, step: step)
                    drawRoadLines(context: &context, originX: originX, originY: originY, step: step)
                    drawRailwayLines(context: &context, originX: originX, originY: originY, step: step)
                    drawStations(context: &context, originX: originX, originY: originY, step: step)
                    drawLastMovePath(context: &context, originX: originX, originY: originY, step: step)
                }

                // 2. 四方陣營方位浮水印標籤
                zoneWatermarkOverlay(originX: originX, originY: originY, step: step)

                // 3. 129 個節點上的棋子與點擊互動層
                ForEach(graph.allCoords, id: \.self) { coord in
                    let pt = point(for: coord, originX: originX, originY: originY, step: step)
                    nodeInteractiveCell(at: coord, step: step)
                        .position(x: pt.x, y: pt.y)
                }

                // 4. 交戰結果浮動徽章
                if let event = viewModel.latestCombatEvent, !viewModel.isReplaying {
                    let pt = point(for: event.coord, originX: originX, originY: originY, step: step)
                    Text(event.label)
                        .font(.system(size: max(11, step * 0.30), weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(combatBadgeColor(for: event.outcome))
                                .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                        )
                        .position(x: pt.x, y: max(18, pt.y - step * 0.72))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.13, green: 0.15, blue: 0.18),
                                Color(red: 0.09, green: 0.11, blue: 0.13)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - 座標換算

    private func point(for coord: BoardCoord, originX: CGFloat, originY: CGFloat, step: CGFloat) -> CGPoint {
        CGPoint(
            x: originX + CGFloat(coord.col) * step,
            y: originY + CGFloat(coord.row) * step
        )
    }

    // MARK: - Canvas 繪圖輔助

    private func drawBoardZones(
        context: inout GraphicsContext,
        originX: CGFloat,
        originY: CGFloat,
        step: CGFloat
    ) {
        let pad = step * 0.46

        // 四方陣地底色框
        let zoneConfigs: [(minRow: Int, maxRow: Int, minCol: Int, maxCol: Int, color: Color)] = [
            (11, 16, 6, 10, Color(red: 0.55, green: 0.16, blue: 0.18).opacity(0.16)), // 南
            (0, 5, 6, 10, Color(red: 0.12, green: 0.48, blue: 0.42).opacity(0.16)),   // 北
            (6, 10, 0, 5, Color(red: 0.42, green: 0.22, blue: 0.62).opacity(0.16)),   // 西
            (6, 10, 11, 16, Color(red: 0.65, green: 0.38, blue: 0.12).opacity(0.16))  // 東
        ]

        for cfg in zoneConfigs {
            let topLeft = point(for: BoardCoord(row: cfg.minRow, col: cfg.minCol), originX: originX, originY: originY, step: step)
            let bottomRight = point(for: BoardCoord(row: cfg.maxRow, col: cfg.maxCol), originX: originX, originY: originY, step: step)
            let rect = CGRect(
                x: topLeft.x - pad,
                y: topLeft.y - pad,
                width: (bottomRight.x - topLeft.x) + pad * 2,
                height: (bottomRight.y - topLeft.y) + pad * 2
            )
            let path = Path(roundedRect: rect, cornerRadius: 10)
            context.fill(path, with: .color(cfg.color))
            context.stroke(path, with: .color(Color.white.opacity(0.14)), lineWidth: 1.2)
        }

        // 中央九宮格底框
        let centerTL = point(for: BoardCoord(row: 6, col: 6), originX: originX, originY: originY, step: step)
        let centerBR = point(for: BoardCoord(row: 10, col: 10), originX: originX, originY: originY, step: step)
        let centerRect = CGRect(
            x: centerTL.x - pad * 0.65,
            y: centerTL.y - pad * 0.65,
            width: (centerBR.x - centerTL.x) + pad * 1.3,
            height: (centerBR.y - centerTL.y) + pad * 1.3
        )
        let centerPath = Path(roundedRect: centerRect, cornerRadius: 8)
        context.fill(centerPath, with: .color(Color.white.opacity(0.04)))
        context.stroke(centerPath, with: .color(Color.yellow.opacity(0.22)), lineWidth: 1)
    }

    private func drawRoadLines(
        context: inout GraphicsContext,
        originX: CGFloat,
        originY: CGFloat,
        step: CGFloat
    ) {
        var roadPath = Path()
        for (coordA, neighbors) in graph.roadNeighbors {
            let ptA = point(for: coordA, originX: originX, originY: originY, step: step)
            for coordB in neighbors where (coordA.row < coordB.row || (coordA.row == coordB.row && coordA.col < coordB.col)) {
                let ptB = point(for: coordB, originX: originX, originY: originY, step: step)
                roadPath.move(to: ptA)
                roadPath.addLine(to: ptB)
            }
        }
        context.stroke(
            roadPath,
            with: .color(Color(red: 0.62, green: 0.66, blue: 0.72).opacity(0.55)),
            lineWidth: max(1.4, step * 0.045)
        )
    }

    private func drawRailwayLines(
        context: inout GraphicsContext,
        originX: CGFloat,
        originY: CGFloat,
        step: CGFloat
    ) {
        let curveSet: Set<Set<BoardCoord>> = Set(graph.outerCurvePairs.map { Set([$0.0, $0.1]) })
        var railPath = Path()

        // 1. 直線鐵路區段
        for (coordA, neighbors) in graph.railwayNeighbors {
            let ptA = point(for: coordA, originX: originX, originY: originY, step: step)
            for coordB in neighbors where (coordA.row < coordB.row || (coordA.row == coordB.row && coordA.col < coordB.col)) {
                if curveSet.contains(Set([coordA, coordB])) {
                    continue
                }
                let ptB = point(for: coordB, originX: originX, originY: originY, step: step)
                railPath.move(to: ptA)
                railPath.addLine(to: ptB)
            }
        }

        // 2. 四條外圍平滑彎道鐵路
        for (coordA, coordB) in graph.outerCurvePairs {
            let ptA = point(for: coordA, originX: originX, originY: originY, step: step)
            let ptB = point(for: coordB, originX: originX, originY: originY, step: step)
            // 控制點選在轉角交會處 (row of B, col of A)
            let controlCoord = BoardCoord(row: coordB.row, col: coordA.col)
            let controlPt = point(for: controlCoord, originX: originX, originY: originY, step: step)
            railPath.move(to: ptA)
            railPath.addQuadCurve(to: ptB, control: controlPt)
        }

        // 底層深色路基
        context.stroke(
            railPath,
            with: .color(Color(red: 0.16, green: 0.18, blue: 0.22)),
            style: StrokeStyle(lineWidth: max(4.2, step * 0.13), lineCap: .round, lineJoin: .round)
        )
        // 上層枕木虛線
        context.stroke(
            railPath,
            with: .color(Color(red: 0.90, green: 0.84, blue: 0.66).opacity(0.88)),
            style: StrokeStyle(
                lineWidth: max(2.2, step * 0.068),
                lineCap: .butt,
                dash: [max(4.0, step * 0.14), max(4.0, step * 0.14)]
            )
        )
    }

    private func drawStations(
        context: inout GraphicsContext,
        originX: CGFloat,
        originY: CGFloat,
        step: CGFloat
    ) {
        for coord in graph.allCoords {
            guard let node = graph.nodes[coord] else { continue }
            let pt = point(for: coord, originX: originX, originY: originY, step: step)

            switch node.type {
            case .camp:
                let radius = step * 0.36
                let outerRect = CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)
                let innerRadius = step * 0.28
                let innerRect = CGRect(x: pt.x - innerRadius, y: pt.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)
                context.fill(Path(ellipseIn: outerRect), with: .color(Color(red: 0.18, green: 0.24, blue: 0.22)))
                context.stroke(Path(ellipseIn: outerRect), with: .color(Color.mint.opacity(0.75)), lineWidth: 1.6)
                context.stroke(Path(ellipseIn: innerRect), with: .color(Color.mint.opacity(0.35)), lineWidth: 1.0)

            case .headquarters:
                let w = step * 0.78
                let h = step * 0.56
                let rect = CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h)
                let path = Path(roundedRect: rect, cornerRadius: 6)
                context.fill(path, with: .color(Color(red: 0.28, green: 0.22, blue: 0.12)))
                context.stroke(path, with: .color(Color.yellow.opacity(0.85)), lineWidth: 1.8)

            case .railway, .normal:
                let w = step * 0.34
                let h = step * 0.26
                let rect = CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color(red: 0.22, green: 0.25, blue: 0.30)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.white.opacity(0.28)), lineWidth: 1.0)
            }
        }
    }

    private func drawLastMovePath(
        context: inout GraphicsContext,
        originX: CGFloat,
        originY: CGFloat,
        step: CGFloat
    ) {
        guard let lastMove = viewModel.displayedLastMove,
              lastMove.path.count >= 2 else {
            return
        }

        var path = Path()
        for (idx, coord) in lastMove.path.enumerated() {
            let pt = point(for: coord, originX: originX, originY: originY, step: step)
            if idx == 0 {
                path.move(to: pt)
            } else {
                path.addLine(to: pt)
            }
        }

        context.stroke(
            path,
            with: .color(Color.cyan.opacity(0.85)),
            style: StrokeStyle(
                lineWidth: max(2.6, step * 0.08),
                lineCap: .round,
                lineJoin: .round,
                dash: [max(5, step * 0.15), max(3, step * 0.10)]
            )
        )

        // 起點空心圓標記
        if let first = lastMove.path.first {
            let startPt = point(for: first, originX: originX, originY: originY, step: step)
            let r = step * 0.18
            let startRect = CGRect(x: startPt.x - r, y: startPt.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: startRect), with: .color(Color.cyan.opacity(0.35)))
            context.stroke(Path(ellipseIn: startRect), with: .color(Color.cyan), lineWidth: 2.0)
        }
    }

    // MARK: - 陣營浮水印

    @ViewBuilder
    private func zoneWatermarkOverlay(originX: CGFloat, originY: CGFloat, step: CGFloat) -> some View {
        let state = viewModel.displayedState
        let badges: [(seat: Seat, coord: BoardCoord)] = [
            (.south, BoardCoord(row: 13, col: 12)),
            (.north, BoardCoord(row: 2, col: 12)),
            (.west, BoardCoord(row: 4, col: 2)),
            (.east, BoardCoord(row: 12, col: 14))
        ]

        ForEach(badges, id: \.seat) { item in
            let pt = point(for: item.coord, originX: originX, originY: originY, step: step)
            let isDead = state.eliminatedSeats.contains(item.seat)
            let isTurn = state.phase == .playing && state.currentTurn == item.seat

            VStack(spacing: 2) {
                Text(item.seat.displayName)
                    .font(.system(size: max(10, step * 0.26), weight: .bold, design: .rounded))
                    .foregroundStyle(seatThemeColor(item.seat))
                if isDead {
                    Text("已淘汰")
                        .font(.system(size: max(9, step * 0.22), weight: .bold))
                        .foregroundStyle(.red)
                } else if isTurn {
                    Text("● 思考/行棋中")
                        .font(.system(size: max(9, step * 0.22), weight: .bold))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isTurn ? Color.yellow : seatThemeColor(item.seat).opacity(0.5), lineWidth: isTurn ? 1.8 : 1.0)
                    )
            )
            .position(x: pt.x, y: pt.y)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 單一節點與棋子互動組件

    @ViewBuilder
    private func nodeInteractiveCell(at coord: BoardCoord, step: CGFloat) -> some View {
        let state = viewModel.displayedState
        let node = graph.nodes[coord]
        let piece = state.pieces[coord]
        let isSelected = viewModel.selectedCoord == coord
        let isValidMoveTarget = !viewModel.isReplaying && viewModel.validMovesForSelected.contains(where: { $0.to == coord })
        let isSwapCandidate = !viewModel.isReplaying && viewModel.canSwapWithSelectedInSetup(coord)
        let isLastMoveTo = viewModel.displayedLastMove?.to == coord

        ZStack {
            // 空行營 / 空大本營文字提示
            if piece == nil, let node {
                if node.type == .camp {
                    Text("營")
                        .font(.system(size: max(9, step * 0.25), weight: .semibold))
                        .foregroundStyle(Color.mint.opacity(0.65))
                } else if node.type == .headquarters {
                    Text("大本營")
                        .font(.system(size: max(8, step * 0.20), weight: .bold))
                        .foregroundStyle(Color.yellow.opacity(0.65))
                }
            }

            // 棋子視圖
            if let piece {
                pieceTileView(
                    piece: piece,
                    coord: coord,
                    step: step,
                    isSelected: isSelected,
                    isAttackableTarget: isValidMoveTarget,
                    isSwapCandidate: isSwapCandidate,
                    isLastMoveDestination: isLastMoveTo
                )
            }

            // 空位合法走步綠點
            if piece == nil && isValidMoveTarget {
                Circle()
                    .fill(Color.green)
                    .frame(width: step * 0.34, height: step * 0.34)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 1.5)
                    )
                    .shadow(color: Color.green.opacity(0.8), radius: 4)
            }
        }
        .frame(width: step * 0.92, height: step * 0.92)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.handleNodeTap(coord)
        }
    }

    @ViewBuilder
    private func pieceTileView(
        piece: Piece,
        coord: BoardCoord,
        step: CGFloat,
        isSelected: Bool,
        isAttackableTarget: Bool,
        isSwapCandidate: Bool,
        isLastMoveDestination: Bool
    ) -> some View {
        let state = viewModel.displayedState
        let revealAll = viewModel.godModeEnabled || state.phase == .finished
        let isVisible = piece.isVisibleToHuman(mode: state.visibilityMode, forceRevealAll: revealAll)
        let tileWidth = step * 0.84
        let tileHeight = step * 0.64

        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [
                            seatThemeColor(piece.owner),
                            seatThemeColor(piece.owner).opacity(0.80)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1.5)

            // 邊框狀態高亮
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    tileBorderColor(
                        isSelected: isSelected,
                        isAttackableTarget: isAttackableTarget,
                        isSwapCandidate: isSwapCandidate,
                        isLastMoveDestination: isLastMoveDestination,
                        isRevealedFlag: piece.isPubliclyRevealed && piece.rank == .flag
                    ),
                    lineWidth: (isSelected || isAttackableTarget || isSwapCandidate || isLastMoveDestination) ? 2.4 : 1.2
                )

            // 棋子文字內容
            if isVisible {
                VStack(spacing: 0) {
                    Text(pieceDisplayText(piece.rank))
                        .font(.system(size: max(10, step * 0.28), weight: .heavy, design: .rounded))
                        .foregroundStyle(pieceTextColor(for: piece.rank))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .padding(.horizontal, 2)
            } else {
                // 暗棋：若有玩家標記則顯示標記，否則顯示陣營暗棋圖樣
                if let tag = piece.suspicionTag {
                    Text("?\(tag.rawValue)")
                        .font(.system(size: max(9, step * 0.25), weight: .bold, design: .rounded))
                        .foregroundStyle(Color.yellow)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.horizontal, 2)
                } else {
                    Text(piece.owner.shortName)
                        .font(.system(size: max(10, step * 0.26), weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }

            // 若在明棋/透視狀態下也有標記，於右上角顯示小角標
            if isVisible, let tag = piece.suspicionTag {
                VStack {
                    HStack {
                        Spacer()
                        Text(tag.rawValue)
                            .font(.system(size: max(7, step * 0.16), weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 2)
                            .background(RoundedRectangle(cornerRadius: 2).fill(Color.yellow))
                    }
                    Spacer()
                }
                .padding(1.5)
            }
        }
        .frame(width: tileWidth, height: tileHeight)
        .scaleEffect(isSelected ? 1.10 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isSelected)
        .contextMenu {
            if piece.owner != .south {
                Section("標記此枚棋子（右鍵情報標記）") {
                    ForEach(SuspicionTag.allCases, id: \.self) { tag in
                        Button {
                            viewModel.setTag(tag, for: coord)
                        } label: {
                            Label("標記為：\(tag.rawValue)", systemImage: piece.suspicionTag == tag ? "checkmark.circle.fill" : "tag")
                        }
                    }
                    if piece.suspicionTag != nil {
                        Divider()
                        Button(role: .destructive) {
                            viewModel.setTag(nil, for: coord)
                        } label: {
                            Label("清除標記", systemImage: "xmark.circle")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 視覺配色輔助

    private func seatThemeColor(_ seat: Seat) -> Color {
        switch seat {
        case .south:
            return Color(red: 0.76, green: 0.17, blue: 0.19) // 南方玩家：赤紅
        case .north:
            return Color(red: 0.11, green: 0.50, blue: 0.43) // 北方盟友：青翠
        case .west:
            return Color(red: 0.45, green: 0.24, blue: 0.66) // 西方敵軍：靛紫
        case .east:
            return Color(red: 0.76, green: 0.43, blue: 0.12) // 東方敵軍：琥珀橙
        }
    }

    private func pieceDisplayText(_ rank: PieceRank) -> String {
        switch rank {
        case .flag:
            return "⚑軍旗"
        case .bomb:
            return "💣炸彈"
        case .mine:
            return "✳地雷"
        default:
            return rank.rawValue
        }
    }

    private func pieceTextColor(for rank: PieceRank) -> Color {
        switch rank {
        case .commander:
            return Color(red: 1.0, green: 0.92, blue: 0.45)
        case .flag:
            return Color(red: 1.0, green: 0.88, blue: 0.32)
        case .bomb:
            return Color(red: 1.0, green: 0.78, blue: 0.72)
        default:
            return .white
        }
    }

    private func tileBorderColor(
        isSelected: Bool,
        isAttackableTarget: Bool,
        isSwapCandidate: Bool,
        isLastMoveDestination: Bool,
        isRevealedFlag: Bool
    ) -> Color {
        if isSelected {
            return .yellow
        }
        if isAttackableTarget {
            return .red
        }
        if isSwapCandidate {
            return .green
        }
        if isLastMoveDestination {
            return .cyan
        }
        if isRevealedFlag {
            return .orange
        }
        return Color.white.opacity(0.38)
    }

    private func combatBadgeColor(for outcome: CombatOutcome) -> Color {
        switch outcome {
        case .attackerWins:
            return Color.green.opacity(0.90)
        case .defenderWins:
            return Color.orange.opacity(0.90)
        case .mutualDestruction:
            return Color.red.opacity(0.92)
        case .moveOnly:
            return Color.blue.opacity(0.85)
        }
    }
}
