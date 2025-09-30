//
//  VirtualSticks.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
// Two lightweight SwiftUI controls: a left "move" stick and a right "look" pad.
//

import SwiftUI
import simd

// MARK: Move stick (returns normalised vec2: [-1,1]x[-1,1])

struct MoveStickView: View {
    var onChange: (SIMD2<Float>) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isActive = false

    private let radius: CGFloat = 54

    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial).frame(width: radius*2, height: radius*2)
            Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1.0)
                .frame(width: radius*2, height: radius*2)
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 32, height: 32)
                .offset(dragOffset.clamped(to: radius))
        }
        .contentShape(Circle().inset(by: -12))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    isActive = true
                    dragOffset = v.translation.clamped(to: radius)
                    let nx = Float(dragOffset.width / radius)
                    let ny = Float(dragOffset.height / radius)
                    onChange(SIMD2<Float>(nx, -ny))
                }
                .onEnded { _ in
                    isActive = false
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
        let len = max(1, sqrt(v.dx*v.dx + v.dy*v.dy))
        if len <= r { return self }
        let f = r/len
        return CGSize(width: v.dx*f, height: v.dy*f)
    }
}

// MARK: Look pad (returns raw pixel delta per event)

struct LookPadView: View {
    var onDelta: (CGPoint) -> Void

    @State private var lastPoint: CGPoint?
    private let size = CGSize(width: 160, height: 160)

    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.25), lineWidth: 1))
            .frame(width: size.width, height: size.height)
            .contentShape(RoundedRectangle(cornerRadius: 18).inset(by: -12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if let last = lastPoint {
                            let dx = v.location.x - last.x
                            let dy = v.location.y - last.y
                            onDelta(CGPoint(x: dx, y: dy))
                        }
                        lastPoint = v.location
                    }
                    .onEnded { _ in lastPoint = nil }
            )
            .opacity(0.92)
            .accessibilityHidden(true)
    }
}
