import Foundation

/// OpenLibrary book search client — keyless, direct. Mirror of web
/// `services/openLibraryService.ts` (search field list + doc map ~168-186,
/// `normalizeBookGenres` + `SUBJECT_TO_GENRE`, `getBookCoverUrl`, `ol_{workKey}`
/// id mint). Books are SEARCH-ONLY: no suggestion engine, no discover pools, and
/// no typo-retry variants — OpenLibrary tokenizes queries itself, so the cheap
/// TMDB prefix-chop retries would be nonsense here (web parity).
///
/// Unlike the TMDB seams, OpenLibrary is NOT behind the `tmdb-proxy` (that proxy
/// is TMDB-only by design, to inject the TMDB key). OpenLibrary is keyless, so
/// iOS calls it DIRECTLY. There is therefore no api key to strip; the only wire
/// concern is the `User-Agent` header the OL API policy asks for (contact-
/// identifying UA, ~3 req/s). A browser CANNOT set User-Agent, so web omits it;
/// iOS setting it is strictly better API citizenship, not a parity gap.
///
/// Best-effort contract, mirroring web's `try/catch` posture: every failure path
/// (non-2xx HTTP, timeout, transport error, cancellation) swallows to `[]` with a
/// log. Callers already treat empty as "no results". `Task.checkCancellation()`
/// runs before and after the network hop so a debounced/superseded search (the
/// caller-seam cancels the stale `Task`) fires no further work — the service
/// itself is a plain async fetch, with debounce owned by the caller.
///
/// Header last reviewed: 2026-07-10
public enum OpenLibraryService {

    /// 8s request timeout — mirrors web `searchBooks(timeoutMs = 8000)`.
    public static let defaultTimeout: TimeInterval = 8

    /// Contact-identifying User-Agent per OpenLibrary API policy. The URL is the
    /// public repo so OL ops can reach the maintainers if we misbehave.
    public static let userAgent = "Spool-iOS/1.0 (https://github.com/BIBOYANG425/Movie_List)"

    /// Exact web `SEARCH_FIELDS` list (`services/openLibraryService.ts:41-45`),
    /// order-preserving so the comma-joined `fields` param is byte-identical.
    static let searchFields = [
        "key", "title", "author_name", "first_publish_year",
        "number_of_pages_median", "cover_i", "ratings_average",
        "ratings_count", "subject", "isbn",
    ]

    // MARK: - Search

