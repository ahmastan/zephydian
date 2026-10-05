// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Modified for Zephydian on 2026-10-05 (from vorssaint/vorssaint-utils, commit 04abae3): trimmed to the scroll-wheel helpers the switcher uses (ScrollWheelEventTraits, ScrollWheelSupport basics).

import Foundation
import CoreGraphics

// (Zephydian: trimmed to the scroll-wheel helpers the switcher uses.)

struct ScrollWheelEventTraits: Equatable {
    let isContinuous: Bool
    let momentumPhase: Int64
    let scrollPhase: Int64
    let scrollCount: Int64
}

/// Tells mouse wheels apart from touch devices, shared by the scroll
/// inverter and smooth scrolling so both features classify events the same
/// way: discrete events are wheels; events flagged continuous are wheels
/// only when they carry no gesture phase at all (how some mouse drivers
/// report their wheels).
enum ScrollWheelSupport {
    /// How long after a gesture-phased event a phaseless continuous event is
    /// still attributed to the same touch device.
    static let touchGestureGraceSeconds: TimeInterval = 1.0

    /// Marks the smooth glide so neither feature handles it twice. Events a
    /// process posts come back through that same process's taps (measured at
    /// every tap location), so without the mark the inverter would turn the
    /// glide around again and cancel the flip smooth scrolling already
    /// applied.
    static let syntheticTag: Int64 = 0x564F5253  // "VORS"
    /// A redirected vertical wheel is not a physical side wheel. The session
    /// tap uses this marker to leave it out of side-wheel shortcut matching.
    static let horizontalRedirectTag: Int64 = 0x564F5248  // "VORH"

    /// Points in one scroll line. The window server measures the fixed-point
    /// delta in lines, so an event that moved forty points reports four;
    /// replaying that number as pixels would travel a tenth of the distance.
    static let pointsPerLine: Double = 10

    /// Called only after wheel classification and the scroll-direction exception
    /// check. Consume the modifier so the receiving app cannot redirect or zoom
    /// the transformed event a second time. Other shortcut combinations keep
    /// their native meaning, as do wheels already supplying a horizontal axis.
    @discardableResult

    /// Movement on the vertical axis only, as a plain mouse wheel sends it.
    static func isVerticalOnly(_ event: CGEvent) -> Bool {
        (event.getIntegerValueField(.scrollWheelEventDeltaAxis1) != 0
            || event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) != 0
            || event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) != 0)
            && event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0
            && event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0
            && event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == 0
    }

    /// Moves a vertical-only event to the horizontal axis, keeping its sign
    /// as Shift does.
    static func moveVerticalToHorizontal(_ event: CGEvent) {
        let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        // Line writes can rederive pixel fields; restore the captured precision
        // only after both line axes have been written.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: line)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: point)
    }

    /// A mouse wheel only turns vertically, so a strip that scrolls only
    /// sideways could not be moved with one. The wheel moves the strip when
    /// nothing around it scrolls down; a list around it keeps the wheel.
    static func wheelMovesStripSideways(stripScrollsHorizontally: Bool, stripScrollsVertically: Bool,
                                        enclosingScrollsVertically: Bool) -> Bool {
        stripScrollsHorizontally && !stripScrollsVertically && !enclosingScrollsVertically
    }



    static func isMouseWheel(_ traits: ScrollWheelEventTraits,
                             secondsSinceLastGesturePhase: TimeInterval?) -> Bool {
        if !traits.isContinuous {
            return true
        }
        guard traits.momentumPhase == 0, traits.scrollPhase == 0 else {
            return false
        }
        // Trackpads/Magic Mouse can emit a phaseless transition event between
        // gesture end and momentum start that still carries the gesture's
        // scrollCount. Mouse wheels that report continuous never emit phases,
        // so only events right after a phased one are treated as touch.
        if traits.scrollCount != 0,
           let elapsed = secondsSinceLastGesturePhase,
           elapsed <= touchGestureGraceSeconds {
            return false
        }
        return true
    }

}

