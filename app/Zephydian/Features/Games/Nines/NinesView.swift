import SwiftUI

struct NinesView: View {
    let game: NinesGame
    @Environment(SettingsStore.self) private var settings

    private static let cell: CGFloat = 34
    private static let side = cell * 9

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                grid
                overlay.frame(width: Self.side, height: Self.side)
            }
            tools
            digitPad
        }
        .animation(.easeOut(duration: 0.2), value: game.state)
    }

    // MARK: Grid

    private var grid: some View {
        // Read the state here (not inside Canvas) so SwiftUI redraws when it changes.
        let accent = settings.accent.color
        let values = (0..<81).map { game.value(at: $0) }
        let givens = game.puzzle?.givens ?? Array(repeating: 0, count: 81)
        let notes = game.notes
        let conflicts = game.conflicts
        let selected = game.selected
        let showSelection = game.state == .playing
        let hidden = game.state != .playing && game.state != .won // no peeking while paused
        let selectedValue = values[selected]
        let cell = Self.cell

        return Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Tokens.fill))
            if !hidden {
                for i in 0..<81 {
                    let rect = CGRect(x: CGFloat(i % 9) * cell, y: CGFloat(i / 9) * cell, width: cell, height: cell)
                    // Highlights: the selected cell, its row/column/box, and every cell with the same number.
                    if showSelection {
                        let isPeer = NinesGenerator.peers[selected].contains(i)
                        let sameValue = selectedValue != 0 && values[i] == selectedValue
                        let opacity = i == selected ? 0.38 : sameValue ? 0.24 : isPeer ? 0.08 : 0
                        if opacity > 0 { context.fill(Path(rect), with: .color(accent.opacity(opacity))) }
                    }
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    if values[i] != 0 {
                        let color: Color = conflicts.contains(i) && givens[i] == 0 ? .red : givens[i] != 0 ? .primary : accent
                        let text = Text("\(values[i])").font(.system(size: 19, weight: givens[i] != 0 ? .semibold : .regular))
                        context.draw(text.foregroundStyle(color), at: center)
                        if conflicts.contains(i) && givens[i] != 0 {
                            context.fill(Path(ellipseIn: CGRect(x: rect.maxX - 8, y: rect.minY + 4, width: 4, height: 4)), with: .color(.red))
                        }
                    } else if notes[i] != 0 {
                        for d in 1...9 where notes[i] & (1 << d) != 0 {
                            let p = CGPoint(x: rect.minX + (CGFloat((d - 1) % 3) + 0.5) * cell / 3,
                                            y: rect.minY + (CGFloat((d - 1) / 3) + 0.5) * cell / 3)
                            context.draw(Text("\(d)").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary), at: p)
                        }
                    }
                }
            }
            // Grid lines: thin between cells, thicker around each 3×3 box.
            var thin = Path(), thick = Path()
            for i in 1..<9 {
                let p = CGFloat(i) * cell
                var line = Path()
                line.move(to: CGPoint(x: p, y: 0)); line.addLine(to: CGPoint(x: p, y: size.height))
                line.move(to: CGPoint(x: 0, y: p)); line.addLine(to: CGPoint(x: size.width, y: p))
                if i % 3 == 0 { thick.addPath(line) } else { thin.addPath(line) }
            }
            context.stroke(thin, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            context.stroke(thick, with: .color(.secondary.opacity(0.6)), lineWidth: 1.5)
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(Rectangle())
        .onTapGesture { location in
            let x = Int(location.x / cell), y = Int(location.y / cell)
            guard (0..<9).contains(x), (0..<9).contains(y) else { return }
            game.select(y * 9 + x)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let v = game.value(at: game.selected)
        return "Nines grid. Row \(game.selected / 9 + 1), column \(game.selected % 9 + 1): \(v == 0 ? "empty" : "\(v)"). Use arrow keys to move and 1 to 9 to fill."
    }

    // MARK: Controls

    private var tools: some View {
        HStack(spacing: 8) {
            Button { _ = game.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help("Undo (⌘Z)")
            Button { game.erase() } label: { Label("Erase", systemImage: "delete.left") }
                .help("Erase (⌫)")
            Button { game.notesMode.toggle() } label: {
                Label(game.notesMode ? "Notes on" : "Notes off", systemImage: "pencil")
            }
            .foregroundStyle(game.notesMode ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .help("Pencil marks (N)")
        }
        .buttonStyle(ToolPillStyle())
        .disabled(game.state != .playing)
    }

    private var digitPad: some View {
        let counts = game.digitCounts
        return HStack(spacing: 4) {
            ForEach(1...9, id: \.self) { d in
                Button { game.enter(d) } label: {
                    Text("\(d)")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 30, height: 36)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tokens.fill))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // All nine placed: dim the key (it still works in notes mode).
                .opacity(counts[d] >= 9 ? 0.35 : 1)
                .accessibilityLabel("\(d)")
            }
        }
        .disabled(game.state != .playing)
    }

    @ViewBuilder private var overlay: some View {
        switch game.state {
        case .loading:
            ProgressView().controlSize(.small)
        case .paused:
            GameOverlay(title: "Paused", subtitle: "\(game.difficulty.title) · \(BestTime.format(game.seconds))") {
                Button("Resume") { game.togglePause() }.prominentButtonStyle()
            }
        case .won:
            GameOverlay(title: game.isNewBest ? "New best time!" : "Solved!",
                        subtitle: "\(game.difficulty.title) in \(BestTime.format(game.seconds))") {
                Button("New game") { game.newGame() }.prominentButtonStyle()
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: 150)
        case .playing:
            EmptyView()
        }
    }
}

/// Small capsule buttons for Undo / Erase / Notes.
private struct ToolPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(configuration.isPressed ? Tokens.fillHover.opacity(2) : Tokens.fillHover))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// Header dropdown: difficulty, new game, and the clock.
struct NinesHeaderMenu: View {
    let game: NinesGame

    var body: some View {
        Menu {
            Section("New game") {
                ForEach(NinesGame.Difficulty.allCases) { d in
                    Button(d.title) { game.newGame(d) }
                }
            }
        } label: {
            Text(game.scoreText)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Start a new puzzle")
        .accessibilityLabel("\(game.difficulty.title), time \(BestTime.format(game.seconds))")
    }
}