    /// Keyless direct GET `openlibrary.org/search.json` → mapped books.
    ///
    /// Best-effort: any non-2xx / timeout / transport error / cancellation yields
    /// `[]` (web `try/catch` posture). Whitespace-only queries short-circuit to
    /// `[]` without a request (web `if (!query.trim()) return []`).
    public static func searchBooks(
        query: String, timeout: TimeInterval = defaultTimeout
    ) async -> [OpenLibraryBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            // A superseded (debounced) search cancels its Task; bail before we
            // touch the network so a stale keystroke fires no request.
            try Task.checkCancellation()

            let request = buildSearchRequest(query: trimmed, timeout: timeout)
            let (data, response) = try await URLSession.shared.data(for: request)

            // And again after the hop: a search cancelled mid-flight must not
            // return results that would clobber a newer query's output.
            try Task.checkCancellation()

            guard let http = response as? HTTPURLResponse else { return [] }
            guard http.statusCode == 200 else {
                print("Open Library search failed: \(http.statusCode)")
                return []
            }

            let decoded = try JSONDecoder().decode(OLSearchResponse.self, from: data)
            // Filter (title && key) then map — coverless books are KEPT (they map
            // to an empty posterUrl), exactly like web.
            return decoded.docs.compactMap(mapDoc)
        } catch is CancellationError {
            // Debounced/superseded search — silent, expected.
            return []
        } catch {
            print("Open Library search error: \(error)")
            return []
        }
    }

    // MARK: - Request builder

    /// Build the direct OpenLibrary search request. Extracted so the params,
    /// keyless-ness, timeout, and the OL-policy User-Agent header are unit-testable
    /// without a network round-trip.
    ///
    /// Params mirror web `searchBooks`: `q` (already-trimmed query), `limit=10`,
    /// and the comma-joined `fields` list. No api key — OpenLibrary is keyless.
    static func buildSearchRequest(
        query: String, timeout: TimeInterval = defaultTimeout
    ) -> URLRequest {
        var comps = URLComponents(string: "https://openlibrary.org/search.json")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "fields", value: searchFields.joined(separator: ",")),
        ]
        var request = URLRequest(url: comps.url!, timeoutInterval: timeout)
        request.httpMethod = "GET"
        // OL API policy: identify the app + a contact URL. Browsers can't set this;
        // iOS can, and does.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return request
    }

    // MARK: - Doc mapping

    /// Map one decoded search doc → `OpenLibraryBook`, or `nil` to drop it.
    ///
    /// Web filters docs on `(doc.title && doc.key)` BEFORE mapping, so a doc
    /// missing either is dropped (→ nil here). Coverless docs pass the filter and
    /// map to an empty-string posterUrl (they are NOT dropped). Field extraction
    /// mirrors web 1:1: first author (`?? "Unknown"`), stringified year (`?? ""`),
    /// `'M'` cover, `normalizeBookGenres(subject)`, first isbn, and the 0-5 rating
    /// doubled to a 0-10 `globalScore` (present iff the rating is present).
    static func mapDoc(_ doc: OLDoc) -> OpenLibraryBook? {
        guard let title = doc.title, !title.isEmpty,
              let key = doc.key, !key.isEmpty else { return nil }

        let workKey = extractWorkKey(key)
        let rating = doc.ratings_average
        return OpenLibraryBook(
            id: "ol_\(workKey)",
            title: title,
            author: doc.author_name?.first ?? "Unknown",
            year: doc.first_publish_year.map(String.init) ?? "",
            posterUrl: getBookCoverUrl(doc.cover_i, size: "M"),
            genres: normalizeBookGenres(doc.subject ?? []),
            pageCount: doc.number_of_pages_median,
            isbn: doc.isbn?.first,
            olWorkKey: workKey,
            olRatingsAverage: rating,
            globalScore: rating.map { $0 * 2 }
        )
    }

    /// "/works/OL27448W" → "OL27448W" — strip the `/works/` prefix exactly like
    /// web `extractWorkKey` (a plain replace, so a key without the prefix passes
    /// through unchanged).
    static func extractWorkKey(_ key: String) -> String {
        key.replacingOccurrences(of: "/works/", with: "")
    }

    /// Full 'S'/'M'/'L' cover URL for a cover id, or "" when there is no id —
    /// mirror of web `getBookCoverUrl` (never returns a broken URL). Default 'M'.
    public static func getBookCoverUrl(_ coverId: Int?, size: String = "M") -> String {
        guard let coverId else { return "" }
        return "https://covers.openlibrary.org/b/id/\(coverId)-\(size).jpg"
    }

    // MARK: - Genre normalization

    /// Map messy OpenLibrary subjects → canonical book genres. Entry-for-entry
    /// port of web `SUBJECT_TO_GENRE` (`services/openLibraryService.ts`).
    static let subjectToGenre: [String: String] = [
        // Fiction genres
        "fiction": "Fiction",
        "literary fiction": "Literary Fiction",
        "fantasy": "Fantasy",
        "fantasy fiction": "Fantasy",
        "science fiction": "Sci-Fi",
        "sci-fi": "Sci-Fi",
        "mystery": "Mystery",
        "mystery and detective stories": "Mystery",
        "detective": "Mystery",
        "thriller": "Thriller",
        "thrillers": "Thriller",
        "suspense": "Thriller",
        "romance": "Romance",
        "romance fiction": "Romance",
        "love stories": "Romance",
        "horror": "Horror",
        "horror fiction": "Horror",
        "humor": "Humor",
        "humorous fiction": "Humor",
        "comedy": "Humor",
        "satire": "Humor",
        "young adult": "Young Adult",
        "young adult fiction": "Young Adult",
        "juvenile fiction": "Children",
        "children's fiction": "Children",
        "children": "Children",
        "graphic novels": "Graphic Novel",
        "comics": "Graphic Novel",
        "manga": "Graphic Novel",
        "poetry": "Poetry",
        "poems": "Poetry",
        // Non-fiction genres
        "non-fiction": "Non-fiction",
        "nonfiction": "Non-fiction",
        "biography": "Biography",
        "biographies": "Biography",
        "autobiography": "Biography",
        "memoirs": "Biography",
        "memoir": "Biography",
        "history": "History",
        "historical": "History",
        "philosophy": "Philosophy",
        "self-help": "Self-help",
        "self help": "Self-help",
        "personal development": "Self-help",
        "science": "Science",
        "popular science": "Science",
        "travel": "Travel",
        "travel writing": "Travel",
    ]

    /// Canonical book genre vocabulary — port of web `ALL_BOOK_GENRES`
    /// (`constants.ts`). Order-preserving. `validGenres` gates the mapper so a
    /// table entry pointing at a non-canonical genre is rejected (defense in
    /// depth, matching web's `VALID_GENRES.has(...)` guard).
    static let allBookGenres = [
        "Fiction", "Non-fiction", "Fantasy", "Sci-Fi", "Mystery", "Thriller",
        "Romance", "Horror", "Biography", "History", "Philosophy", "Poetry",
        "Self-help", "Science", "Travel", "Young Adult", "Children",
        "Graphic Novel", "Humor", "Literary Fiction",
    ]

    private static let validGenres = Set(allBookGenres)

    /// Normalize raw subjects into up to 5 canonical genres. Pure port of web
    /// `normalizeBookGenres`.
    ///
    /// Pass 1 — exact map: lowercase+trim each subject, take the mapped genre if
    /// it is a valid canonical genre. Pass 2 — partial-match fallback, only when
    /// pass 1 found nothing: scan the map keywords LONGEST-FIRST (so "science
    /// fiction" beats "science"), take the first keyword each subject contains,
    /// `break` after that subject's first hit, and stop once 3 genres accumulate.
    /// The final result is capped at 5.
    public static func normalizeBookGenres(_ subjects: [String]) -> [String] {
        var genres = OrderedStringSet()

        for subject in subjects {
            let lower = subject.lowercased().trimmingCharacters(in: .whitespaces)
            if let mapped = subjectToGenre[lower], validGenres.contains(mapped) {
                genres.insert(mapped)
            }
        }

        // Fallback: partial keyword matching (longest keyword first to avoid
        // misclassification), only if nothing matched exactly.
        if genres.isEmpty {
            let sortedEntries = subjectToGenre.sorted { $0.key.count > $1.key.count }
            for subject in subjects {
                let lower = subject.lowercased().trimmingCharacters(in: .whitespaces)
                for (keyword, genre) in sortedEntries {
                    if lower.contains(keyword), validGenres.contains(genre) {
                        genres.insert(genre)
                        break
                    }
                }
                if genres.count >= 3 { break }
            }
        }

        return Array(genres.elements.prefix(5))
    }

    // MARK: - Decode DTO

    /// One `search.json` doc (only the fields we request). All optional — OL omits
    /// absent fields entirely.
    struct OLDoc: Decodable {
        let key: String?                    // "/works/OL27448W"
        let title: String?
        let author_name: [String]?
        let first_publish_year: Int?
        let number_of_pages_median: Int?
        let cover_i: Int?
        let ratings_average: Double?
        let ratings_count: Int?
        let subject: [String]?
        let isbn: [String]?
    }

    private struct OLSearchResponse: Decodable {
        let docs: [OLDoc]
    }
}

