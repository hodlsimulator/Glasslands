//
//  Signposts.swift
//  Glasslands
//
//  Created by . . on 10/2/25.
//

import Foundation
import os.signpost

enum Signposts {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.conornolan.Glasslands",
        category: .pointsOfInterest
    )

    @inline(__always) static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    @inline(__always) static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    @inline(__always) static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}
