import SwiftUI

public func tierColor(_ tier: Tier, mode: SpoolMode = .paper) -> Color {
    let p = SpoolTokens.palette(for: mode)
    switch tier {
    case .S: return p.tierS
    case .A: return p.tierA
    case .B: return p.tierB
    case .C: return p.tierC
    case .D: return p.tierD
    }
}
