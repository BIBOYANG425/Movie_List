import Foundation

/// English string table — the CANONICAL key set. Every key here MUST exist in
/// `ZH.table` (enforced by `L10nParityTests`), the Swift analogue of web's
/// `zh satisfies Record<TranslationKey, string>` type check (i18n/zh.ts).
///
/// Populated by the C6-iOS Task 3 sweep: the app's USER-VISIBLE copy is wired
/// through `L10n.t` and lives here (nav, chrome, toasts, rank/ceremony flow,
/// watchlist, discover incl. chip labels, shelf, stubs/journal, profile/friends/
/// auth, onboarding). Debug/NSLog strings, brand/ticket-design chrome
/// (ADMIT ONE / SPOOL · 2026 / TIER), test-pinned pure formatters, and demo
/// fixture content stay EN by design. Add keys here FIRST, then their zh in
/// `ZH.table`.
public enum EN {
    public static let table: [String: String] = [
        // Bottom nav tab labels (BottomNav.swift `tabButton` labels).
        "nav.feed": "feed",
        "nav.stubs": "stubs",
        "nav.queue": "watchlist",
        "nav.friends": "friends",
        "nav.me": "me",

        // Bottom nav floating "+" accessibility label (BottomNav.swift).
        "nav.rankNew": "Rank a new movie",

        // Rank flow toasts (RankH2H / rank persistence sites).
        "toast.rankSaveFailed": "couldn't save your rank. check connection",
        "toast.reRankFailed": "couldn't re-rank this show. try again",
        // Preview-mode queue refused a tv/book rank (session died mid-ceremony).
        // iOS-only path (RankPersistence). New zh below.
        "toast.rankSaveSignIn": "couldn't save your rank. sign in and try again",

        // Shelf/watchlist manage-action failure toasts (RankManageModel /
        // WatchlistModel). Each carries a {title} token (the item that failed).
        // iOS-only surfaces (web has no equivalent per-item error toasts). New zh.
        "toast.removeFailed": "couldn't remove {title}. try again",
        "toast.reorderFailed": "couldn't reorder {title}. try again",
        "toast.moveFailed": "couldn't move {title}. try again",
        "toast.deleteFailed": "couldn't delete {title}. try again",
        // Notes-edit sheet probe/save failures (RankManageModel). iOS-only. New zh.
        "toast.noteLoadFailed": "couldn't load your existing note. saving may overwrite it",
        "toast.noteSaveFailed": "couldn't save notes. try again",

        // Ranking-management confirm (carries a {label} token — proves
        // interpolation + placeholder-set parity with zh; mirrors web
        // 'ranking.resetConfirm').
        "ranking.resetConfirm": "Reset your {label} list? This cannot be undone.",

        // A generic failure toast, ported from web 'ranking.failedSave' (i18n/
        // en.ts). Recast dash-free per the owner's EN prose no-em-dash rule
        // (2026-07-11), so it diverges from web's em-dashed original by design.
        "toast.saveFailed": "Failed to save. please try again",

        // Deep-link profile resolution failed (C7-iOS Task 5): a spool://u/…
        // or rankspool.com/u/… link named a username with no matching profile,
        // or the lookup failed. iOS-only surface. New zh below.
        "toast.profileNotFound": "couldn't find that profile",

        // ── Feed (FeedScreen, FeedTicket, FeedTicketBack) ─────────────────────
        // Discover header a11y reuses web nav.discover. Mode switcher: the
        // friends pill is iOS-short "friends" (feed.modeFriends, new zh); explore
        // reuses web feed.explore. Empty states + card chrome below.
        "nav.discover": "Discover",              // web nav.discover
        "feed.modeFriends": "friends",           // iOS-short; web feed.friendsFeed longer
        "feed.explore": "explore",               // web feed.explore
        // Signed-out ticket back (fixtureBack).
        "feed.reactionsReplies": "REACTIONS + REPLIES",
        "feed.signInToReact": "sign in to react and reply",
        "feed.tapToFlipBack": "TAP TO FLIP BACK",
        // Friends/explore empty states (iOS copy; web feed.emptyFriends/Explore
        // are single-string; iOS splits title + hint + CTA).
        "feed.emptyFriendsTitle": "your feed is quiet",
        "feed.emptyFriendsHint": "follow people to see their rankings, reviews, and lists here",
        "feed.findYourPeople": "find your people",
        "feed.emptyExploreTitle": "explore is empty",
        "feed.emptyExploreHint": "public profiles appear here. make yours public in settings",
        "feed.openSettings": "open settings",
        // Ticket front: mute-title menu + spoiler shield (web localizes spoilers).
        "feed.muteTitle": "mute this title",
        "feed.spoilersTapReveal": "tap to reveal spoilers",
        // Ticket back: thread empty/error, composer, a11y ({title}/{body}/{error}
        // carry dynamic content).
        "feed.ticketBackFor": "ticket back for {title}",
        "feed.reactionsLoadFailed": "couldn't load reactions",
        "feed.noRepliesYet": "no replies yet. be first",
        "feed.deleteComment": "delete",
        "feed.replyPrefix": "reply: {body}",
        "feed.commentDeleteHint": "your comment, long-press to delete",
        "feed.errorPrefix": "error: {error}",
        "feed.composerPlaceholder": "say something…",
        "feed.postComment": "post comment",
        // Composer inline validation + send-failure (TicketEngagementModel emitter).
        "feed.composerEmpty": "say something",
        "feed.composerTooLong": "keep it under 500",
        "feed.composerPostFailed": "couldn't post. try again",
        "feed.flipBackA11y": "flip back to the ticket front",

        // ── Notifications (NotificationBellView) ──────────────────────────────
        // Title reuses web notifications.title. a11y + empty state are iOS-only.
        "notifications.a11yNone": "notifications",
        "notifications.a11yUnread": "notifications, {count} unread",
        "notifications.title": "Notifications",   // web notifications.title
        "notifications.emptyTitle": "nothing yet",
        "notifications.emptyHint": "follows, likes, and comments land here",
        "notifications.opensProfile": "opens profile",

        // ── Onboarding (OnboardingFlow / Screens / FriendSearch / Primitives) ──
        // The marquee wordmark "Spool", "DOORS OPEN · 9:41" (decorative time), and
        // the styled-CONCATENATED narrative lines (Text + accent-Text fragments:
        // rules, "one down · 119 to go", "pick tier {X} films") stay EN — a fragment
        // rebuild risks drift/mixed script. Standalone copy localizes. {n}/{current}
        // /{total}/{saved} carry dynamic content.
        "onb.savingPicks": "saving your picks…",
        "onb.picksPartialSave": "saved {saved} of {total} picks. we'll retry on next sign-in",
        "onb.tonightOnly": "TONIGHT · ONLY",
        "onb.privatePalace": "a private picture palace\nof everything you watch.",
        "onb.noSignupYet": "no sign-up yet.\nrank first. we'll talk later.",
        "onb.takeYourSeat": "take your seat ↘",
        "onb.logIn": "log in ↗",
        "onb.logInA11y": "Log in",
        "onb.ticketShelf": "your ticket,\nyour shelf.",
        "onb.saveStubsHint": "save your stubs across devices.\nfind friends' shelves. pick up where you left off.",
        "onb.continueWithoutAccount": "continue without account. preview only",
        "onb.theRules": "— THE RULES —",
        "onb.seenItTierIt": "seen it? tier it.",
        "onb.loadingPicks": "loading this week's picks…",
        "onb.tieredCount": "{n} tiered · pick at least 4",
        "onb.headToHead": "— HEAD TO HEAD · MATCH {current} OF {total} —",
        "onb.whichLoveMore": "which do you love more?",
        "onb.challenger": "CHALLENGER",
        "onb.vs": "vs",
        "onb.winnerStays": "winner stays. we climb the ladder.\n{n} more to go.",
        "onb.needMorePicks": "need more picks to compare. skip ahead.",
        "onb.opener": "OPENER",
        "onb.reigningChampion": "REIGNING CHAMPION",
        "onb.skipArrow": "skip →",
        "onb.pickOne": "pick one",
        "onb.crownWinner": "crown winner →",
        "onb.nextMatchup": "next matchup →",
        "onb.picked": "picked ✓",
        "onb.stamped": "STAMPED",
        "onb.whoShallWeSeat": "— WHO SHALL WE SEAT? —",
        "onb.andYouAre": "and you are…?",
        "onb.available": "AVAILABLE ✓",
        "onb.walkOutQ": "the one movie\nyou'd walk out of?",
        "onb.defendQ": "the one you'll\ndefend to the grave?",
        "onb.typeAnything": "type anything…",
        "onb.thatsMe": "that's me →",
        "onb.findYourPeople": "— FIND YOUR PEOPLE —",
        "onb.findYourPeopleTitle": "find your\npeople.",
        "onb.done": "done →",
        "onb.searchHandle": "search a handle to follow someone.",
        "onb.needSignInFriends": "you need to be signed in to find friends.\nyou can always come back. they'll still be here.",
        "onb.handlePlaceholder": "handle",
        "onb.searching": "searching…",
        "onb.noHandleMatch": "no one by that handle. yet.",
        "onb.following": "following",
        "onb.follow": "follow",
        "onb.skip": "skip",
        "onb.reelLoaded": "the reel is loaded.\nlights dimming…",
        "onb.startSpooling": "start spooling ▸",
        "onb.comingThisYear": "— COMING THIS YEAR —",

        // ── Auth (SignInSheet + SignInFormBody) ───────────────────────────────
        // Reuses web auth.* register where it maps (cited); the rest is iOS auth
        // copy (new zh). AuthService error messages stay their own system (EN).
        "auth.reserveSeat": "— RESERVE YOUR SEAT —",
        "auth.saveRankings": "save your\nrankings.",
        "auth.stubsAcrossDevices": "your stubs live across devices.\nsign in to keep what you just ranked.",
        "auth.notNow": "not now. keep previewing",
        "auth.emailLabel": "EMAIL",
        "auth.emailPlaceholder": "you@spool.co",
        "auth.passcodeLabel": "PASSCODE",
        "auth.passcodePlaceholder": "8+ characters",
        "auth.working": "working…",
        "auth.signIn": "sign in",                    // web auth.signIn register
        "auth.createAccount": "create account",      // web auth.createAccount register
        "auth.newHere": "new here? create an account",
        "auth.haveAccountSignIn": "have an account? sign in",
        "auth.openingGoogle": "opening Google…",
        "auth.continueGoogle": "continue with Google",  // web auth.google register
        "auth.or": "or",                             // web auth.or register

        // ── Edit profile (EditProfileScreen) ──────────────────────────────────
        // Reuses web profile.* register where it maps (cited).
        "editProfile.title": "edit profile",         // web profile.editProfile register
        "editProfile.cancel": "cancel",
        "editProfile.username": "USERNAME",
        "editProfile.readOnly": "read-only",
        "editProfile.displayName": "DISPLAY NAME",    // web profile.displayName register
        "editProfile.displayNameHint": "shown above your bio on your profile.",
        "editProfile.displayNamePlaceholder": "e.g. yurui",
        "editProfile.bio": "BIO",                     // web profile.bio register
        "editProfile.bioHint": "two lines max. press return between them.",
        "editProfile.bioPlaceholder": "what's your vibe?",
        "editProfile.saving": "saving…",              // web profile.saving register
        "editProfile.save": "save",

        // ── Profile (ProfileScreen) ───────────────────────────────────────────
        // Decorative fixture demo (Past Lives, 3rd rewatch) stays EN. {n}/{handle}
        // /{score}/{month} carry dynamic content.
        "profile.openSettings": "Open settings",
        "profile.stubsLabel": "STUBS",
        "profile.currentlyObsessed": "CURRENTLY OBSESSED",
        "profile.nowPlaying": "NOW PLAYING",
        "profile.nothingYet": "nothing yet",
        "profile.rankSTierHint": "rank an S-tier to light this up",
        "profile.yourTopSTier": "your top S-tier.",
        "profile.myTop4": "MY TOP 4 · ALL TIME",
        "profile.seeFullShelf": "see full shelf →",
        "profile.seeFullShelfA11y": "See full shelf",
        "profile.recentStubs": "RECENT STUBS · {month}",
        "profile.friendsCount": "◉ {n} friends",
        "profile.tasteTwin": "taste twin {handle} · {score}%",

        // ── Friends (FriendsScreen + FriendRow) ───────────────────────────────
        // Demo "last watched Past Lives · S" line stays EN fixture. {n}/{handle}
        // /{score} carry dynamic content.
        "friends.title": "friends",
        "friends.add": "+ add",
        "friends.loadFailed": "COULDN'T LOAD FRIENDS",
        "friends.pullToRetry": "pull to retry.",
        "friends.demoTwins": "DEMO TWINS · SIGN IN FOR REAL FRIENDS",
        "friends.yourTwins": "YOUR TASTE TWINS · {n}",
        "friends.noTwins": "NO TWINS YET",
        "friends.noTwinsHint": "follow someone to see how your tastes compare.",
        "friends.twinLabel": "TWIN",
        "friends.viewProfileA11y": "View {handle} profile",
        "friends.openTwinA11y": "Open taste twin with {handle}, {score}% match",

        // ── Friend profile (FriendProfileScreen) ──────────────────────────────
        "friendProfile.back": "← FRIENDS",
        "friendProfile.following": "following",       // web profile.following register
        "friendProfile.follow": "+ follow",           // web profile.follow register
        "friendProfile.tasteTwin": "{score}% TASTE TWIN",
        "friendProfile.seeMore": "· SEE MORE →",
        "friendProfile.openTwinA11y": "Open taste twin detail",
        "friendProfile.theirTop4": "THEIR TOP 4 · S-TIER",
        "friendProfile.mutual": "◉ {n} mutual",
        "friendProfile.stubsPill": "{n} stubs",

        // ── Achievements section (AchievementsSection on Profile / FriendProfile) ─
        // Section CHROME localizes; badge NAMES + DESCRIPTIONS stay EN proper
        // nouns (web's BADGE_CATALOG copy lives in AchievementsView.tsx, NOT the
        // i18n tables — web zh mode shows the same EN badge names). Category
        // labels mirror web CATEGORY_STYLES.label.
        "achievements.title": "ACHIEVEMENTS",
        "achievements.count": "{earned}/{total} UNLOCKED",
        "achievements.noneYet": "no badges yet.",
        "achievements.loading": "loading badges…",
        "achievements.locked": "locked",
        "achievements.category.milestone": "MILESTONES",
        "achievements.category.social": "SOCIAL",
        "achievements.category.taste": "TASTE",
        "achievements.category.special": "SPECIAL",

        // ── Taste twin (TwinScreen) ───────────────────────────────────────────
        // The narrative summary/fight SENTENCES (concatenated Text + markText,
        // demo-heavy) stay EN. Chrome + empty states + Venn labels localize.
        "twin.shareCard": "↗ share card",
        "twin.yourLibraries": "YOUR LIBRARIES",
        "twin.biggestFights": "BIGGEST FIGHTS",
        "twin.recommendTo": "RECOMMEND TO {handle}",
        "twin.send3Recs": "send 3 recs →",
        "twin.spoolTasteTwin": "SPOOL · TASTE TWIN",
        "twin.noSharedFilms": "no shared films yet.",
        "twin.rankMoreFillsIn": "rank a few more and the taste map fills in.",
        "twin.comeBackMath": "then come back. we'll do the math.",
        "twin.noDisagreements": "no big disagreements yet. rank more to find friction.",
        "twin.nothingToRecommend": "nothing to recommend yet. rank more S/A films.",
        "twin.argue": "argue →",
        "twin.youOnly": "you only",
        "twin.filmsCount": "{n} films",
        "twin.handleOnly": "{handle} only",
        "twin.bothLove": "both ♡ {n}",
        "twin.sharedSoFar": "shared {n} films so far.",
        "twin.plentyMore": "plenty more to compare.",
        "twin.rankMoreShape": "rank a few more to see the shape.",

        // ── Stubs / memories (StubsScreen, StubDetail, StubShare) ─────────────
        // iOS ticket-stub calendar. Some ticket-DESIGN chrome (ADMIT ONE, SPOOL ·
        // 2026, TIER) stays EN in AdmitStub (physical-ticket aesthetic, matching
        // web's untranslated ticket decoration). {n}/{month} carry dynamic data.
        "stubs.myStubs": "my stubs",
        "stubs.tabStubs": "stubs",
        "stubs.tabJournal": "journal",
        "stubs.tapADay": "tap a day to see the stub ↑",
        "stubs.lastWatched": "LAST WATCHED",
        "stubs.watchedCount": "{n} WATCHED",
        "stubs.emptyCollection": "nothing here yet · rank something to start your stub collection.",
        "stubs.signInToSee": "sign in to see your real stubs.",
        "stubs.monthInLetters": "{month}, in letters.",
        "stubs.makeRecap": "🎞 make {month} recap",
        "stubs.recapNothing": "nothing yet.",
        "stubs.recapStacked": "a pretty stacked month.",
        "stubs.recapSlow": "a slow month.",
        "stubs.recapSolid": "a solid month.",
        // Stub detail (fixture friend chips + notes body stay demo data).
        "stubDetail.back": "← APRIL",
        "stubDetail.share": "SHARE ↗",
        "stubDetail.friendsWatched": "— FRIENDS WHO ALSO WATCHED —",
        "stubDetail.notes": "— NOTES —",
        // Stub share sheet.
        "stubShare.back": "← BACK",
        "stubShare.forYourStory": "for your story ↓",
        "stubShare.ig": "↗ IG",
        "stubShare.tiktok": "↗ tiktok",
        "stubShare.save": "↗ save",
        "stubShare.postToFeed": "post to spool feed",
        "stubShare.comingSoon": "post to feed coming soon",

        // ── Journal list (JournalListView) ────────────────────────────────────
        // Search placeholder reuses web journal.search register; empty states are
        // iOS copy (new zh).
        "journal.searchPlaceholder": "search your journal…",
        "journal.listEmpty": "no entries yet. rank something and write about it",
        "journal.nothingMatches": "nothing matches",
        // Journal visibility labels REUSE the web journal.vis* keys VERBATIM.
        "journal.visDefault": "default",              // web journal.visDefault
        "journal.visPublic": "public",                // web journal.visPublic
        "journal.visFriends": "friends",              // web journal.visFriends
        "journal.visPrivate": "private",              // web journal.visPrivate

        // ── Journal composer (JournalComposer) ────────────────────────────────
        // iOS journal entry editor. Reuses web journal.* register where it maps
        // (cited); the rest is iOS composer copy (new zh). {character} = a role.
        "composer.loading": "loading your entry…",
        "composer.close": "× close",
        "composer.title": "write about it",
        "composer.subtitle": "your journal entry",
        "composer.sectionMoment": "the moment",
        "composer.reviewPlaceholder": "what did it stir in you?",
        "composer.containsSpoilers": "contains spoilers",
        "composer.sectionFeeling": "the feeling",
        "composer.moods": "moods",
        "composer.vibes": "vibes",
        "composer.sectionDetails": "the details",
        "composer.favoriteMoments": "favorite moments",
        "composer.momentPlaceholder": "a moment you loved",
        "composer.addMoment": "add a moment",
        "composer.standoutPerformances": "standout performances",
        "composer.asCharacter": "as {character}",
        "composer.actor": "actor",
        "composer.asOptional": "as… (optional)",
        "composer.watchContext": "watch context",
        "composer.locationPlaceholder": "where did you watch?",
        "composer.platformNone": "none",
        "composer.platform": "platform",
        "composer.watchedWith": "watched with",
        "composer.noFriendsToTag": "no friends to tag yet",
        "composer.wasRewatch": "this was a rewatch",
        "composer.rewatchPlaceholder": "what changed this time?",
        "composer.sectionPrivate": "private",
        "composer.privateHint": "only you will ever see this",
        "composer.takeawayPlaceholder": "a note to your future self…",
        "composer.sectionPhotos": "photos",
        "composer.addPhotos": "add photos",
        "composer.photosMax": "6 photos max",
        "composer.sectionVisibility": "visibility",
        "composer.defaultFollowsProfile": "default follows your profile",
        "composer.saving": "saving…",
        "composer.saveEntry": "save entry ✓",

        // ── Shelf / full list (FullListScreen + manage menus + notes editor) ──
        // iOS "my shelf" management surface. re-rank reuses web detail.reRank
        // register; the rest is iOS copy (new zh). {title} names the delete item.
        "shelf.title": "my shelf",
        "shelf.edit": "edit",
        "shelf.done": "done",
        "shelf.loading": "loading your shelf…",
        "shelf.signInTitle": "sign in to see your shelf",
        "shelf.signInHint": "your rankings live on your account.\nsign in from the home screen to pull them here.",
        "shelf.emptyTitle": "nothing ranked yet",
        "shelf.emptyHint": "rank something from the home tab\nand it'll show up here by tier.",
        "shelf.rankSomething": "rank something →",
        "shelf.moveToTier": "move to tier",
        "shelf.editNotes": "edit notes",
        "shelf.reRank": "re-rank",                   // web detail.reRank register
        "shelf.delete": "delete",
        "shelf.cancel": "cancel",
        "shelf.save": "save",
        "shelf.deleteTitle": "delete {title}?",
        "shelf.deleteTitleGeneric": "delete?",
        "shelf.deleteMessage": "this removes it from your shelf. it won't return to your watchlist.",
        "shelf.refreshFailed": "couldn't refresh. check connection",
        "shelf.yourNotes": "YOUR NOTES",
        "shelf.loadingNotes": "loading your notes…",

        // ── Discover (DiscoverScreen) ─────────────────────────────────────────
        // Provenance chips REUSE the web discover.chip.* keys VERBATIM (both
        // clients render identical chip copy). Section headers/subs + empty/error
        // states reuse web discover.* en where it matches (cited); the rest is
        // iOS Discover copy (new zh). Card count-lines (friendCountLine /
        // rankerCountLine) + genre metaLine stay EN — test-pinned pure formatters.
        "discover.chip.friend": "friends loved",         // web discover.chip.friend
        "discover.chip.taste": "your taste",             // web discover.chip.taste
        "discover.chip.similar": "because you ranked",   // web discover.chip.similar
        "discover.chip.trending": "trending",            // web discover.chip.trending
        "discover.chip.variety": "something different",  // web discover.chip.variety
        "discover.chip.generic": "popular",              // web discover.chip.generic
        "discover.chip.new_release": "new",              // web discover.chip.new_release
        "discover.fromFriends": "from your friends",     // web discover.fromCircle register
        "discover.fromFriendsSub": "loved by people you follow",
        "discover.trendingFriends": "trending with friends",
        "discover.trendingFriendsSub": "most-ranked this month",
        "discover.forYou": "for you",                    // web discover.forYou register
        "discover.forYouSub": "picked from your taste",
        "discover.refresh": "refresh",                   // web discover.refresh
        "discover.engineEmpty": "no suggestions yet. rank a few movies to seed these",
        "discover.engineError": "couldn't load suggestions",
        "discover.newReleases": "new releases",          // web discover.newReleases register
        "discover.newReleasesSub": "fresh in theaters and streaming",
        "discover.newReleasesEmpty": "no new releases right now",
        "discover.newReleasesError": "couldn't load new releases",  // web discover.newReleasesError register
        "discover.loadFailed": "couldn't load discover",
        "discover.followSomePeople": "follow some people",
        "discover.followSomePeopleSub": "this section fills up with what your friends love once you follow a few",
        "discover.findFriends": "find friends",
        "discover.quietTitle": "nothing new from your friends yet",
        "discover.quietSub": "check back after they rank a few more",
        "discover.save": "save",
        "discover.saved": "saved",
        "discover.saveA11y": "save for later",
        "discover.savedA11y": "saved for later",
        // {title} carries the item name.
        "discover.savedToast": "saved {title} for later",
        "discover.saveFailedToast": "couldn't save {title}. try again",

        // ── Watchlist (WatchlistScreen + WatchlistCard) ───────────────────────
        // Header + card actions. rank it / remove reuse web watchlist.* register.
        // Empty/error lines are iOS-split (new zh). {title}/{date} carry dynamic
        // content.
        "watchlist.title": "watchlist",
        "watchlist.loadFailed": "couldn't load your watchlist",
        "watchlist.tryAgain": "try again",
        "watchlist.emptyMovies": "no movies saved yet. bookmark something to watch later",
        "watchlist.emptyShows": "no shows saved yet. bookmark a season to watch later",
        "watchlist.emptyBooks": "no books saved yet. bookmark one to read later",
        "watchlist.rankIt": "rank it",              // web watchlist.rankIt
        "watchlist.remove": "remove",               // web watchlist.remove
        "watchlist.rankA11y": "Rank {title}",
        "watchlist.removeA11y": "Remove {title} from watchlist",
        "watchlist.added": "added {date}",

        // ── Tier labels/sublabels (Tier model — used across ceremony/shelf) ───
        // iOS-only copy (web renders no tier sub-labels). New zh. The raw case
        // (S/A/B/C/D) is the data; these are display-only.
        "tier.labelS": "masterpiece",
        "tier.labelA": "loved it",
        "tier.labelB": "good",
        "tier.labelC": "meh",
        "tier.labelD": "no",
        "tier.subS": "obsessed. tell everyone.",
        "tier.subA": "would rewatch.",
        "tier.subB": "glad i watched.",
        "tier.subC": "wouldn't recommend.",
        "tier.subD": "get it away from me.",

        // ── Ranking ceremony (RankTier/H2H/Ceremony screens) ──────────────────
        // Chrome labels are stored lowercase; .uppercased() is applied at every
        // call site that renders them (verified in RankTierScreen / RankH2HScreen
        // / RankCeremonyScreen). Reuses web ceremony.skip; the rest is iOS
        // ceremony flow copy (new zh). The H2H
        // comparison PROMPTS themselves stay EN (engine parity, SpoolPrompts —
        // web's spoolPrompts.ts is not localized either). {tier}/{round}/{rank}
        // carry dynamic content.
        "ceremony.back": "← back",
        "ceremony.backPill": "← back",
        "ceremony.step1": "step 1 of 3 · gut check",
        "ceremony.step2Match": "step 2 · match {round}",
        "ceremony.step2Placed": "step 2 · placed",
        "ceremony.step2WarmingUp": "step 2 · warming up",
        "ceremony.step3": "step 3 of 3 · ceremony",
        "ceremony.howDidItFeel": "how did it feel?",
        "ceremony.justWatched": "just watched",
        "ceremony.whichHitHarder": "which hit harder?",
        "ceremony.placingWithin": "placing within",
        "ceremony.tierSuffix": "{tier}-tier",
        "ceremony.vs": "— vs —",
        "ceremony.yourTierRank": "your {tier}-tier · #{rank}",
        "ceremony.tie": "= tie",
        "ceremony.haventSeen": "? haven't seen",
        "ceremony.skip": "skip",                    // web ceremony.skip
        "ceremony.readingTaste": "reading your taste…",
        "ceremony.placed": "placed ✓",
        "ceremony.rankIn": "#{rank} in",
        "ceremony.tapToPick": "tap to pick",
        "ceremony.tierShelf": "{tier}-tier shelf",
        "ceremony.new": "new",
        "ceremony.bottleItUp": "now bottle it up.",
        "ceremony.pickMoodsHint": "pick up to 3 moods · one line to remember",
        "ceremony.printStub": "print my stub →",
        "ceremony.lineToRemember": "a line to remember",

        // ── Printed stub (RankPrintedScreen) ──────────────────────────────────
        // iOS ceremony finale. New zh. {no}/{rank}/{tier} carry dynamic content.
        "printed.ready": "your stub is ready.",
        "printed.collectionNo": "{no} of your collection",
        "printed.rankInTier": "#{rank} in {tier}-tier",
        "printed.shareStory": "↗ share to story",
        "printed.savePNG": "save PNG",
        "printed.postToFeed": "post to feed ✓",
        "printed.writeMore": "write more about it →",
        "printed.keepPrivate": "keep private →",

        // ── Rank entry (RankEntryScreen + RankEntryModel search) ──────────────
        // Search-flow entry. Reuses web ceremony.* where the copy matches (cited);
        // section labels + iOS-lowercase mode pills are new zh. Section-header
        // chrome is stored lowercase; .uppercased() is applied at the call sites
        // in RankEntryScreen (sectionLabel helper + basedOnTaste/popularNow).
        "rankEntry.makeStub": "let's make you a stub.",
        "rankEntry.justWatched": "just watched?",
        "rankEntry.justRead": "just read?",
        "rankEntry.back": "← back",
        "rankEntry.cancel": "cancel ✕",
        "rankEntry.modeMovies": "movies",
        "rankEntry.modeTV": "tv",
        "rankEntry.modeBooks": "books",
        "rankEntry.searchFilms": "search films…",
        "rankEntry.searchShows": "search shows…",
        "rankEntry.searchBooks": "search books…",
        "rankEntry.sectionMatches": "matches",
        "rankEntry.sectionDemo": "demo results",
        "rankEntry.sectionShows": "shows",
        "rankEntry.sectionBooks": "books",
        "rankEntry.basedOnTaste": "based on your taste",     // web ceremony.basedOnTaste
        "rankEntry.popularNow": "popular right now",          // web ceremony.popularNow
        "rankEntry.refresh": "refresh",                       // web ceremony.refresh
        "rankEntry.suggestionsLoadFailed": "couldn't load suggestions",
        "rankEntry.retry": "retry",
        "rankEntry.searchShowHint": "search a show to rank a season",
        "rankEntry.searchFilmHint": "search a film to rank it",
        "rankEntry.seasonsLoadFailed": "couldn't load seasons. go back and try again",
        "rankEntry.pickSeason": "pick a season",
        "rankEntry.whichSeason": "which season?",
        "rankEntry.loadingSeasons": "loading seasons…",
        "rankEntry.searching": "searching…",
        "rankEntry.noResults": "no results",                  // web search.noResults
        "rankEntry.signInShows": "sign in to rank shows",
        "rankEntry.signInBooks": "sign in to rank books",
        "rankEntry.signInHint": "tv and books save to your account. sign in first.",
        "rankEntry.signIn": "sign in",
        "rankEntry.onList": "on list",
        // {year}: the show's year (or an em-dash placeholder when unknown).
        "rankEntry.tvYear": "TV · {year}",
        // {n}: season episode count. Two keys keep the existing plural branch.
        "rankEntry.episodeSingular": "{n} episode",
        "rankEntry.episodePlural": "{n} episodes",
        "rankEntry.ranked": "ranked",
        // Rank-flow suggestion-grid save affordance (C7-iOS Task 4) — the small
        // bookmark on a movie/show suggestion card. Mirrors web's modal-grid
        // bookmark (`AddMediaModal`/`AddTVSeasonModal` `handleBookmark*`). A11y
        // labels + optimistic-save toasts. {title}: the movie/show title.
        "rankEntry.saveA11y": "save for later",
        "rankEntry.savedA11y": "saved for later",
        "rankEntry.savedToast": "saved {title} for later",
        "rankEntry.saveFailedToast": "couldn't save {title}. try again",

        // App chrome (SpoolAppRoot). Preview-mode banner shown above the tab bar
        // to a user who onboarded without signing in (iOS-only surface; web has
        // no equivalent banner key). Recast dash-free per the owner's EN prose
        // no-em-dash rule (2026-07-11); zh already dash-free.
        "app.previewBanner": "preview mode. sign in to save your rankings",

        // Settings → language row (C6-iOS Task 2). Web has no settings.* keys yet,
        // so these are iOS-first; the two option labels reuse the web
        // `LanguageToggle` glyphs ('EN' / '中文', components/shared/LanguageToggle.tsx)
        // verbatim so both surfaces name the languages identically.
        "settings.language": "language",
        "settings.languageEnglish": "EN",
        "settings.languageChinese": "中文",

        // Settings sheet chrome + rows (SettingsScreen). iOS-only surface (web
        // routes these through Profile/menus, no settings.* keys). Lowercase
        // hand-voice register throughout; section titles are uppercased inside
        // the section(title:) helper, so stored values stay lowercase.
        "settings.close": "close",
        "settings.title": "settings",
        "settings.sectionAccount": "account",
        "settings.editProfile": "edit profile",
        "settings.signedIn": "signed in",
        "settings.profileNotLoadedRetry": "profile not loaded yet. pull to retry",
        "settings.profileNotLoaded": "profile not loaded yet",
        "settings.previewMode": "preview mode",
        "settings.previewModeHint": "sign in from the home screen to save your rankings",
        "settings.sectionAppearance": "appearance",
        "settings.themeSystem": "match system",
        "settings.themePaper": "paper",
        "settings.themeDark": "dark",
        "settings.sectionPrivacy": "privacy",
        "settings.profileVisibility": "profile visibility",
        // Visibility option DISPLAY labels (the DB value stays public/friends/private).
        "settings.visPublic": "public",
        "settings.visFriends": "friends",
        "settings.visPrivate": "private",
        "settings.visibilityExploreHint": "public shows your activity in explore",
        // {label} = the resolved visibility option label (VoiceOver).
        "settings.visibilityA11y": "{label} visibility",
        "settings.sectionAbout": "about",
        "settings.privacy": "privacy",
        "settings.terms": "terms",
        "settings.version": "version",
        "settings.signingOut": "signing out…",
        "settings.signOut": "sign out",
    ]
}
