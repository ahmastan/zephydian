import SwiftUI
import SwitcherKit

/// What the wheel on screen shows. The controller changes it; the view only draws it.
@Observable
final class RadialMenuModel {
    var wheel = RadialWheel()
    var slices: [RadialSlice] = []
    /// Names of the folders opened, for the center's Back.
    var trail: [String] = []
    var lit: Int?
    /// Where the highlight points, in radians, kept unwrapped so stepping from the last slice to
    /// the first is one step on instead of a spin all the way back.
    var wedgeAngle = 0.0
    /// The disc is up (it grows in when the wheel opens).
    var discShown = false
    /// The slices are out (they fly out of the center on opening and in each folder).
    var revealed = false
    /// While a number key is down, each slice shows its key.
    var showNumbers = false
    var scale: CGFloat = 1

    /// The panel's side: the disc plus room for its shadow and for clicks just past its edge.
    var side: CGFloat { (RadialLayout.wheelDiameter * scale * 1.34).rounded() }

    func setLit(_ index: Int?) {
        guard index != lit else { return }
        lit = index
        guard let index, !slices.isEmpty else { return }
        let target = 2 * Double.pi * Double(index) / Double(slices.count)
        // The short way round.
        var delta = (target - wedgeAngle).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        wedgeAngle += delta
    }
}

/// The wheel: a glass disc with one chip per slice, a highlight wedge under the pointed slice,
/// and a center that names the slice (or leads back out of a folder).
struct RadialMenuView: View {
    let model: RadialMenuModel
    /// A click, in points from the center (y up).
    let onClick: (CGFloat, CGFloat) -> Void
    /// The editor's live preview in Settings: a plain disc (no glass on Settings pages), no margin.
    var preview = false

    @State private var radial = RadialSettings.shared
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var s: CGFloat { model.scale }
    private var diameter: CGFloat { RadialLayout.wheelDiameter * s }
    private var color: Color { model.wheel.color.color(accent: settings.accentColor) }
    private var side: CGFloat { preview ? diameter : model.side }

    var body: some View {
        ZStack {
            // Almost invisible, so clicks just past the disc reach the wheel instead of the app below.
            Color.black.opacity(0.001)
            Group {
                disc
                wedge
                ForEach(Array(model.slices.enumerated()), id: \.element.id) { index, slice in
                    chip(slice, index: index)
                }
                hub
            }
            .frame(width: diameter, height: diameter)
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { point in
            onClick(point.x - side / 2, side / 2 - point.y)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.wheel.name) wheel")
    }

    // MARK: Pieces

    @ViewBuilder private var disc: some View {
        if preview {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Circle().strokeBorder(.separator, lineWidth: 1))
                .frame(width: diameter, height: diameter)
        } else {
            liveDisc
        }
    }

    private var liveDisc: some View {
        Circle()
            .fill(.clear)
            .frame(width: diameter, height: diameter)
            .glassSurface(in: Circle(), fallback: .regularMaterial)
            .overlay {
                if !settings.usesGlass {
                    Circle().strokeBorder(colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.1), lineWidth: 0.5)
                }
            }
            .shadow(color: .black.opacity(settings.usesGlass ? 0 : 0.25), radius: 18, y: 8)
            .scaleEffect(model.discShown || reduceMotion ? 1 : 0.82)
            .opacity(model.discShown ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.8), value: model.discShown)
    }

    private var wedge: some View {
        let count = max(model.slices.count, 1)
        let hub = RadialLayout.hubDiameter * s / 2
        return RadialWedgeShape(centerAngle: model.wedgeAngle, sliceAngle: 2 * .pi / Double(count),
                                innerRadius: hub, outerRadius: diameter / 2)
            .fill(RadialGradient(colors: [color.opacity(0.04), color.opacity(radial.highlightOpacity)],
                                 center: .center, startRadius: diameter / 8, endRadius: diameter / 2))
            .opacity(model.lit == nil ? 0 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.85), value: model.wedgeAngle)
            .animation(.easeOut(duration: 0.12), value: model.lit == nil)
            .allowsHitTesting(false)
    }

    private func chip(_ slice: RadialSlice, index: Int) -> some View {
        let count = model.slices.count
        let unit = RadialGeometry.unitPosition(index: index, itemCount: count)
        let radius = RadialLayout.ringRadius * s
        let position = CGSize(width: unit.dx * radius, height: -unit.dyUp * radius)
        let lit = model.lit == index
        let size = RadialLayout.chipSize * s
        let out = model.revealed || reduceMotion
        // The opening sweep takes the same time however many slices there are.
        let delay = 0.17 * Double(index) / Double(max(count, 1))

        return ZStack {
            Circle().fill(lit ? AnyShapeStyle(color) : AnyShapeStyle(.primary.opacity(0.08)))
            icon(slice.icon, lit: lit)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if slice.isFolder {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 13 * s, weight: .semibold))
                    .foregroundStyle(lit ? .white : .secondary)
                    .background(Circle().fill(lit ? color : Color(nsColor: .windowBackgroundColor)).padding(1))
            }
        }
        .overlay(alignment: .top) {
            if model.showNumbers, index < 12 {
                Text(String(Array("1234567890-=")[index]))
                    .font(.system(size: 10 * s, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .offset(y: -12 * s)
            }
        }
        .shadow(color: lit ? color.opacity(0.45) : .clear, radius: 7, y: 3)
        .scaleEffect(out ? (lit && !reduceMotion ? 1.12 : 1) : 0.4)
        .offset(out ? position : .zero)
        .opacity(model.revealed ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.72).delay(model.revealed ? delay : 0),
                   value: model.revealed)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: lit)
        .accessibilityElement()
        .accessibilityLabel(slice.title)
        .accessibilityHint(slice.detail)
        .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private func icon(_ icon: RadialIcon, lit: Bool) -> some View {
        switch icon {
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 36 * s, height: 36 * s)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 20 * s, weight: .medium))
                .foregroundStyle(lit ? .white : .primary)
        }
    }

    private var hub: some View {
        let size = RadialLayout.hubDiameter * s
        return VStack(spacing: 2 * s) {
            if let lit = model.lit, model.slices.indices.contains(lit) {
                let slice = model.slices[lit]
                Text(slice.title)
                    .font(.system(size: 12 * s, weight: .semibold))
                    .lineLimit(2)
                Text(slice.detail)
                    .font(.system(size: 9.5 * s))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let folder = model.trail.last {
                Image(systemName: "chevron.left").font(.system(size: 13 * s, weight: .bold))
                Text(folder).font(.system(size: 12 * s, weight: .semibold)).lineLimit(1)
                Text("Back").font(.system(size: 9.5 * s)).foregroundStyle(.secondary)
            } else {
                Text(model.wheel.name).font(.system(size: 12 * s, weight: .semibold)).lineLimit(2)
                Text("\(model.slices.count) item\(model.slices.count == 1 ? "" : "s")")
                    .font(.system(size: 9.5 * s)).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.8)
        .frame(width: size - 6, height: size)
        .opacity(model.discShown ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: model.lit)
        .allowsHitTesting(false)
    }
}
