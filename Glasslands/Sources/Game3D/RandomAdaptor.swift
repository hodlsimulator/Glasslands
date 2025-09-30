//
//  RandomAdaptor.swift
//  Glasslands
//
//  Created by . . on 9/30/25.
//
//  Adapts a GameplayKit GKRandomSource to Swift's RandomNumberGenerator,
//  so you can use Double.random(in:using:), shuffle(using:), etc., with a seed.
//

import Foundation
import GameplayKit

struct RandomAdaptor: RandomNumberGenerator {
    private var src: GKRandomSource

    init(_ source: GKRandomSource) {
        self.src = source
    }

    mutating func next() -> UInt64 {
        // Combine two 32-bit samples into one 64-bit value.
        // GKRandomSource.nextInt() yields a uniform Int in the Int32 range.
        let hi = UInt64(UInt32(bitPattern: Int32(src.nextInt())))
        let lo = UInt64(UInt32(bitPattern: Int32(src.nextInt())))
        return (hi << 32) | lo
    }
}
