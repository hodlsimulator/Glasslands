//
//  VirtualSticks.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Two lightweight SwiftUI controls: a left "move" stick and a right "look" pad.
//   - Move stick returns a normalised vec2 in [-1, 1]^2.
//   - Look pad is *rate based* (inertial): hold your thumb off‑centre to keep turning.
//

import SwiftUI
import simd

// MARK: - Move stick (returns normalised vec2: [-1,1] x [-1,1])
struct MoveStickView: View {
    var onChange: (SIMD2<Float>) -> Void

    @State private var dragOffset: CGSize = .zero
    private let radius: CGFloat = 54

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.0)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 32, height: 32)
                .offset(dragOffset.clamped(to: radius))
        }
        .contentShape(Circle().inset(by: -12))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragOffset = v.translation.clamped(to: radius)
                    let nx = Float(dragOffset.width / radius)
                    let ny = Float(dragOffset.height / radius)
                    onChange(SIMD2<Float>(nx, -ny))  // x = strafe, y = forward
                }
                .onEnded { _ in
                    dragOffset = .zero
                    onChange(.zero)
                }
        )
        .opacity(0.92)
        .accessibilityHidden(true)
    }
}

private extension CGSize {
    func clamped(to r: CGFloat) -> CGSize {
        let v = CGVector(dx: width, dy: height)
        let len = max(1, sqrt(v.dx * v.dx + v.dy * v.dy))
        if len <= r { return self }
        let f = r / len
        return CGSize(width: v.dx * f, height: v.dy * f)
    }
}

// MARK: - Look pad (returns a *rate* while held)
struct LookPadView: View {
    /// Called continuously with a normalised rate in [-1, 1]^2 (x = yaw, y = pitch).
    var onRate: (SIMD2<Float>) -> Void

    @State private var anchor: CGPoint?
    @State private var offset: CGSize = .zero

    private let size = CGSize(width: 160, height: 160)
    private let radius: CGFloat = 70       // full deflection near the edge
    private let deadzone: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .frame(width: size.width, height: size.height)
            .overlay(
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 28, height: 28)
                    .offset(offset.clamped(to: radius))
            )
            .contentShape(RoundedRectangle(cornerRadius: 18).inset(by: -12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if anchor == nil { anchor = v.startLocation }
                        guard let anchor else { return }
                        let dx = v.location.x - anchor.x
                        let dy = v.location.y - anchor.y
                        offset = CGSize(width: dx, height: dy)

                        var nx = CGFloat(dx) / radius
                        var ny = CGFloat(dy) / radius

                        // Deadzone (no jitter around centre)
                        if abs(nx) < deadzone / radius { nx = 0 }
                        if abs(ny) < deadzone / radius { ny = 0 }

                        nx = max(-1, min(1, nx))
                        ny = max(-1, min(1, ny))

                        // Right swipe → look right (positive yaw rate).
                        onRate(SIMD2<Float>(Float(nx), Float(-ny)))
                    }
                    .onEnded { _ in
                        anchor = nil
                        offset = .zero
                        onRate(.zero)
                    }
            )
            .opacity(0.92)
            .accessibilityHidden(true)
    }
}
