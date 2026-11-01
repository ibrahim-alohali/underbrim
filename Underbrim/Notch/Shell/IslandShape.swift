//
//  IslandShape.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The notch's outline: upstream's NotchShape with continuous-curvature bottom corners like the
//  hardware's. Closed it's the cutout's size, so it disappears behind it; the frame and both radii
//  animate on one spring, so opening is a single morph.
//

import SwiftUI

struct IslandShape: Shape {
    /// The concave flare into the screen edge at each top corner.
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Floating below the screen's edge (FloatingIsland): no flares, `bottomRadius` at all four corners.
    var floating = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { (topRadius, bottomRadius) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        if floating { return Self.floatingPath(in: rect, radius: bottomRadius) }
        let flare = min(max(0, topRadius), rect.width / 2, rect.height)
        let left = rect.minX + flare, right = rect.maxX - flare
        // Each bottom corner may use the side below the flare and half the bottom.
        let extent = max(0, min(rect.height - flare, (right - left) / 2))
        var path = Path()
        path.move(to: rect.origin)
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + flare), control: CGPoint(x: left, y: rect.minY))
        Self.addCorner(to: &path, at: CGPoint(x: left, y: rect.maxY),
                       from: CGVector(dx: 0, dy: 1), to: CGVector(dx: 1, dy: 0), radius: bottomRadius, extent: extent)
        Self.addCorner(to: &path, at: CGPoint(x: right, y: rect.maxY),
                       from: CGVector(dx: 1, dy: 0), to: CGVector(dx: 0, dy: -1), radius: bottomRadius, extent: extent)
        path.addLine(to: CGPoint(x: right, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }

    /// Each corner may use half the shorter side: closed, a capsule; open, continuous corners.
    static func floatingExtent(_ size: CGSize) -> CGFloat { max(0, min(size.width, size.height) / 2) }

    /// From the top centre, anticlockwise: trim 0.5 is the bottom centre.
    static func floatingPath(in rect: CGRect, radius: CGFloat) -> Path {
        let extent = floatingExtent(rect.size)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        addCorner(to: &path, at: CGPoint(x: rect.minX, y: rect.minY), from: CGVector(dx: -1, dy: 0), to: CGVector(dx: 0, dy: 1),
                  radius: radius, extent: extent)
        addCorner(to: &path, at: CGPoint(x: rect.minX, y: rect.maxY), from: CGVector(dx: 0, dy: 1), to: CGVector(dx: 1, dy: 0),
                  radius: radius, extent: extent)
        addCorner(to: &path, at: CGPoint(x: rect.maxX, y: rect.maxY), from: CGVector(dx: 1, dy: 0), to: CGVector(dx: 0, dy: -1),
                  radius: radius, extent: extent)
        addCorner(to: &path, at: CGPoint(x: rect.maxX, y: rect.minY), from: CGVector(dx: 0, dy: -1), to: CGVector(dx: -1, dy: 0),
                  radius: radius, extent: extent)
        path.closeSubpath()
        return path
    }

    /// A line to, then around, a convex corner with continuous curvature (Figma's squircle at iOS's 60%
    /// smoothing), starting up to 1.6 radii before the corner and smoothing less with less room.
    /// (The equations follow figma-squircle, MIT, (c) 2021 Tien Pham; see THIRD_PARTY_LICENSES.)
    static func addCorner(to path: inout Path, at corner: CGPoint, from incoming: CGVector, to outgoing: CGVector,
                          radius: CGFloat, extent: CGFloat) {
        /// `along`: back from the corner on the incoming side; `inward`: off it.
        func point(_ along: CGFloat, _ inward: CGFloat) -> CGPoint {
            CGPoint(x: corner.x - incoming.dx * along + outgoing.dx * inward,
                    y: corner.y - incoming.dy * along + outgoing.dy * inward)
        }
        let r = max(0, min(radius, extent))
        guard r > 0.01 else { path.addLine(to: corner); return }
        let smoothing = min(0.6, extent / r - 1)
        let p = (1 + smoothing) * r
        let arc = CGFloat.pi / 2 * (1 - smoothing)
        let arcSpan = sin(arc / 2) * r * 2.squareRoot()
        let beta = CGFloat.pi / 4 * smoothing
        let c = r * tan((CGFloat.pi / 2 - arc) / 4) * cos(beta)
        let d = c * tan(beta)
        let b = (p - arcSpan - c - d) / 3
        let a = 2 * b

        path.addLine(to: point(p, 0))
        let arcStart = point(d + arcSpan, d), arcEnd = point(d, d + arcSpan)
        path.addCurve(to: arcStart, control1: point(p - a, 0), control2: point(p - a - b, 0))
        // The arc as one cubic, its handles along the tangents either end.
        let handle = 4 / 3 * tan(arc / 4) * r
        let startTangent = CGVector(dx: incoming.dx * cos(beta) + outgoing.dx * sin(beta),
                                    dy: incoming.dy * cos(beta) + outgoing.dy * sin(beta))
        let endTangent = CGVector(dx: incoming.dx * sin(beta) + outgoing.dx * cos(beta),
                                  dy: incoming.dy * sin(beta) + outgoing.dy * cos(beta))
        path.addCurve(to: arcEnd,
                      control1: CGPoint(x: arcStart.x + startTangent.dx * handle, y: arcStart.y + startTangent.dy * handle),
                      control2: CGPoint(x: arcEnd.x - endTangent.dx * handle, y: arcEnd.y - endTangent.dy * handle))
        path.addCurve(to: point(0, p), control1: point(0, p - a - b), control2: point(0, p - a))
    }
}

#Preview {
    VStack(spacing: 20) {
        IslandShape(topRadius: 4, bottomRadius: 8)
            .frame(width: 185, height: 32)
        IslandShape(topRadius: NotchMetrics.openTopRadius, bottomRadius: NotchMetrics.openBottomRadius)
            .frame(width: 440, height: 160)
        IslandShape(topRadius: 0, bottomRadius: 12, floating: true)
            .frame(width: 185, height: 24)
        IslandShape(topRadius: 0, bottomRadius: NotchMetrics.openBottomRadius, floating: true)
            .frame(width: 440, height: 160)
    }
    .padding()
    .background(.gray)
}
