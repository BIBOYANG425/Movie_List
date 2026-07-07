# C1 iOS Feed UI Design (Part B)

Owner design decisions (2026-07-08, visual companion session):

1. **Ticket wall** — every feed event renders as an admit-one stub: perforated edge, poster-forward, `ADMIT ONE · @HANDLE · 2H` mono caps header, tier stamp rotated slightly (S = gold), score on the stamp for ranking/review events. Reuses/extends the existing `AdmitStub`/`Tape`/`TierStamp` component family and `SpoolTokens` paper theme.
2. **Flip the ticket** — tapping a stub flips it in place (3D Y-rotation). The back carries: the five reaction stamps (`love, fire, laugh, sad, mind_blown` — shared contract) as tappable stamp buttons with counts, my-reaction state stamped darker; below, the comment thread (asc, 1-level replies, scrolls within the back when long); composer field at the bottom (≤500 chars, `CommentError` surfaced inline); `TAP TO FLIP BACK` affordance. The flip must feel physical (spring, slight paper shadow); if a thread is open-keyboard, the back expands to a taller card rather than a sheet.
3. **Friends + Explore switcher** — segmented control in the feed header. Explore's empty state is the visibility opt-in prompt: `public profiles appear here — make yours public in settings`, with a button deep-linking to the Settings visibility row (Settings gains that row in this plan — profiles.profile_visibility now exists in prod).
4. **Bell in the feed header** — unread badge (15 s poll while the feed is foregrounded), opens a sheet listing newest 30 with actor avatars, marks fetched-unread read on open (web-exact semantics incl. the >30 badge-resurrection quirk).

Controller adjudication (owner may veto at spec review): **event-type/tier/time filter UI is deferred** to a fast-follow. Rationale: v1 scope stays the wall + flip + switcher + bell; filters are purely additive client-side stages (`FeedPipeline.applyTypeFilter` already exists); the parity gap is ledgered. Mute actions (mute user/movie from a ticket's context menu) ARE in scope — they gate what users see and the repository ships them.

## Screens and components

- **FeedScreen (rebuild)**: header (wordmark, segmented switcher, bell), ticket wall list (LazyVStack), pull-to-refresh, infinite scroll driven by the ledger's Part-B caller contract (hasMore = page full; ≤10 RPC pages per assembly; cursor advances over dropped rows; per-call throttle dict; reads catch-to-empty). Empty states: friends (no follows → `find your people` CTA → FriendsScreen), explore (opt-in prompt above). Preview/fixture mode renders the existing demo data pattern.
- **FeedTicket**: the front face. Event-type variants: ranking_add/ranking_move (poster, tier stamp + live score badge via `rankingScores`, notes line if metadata carries one), review (review chip + spoiler shield if `containsSpoilers`), list_create (list title + count), milestone (badge icon + description). Unknown types coerce to the ranking presentation (contract `toFeedCardType` rule). Actor identity: avatar (3-step fallback chain: `avatar_url` → storage public URL from `avatar_path` → dicebear URL), handle, relative time.
- **FeedTicketBack**: reactions row (toggle via `FeedRepository.toggleReaction`, optimistic with revert-on-throw), comment thread (`comments(for:)`, `FeedPipelineComments.nest`), composer (`addComment`), delete-own via swipe. Long-press on a comment by self → delete.
- **Context menu** (long-press front): mute @user, mute this title, open actor profile (existing FriendProfileScreen).
- **NotificationBell + sheet**: `NotificationRepository` end-to-end; `NotificationKind` icon map with `new_follower` fallback; rows deep-link (follower → profile, journal_tag → nothing in v1, ledgered until C2-iOS).
- **Settings addition**: `profile visibility` row (public/friends/private) writing `profiles.profile_visibility` — the explore opt-in loop's other half.
- **Pure helpers shipped here** (the Part-B deferral list): FeedCard mapping incl. unknown-type coercion + S–D tier guard, avatar fallback chain, score-pair collection rule (ranking/review cards with `media_tmdb_id` only).

## Non-goals (ledgered)

Filter UI (fast-follow); journal_tag deep-links (C2-iOS); realtime (both platforms poll); web's feed visual redesign (web keeps its cards — ticket wall is an accepted platform difference in PRESENTATION only; data and ordering are contract-identical).

## Definition of done

Feed renders both modes with real prod data; flip + reactions + comments round-trip on device; bell badge/read-marking works; explore empty state drives at least the Settings row; suite green; device smoke by owner.
