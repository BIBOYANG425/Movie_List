import Foundation

/// Pure port of `services/spoolPrompts.ts`.
public enum SpoolPrompts {

    private static let genrePromptTiers: Set<Tier> = [.S, .A, .B]

    public static func getComparisonPrompt(
        tier: Tier, genreA: String, genreB: String, phase: EnginePhase
    ) -> String {
        let tierPrompt = SpoolConstants.tierComparisonPrompts[tier] ?? ""

        if phase == .crossGenre { return tierPrompt }

        if genrePromptTiers.contains(tier),
           genreA == genreB,
           let genrePrompt = SpoolConstants.genreComparisonPrompts[genreA] {
            return genrePrompt
        }
        return tierPrompt
    }
}
