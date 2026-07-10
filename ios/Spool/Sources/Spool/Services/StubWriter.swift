import Foundation

/// Stub write orchestration — the iOS mirror of web `createStub` +
/// `insertStubOrUpdateOnConflict` as fixed in PR #30:
///
///  1. INSERT with explicit user-local watched_date, no palette field.
///  2. On unique violation (23505): UPDATE only the refresh subset
///     (title/poster_path/tier/template_id/updated_at) keyed on
///     (user_id, media_type, tmdb_id) — preserving watched_date,
///     palette, mood_tags, stub_line.
///  3. Either way, kick an unstructured palette-refresh task (fetch
///     poster → PosterPalette → UPDATE palette only). Extraction failure
///     leaves the palette untouched.
///
/// Fire-and-forget: nothing here throws to the caller; a stub failure
/// must never fail a rank save. Contract source of truth:
/// docs/contracts/shared-payloads.md.
///
/// C5-iOS Task 5: `writeStub` is now MEDIA-AWARE. The `media_type` comes from
/// `StubWriteContract.stubMediaType(for:)`: `.movie` → `"movie"`, `.tv` →
/// `"tv_season"`, `.book` → NO stub (the `movie_stubs` CHECK allows only
/// movie|tv_season, and web's book ceremony writes no stub). The conflict-UPDATE
/// + palette `.eq("media_type", …)` filters use the same resolved value.
///
/// Header last reviewed: 2026-07-10
public enum StubWriter {

    /// Write (or refresh on conflict) the stub for a just-ranked item.
    /// `media` selects the stub `media_type` via `StubWriteContract.stubMediaType`:
    ///  - `.movie` → a `"movie"` stub (unchanged);
    ///  - `.tv`    → a `"tv_season"` stub (web `createStub({mediaType:'tv_season'})`);
    ///  - `.book`  → NO stub at all (early return) — the `movie_stubs` CHECK only
    ///    allows `movie|tv_season`, and web's book path never calls `createStub`.
    /// The conflict-UPDATE and palette-refresh `.eq("media_type", …)` filters use
    /// the SAME resolved value so a tv re-rank refreshes its tv_season stub, not a
    /// phantom movie one. Fire-and-forget: nothing here throws to the caller.
    public static func writeStub(movie: Movie, tier: Tier, media: RankMedia = .movie) async {
        // Book path writes no stub. Resolve first so the whole method is skipped
        // (no client fetch, no palette task) for a media with no stub table row.
        guard let mediaType = StubWriteContract.stubMediaType(for: media) else { return }
        guard let client = SpoolClient.shared,
              let userID = await SpoolClient.currentUserID() else { return }

        // Web parity: JS dates are gregorian regardless of device locale.
        // A device set to a Buddhist/Japanese calendar would otherwise
        // produce e.g. "2569-07-06" via Calendar.current.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let insert = StubWriteContract.insertPayload(
            userID: userID, movie: movie, tier: tier, mediaType: mediaType, calendar: gregorian)
        do {
            try await client.from("movie_stubs").insert(insert).execute()
        } catch where PostgresErrors.isUniqueViolation(error) {
            let update = StubWriteContract.conflictUpdatePayload(movie: movie, tier: tier)
            do {
                try await client.from("movie_stubs")
                    .update(update)
                    .eq("user_id", value: userID.uuidString)
                    .eq("media_type", value: mediaType)
                    .eq("tmdb_id", value: movie.id)
                    .execute()
            } catch {
                NSLog("[StubWriter] conflict update failed: \(error)")
                return
            }
        } catch {
            NSLog("[StubWriter] insert failed: \(error)")
            return
        }

        // Palette refresh runs detached so the rank-flow finish path never
        // waits on an image download. Mirrors web's unawaited extraction.
        Task.detached(priority: .utility) {
            await refreshPalette(userID: userID, movie: movie, mediaType: mediaType)
        }
    }

    private struct PaletteUpdatePayload: Encodable {
        let palette: [String]
    }

    private static func refreshPalette(userID: UUID, movie: Movie, mediaType: String) async {
        guard let client = SpoolClient.shared,
              let urlString = movie.posterUrl,
              let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return }

        let colors = PosterPalette.extract(from: data)
        guard !colors.isEmpty else { return } // failure leaves palette as-is

        do {
            try await client.from("movie_stubs")
                .update(PaletteUpdatePayload(palette: colors))
                .eq("user_id", value: userID.uuidString)
                .eq("media_type", value: mediaType)
                .eq("tmdb_id", value: movie.id)
                .execute()
        } catch {
            NSLog("[StubWriter] palette update failed: \(error)")
        }
    }
}
