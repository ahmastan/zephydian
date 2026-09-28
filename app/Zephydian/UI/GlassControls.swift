import SwiftUI

// Zephydian's glass building blocks, matched to the panel style:
// - Liquid Glass (macOS 26+): real glass that refracts what's behind it, like Apple's tab bars and switchers.
// - Frosted: the classic macOS look.
// They keep exactly the same size in both styles. (Sliders and toggles are Apple's own controls,
// which already get Apple's Liquid Glass knob on macOS 26+.)
//
// Glass belongs only on the floating control layer (buttons, tab bars, overlays, toasts), never on
// content such as game boards, game tiles or the notes text. Feature code uses the helpers below
// instead of calling `.glassEffect` directly, so the Frosted fallback lives in one place.
// Apple's glass adapts to Reduce Transparency and Increase Contrast by itself; the Frosted fallback
// adds a visible edge when Increase Contrast is on.

extension SettingsStore {
    /// True when Liquid Glass is both chosen and available (macOS 26+).
    var usesGlass: Bool { effectivePanelStyle == .glass }
}

// MARK: - Glass surface

private struct GlassSurface<S: InsettableShape, Fallback: ShapeStyle>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let fallback: Fallback

    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if #available(macOS 26, *), settings.usesGlass {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background(shape.fill(fallback))
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(.primary.opacity(0.35), lineWidth: 1)
                    }
                }
        }
    }
}

extension View {
    /// Puts a floating control or overlay on Liquid Glass (macOS 26+, Liquid Glass style), or on
    /// `fallback` in Frosted mode. Pass `tint` (usually the accent) for calls to action, and
    /// `interactive` for things you click so the glass reacts to the pointer.
    func glassSurface<S: InsettableShape, Fallback: ShapeStyle>(
        in shape: S, tint: Color? = nil, interactive: Bool = false, fallback: Fallback = Tokens.fill
    ) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, fallback: fallback))
    }
}

// MARK: - Glass group

/// Groups neighbouring glass controls so they share one rendering pass and can blend or morph
/// into each other (`GlassEffectContainer` on macOS 26+). In Frosted mode it's a plain container.
/// Only for controls whose glass is applied to the control itself (a glass button with its icon).
/// Never wrap glass used as a background behind other views: the container draws that glass on
/// top of them, covering their text and taking their clicks.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    @Environment(SettingsStore.self) private var settings

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26, *), settings.usesGlass {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Icon buttons

/// A round icon button for headers (back, pause, add…): a glass circle in Liquid Glass mode,
/// a plain icon with a hover circle in Frosted mode. Same size in both.
private struct GlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassIconButton(configuration: configuration)
    }
}

private struct GlassIconButton: View {
    let configuration: ButtonStyleConfiguration

    @Environment(SettingsStore.self) private var settings
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let label = configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(width: Tokens.iconButtonSize, height: Tokens.iconButtonSize)
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)

        if #available(macOS 26, *), settings.usesGlass {
            label
                .foregroundStyle(.primary)
                .glassEffect(.regular.interactive(isEnabled), in: Circle())
        } else {
            label
                .foregroundStyle(.secondary)
                .background(Circle().fill(configuration.isPressed ? Tokens.fillHover : hovering ? Tokens.fill : .clear))
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// Round icon button for the panel's headers. See `GlassIconButtonStyle`.
    func glassIconButtonStyle() -> some View { buttonStyle(GlassIconButtonStyle()) }
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
        // Not in a GlassGroup: a container draws its glass above the labels (covering the text)
        // and lets the interactive bubble swallow clicks meant for the other segments.
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
