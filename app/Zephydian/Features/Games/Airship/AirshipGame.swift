import AppKit
import SwiftUI

/// Airship: a top-down shooter. Fly the Zephydian jet, shoot down waves of enemies, grab power-ups.
@Observable
final class AirshipGame: GameSession {
    enum State { case ready, running, paused, over }

    enum EnemyKind {
        case drone, zigzag, heavy
        var radius: CGFloat { self == .heavy ? 15 : 10 }
        var points: Int { switch self { case .drone: 10; case .zigzag: 20; case .heavy: 50 } }
        var health: Int { self == .heavy ? 3 : 1 }
    }

    enum PowerKind: CaseIterable { case doubleShot, shield, life }

    struct Enemy {
        var kind: EnemyKind
        var position: CGPoint
        var baseX: CGFloat
        var age: Double = 0
        var health: Int
        var nextShot: Double
    }

    struct Bullet { var position: CGPoint; var velocity: CGVector }
    struct PowerUp { var kind: PowerKind; var position: CGPoint }
    struct Explosion { var position: CGPoint; var age: Double = 0; var size: CGFloat }
    struct Star { var position: CGPoint; var speed: CGFloat }

    /// Everything that moves, in one value so each frame is a single update for SwiftUI.
    struct World {
        var player = CGPoint(x: AirshipGame.field.width / 2, y: AirshipGame.field.height - 40)
        var bullets: [Bullet] = []
        var enemyBullets: [Bullet] = []
        var enemies: [Enemy] = []
        var powerUps: [PowerUp] = []
        var explosions: [Explosion] = []
        var stars: [Star] = []
        var score = 0
        var lives = 3
        var wave = 0
        var time: Double = 0
        var invulnerableUntil: Double = 0
        var doubleShotUntil: Double = 0
        var hasShield = false
        var nextShot: Double = 0
        var spawnQueue: [EnemyKind] = []
        var nextSpawn: Double = 0
        var waveBanner: Double = -10   // time the current wave started (for the "Wave N" banner)
        var escapedThisWave = 0        // enemies that flew off the bottom this wave
        var perfectBanner: Double = -10 // time of the last "Perfect wave!" bonus
    }

    static let field = CGSize(width: 340, height: 408)
    static let bestKey = "airship.best"
    private static let playerSpeed: CGFloat = 230
    private static let playerRadius: CGFloat = 11

    private(set) var state: State = .ready
    private(set) var world = World()
    private(set) var best = BestScore.get(AirshipGame.bestKey)
    private(set) var isNewBest = false

    // Input
    @ObservationIgnored private var held: Set<UInt16> = []
    @ObservationIgnored private var firing = false
    @ObservationIgnored private var mouseTarget: CGPoint?
    @ObservationIgnored private var mouseFiring = false
    @ObservationIgnored private var lastTick: ContinuousClock.Instant?
    @ObservationIgnored private var loop: GameLoop!

    init() {
        loop = GameLoop(interval: .milliseconds(16)) { [weak self] in self?.tick() }
        reset()
    }

    // MARK: GameSession

    var scoreText: String { "\(world.score.formatted()) · best \(best.formatted())" }
    var hint: String { "←→↑↓ or WASD fly · hold Space to fire · or use the mouse · P pause" }
    var showsPauseButton: Bool { true }
    var isRunning: Bool { state == .running }

    func pause() {
        guard state == .running else { return }
        state = .paused
        loop.stop()
        releaseInput()
    }

    func togglePause() { state == .running ? pause() : start() }

    private static let moveKeys: Set<UInt16> = [Key.left, Key.right, Key.up, Key.down, Key.a, Key.d, Key.w, Key.s]

    func handleKey(_ event: NSEvent) -> Bool {
        if Self.moveKeys.contains(event.keyCode) {
            held.insert(event.keyCode)
            mouseTarget = nil // keyboard takes over from the mouse
            if state == .ready || state == .paused { start() }
            return true
        }
        switch event.keyCode {
        case Key.space:
            firing = true
            if state != .running, !event.isARepeat { start() }
            return true
        case Key.enter, Key.keypadEnter:
            if state != .running { start() }
            return true
        default:
            break
        }
        switch Key.letter(event) {
        case "p": togglePause(); return true
        case "r": reset(); return true
        default: return false
        }
    }

    func handleKeyUp(_ event: NSEvent) -> Bool {
        if Self.moveKeys.contains(event.keyCode) { held.remove(event.keyCode); return true }
        if event.keyCode == Key.space { firing = false; return true }
        return false
    }

    func makeView() -> AnyView { AnyView(AirshipView(game: self)) }

