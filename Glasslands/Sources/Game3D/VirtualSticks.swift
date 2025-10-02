//
//  VirtualSticks.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
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
                    // x = strafe, y = forward (thumb up = forward)
                    onChange(SIMD2<Float>(nx, -ny))
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

// MARK: - Look pad (swipe-to-look: sends incremental deltas in UIKit points)
struct LookPadView: View {
    // x > 0 = swipe right (turn right), y uses raw UIKit sign so thumb up (dy < 0) looks UP.
    var onDelta: (SIMD2<Float>) -> Void

    @State private var lastLocation: CGPoint?
    private let size = CGSize(width: 160, height: 160)

    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .frame(width: size.width, height: size.height)
            .contentShape(RoundedRectangle(cornerRadius: 18).inset(by: -12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if let last = lastLocation {
                            let dx = Float(v.location.x - last.x)
                            let dy = Float(v.location.y - last.y)
                            // Use raw dy here so engine’s mapping yields: thumb up => look up.
                            onDelta(SIMD2<Float>(dx, dy))
                        }
                        lastLocation = v.location
                    }
                    .onEnded { _ in
                        lastLocation = nil
                    }
            )
            .opacity(0.92)
            .accessibilityHidden(true)
    }
}
