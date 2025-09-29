//
//  GlasslandsApp.swift
//  Glasslands
//
//  Created by . . on 9/29/25.
//

import SwiftUI

// This shim removes the duplicate @main to fix "Invalid redeclaration of 'GlasslandsApp'".
struct _LegacyAppShim_Previews: PreviewProvider {
    static var previews: some View { Text("Glasslands") }
}