    // MARK: Mouse

    /// The plane follows the mouse (both directions) until a movement key is pressed.
    func mouseMoved(to point: CGPoint?) { mouseTarget = point }
    func setMouseFiring(_ on: Bool) {
        mouseFiring = on
        if on, state != .running { start() }
    }

    // MARK: Lifecycle

    func start() {
        guard state != .running else { return }
        if state == .over { reset() }
        state = .running
        lastTick = nil
        loop.start()
    }

    func reset() {
        loop.stop()
        releaseInput()
        var fresh = World()
        fresh.stars = (0..<28).map { _ in
            Star(position: CGPoint(x: .random(in: 0...Self.field.width), y: .random(in: 0...Self.field.height)),
                 speed: .random(in: 20...70))
        }
        world = fresh
        isNewBest = false
        state = .ready
    }

    private func releaseInput() {
        held = []
        firing = false
        mouseFiring = false
    }

    private func endGame() {
        state = .over
        loop.stop()
        releaseInput()
        if world.score > best {
            best = world.score
            isNewBest = true
            BestScore.set(best, for: Self.bestKey)
        }
    }

    // MARK: Simulation

    private func tick() {
        let now = ContinuousClock.now
        let elapsed = lastTick?.duration(to: now) ?? .milliseconds(16)
        lastTick = now
        // Seconds since the last frame, capped so a hiccup can't teleport things.
        let dt = min(0.05, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        var w = world
        update(&w, dt: dt)
        world = w
        if w.lives <= 0 { endGame() }
    }

    private func update(_ w: inout World, dt: Double) {
        w.time += dt
        let f = Self.field

        // Background
        for i in w.stars.indices {
            w.stars[i].position.y += w.stars[i].speed * dt
            if w.stars[i].position.y > f.height { w.stars[i].position = CGPoint(x: .random(in: 0...f.width), y: 0) }
        }

        // Player movement
        var dx: CGFloat = 0, dy: CGFloat = 0
        if held.contains(Key.left) || held.contains(Key.a) { dx -= 1 }
        if held.contains(Key.right) || held.contains(Key.d) { dx += 1 }
        if held.contains(Key.up) || held.contains(Key.w) { dy -= 1 }
        if held.contains(Key.down) || held.contains(Key.s) { dy += 1 }
        if let target = mouseTarget, dx == 0, dy == 0 {
            // Ease toward the pointer: full speed when far, slowing as it arrives.
            let gapX = target.x - w.player.x, gapY = target.y - w.player.y
            dx = abs(gapX) < 2 ? 0 : max(-1, min(1, gapX / 20))
            dy = abs(gapY) < 2 ? 0 : max(-1, min(1, gapY / 20))
        }
        w.player.x = min(max(w.player.x + dx * Self.playerSpeed * dt, 14), f.width - 14)
        w.player.y = min(max(w.player.y + dy * Self.playerSpeed * dt, f.height * 0.5), f.height - 18)

        // Shooting
        if (firing || mouseFiring), w.time >= w.nextShot {
            let double = w.time < w.doubleShotUntil
            let nose = CGPoint(x: w.player.x, y: w.player.y - 14)
            for offset: CGFloat in double ? [-6, 6] : [0] {
                w.bullets.append(Bullet(position: CGPoint(x: nose.x + offset, y: nose.y), velocity: CGVector(dx: 0, dy: -520)))
            }
            w.nextShot = w.time + (double ? 0.16 : 0.2)
        }
        move(&w.bullets, dt: dt)
        move(&w.enemyBullets, dt: dt)

        // Waves
        if w.enemies.isEmpty && w.spawnQueue.isEmpty {
            // Bonus only for a perfect wave: every enemy shot down, none escaped.
            if w.wave > 0 && w.escapedThisWave == 0 {
                w.score += 100 * w.wave
                w.perfectBanner = w.time
            }
            w.wave += 1
            w.waveBanner = w.time
            w.escapedThisWave = 0
            w.spawnQueue = Self.waveEnemies(w.wave)
            w.nextSpawn = w.time + 1.2
        }
        if !w.spawnQueue.isEmpty, w.time >= w.nextSpawn {
            let kind = w.spawnQueue.removeFirst()
            let x = CGFloat.random(in: 30...(f.width - 30))
            w.enemies.append(Enemy(kind: kind, position: CGPoint(x: x, y: -20), baseX: x, health: kind.health,
                                   nextShot: w.time + .random(in: 1...2)))
            w.nextSpawn = w.time + max(0.25, 0.55 - Double(w.wave) * 0.02)
        }

        // Enemies
        let speedUp = CGFloat(min(w.wave, 12)) * 5
        for i in w.enemies.indices {
            w.enemies[i].age += dt
            switch w.enemies[i].kind {
            case .drone:
                w.enemies[i].position.y += (60 + speedUp) * dt
            case .zigzag:
                w.enemies[i].position.y += (70 + speedUp) * dt
                w.enemies[i].position.x = w.enemies[i].baseX + sin(w.enemies[i].age * 2.6) * 42
            case .heavy:
                w.enemies[i].position.y += (35 + speedUp * 0.5) * dt
                if w.time >= w.enemies[i].nextShot, w.enemies[i].position.y > 0 {
                    let from = w.enemies[i].position
                    let angle = atan2(w.player.y - from.y, w.player.x - from.x)
                    w.enemyBullets.append(Bullet(position: from, velocity: CGVector(dx: cos(angle) * 170, dy: sin(angle) * 170)))
                    w.enemies[i].nextShot = w.time + .random(in: 1.4...2.4)
                }
            }
        }
        let before = w.enemies.count
        w.enemies.removeAll { $0.position.y > f.height + 30 }
        w.escapedThisWave += before - w.enemies.count

        // Hits on enemies
        var remainingBullets: [Bullet] = []
        for bullet in w.bullets {
            if let e = w.enemies.firstIndex(where: { distance($0.position, bullet.position) < $0.kind.radius + 3 }) {
                w.enemies[e].health -= 1
                if w.enemies[e].health <= 0 {
                    let dead = w.enemies.remove(at: e)
                    w.score += dead.kind.points
                    w.explosions.append(Explosion(position: dead.position, size: dead.kind.radius * 2.2))
                    if Double.random(in: 0...1) < (dead.kind == .heavy ? 0.35 : 0.07) {
                        let kind: PowerKind = Double.random(in: 0...1) < 0.15 ? .life : (Bool.random() ? .doubleShot : .shield)
                        w.powerUps.append(PowerUp(kind: kind, position: dead.position))
                    }
                }
            } else {
                remainingBullets.append(bullet)
            }
        }
        w.bullets = remainingBullets

        // Power-ups
        for i in w.powerUps.indices { w.powerUps[i].position.y += 70 * dt }
        w.powerUps.removeAll { powerUp in
            guard distance(powerUp.position, w.player) < 20 else { return powerUp.position.y > f.height + 20 }
            switch powerUp.kind {
            case .doubleShot: w.doubleShotUntil = w.time + 8
            case .shield: w.hasShield = true
            case .life: w.lives = min(w.lives + 1, 5)
            }
            return true
        }

        // Hits on the player
        let hitByBullet = w.enemyBullets.firstIndex { distance($0.position, w.player) < Self.playerRadius + 3 }
        let hitByEnemy = w.enemies.firstIndex { distance($0.position, w.player) < Self.playerRadius + $0.kind.radius - 2 }
        if (hitByBullet != nil || hitByEnemy != nil), w.time >= w.invulnerableUntil {
            if let hitByBullet { w.enemyBullets.remove(at: hitByBullet) }
            if let hitByEnemy {
                let e = w.enemies.remove(at: hitByEnemy)
                w.explosions.append(Explosion(position: e.position, size: e.kind.radius * 2.2))
            }
            if w.hasShield {
                w.hasShield = false
                w.invulnerableUntil = w.time + 1
            } else {
                w.lives -= 1
                w.invulnerableUntil = w.time + 1.5
                w.explosions.append(Explosion(position: w.player, size: 30))
            }
        }

        // Explosions fade out
        for i in w.explosions.indices { w.explosions[i].age += dt }
        w.explosions.removeAll { $0.age > 0.4 }
    }

    private func move(_ bullets: inout [Bullet], dt: Double) {
        for i in bullets.indices {
            bullets[i].position.x += bullets[i].velocity.dx * dt
            bullets[i].position.y += bullets[i].velocity.dy * dt
        }
        let f = Self.field
        bullets.removeAll { $0.position.y < -10 || $0.position.y > f.height + 10 || $0.position.x < -10 || $0.position.x > f.width + 10 }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Waves get bigger and mix in tougher enemies as you go.
    static func waveEnemies(_ wave: Int) -> [EnemyKind] {
        let count = min(6 + wave * 2, 26)
        return (0..<count).map { _ in
            let r = Double.random(in: 0...1)
            if wave >= 3, r < min(0.1 + Double(wave) * 0.02, 0.3) { return .heavy }
            if wave >= 2, r < 0.55 { return .zigzag }
            return .drone
        }
    }
}