// MARK: - Public DTO

/// A book search result — mirror of web `OpenLibraryBook`. `posterUrl` is `""`
/// (never nil) when the book has no cover, matching web's empty-string convention.
public struct OpenLibraryBook: Codable, Sendable, Hashable, Identifiable {
    public let id: String              // "ol_OL27448W"
    public let title: String
    public let author: String
    public let year: String
    public let posterUrl: String
    public let genres: [String]
    public let pageCount: Int?
    public let isbn: String?
    public let olWorkKey: String       // "OL27448W"
    public let olRatingsAverage: Double?   // 0-5 scale
    public let globalScore: Double?        // 0-10 scale (olRatingsAverage * 2)

    public init(
        id: String, title: String, author: String, year: String,
        posterUrl: String, genres: [String], pageCount: Int?, isbn: String?,
        olWorkKey: String, olRatingsAverage: Double?, globalScore: Double?
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.year = year
        self.posterUrl = posterUrl
        self.genres = genres
        self.pageCount = pageCount
        self.isbn = isbn
        self.olWorkKey = olWorkKey
        self.olRatingsAverage = olRatingsAverage
        self.globalScore = globalScore
    }
}

// MARK: - Insertion-ordered de-duping set (mirrors JS `Set` iteration order)

/// A tiny insertion-ordered string set. Web relies on `Set<string>` preserving
/// first-insertion order for the genre list; Swift's `Set` is unordered, so we
/// keep this explicit ordered structure to match web's output order exactly.
private struct OrderedStringSet {
    private(set) var elements: [String] = []
    private var seen: Set<String> = []

    var isEmpty: Bool { elements.isEmpty }
    var count: Int { elements.count }

    mutating func insert(_ value: String) {
        if seen.insert(value).inserted {
            elements.append(value)
        }
    }
}
