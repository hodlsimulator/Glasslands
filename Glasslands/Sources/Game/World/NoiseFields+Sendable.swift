//
//  NoiseFields+Sendable.swift
//  Glasslands
//
//  Created by . . on 10/2/25.
//
//  We use NoiseFields inside background tasks. GKNoise is effectively thread-safe
//  for reads; mark this as @unchecked Sendable so Swift 6 is happy.
//

extension NoiseFields: @unchecked Sendable {}
