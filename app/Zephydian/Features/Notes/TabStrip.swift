import SwiftUI

/// The tabs' coordinate space and gap, for dragging a tab (`NotesView`).
let noteTabSpace = "noteTabs"
let noteTabSpacing: CGFloat = 6

/// Where each tab is in `noteTabSpace`, so a dragged tab knows which tabs it has passed.
struct NoteTabFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The horizontally scrolling row of note tabs.
/// When the tabs don't fit, a slim slider appears underneath (drag it, or click the track to jump).
/// The active tab is always scrolled into view.
struct NoteTabStrip<Content: View>: View {
    let activeID: UUID?
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 15, *) {
            SliderTabStrip(activeID: activeID, content: content)
        } else {
            // macOS 14 lacks the scroll-position APIs the custom slider needs; use the system scroll bar.
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: noteTabSpacing) { content() }.padding(2)
                        .coordinateSpace(name: noteTabSpace)
                }
                .scrollIndicators(.visible)
                .onChange(of: activeID) {
                    guard let activeID else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(activeID) }
                }
            }
        }
    }
}

@available(macOS 15, *)
private struct SliderTabStrip<Content: View>: View {
    let activeID: UUID?
    let content: () -> Content

    @State private var position = ScrollPosition(idType: UUID.self)
    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var dragStartOffset: CGFloat?
    @State private var hovering = false

    private var maxOffset: CGFloat { max(0, contentWidth - viewportWidth) }
    private var overflows: Bool { maxOffset > 1 }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: noteTabSpacing) { content() }
                .padding(2)
                .coordinateSpace(name: noteTabSpace)
                .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        .onScrollGeometryChange(for: [CGFloat].self) { geometry in
            [geometry.contentOffset.x, geometry.contentSize.width, geometry.containerSize.width]
        } action: { _, values in
            offset = values[0]
            contentWidth = values[1]
            viewportWidth = values[2]
        }
        .onChange(of: activeID) {
            guard let activeID else { return }
            withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(id: activeID) }
        }
        // The slider sits in the gap below the tabs, so showing it doesn't shift the layout.
        .overlay(alignment: .bottom) {
            if overflows {
                slider
                    .offset(y: 6)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: overflows)
    }

    private var slider: some View {
        GeometryReader { geometry in
            let track = geometry.size.width
            let thumb = max(28, track * viewportWidth / max(contentWidth, 1))
            let travel = max(track - thumb, 1)
            let thumbX = maxOffset > 0 ? offset / maxOffset * travel : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Tokens.fill)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        // Click the track: center the thumb there.
                        let target = (location.x - thumb / 2) / travel * maxOffset
                        withAnimation(.easeOut(duration: 0.2)) { scroll(to: target) }
                    }
                Capsule()
                    .fill(Color.secondary.opacity(hovering || dragStartOffset != nil ? 0.6 : 0.35))
                    .frame(width: thumb)
                    .offset(x: thumbX)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let start = dragStartOffset ?? offset
                                dragStartOffset = start
                                scroll(to: start + drag.translation.width / travel * maxOffset)
                            }
                            .onEnded { _ in dragStartOffset = nil }
                    )
            }
        }
        .frame(height: hovering || dragStartOffset != nil ? 6 : 4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement()
        .accessibilityLabel("Note tabs scroller")
        .accessibilityValue("\(Int((maxOffset > 0 ? offset / maxOffset : 0) * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = viewportWidth * 0.5
            scroll(to: offset + (direction == .increment ? step : -step))
        }
    }

    private func scroll(to x: CGFloat) {
        position.scrollTo(x: min(max(0, x), maxOffset))
    }
}
