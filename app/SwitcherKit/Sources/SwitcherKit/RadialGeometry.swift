// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copied into Zephydian on 2026-10-06 from vorssaint/vorssaint-utils, commit 567ba36
// (Services/RadialMenu/RadialMenuSupport.swift: RadialMenuLayout, RadialMenuGeometry;
// UI/RadialMenu/RadialMenuView.swift: RadialWedgeShape). Zephydian's changes: made public for the
// app target, renamed to RadialLayout/RadialGeometry, dropped `panelSize` (the app sizes its own
// panel per wheel size) and added `scaled(_:)`.

import SwiftUI

/// Shared wheel dimensions, points, at the Medium size. The app positions the panel and maps
/// pointer distances with these; the view draws with them.
public enum RadialLayout {
    public static let wheelDiameter: CGFloat = 300
    public static let ringRadius: CGFloat = 112
    public static let chipSize: CGFloat = 52
    public static let hubDiameter: CGFloat = 76
    public static let deadZoneRadius: CGFloat = 40
    /// The pointer must travel this far from where the wheel opened before
    /// slices start highlighting, so a center-of-screen wheel never fires on
    /// whatever direction the pointer already happened to sit in.
    public static let moveActivationDistance: CGFloat = 8

    /// A Medium measurement at another wheel size (Zephydian).
    public static func scaled(_ value: CGFloat, by scale: CGFloat) -> CGFloat { (value * scale).rounded() }
}

/// Pure slice math shared by the wheel view and the pointer tracking. Slice 0
/// sits at 12 o'clock and indices grow clockwise; angles are measured
/// clockwise from the top in radians.
public enum RadialGeometry {
    /// Angle of the vector (dx, dyUp) where dyUp grows toward the top of the
    /// screen, in [0, 2 * pi).
    public static func angle(dx: CGFloat, dyUp: CGFloat) -> CGFloat {
        let raw = atan2(dx, dyUp)
        return raw < 0 ? raw + 2 * .pi : raw
    }

    public static func index(forAngle angle: CGFloat, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        let step = 2 * .pi / CGFloat(itemCount)
        let shifted = (angle + step / 2).truncatingRemainder(dividingBy: 2 * .pi)
        let index = Int(shifted / step)
        return min(max(index, 0), itemCount - 1)
    }

    /// The slice under the pointer, nil inside the dead zone around the hub.
    public static func highlightedIndex(dx: CGFloat, dyUp: CGFloat,
                                        deadZoneRadius: CGFloat, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        let distance = (dx * dx + dyUp * dyUp).squareRoot()
        guard distance >= deadZoneRadius else { return nil }
        return index(forAngle: angle(dx: dx, dyUp: dyUp), itemCount: itemCount)
    }

    /// Unit-circle position of a slice center, dyUp toward the screen top.
    public static func unitPosition(index: Int, itemCount: Int) -> (dx: CGFloat, dyUp: CGFloat) {
        guard itemCount > 0 else { return (0, 1) }
        let theta = 2 * .pi * CGFloat(index) / CGFloat(itemCount)
        return (sin(theta), cos(theta))
    }
}

/// A slice-shaped highlight between the hub and the wheel border.
public struct RadialWedgeShape: Shape {
    public var centerAngle: Double
    public var sliceAngle: Double
    public let innerRadius: CGFloat
    public let outerRadius: CGFloat

    public init(centerAngle: Double, sliceAngle: Double, innerRadius: CGFloat, outerRadius: CGFloat) {
        self.centerAngle = centerAngle
        self.sliceAngle = sliceAngle
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
    }

    /// The angle and the width are what move, so the highlight sweeps to the
    /// slice under the pointer, and re-fits when a submenu holds a different
    /// number of them.
    public var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(centerAngle, sliceAngle) }
        set {
            centerAngle = newValue.first
            sliceAngle = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Screen angles: 0 at +x, growing clockwise (flipped y); our slice
        // angles run clockwise from 12 o'clock, so shift by a quarter turn.
        let start = Angle(radians: centerAngle - sliceAngle / 2 - .pi / 2)
        let end = Angle(radians: centerAngle + sliceAngle / 2 - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: innerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: outerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}
