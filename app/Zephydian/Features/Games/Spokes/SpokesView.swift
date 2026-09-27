import SwiftUI

struct SpokesView: View {
    let game: SpokesGame
    @Environment(SettingsStore.self) private var settings

    @State private var dragPoint: CGPoint?
    @State private var dragMoved = false
    @State private var dragStarted = false
    @State private var pressedLast = false

    private static let wheelSize: CGFloat = 176
    private static let letterSize: CGFloat = 42
    private static let letterRadius: CGFloat = 58

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 10) {
                grid.frame(height: 188)
                currentWord.frame(height: 34)
                HStack(spacing: 18) {
                    roundButton("shuffle", label: "Shuffle (Space)") { game.shuffle() }
                    wheel
                    hintButton
                }
                Text("Bonus words: \(game.bonus.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let message = game.message {
                GameToast(text: message)
            }

            if game.isComplete {
                GameOverlay(title: "Level \(game.level) complete!",
                            subtitle: "\(game.bonus.count) bonus word\(game.bonus.count == 1 ? "" : "s") · +1 hint") {
                    Button("Next level") { game.nextLevel() }.prominentButtonStyle()
                }
                .padding(.horizontal, 16)
            }
        }
        .animation(.easeOut(duration: 0.15), value: game.message)
        .animation(.easeOut(duration: 0.2), value: game.isComplete)
    }

    // MARK: Crossword

    private var grid: some View {
        let puzzle = game.puzzle
        let visible = game.visibleCells
        let solution = puzzle.solution
        let found = game.found
        let justFound = game.justFound.flatMap { word in puzzle.entries.first { $0.word == word } }.map { Set($0.cells) } ?? []
        let accent = settings.accent.color

        return GeometryReader { geometry in
            let cell = min(30, geometry.size.width / CGFloat(puzzle.width), geometry.size.height / CGFloat(puzzle.height))
            let origin = CGPoint(x: (geometry.size.width - cell * CGFloat(puzzle.width)) / 2,
                                 y: (geometry.size.height - cell * CGFloat(puzzle.height)) / 2)
            Canvas { context, _ in
                for (position, letter) in solution {
                    let rect = CGRect(x: origin.x + CGFloat(position.x) * cell + 1.5, y: origin.y + CGFloat(position.y) * cell + 1.5,
                                      width: cell - 3, height: cell - 3)
                    let inFoundWord = puzzle.entries.contains { found.contains($0.word) && $0.cells.contains(position) }
                    let fill: Color = justFound.contains(position) ? accent.opacity(0.75) : (inFoundWord ? accent : Tokens.fillHover)
                    context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(fill))
                    if visible.contains(position) {
                        let text = Text(String(letter))
                            .font(.system(size: cell * 0.55, weight: .bold, design: .rounded))
                            .foregroundStyle(inFoundWord ? Color.white : Color.secondary)
                        context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement()
        .accessibilityLabel("Crossword: \(game.found.count) of \(puzzle.entries.count) words found")
    }

    // MARK: Current word

    private var currentWord: some View {
        HStack(spacing: 8) {
            if !game.selection.isEmpty {
                Text(game.currentWord)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .background(Capsule().fill(.tint))
                    .modifier(SpokesShake(animatableData: CGFloat(game.shakeCount)))
                    .animation(.linear(duration: 0.3), value: game.shakeCount)
                Button { game.submit() } label: { Image(systemName: "checkmark") }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                    .help("Submit (Enter)").accessibilityLabel("Submit word")
                Button { game.clearSelection() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear").accessibilityLabel("Clear letters")
            }
        }
        .font(.system(size: 13, weight: .semibold))
    }

    // MARK: Wheel

    private var wheel: some View {
        let size = Self.wheelSize
        let center = CGPoint(x: size / 2, y: size / 2)
        let positions = letterPositions(center: center)
        let selected = game.selection
        let accent = settings.accent.color

        return ZStack {
            Circle().fill(Tokens.fill)

            // Line connecting the picked letters (and following the pointer while dragging).
            Path { path in
                guard let first = selected.first else { return }
                path.move(to: positions[first])
                for index in selected.dropFirst() { path.addLine(to: positions[index]) }
                if let dragPoint, dragMoved { path.addLine(to: dragPoint) }
            }
            .stroke(accent.opacity(0.6), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))

            ForEach(game.letters.indices, id: \.self) { index in
                let isSelected = selected.contains(index)
                Text(String(game.letters[index]))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(width: Self.letterSize, height: Self.letterSize)
                    .background(Circle().fill(isSelected ? accent : Tokens.fillHover))
                    .position(positions[index])
                    .accessibilityElement()
                    .accessibilityLabel(String(game.letters[index]))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { game.tap(index) }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let hit = letterIndex(at: drag.location, positions: positions)
                    if !dragStarted {
                        dragStarted = true
                        dragMoved = false
                        pressedLast = hit != nil && hit == game.selection.last
                        if let hit, !pressedLast { game.dragOver(hit) }
                    } else if let hit {
                        game.dragOver(hit)
                    }
                    if hypot(drag.translation.width, drag.translation.height) > 6 { dragMoved = true }
                    dragPoint = drag.location
                }
                .onEnded { _ in
                    if dragMoved {
                        if game.selection.count >= 2 { game.submit() }
                    } else if pressedLast {
                        game.tap(game.selection.last!) // clicking the last letter again removes it
                    }
                    dragStarted = false
                    dragMoved = false
                    dragPoint = nil
                }
        )
        .animation(.easeInOut(duration: 0.25), value: game.letters)
    }

    private func letterPositions(center: CGPoint) -> [CGPoint] {
        let count = game.letters.count
        return (0..<count).map { i in
            let angle = Double(i) / Double(count) * 2 * .pi - .pi / 2
            return CGPoint(x: center.x + cos(angle) * Self.letterRadius, y: center.y + sin(angle) * Self.letterRadius)
        }
    }

    private func letterIndex(at point: CGPoint, positions: [CGPoint]) -> Int? {
        positions.indices.first { hypot(positions[$0].x - point.x, positions[$0].y - point.y) <= Self.letterSize / 2 + 2 }
    }

    // MARK: Buttons

    private var hintButton: some View {
        roundButton("lightbulb", label: "Hint (?): \(game.hints) left") { game.useHint() }
            .overlay(alignment: .topTrailing) {
                Text("\(game.hints)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(game.hints > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.gray)))
                    .offset(x: 4, y: -4)
            }
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Tokens.fillHover))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct SpokesShake: ViewModifier, Animatable {
    var animatableData: CGFloat
    func body(content: Content) -> some View {
        content.offset(x: sin(animatableData * .pi * 4) * 5)
    }
}
