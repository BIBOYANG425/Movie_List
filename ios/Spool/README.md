# Spool — iOS SwiftUI

Native iOS port of the Spool design (see `/tmp/spool_design/spool/project/Spool Hi-Fi.html` or the web app in the parent repo). This is a **Swift Package** containing the full UI — screens, components, theme tokens, fixture data — with no Supabase wiring yet.

## Run it

Open `Package.swift` in Xcode 15+. SwiftUI Previews will render every screen. To run on a device or simulator, create a thin App target that imports `Spool`:

```swift
import SwiftUI
import Spool

@main
struct SpoolApp: App {
    var body: some Scene {
        WindowGroup {
            SpoolAppRoot()
        }
    }
}
```

## Fonts

The design calls for **Gloock** (serif), **Kalam** (hand), **Caveat** (script), **DM Mono** (monospace). iOS doesn't ship these. To match pixel-for-pixel, download the `.ttf` files from Google Fonts and add them to your App target's bundle with `UIAppFonts` entries in `Info.plist`. Without them, the theme falls back to system fonts (New York for serif, Chalkboard SE for hand/script, SF Mono for mono) — the feel holds, but the letterforms differ.

## Structure

```
Sources/Spool/
├── Theme/          SpoolTokens, SpoolFonts, tierColor
├── Models/         Tier, Movie, Friend, Stub, etc.
├── Data/           SpoolData fixtures (mirrors the JSX design)
├── Components/     PosterBlock, AdmitStub, TierStamp, Tape, Grain, pills, nav
├── Screens/        Feed, Stubs, Ranking (5 steps), Friends, Twin, Profile
└── App/            SpoolAppRoot — navigation + state
```

Ported 1:1 from the `hifi/*.jsx` files. File names map: `feed.jsx` → `FeedScreen.swift`, `ranking.jsx` → `RankEntry/Tier/H2H/Ceremony/Printed.swift`, etc.

## Palettes

- `paper` (default) — cream `#F2ECDC`, ink `#141414`, tomato `#CE3B1F`
- `dark` — warm black `#0F0D0B`, bone `#F0E6D0`, marquee amber `#F2B233`

Toggle via `SpoolTheme.mode` (environment).

## From fixtures to Supabase

Every screen reads from `SpoolData` (fixture). When you're ready to wire Supabase, replace the fixture calls in each screen's `@State` with `supabase-swift` repository calls. The `docs/iOS_PORT_REVIEW.md` file at the repo root has the full service → table mapping.
