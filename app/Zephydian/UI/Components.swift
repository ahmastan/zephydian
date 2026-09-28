import SwiftUI

/// A titled, rounded group of rows, like macOS System Settings.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous).fill(Tokens.fill))
        }
    }
}

/// One label + control row inside a SettingsSection.
struct SettingsRow<Control: View>: View {
    let label: String
    var isLast = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(label).font(.system(size: 13))
                Spacer(minLength: 0)
                control
            }
            .frame(minHeight: 38)
            .padding(.vertical, 4)
            if !isLast { Divider() }
        }
    }
}

/// A slider for a millisecond value, with its value shown next to it.
struct MillisecondSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Double>
    let step: Double
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            // Apple's own slider (on macOS 26+ its knob is the same Liquid Glass capsule as the toggles).
            // It slides smoothly and the value snaps to `step`, so no tick marks are drawn.
            Slider(
                value: Binding(get: { Double(value) }, set: { value = Int(($0 / step).rounded() * step) }),
                in: range
            )
            .frame(width: 120)
            .accessibilityLabel(label)
            Text("\(value) ms")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

/// A miniature screen with a button in each corner.
struct CornerPicker: View {
    @Binding var corner: Corner
    var width: CGFloat = 132
    var height: CGFloat = 84
    var dot: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.white.opacity(colorScheme == .dark ? 0.12 : 0.4)).frame(height: 8)
            ForEach(Corner.allCases) { c in
                Button { corner = c } label: {
                    dotView(selected: corner == c)
                        .frame(width: dot, height: dot)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(c.name)
                .accessibilityLabel(c.name)
                .accessibilityAddTraits(corner == c ? .isSelected : [])
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: Alignment(horizontal: c.isLeft ? .leading : .trailing, vertical: c.isTop ? .top : .bottom))
                .padding(EdgeInsets(top: c.isTop ? 13 : 6, leading: 6, bottom: 6, trailing: 6))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Corner")
    }

    /// The selected corner is accent-tinted glass in Liquid Glass mode (solid accent in Frosted).
    @ViewBuilder private func dotView(selected: Bool) -> some View {
        if selected, settings.usesGlass {
            Circle().fill(.clear)
                .glassSurface(in: Circle(), tint: settings.accent.color, fallback: .tint)
        } else {
            Circle()
                .fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(colorScheme == .dark ? 0.2 : 0.6)))
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 1))
        }
    }

    private var wallpaper: [Color] {
        colorScheme == .dark
            ? [Color(red: 0.07, green: 0.19, blue: 0.37), Color(red: 0.15, green: 0.09, blue: 0.37), Color(red: 0.29, green: 0.12, blue: 0.32)]
            : [Color(red: 0.66, green: 0.85, blue: 1.0), Color(red: 0.91, green: 0.84, blue: 1.0), Color(red: 1.0, green: 0.84, blue: 0.92)]
    }
}

/// Orange warning shown when macOS Hot Corners uses the same corner.
struct HotCornerWarning: View {
    let corner: Corner

    var body: some View {
        if HotCorners.hasSystemAction(at: corner) {
            Label("macOS Hot Corners also uses this corner. Pick another one here, or change it in System Settings → Desktop & Dock → Hot Corners.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
