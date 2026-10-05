import SwiftUI

// Controls shared by the panel's short Settings tab and the Settings window.
// `glass` puts the Liquid Glass selection bubble behind the chosen option: the panel's controls
// are a floating control layer, while the window's rows are content and keep a plain selection.

/// Springy slide for the selection bubbles (a quick fade with Reduce Motion).
private func selectionAnimation(_ reduceMotion: Bool) -> Animation {
    reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.78)
}

/// The glass bubble behind a selected option. It's a background, so it slides between options and never covers them.
private struct SelectionBubble<S: InsettableShape>: View {
    let shape: S
    let namespace: Namespace.ID

    var body: some View {
        shape.fill(.clear)
            .glassSurface(in: shape, interactive: true)
            .matchedGeometryEffect(id: "bubble-\(S.self)", in: namespace)
    }
}

/// One dot per accent theme. System's dot is a rainbow ring around macOS's current accent.
struct AccentSwatches: View {
    var glass: Bool
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AccentTheme.allCases) { theme in
                let selected = settings.accent == theme
                // System's swatch shows macOS's current accent (redrawn when it changes).
                let swatchColor = theme == .system ? Color(nsColor: theme.nsColor) : theme.color
                Button { settings.accent = theme } label: {
                    swatch(theme, color: swatchColor)
                        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay {
                            // Without glass: a ring in the swatch's color. With glass: a bubble behind it.
                            if !glass {
                                Circle().strokeBorder(selected ? swatchColor : .clear, lineWidth: 2)
                            }
                        }
                        .background { if glass && selected { SelectionBubble(shape: Circle(), namespace: namespace) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(theme.name)
                .accessibilityLabel(theme.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(selectionAnimation(reduceMotion), value: settings.accent)
        .id(settings.systemAccentRevision)   // redraw System's swatch when macOS's accent changes
    }

    /// A plain color dot, or for System a rainbow ring (like macOS's Multicolor swatch) around macOS's accent.
    @ViewBuilder private func swatch(_ theme: AccentTheme, color: Color) -> some View {
        if theme == .system {
            Circle()
                .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red], center: .center))
                .overlay(Circle().fill(color).padding(4))
        } else {
            Circle().fill(color)
        }
    }
}

/// The menu bar icon choices, side by side.
struct MenuBarIconPicker: View {
    var glass: Bool
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarIcon.allCases) { icon in
                let selected = settings.menuBarIcon == icon
                Button { settings.menuBarIcon = icon } label: {
                    icon.swiftUIImage
                        .frame(width: 15, height: 15)
                        .font(.system(size: 13))
                        // Slightly narrower in the Small panel, so the label stays on one line.
                        .frame(width: glass && settings.panelSize == .small ? 23 : 26, height: 24)
                        .foregroundStyle(iconStyle(selected: selected))
                        .background {
                            if glass {
                                if selected { SelectionBubble(shape: Capsule(), namespace: namespace) }
                            } else {
                                RoundedRectangle(cornerRadius: 6).fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(icon.title)
                .accessibilityLabel(icon.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(selectionAnimation(reduceMotion), value: settings.menuBarIcon)
    }

    private func iconStyle(selected: Bool) -> AnyShapeStyle {
        guard selected else { return AnyShapeStyle(.secondary) }
        return glass ? AnyShapeStyle(.tint) : AnyShapeStyle(.white)
    }
}

/// Which display's corner to watch: a menu when there's more than one display.
struct DisplayPicker: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let others = NSScreen.screens.dropFirst().map(\.localizedName)
        if others.isEmpty {
            Text("Main display").foregroundStyle(.secondary)
        } else {
            Picker("Display", selection: $settings.displayName) {
                Text("Main display").tag(String?.none)
                ForEach(others, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .labelsHidden().fixedSize()
        }
    }
}

/// "Allowed", or a button to allow (or repair) a permission.
struct PermissionControl: View {
    let permission: Permission

    var body: some View {
        let permissions = Permissions.shared
        if permissions.isGranted(permission) {
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        } else if permissions.looksStuck(permission) {
            Button(permissions.repairing == permission ? "Repairing…" : "Repair") { permissions.repair(permission) }
                .disabled(permissions.repairing != nil)
                .help("macOS still lists Zephydian, but for an earlier version. This clears that entry and asks again.")
        } else {
            Button("Allow…") { permissions.request(permission) }
        }
    }
}

extension PackManager {
    /// "Last checked: today, 14:02", or what went wrong with the last check.
    var statusLine: String {
        if installed.isEmpty { return "No packs installed yet" }
        switch catalogState {
        case .loading: return "Checking…"
        case .offline: return "You're offline"
        case .failed: return "Couldn't check. Try again later."
        default:
            guard let date = lastChecked else { return "Not checked yet" }
            return "Last checked: \(date.formatted(.relative(presentation: .named)))"
        }
    }
}
