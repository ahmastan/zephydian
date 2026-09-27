import SwiftUI

// Zephydian's segmented control and button styles, matched to the panel style:
// - Liquid Glass (macOS 26+): real glass that refracts what's behind it, like Apple's tab bars and switchers.
// - Frosted: the classic macOS look.
// They keep exactly the same size in both styles. (Sliders and toggles are Apple's own controls,
// which already get Apple's Liquid Glass knob on macOS 26+.)

extension SettingsStore {
    /// True when Liquid Glass is both chosen and available (macOS 26+).
    var usesGlass: Bool { effectivePanelStyle == .glass }
}

// MARK: - Segmented control

/// A segmented control with equal-width segments. In Liquid Glass mode the selected segment
/// is a glass "bubble" that slides between options.
struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var height: CGFloat = 30
    var fontSize: CGFloat = 12

    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(track)
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.78), value: selection)
        .accessibilityElement(children: .contain)
    }

    private func segment(_ option: Value) -> some View {
        let isSelected = option == selection
        return Button { selection = option } label: {
            Text(title(option))
                .font(.system(size: fontSize, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: height - 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                selectionShape.matchedGeometryEffect(id: "selection", in: namespace)
            }
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var selectionShape: some View {
        if #available(macOS 26, *), settings.usesGlass {
            // A real Liquid Glass capsule: it lenses and refracts the panel behind it.
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.22) : Color.white)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 1, y: 0.5)
        }
    }

    @ViewBuilder private var track: some View {
        if settings.usesGlass {
            Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tokens.fillHover)
        }
    }
}

// MARK: - Buttons

/// Apple's glass button styles in Liquid Glass mode, classic buttons in Frosted mode.
private struct PanelButtonStyle: ViewModifier {
    @Environment(SettingsStore.self) private var settings

    func body(content: Content) -> some View {
        if #available(macOS 26, *), settings.usesGlass {
            content.buttonStyle(.glass)
        } else {
            content
        }
    }
}

private struct ProminentButtonStyle: ViewModifier {
    @Environment(SettingsStore.self) private var settings

    func body(content: Content) -> some View {
        if #available(macOS 26, *), settings.usesGlass {
            content.buttonStyle(.glassProminent)
        } else {
            content.prominentButtonStyle()
        }
    }
}

extension View {
    /// Default look for ordinary buttons inside the panel.
    func panelButtonStyle() -> some View { modifier(PanelButtonStyle()) }
    /// The main action button (Start, Play again, Done…).
    func prominentButtonStyle() -> some View { modifier(ProminentButtonStyle()) }
}
