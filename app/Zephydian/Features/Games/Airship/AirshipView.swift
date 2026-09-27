import SwiftUI

struct AirshipView: View {
    let game: AirshipGame
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let world = game.world
        let accent = settings.accent.color
        let field = AirshipGame.field

        ZStack {
            Canvas { context, size in
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10), with: .color(Tokens.fill))
                context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10))

                for star in world.stars {
                    let r: CGFloat = star.speed > 50 ? 1.2 : 0.8
                    context.fill(Path(ellipseIn: CGRect(x: star.position.x - r, y: star.position.y - r, width: r * 2, height: r * 2)),
                                 with: .color(.secondary.opacity(0.5)))
                }
                for p in world.powerUps { Self.drawPowerUp(&context, p) }
                for e in world.enemies { Self.drawEnemy(&context, e) }
                for b in world.bullets {
                    context.fill(Path(roundedRect: CGRect(x: b.position.x - 1.5, y: b.position.y - 5, width: 3, height: 10), cornerRadius: 1.5),
                                 with: .color(.yellow))
                }
                for b in world.enemyBullets {
                    context.fill(Path(ellipseIn: CGRect(x: b.position.x - 3.5, y: b.position.y - 3.5, width: 7, height: 7)), with: .color(.orange))
                }
                for x in world.explosions {
                    let t = x.age / 0.4
                    let r = x.size * (0.4 + t * 0.8)
                    context.stroke(Path(ellipseIn: CGRect(x: x.position.x - r / 2, y: x.position.y - r / 2, width: r, height: r)),
                                   with: .color(.orange.opacity(1 - t)), lineWidth: 3)
                }

                // The player: the Zephydian jet, blinking while invulnerable.
                let blinking = world.time < world.invulnerableUntil && Int(world.time * 12) % 2 == 0
                if !blinking && world.lives > 0 {
                    context.fill(Self.jetPath(center: world.player, size: 28), with: .color(accent))
                    if world.hasShield {
                        context.stroke(Path(ellipseIn: CGRect(x: world.player.x - 19, y: world.player.y - 19, width: 38, height: 38)),
                                       with: .color(.cyan.opacity(0.8)), lineWidth: 2)
                    }
                }
            }
            .frame(width: field.width, height: field.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase { game.mouseMoved(to: point) } else { game.mouseMoved(to: nil) }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        game.mouseMoved(to: value.location)
                        game.setMouseFiring(true)
                    }
                    .onEnded { _ in game.setMouseFiring(false) }
            )
            .accessibilityElement()
            .accessibilityLabel("Airship. Score \(world.score), \(world.lives) lives, wave \(world.wave)")

            hud(world).frame(width: field.width, height: field.height)
            overlay.frame(width: field.width, height: field.height)
        }
        .animation(.easeOut(duration: 0.15), value: game.state)
    }

    private func hud(_ world: AirshipGame.World) -> some View {
        VStack {
            HStack {
                HStack(spacing: 3) {
                    ForEach(0..<max(world.lives, 0), id: \.self) { _ in
                        Image(systemName: "heart.fill").font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
                Spacer()
                if world.time < world.doubleShotUntil {
                    Label("2×", systemImage: "bolt.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.yellow)
                }
                Text("Wave \(world.wave)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(8)
            Spacer()
            if world.time - world.perfectBanner < 1.3, game.state == .running {
                Text("Perfect wave! +\(100 * (world.wave - 1))")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .transition(.opacity)
            }
            if world.time - world.waveBanner < 1.3, world.wave > 0, game.state == .running {
                Text("Wave \(world.wave)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var overlay: some View {
        switch game.state {
        case .ready:
            GameOverlay(title: "Airship", subtitle: "Fly with the arrow keys or mouse.\nHold Space or click to fire.") {
                Button("Take off") { game.start() }.prominentButtonStyle()
            }
        case .paused:
            GameOverlay(title: "Paused", subtitle: "Score \(game.world.score.formatted())") {
                Button("Resume") { game.start() }.prominentButtonStyle()
                Button("Restart") { game.reset(); game.start() }
            }
        case .over:
            GameOverlay(title: game.isNewBest ? "New best!" : "Shot down",
                        subtitle: "Score \(game.world.score.formatted()) · reached wave \(game.world.wave)") {
                Button("Fly again") { game.start() }.prominentButtonStyle()
            }
        case .running:
            EmptyView()
        }
    }

    // MARK: Drawing

    private static func drawEnemy(_ context: inout GraphicsContext, _ e: AirshipGame.Enemy) {
        let p = e.position, r = e.kind.radius
        var path = Path()
        switch e.kind {
        case .drone: // downward triangle
            path.move(to: CGPoint(x: p.x, y: p.y + r))
            path.addLine(to: CGPoint(x: p.x - r, y: p.y - r * 0.8))
            path.addLine(to: CGPoint(x: p.x + r, y: p.y - r * 0.8))
            path.closeSubpath()
            context.fill(path, with: .color(.secondary))
        case .zigzag: // diamond
            path.move(to: CGPoint(x: p.x, y: p.y - r))
            path.addLine(to: CGPoint(x: p.x + r, y: p.y))
            path.addLine(to: CGPoint(x: p.x, y: p.y + r))
            path.addLine(to: CGPoint(x: p.x - r, y: p.y))
            path.closeSubpath()
            context.fill(path, with: .color(.purple))
        case .heavy: // hexagon with health pips
            for i in 0..<6 {
                let a = Double(i) / 6 * 2 * .pi + .pi / 6
                let pt = CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
                i == 0 ? path.move(to: pt) : path.addLine(to: pt)
            }
            path.closeSubpath()
            context.fill(path, with: .color(.red.opacity(0.85)))
            for i in 0..<e.health {
                let x = p.x - 6 + CGFloat(i) * 6
                context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(.white))
            }
        }
    }

    private static func drawPowerUp(_ context: inout GraphicsContext, _ p: AirshipGame.PowerUp) {
        let (color, label): (Color, Text) = switch p.kind {
        case .doubleShot: (.yellow, Text("2×"))
        case .shield: (.cyan, Text("S"))
        case .life: (.red, Text(Image(systemName: "heart.fill")))
        }
        let rect = CGRect(x: p.position.x - 9, y: p.position.y - 9, width: 18, height: 18)
        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.9)))
        context.draw(label.font(.system(size: 9, weight: .heavy)).foregroundStyle(.black), at: p.position)
    }

    /// The Zephydian logo jet (same shape as assets/brand/zephydian-jet.svg), centered on a point.
    private static let jetPoints: [CGPoint] = [
        (12, 1), (12.9, 4), (13.3, 7.6), (14.6, 9.2), (14.6, 11), (22, 16), (22, 17.6), (14.8, 17), (14.8, 18.6),
        (18.6, 21.4), (18.6, 23), (13.6, 22.2), (13, 23.2), (11, 23.2), (10.4, 22.2), (5.4, 23), (5.4, 21.4),
        (9.2, 18.6), (9.2, 17), (2, 17.6), (2, 16), (9.4, 11), (9.4, 9.2), (10.7, 7.6), (11.1, 4),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    private static func jetPath(center: CGPoint, size: CGFloat) -> Path {
        let scale = size / 24
        var path = Path()
        for (i, pt) in jetPoints.enumerated() {
            let p = CGPoint(x: center.x + (pt.x - 12) * scale, y: center.y + (pt.y - 12) * scale)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}
