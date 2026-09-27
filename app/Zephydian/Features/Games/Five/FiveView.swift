import SwiftUI

struct FiveView: View {
    let game: FiveGame
    @Environment(SettingsStore.self) private var settings

    private static let rows = ["QWERTYUIOP", "ASDFGHJKL", "↵ZXCVBNM⌫"]

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 10) {
                board
                actions
                keyboard
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let message = game.message {
                GameToast(text: message)
            }

            if game.showsResult {
                result.padding(.horizontal, 16)
            }
        }
        .animation(.easeOut(duration: 0.15), value: game.message)
        .animation(.easeOut(duration: 0.2), value: game.showsResult)
    }

    // MARK: Board

    private var board: some View {
        VStack(spacing: 5) {
            ForEach(0..<FiveGame.maxGuesses, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(0..<FiveGame.length, id: \.self) { col in
                        tile(row: row, col: col)
                    }
                }
                .modifier(Shake(animatableData: CGFloat(row == game.guesses.count ? game.shakeCount : 0)))
                .animation(.linear(duration: 0.35), value: game.shakeCount)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Five board")
    }

    @ViewBuilder
    private func tile(row: Int, col: Int) -> some View {
        let isLastGuess = row == game.guesses.count - 1
        let revealed = row < game.guesses.count && (!isLastGuess || col < game.revealedInLastRow)
        let letter: Character? = row < game.guesses.count
            ? Array(game.guesses[row])[col]
            : (row == game.guesses.count && col < game.current.count ? Array(game.current)[col] : nil)
        let mark = revealed ? FiveGame.marks(for: game.guesses[row], answer: game.answer)[col] : nil
        // Faint hint letter in the row being typed, until the player types over that spot.
        let ghost = row == game.guesses.count && letter == nil && !game.isDone ? game.knownPositions[col] : nil

        FiveTile(letter: letter, ghost: ghost, mark: mark, colors: colors)
    }

    // MARK: Hint & reveal

    private var actions: some View {
        HStack {
            Button { game.useHint() } label: {
                Label("Hint", systemImage: "lightbulb")
            }
            .disabled(!game.canUseHint)
            .help("Show one letter in its correct spot (?)")
            Spacer()
            Button { game.requestReveal() } label: {
                Label("Reveal word", systemImage: "eye")
            }
            .disabled(game.isDone)
            .help(game.mode == .daily ? "Show the answer (counts as a loss)" : "Show the answer")
        }
        .buttonStyle(ActionPillStyle())
        .frame(width: 329)
        .alert("Reveal today’s word?", isPresented: Binding(get: { game.confirmingReveal }, set: { game.confirmingReveal = $0 })) {
            Button("Reveal", role: .destructive) { game.revealAnswer() }
            Button("Keep trying", role: .cancel) {}
        } message: {
            Text("This counts as a loss and resets your streak.")
        }
    }

    // MARK: Keyboard

    private var keyboard: some View {
        let marks = game.keyboardMarks
        return VStack(spacing: 6) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(Array(row), id: \.self) { key in
                        keyButton(key, mark: marks[key])
                    }
                }
            }
        }
    }

    private func keyButton(_ key: Character, mark: FiveGame.Mark?) -> some View {
        let wide = key == "↵" || key == "⌫"
        return Button {
            switch key {
            case "↵": game.isDone ? game.startPractice() : game.submit()
            case "⌫": game.deleteLetter()
            default: game.type(String(key))
            }
        } label: {
            Text(key == "↵" ? "Enter" : String(key))
                .font(.system(size: wide ? 11 : 13, weight: .semibold))
                .frame(width: wide ? 47 : 29, height: 38)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(colors.key(mark)))
                .foregroundStyle(colors.keyText(mark))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(Self.keyLabel(key, mark: mark))
    }

    private static func keyLabel(_ key: Character, mark: FiveGame.Mark?) -> String {
        switch key {
        case "↵": return "Enter"
        case "⌫": return "Delete"
        default: return mark.map { "\(String(key)), \(FiveTile.name($0))" } ?? String(key)
        }
    }

    // MARK: Result card

    private var result: some View {
        let stats = game.stats
        let won = game.guesses.last == game.answer
        return VStack(spacing: 10) {
            HStack {
                Spacer()
                Button { game.closeResult() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Show the board").accessibilityLabel("Close results")
            }
            Text(won ? "Solved in \(game.guesses.count)/6" : "The word was \(game.answer)")
                .font(.system(size: 18, weight: .bold))
            if !game.hintedPositions.isEmpty {
                Text("\(game.hintedPositions.count) hint\(game.hintedPositions.count == 1 ? "" : "s") used")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if game.mode == .daily {
                HStack(spacing: 18) {
                    statCell(stats.played, "Played")
                    statCell(stats.played > 0 ? stats.wins * 100 / stats.played : 0, "Win %")
                    statCell(FiveGame.currentStreak(stats), "Streak")
                    statCell(stats.maxStreak, "Best")
                }
                Text("New daily word tomorrow").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if game.mode == .practice { Button("Back to daily") { game.startDaily() } }
                Button(game.mode == .daily ? "Practice" : "Next word") { game.startPractice() }
                    .prominentButtonStyle()
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 16).padding(.bottom, 18).padding(.top, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.top, 60)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func statCell(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text("\(value)").font(.system(size: 20, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var colors: FiveColors { FiveColors(highContrast: settings.fiveHighContrast) }
}

/// The header dropdown: switch between today's word and practice words.
struct FiveModeMenu: View {
    let game: FiveGame

    var body: some View {
        Menu {
            Picker("Mode", selection: Binding(
                get: { game.mode },
                set: { $0 == .daily ? game.startDaily() : game.startPractice() }
            )) {
                Text("Daily word").tag(FiveGame.Mode.daily)
                Text("Practice").tag(FiveGame.Mode.practice)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if game.mode == .practice {
                Divider()
                Button("New practice word") { game.startPractice() }
            }
        } label: {
            Text(game.scoreText)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Switch between the daily word and practice")
        .accessibilityLabel("Mode: \(game.mode == .daily ? "Daily word" : "Practice")")
    }
}

/// Five's tile colors: slightly deeper than system colors so white letters stay readable.
struct FiveColors {
    let highContrast: Bool

    func fill(_ mark: FiveGame.Mark) -> Color {
        switch mark {
        case .correct: highContrast ? .dynamic(light: 0xE07700, dark: 0xE07700) : .dynamic(light: 0x30A14E, dark: 0x2EA043)
        case .present: highContrast ? .dynamic(light: 0x1673D9, dark: 0x1673D9) : .dynamic(light: 0xC28F00, dark: 0xB8900A)
        case .absent: .dynamic(light: 0x8E8E93, dark: 0x48484A)
        }
    }

    /// On-screen keys, Wordle-style: ruled-out letters turn clearly darker than unused keys.
    func key(_ mark: FiveGame.Mark?) -> Color {
        switch mark {
        case nil: .dynamic(light: 0xD3D6DA, dark: 0x818384)
        case .absent: .dynamic(light: 0x787C7E, dark: 0x3A3A3C)
        case let mark?: fill(mark)
        }
    }

    func keyText(_ mark: FiveGame.Mark?) -> Color {
        mark == nil ? .dynamic(light: 0x1A1A1B, dark: 0xFFFFFF) : .white
    }
}

/// Small capsule buttons for Hint / Reveal word.
private struct ActionPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(configuration.isPressed ? Tokens.fillHover.opacity(2) : Tokens.fillHover))
            .foregroundStyle(.secondary)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

private struct FiveTile: View {
    let letter: Character?
    var ghost: Character?
    let mark: FiveGame.Mark?
    let colors: FiveColors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text((letter ?? ghost).map(String.init) ?? "")
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(textStyle)
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(mark.map(colors.fill) ?? .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1.5))
            .keyframeAnimator(initialValue: 0.0, trigger: mark) { content, angle in
                content.rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0))
            } keyframes: { _ in
                LinearKeyframe(flipAngle, duration: 0.12)
                LinearKeyframe(0.0, duration: 0.12)
            }
            .accessibilityLabel(accessibilityText)
    }

    /// Tiles flip over when they're revealed (no flip with Reduce Motion).
    private var flipAngle: Double { mark != nil && !reduceMotion ? 90 : 0 }

    private var textStyle: AnyShapeStyle {
        if mark != nil { return AnyShapeStyle(.white) }
        if letter == nil, ghost != nil { return AnyShapeStyle(Color.primary.opacity(0.25)) } // hint ghost
        return AnyShapeStyle(.primary)
    }

    private var border: Color {
        if mark != nil { return .clear }
        return Color.primary.opacity(letter == nil ? 0.1 : 0.28)
    }

    private var accessibilityText: String {
        guard let letter else { return ghost.map { "empty, hint: \(String($0))" } ?? "empty" }
        guard let mark else { return String(letter) }
        return "\(String(letter)), \(Self.name(mark))"
    }

    static func name(_ mark: FiveGame.Mark) -> String {
        switch mark {
        case .correct: "correct"
        case .present: "in the word"
        case .absent: "not in the word"
        }
    }
}

/// Side-to-side shake for an invalid guess.
private struct Shake: ViewModifier, Animatable {
    var animatableData: CGFloat

    func body(content: Content) -> some View {
        content.offset(x: sin(animatableData * .pi * 4) * 5)
    }
}
