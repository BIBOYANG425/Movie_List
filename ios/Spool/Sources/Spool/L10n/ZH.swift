import Foundation

/// Chinese string table. Key set MUST match `EN.table` exactly
/// (`L10nParityTests`), and every `{token}` in an English value MUST appear in
/// its zh counterpart. Owner-voice rule: NO em dashes (— U+2014 / – U+2013 /
/// ― U+2015) — the parity test fails the build if one slips in.
///
/// Populated by the C6-iOS Task 3 sweep. Web zh (i18n/zh.ts) is reused VERBATIM
/// wherever an en string matches a web key (the reuse is cited inline, e.g.
/// discover.chip.*, journal.vis*, nav.*); iOS-only strings get new zh in the
/// web zh register (lowercase-neutral, no 不是…而是, no em/en dashes — the parity
/// test fails the build on a dash in any zh VALUE, so recast instead).
public enum ZH {
    public static let table: [String: String] = [
        // Bottom nav tab labels — reuse web zh nav values where they map.
        "nav.feed": "动态",       // web nav.feed
        "nav.stubs": "票根",
        "nav.queue": "想看",      // web nav.watchlist
        "nav.friends": "好友",
        "nav.me": "我的",         // web nav.profile

        // Rank-button accessibility label.
        "nav.rankNew": "给新电影排名",

        // Rank flow toasts — recast without em dashes.
        "toast.rankSaveFailed": "排名没保存成功，检查一下网络",
        "toast.reRankFailed": "这部剧重新排名失败了，再试一次",
        // Preview-mode queue refused a tv/book rank (iOS-only). New zh, dash-free.
        "toast.rankSaveSignIn": "排名没保存成功，登录后再试一次",

        // Shelf/watchlist manage-action failures — each keeps the {title} token.
        // iOS-only. New zh, recast without em dashes.
        "toast.removeFailed": "没能移除{title}，再试一次",
        "toast.reorderFailed": "没能给{title}重新排序，再试一次",
        "toast.moveFailed": "没能移动{title}，再试一次",
        "toast.deleteFailed": "没能删除{title}，再试一次",
        // Notes-edit sheet probe/save failures (iOS-only). New zh, dash-free.
        "toast.noteLoadFailed": "没能读取你原有的备注，保存可能会覆盖它",
        "toast.noteSaveFailed": "备注没保存成功，再试一次",

        // Ranking-management confirm — carries the same {label} token as en.
        "ranking.resetConfirm": "重置你的{label}列表？此操作无法撤销。",

        // Generic failure toast — reuse web 'ranking.failedSave'.
        "toast.saveFailed": "保存失败，请重试",

        // ── Feed (FeedScreen, FeedTicket, FeedTicketBack) ─────────────────────
        "nav.discover": "发现",                    // web nav.discover
        "feed.modeFriends": "好友",                // iOS-short (web feed.friendsFeed=好友动态)
        "feed.explore": "探索",                    // web feed.explore
        // Signed-out ticket back (fixtureBack). New zh, dash-free.
        "feed.reactionsReplies": "回应 + 回复",
        "feed.signInToReact": "登录后就能回应和回复",
        "feed.tapToFlipBack": "点这里翻回正面",
        // Friends/explore empty states. New zh, dash-free.
        "feed.emptyFriendsTitle": "你的动态还很安静",
        "feed.emptyFriendsHint": "关注一些人，他们的排名、影评和片单会出现在这里",
        "feed.findYourPeople": "去找你的人",
        "feed.emptyExploreTitle": "探索这里还是空的",
        "feed.emptyExploreHint": "公开的主页会出现在这里，去设置里把你的设为公开",
        "feed.openSettings": "打开设置",
        // Ticket front: mute-title menu + spoiler shield. Spoiler reuses the web
        // feed.containsSpoilers / feed.tapToReveal wording (包含剧透 / 点击查看).
        "feed.muteTitle": "屏蔽这部片子",
        "feed.spoilersTapReveal": "包含剧透，点击查看",   // web feed.containsSpoilers + tapToReveal
        // Ticket back: thread empty/error, composer, a11y. New zh, dash-free.
        "feed.ticketBackFor": "{title}的票根背面",
        "feed.reactionsLoadFailed": "回应没加载出来",
        "feed.noRepliesYet": "还没有回复，来抢第一个",
        "feed.deleteComment": "删除",
        "feed.replyPrefix": "回复：{body}",
        "feed.commentDeleteHint": "你的评论，长按可删除",
        "feed.errorPrefix": "错误：{error}",
        "feed.composerPlaceholder": "说点什么…",
        "feed.postComment": "发送评论",
        // Composer inline validation + send-failure. New zh, dash-free.
        "feed.composerEmpty": "说点什么吧",
        "feed.composerTooLong": "控制在500字以内",
        "feed.composerPostFailed": "没发送成功，再试一次",
        "feed.flipBackA11y": "翻回票根正面",

        // ── Notifications (NotificationBellView) ──────────────────────────────
        "notifications.a11yNone": "通知",
        "notifications.a11yUnread": "通知，{count}条未读",
        "notifications.title": "通知",              // web notifications.title
        "notifications.emptyTitle": "还没有内容",
        "notifications.emptyHint": "关注、点赞和评论都会出现在这里",
        "notifications.opensProfile": "打开主页",

        // ── Onboarding (OnboardingFlow / Screens / FriendSearch / Primitives) ──
        // 拼接的叙述性文本保留英文。以下为独立文案，新 zh，无破折号。
        "onb.savingPicks": "正在保存你的选择…",
        "onb.picksPartialSave": "已保存 {total} 部中的 {saved} 部，下次登录时会重试",
        "onb.tonightOnly": "今夜 · 限定",
        "onb.privatePalace": "一座私人放映殿堂，\n收藏你看过的一切。",
        "onb.noSignupYet": "还不用注册。\n先排名，晚点再聊。",
        "onb.takeYourSeat": "入座 ↘",
        "onb.logIn": "登录 ↗",
        "onb.logInA11y": "登录",
        "onb.ticketShelf": "你的票根，\n你的片单。",
        "onb.saveStubsHint": "把票根同步到各设备。\n找到朋友的片单，接着上次继续。",
        "onb.continueWithoutAccount": "不创建账号继续，仅预览",
        "onb.theRules": "· 规则 ·",
        "onb.seenItTierIt": "看过？给它评个级。",
        "onb.loadingPicks": "正在加载本周精选…",
        "onb.tieredCount": "已评 {n} 部 · 至少选 4 部",
        "onb.headToHead": "对决 · 第 {current} 组，共 {total} 组",
        "onb.whichLoveMore": "你更喜欢哪一部？",
        "onb.challenger": "挑战者",
        "onb.vs": "对",
        "onb.winnerStays": "赢家留下，我们一路往上爬。\n还剩 {n} 场。",
        "onb.needMorePicks": "需要更多选择来对比，先跳过。",
        "onb.opener": "开局",
        "onb.reigningChampion": "卫冕冠军",
        "onb.skipArrow": "跳过 →",
        "onb.pickOne": "选一个",
        "onb.crownWinner": "加冕赢家 →",
        "onb.nextMatchup": "下一组 →",
        "onb.picked": "已选 ✓",
        "onb.stamped": "已盖章",
        "onb.whoShallWeSeat": "· 该给谁安排座位？ ·",
        "onb.andYouAre": "你是…？",
        "onb.available": "可用 ✓",
        "onb.walkOutQ": "哪一部电影\n会让你中途退场？",
        "onb.defendQ": "哪一部你会\n誓死捍卫？",
        "onb.typeAnything": "随便写点…",
        "onb.thatsMe": "就是我 →",
        "onb.findYourPeople": "· 找到你的人 ·",
        "onb.findYourPeopleTitle": "找到你的\n同好。",
        "onb.done": "完成 →",
        "onb.searchHandle": "搜索一个用户名去关注对方。",
        "onb.needSignInFriends": "找朋友需要先登录。\n你随时可以回来，他们都还在。",
        "onb.handlePlaceholder": "用户名",
        "onb.searching": "搜索中…",
        "onb.noHandleMatch": "还没有叫这个用户名的人。",
        "onb.following": "已关注",
        "onb.follow": "关注",
        "onb.skip": "跳过",
        "onb.reelLoaded": "胶片已就位。\n灯光渐暗…",
        "onb.startSpooling": "开始 spooling ▸",
        "onb.comingThisYear": "· 今年即将上映 ·",

        // ── Auth (SignInSheet + SignInFormBody) ───────────────────────────────
        // Web auth.* zh reused where it maps (cited); rest new zh, dash-free.
        "auth.reserveSeat": "· 预定你的座位 ·",
        "auth.saveRankings": "保存你的\n排名。",
        "auth.stubsAcrossDevices": "你的票根会在各设备间同步。\n登录后就能保留你刚排的内容。",
        "auth.notNow": "先不用，继续预览",
        "auth.emailLabel": "邮箱",                    // web auth.email register
        "auth.emailPlaceholder": "you@spool.co",
        "auth.passcodeLabel": "密码",                 // web auth.password register
        "auth.passcodePlaceholder": "至少 8 位",
        "auth.working": "处理中…",
        "auth.signIn": "登录",                        // web auth.signIn
        "auth.createAccount": "创建账号",              // web auth.createAccount
        "auth.newHere": "新用户？创建一个账号",
        "auth.haveAccountSignIn": "已有账号？去登录",
        "auth.openingGoogle": "正在打开 Google…",
        "auth.continueGoogle": "使用 Google 登录",     // web auth.google
        "auth.or": "或",                             // web auth.or

        // ── Edit profile (EditProfileScreen) ──────────────────────────────────
        "editProfile.title": "编辑资料",              // web profile.editProfile
        "editProfile.cancel": "取消",
        "editProfile.username": "用户名",             // web auth.username register
        "editProfile.readOnly": "只读",
        "editProfile.displayName": "显示名称",         // web profile.displayName
        "editProfile.displayNameHint": "显示在你主页简介上方的名字。",
        "editProfile.displayNamePlaceholder": "例如 yurui",
        "editProfile.bio": "简介",                    // web profile.bio
        "editProfile.bioHint": "最多两行，中间按回车换行。",
        "editProfile.bioPlaceholder": "你的风格是什么？",
        "editProfile.saving": "保存中…",              // web profile.saving
        "editProfile.save": "保存",

        // ── Profile (ProfileScreen) ───────────────────────────────────────────
        // 演示数据（Past Lives 等）保留英文。{n}/{handle}/{score}/{month} 为动态内容。
        "profile.openSettings": "打开设置",
        "profile.stubsLabel": "票根",
        "profile.currentlyObsessed": "最近上头",
        "profile.nowPlaying": "正在放映",
        "profile.nothingYet": "还没有内容",
        "profile.rankSTierHint": "排一部 S 级来点亮这里",
        "profile.yourTopSTier": "你的 S 级之最。",
        "profile.myTop4": "我的 TOP 4 · 历来最爱",
        "profile.seeFullShelf": "查看完整片单 →",
        "profile.seeFullShelfA11y": "查看完整片单",
        "profile.recentStubs": "最近票根 · {month}",
        "profile.friendsCount": "◉ {n} 位好友",
        "profile.tasteTwin": "品味双子 {handle} · {score}%",

        // ── Friends (FriendsScreen + FriendRow) ───────────────────────────────
        "friends.title": "好友",                      // web nav.friends register
        "friends.add": "+ 添加",
        "friends.loadFailed": "好友没加载出来",
        "friends.pullToRetry": "下拉重试。",
        "friends.demoTwins": "演示双子 · 登录查看真实好友",
        "friends.yourTwins": "你的品味双子 · {n}",
        "friends.noTwins": "还没有双子",
        "friends.noTwinsHint": "关注一个人，看看你们的口味有多像。",
        "friends.twinLabel": "双子",
        "friends.viewProfileA11y": "查看{handle}的主页",
        "friends.openTwinA11y": "打开与{handle}的品味双子，匹配{score}%",

        // ── Friend profile (FriendProfileScreen) ──────────────────────────────
        "friendProfile.back": "← 好友",
        "friendProfile.following": "已关注",           // web profile.following
        "friendProfile.follow": "+ 关注",             // web profile.follow register
        "friendProfile.tasteTwin": "{score}% 品味双子",
        "friendProfile.seeMore": "· 查看更多 →",
        "friendProfile.openTwinA11y": "打开品味双子详情",
        "friendProfile.theirTop4": "他们的 TOP 4 · S 级",
        "friendProfile.mutual": "◉ {n} 位共同好友",
        "friendProfile.stubsPill": "{n} 张票根",

        // ── Taste twin (TwinScreen) ───────────────────────────────────────────
        // 叙述性句子（拼接的 Text，演示为主）保留英文。以下为界面框架 + 空态 + 韦恩图标签。
        "twin.shareCard": "↗ 分享卡片",               // web share.createCard register
        "twin.yourLibraries": "你们的片库",
        "twin.biggestFights": "最大分歧",
        "twin.recommendTo": "推荐给 {handle}",
        "twin.send3Recs": "发送 3 条推荐 →",
        "twin.spoolTasteTwin": "SPOOL · 品味双子",
        "twin.noSharedFilms": "还没有共同看过的片子。",
        "twin.rankMoreFillsIn": "再排几部，口味地图就会补全。",
        "twin.comeBackMath": "然后回来，我们帮你算一算。",
        "twin.noDisagreements": "还没有大的分歧。排更多来找找摩擦点。",
        "twin.nothingToRecommend": "还没有可推荐的，多排几部 S/A 级片子。",
        "twin.argue": "争论 →",
        "twin.youOnly": "只有你",
        "twin.filmsCount": "{n} 部",
        "twin.handleOnly": "只有 {handle}",
        "twin.bothLove": "都爱 ♡ {n}",
        "twin.sharedSoFar": "目前共同看过 {n} 部。",
        "twin.plentyMore": "还有很多可以比。",
        "twin.rankMoreShape": "再排几部就能看出轮廓。",

        // ── Stubs / memories (StubsScreen, StubDetail, StubShare) ─────────────
        // Ticket-DESIGN chrome (ADMIT ONE etc.) stays EN in AdmitStub. New zh
        // here, dash-free. {n}/{month} carry dynamic data.
        "stubs.myStubs": "我的票根",
        "stubs.tabStubs": "票根",
        "stubs.tabJournal": "日记",                   // web profile.tabJournal register
        "stubs.tapADay": "点某一天看那张票根 ↑",
        "stubs.lastWatched": "最近观看",
        "stubs.watchedCount": "看了{n}部",
        "stubs.emptyCollection": "这里还空着，去排点什么开始收集你的票根吧。",
        "stubs.signInToSee": "登录后查看你真实的票根。",
        "stubs.monthInLetters": "{month}，用文字记下。",
        "stubs.makeRecap": "🎞 生成{month}回顾",
        "stubs.recapNothing": "还没有内容。",
        "stubs.recapStacked": "这个月相当充实。",
        "stubs.recapSlow": "这个月有点慢。",
        "stubs.recapSolid": "这个月还不错。",
        "stubDetail.back": "← 四月",
        "stubDetail.share": "分享 ↗",
        "stubDetail.friendsWatched": "· 也看过的朋友 ·",
        "stubDetail.notes": "· 备注 ·",
        "stubShare.back": "← 返回",
        "stubShare.forYourStory": "放进你的快拍 ↓",
        "stubShare.ig": "↗ IG",
        "stubShare.tiktok": "↗ tiktok",
        "stubShare.save": "↗ 保存",
        "stubShare.postToFeed": "发到 spool 动态",
        "stubShare.comingSoon": "发到动态功能即将上线",

        // ── Journal list (JournalListView) ────────────────────────────────────
        "journal.searchPlaceholder": "搜索你的日记…",     // web journal.search register
        "journal.listEmpty": "还没有记录，去排点什么写点感受吧",
        "journal.nothingMatches": "没有匹配的内容",
        // Journal visibility labels REUSE web journal.vis* zh VERBATIM.
        "journal.visDefault": "默认",                  // web journal.visDefault
        "journal.visPublic": "公开",                   // web journal.visPublic
        "journal.visFriends": "好友",                  // web journal.visFriends
        "journal.visPrivate": "私密",                  // web journal.visPrivate

        // ── Journal composer (JournalComposer) ────────────────────────────────
        // Web journal.* zh reused where it maps (cited); rest new zh, dash-free.
        "composer.loading": "正在加载你的记录…",
        "composer.close": "× 关闭",
        "composer.title": "写点感受",
        "composer.subtitle": "你的日记",
        "composer.sectionMoment": "这一刻",
        "composer.reviewPlaceholder": "它触动了你什么？",
        "composer.containsSpoilers": "包含剧透",         // web journal.containsSpoilers
        "composer.sectionFeeling": "感受",
        "composer.moods": "心情",
        "composer.vibes": "氛围",                      // web journal.vibe register
        "composer.sectionDetails": "细节",
        "composer.favoriteMoments": "最爱时刻",         // web journal.favoriteMoments
        "composer.momentPlaceholder": "你喜欢的一个瞬间",
        "composer.addMoment": "添加时刻",               // web journal.addMoment register
        "composer.standoutPerformances": "亮眼表演",     // web journal.standoutPerformances
        "composer.asCharacter": "饰{character}",        // web stubs.asCharacter register
        "composer.actor": "演员",
        "composer.asOptional": "饰…（选填）",
        "composer.watchContext": "观看信息",            // web journal.watchContext
        "composer.locationPlaceholder": "你在哪里看的？",  // web journal.locationPlaceholder register
        "composer.platformNone": "无",
        "composer.platform": "平台",
        "composer.watchedWith": "和谁一起看",            // web journal.watchedWith register
        "composer.noFriendsToTag": "还没有可标记的好友",
        "composer.wasRewatch": "这是一次重看",
        "composer.rewatchPlaceholder": "这次有什么不一样？", // web journal.rewatchPlaceholder register
        "composer.sectionPrivate": "私密",
        "composer.privateHint": "只有你自己能看到",
        "composer.takeawayPlaceholder": "写给未来的自己…",  // web journal.takeawayPlaceholder register
        "composer.sectionPhotos": "照片",              // web journal.photos register
        "composer.addPhotos": "添加照片",
        "composer.photosMax": "最多 6 张照片",
        "composer.sectionVisibility": "可见性",          // web journal.visibility register
        "composer.defaultFollowsProfile": "默认跟随你的主页设置",
        "composer.saving": "保存中…",                   // web journal.saving register
        "composer.saveEntry": "保存记录 ✓",

        // ── Shelf / full list (FullListScreen + manage menus + notes editor) ──
        // re-rank reuses web detail.reRank zh; rest new zh, dash-free.
        "shelf.title": "我的片单",                    // web ranking.myCanon register
        "shelf.edit": "编辑",
        "shelf.done": "完成",                        // web journal.done register
        "shelf.loading": "正在加载你的片单…",
        "shelf.signInTitle": "登录后查看你的片单",
        "shelf.signInHint": "你的排名存在账号里。\n在主屏登录后把它们拉过来。",
        "shelf.emptyTitle": "还没有排名",
        "shelf.emptyHint": "去主页排一部片子，\n它会按等级显示在这里。",
        "shelf.rankSomething": "去排点什么 →",
        "shelf.moveToTier": "移到某等级",
        "shelf.editNotes": "编辑备注",
        "shelf.reRank": "重新排名",                   // web detail.reRank
        "shelf.delete": "删除",
        "shelf.cancel": "取消",
        "shelf.save": "保存",                        // web journal.save register
        "shelf.deleteTitle": "删除{title}？",
        "shelf.deleteTitleGeneric": "删除？",
        "shelf.deleteMessage": "这会把它从你的片单里移除，不会退回想看列表。",
        "shelf.refreshFailed": "刷新失败，检查一下网络",
        "shelf.yourNotes": "你的备注",
        "shelf.loadingNotes": "正在加载你的备注…",

        // ── Discover (DiscoverScreen) ─────────────────────────────────────────
        // Provenance chips REUSE web discover.chip.* zh VERBATIM. Section
        // headers/states reuse web discover.* zh where matching (cited); rest new
        // zh, dash-free.
        "discover.chip.friend": "朋友喜欢",             // web discover.chip.friend
        "discover.chip.taste": "你的口味",              // web discover.chip.taste
        "discover.chip.similar": "因为你排过",           // web discover.chip.similar
        "discover.chip.trending": "热门",               // web discover.chip.trending
        "discover.chip.variety": "换个口味",             // web discover.chip.variety
        "discover.chip.generic": "大众热门",             // web discover.chip.generic
        "discover.chip.new_release": "新片",             // web discover.chip.new_release
        "discover.fromFriends": "来自你的朋友",
        "discover.fromFriendsSub": "你关注的人喜欢的",
        "discover.trendingFriends": "朋友间的热门",
        "discover.trendingFriendsSub": "本月排名最多的",
        "discover.forYou": "为你推荐",                   // web discover.forYou
        "discover.forYouSub": "根据你的口味精选",         // web discover.forYouEngineHint
        "discover.refresh": "换一批",                    // web discover.refresh
        "discover.engineEmpty": "还没有推荐，先排几部电影来解锁",
        "discover.engineError": "推荐没加载出来",
        "discover.newReleases": "新片上映",              // web discover.newReleases
        "discover.newReleasesSub": "正在热映与流媒体上新",
        "discover.newReleasesEmpty": "暂无新片",
        "discover.newReleasesError": "新片加载失败",      // web discover.newReleasesError register
        "discover.loadFailed": "发现页没加载出来",
        "discover.followSomePeople": "去关注一些人",
        "discover.followSomePeopleSub": "关注几个人之后，这里会填满他们喜欢的内容",
        "discover.findFriends": "找朋友",
        "discover.quietTitle": "朋友们还没有新动态",
        "discover.quietSub": "等他们再排几部回来看看",
        "discover.save": "保存",
        "discover.saved": "已保存",
        "discover.saveA11y": "稍后再看",                 // web ceremony.saveForLater register
        "discover.savedA11y": "已保存稍后再看",
        "discover.savedToast": "已把{title}保存到稍后再看",
        "discover.saveFailedToast": "没能保存{title}，再试一次",

        // ── Watchlist (WatchlistScreen + WatchlistCard) ───────────────────────
        // rank it / remove reuse web watchlist.* zh; rest new zh, dash-free.
        "watchlist.title": "想看",                   // web nav.watchlist
        "watchlist.loadFailed": "想看列表没加载出来",
        "watchlist.tryAgain": "重试",
        "watchlist.emptyMovies": "还没有收藏电影，先收藏几部改天看",
        "watchlist.emptyShows": "还没有收藏剧集，先收藏一季改天看",
        "watchlist.emptyBooks": "还没有收藏书籍，先收藏一本改天读",
        "watchlist.rankIt": "去排名",                // web watchlist.rankIt
        "watchlist.remove": "删除",                  // web watchlist.remove
        "watchlist.rankA11y": "给{title}排名",
        "watchlist.removeA11y": "把{title}从想看里删除",
        "watchlist.added": "添加于{date}",

        // ── Tier labels/sublabels (Tier model) ────────────────────────────────
        // iOS-only copy. New zh, dash-free.
        "tier.labelS": "神作",
        "tier.labelA": "很喜欢",
        "tier.labelB": "还不错",
        "tier.labelC": "一般",
        "tier.labelD": "不行",
        "tier.subS": "上头，逢人就安利。",
        "tier.subA": "会想再看一遍。",
        "tier.subB": "看了不亏。",
        "tier.subC": "不太推荐。",
        "tier.subD": "别让我再看到它。",

        // ── Ranking ceremony (RankTier/H2H/Ceremony screens) ──────────────────
        // Web ceremony.skip reused; rest new zh, dash-free. {tier}/{round}/{rank}
        // carry dynamic content.
        "ceremony.back": "← 返回",
        "ceremony.backPill": "← 返回",
        "ceremony.step1": "第 1 步，共 3 步 · 凭直觉",
        "ceremony.step2Match": "第 2 步 · 第 {round} 组",
        "ceremony.step2Placed": "第 2 步 · 已定位",
        "ceremony.step2WarmingUp": "第 2 步 · 热身中",
        "ceremony.step3": "第 3 步，共 3 步 · 仪式",
        "ceremony.howDidItFeel": "这个等级感觉如何？",   // web ceremony.tierFeel wording
        "ceremony.justWatched": "刚看完",
        "ceremony.whichHitHarder": "哪部更打动你？",
        "ceremony.placingWithin": "定位在",
        "ceremony.tierSuffix": "{tier}级",
        "ceremony.vs": "对比",
        "ceremony.yourTierRank": "你的{tier}级 · 第{rank}名",
        "ceremony.tie": "= 平局",
        "ceremony.haventSeen": "? 没看过",
        "ceremony.skip": "跳过",                    // web ceremony.skip
        "ceremony.readingTaste": "正在读取你的口味…",
        "ceremony.placed": "已定位 ✓",
        "ceremony.rankIn": "第{rank}名",
        "ceremony.tapToPick": "点这个",
        "ceremony.tierShelf": "{tier}级书架",
        "ceremony.new": "新",                       // web ceremony.new
        "ceremony.bottleItUp": "把这一刻封存起来。",
        "ceremony.pickMoodsHint": "最多选 3 个氛围 · 留一句话记住它",
        "ceremony.printStub": "打印我的票根 →",
        "ceremony.lineToRemember": "留一句话记住它",

        // ── Printed stub (RankPrintedScreen) ──────────────────────────────────
        "printed.ready": "你的票根做好了。",
        "printed.collectionNo": "你收藏中的第 {no} 张",
        "printed.rankInTier": "{tier}级第{rank}名",
        "printed.shareStory": "↗ 分享到快拍",
        "printed.savePNG": "保存图片",
        "printed.postToFeed": "发到动态 ✓",
        "printed.writeMore": "再多写点 →",
        "printed.keepPrivate": "保持私密 →",

        // ── Rank entry (RankEntryScreen + RankEntryModel search) ──────────────
        // Web ceremony.* reused where the copy matches (cited); rest new zh,
        // dash-free, web lowercase-neutral register.
        "rankEntry.makeStub": "来给你做张票根吧。",
        "rankEntry.justWatched": "刚看完？",
        "rankEntry.justRead": "刚读完？",
        "rankEntry.back": "← 返回",
        "rankEntry.cancel": "取消 ✕",
        "rankEntry.modeMovies": "电影",              // web nav.movies register
        "rankEntry.modeTV": "剧集",                  // web nav.tv register
        "rankEntry.modeBooks": "书籍",               // web nav.books register
        "rankEntry.searchFilms": "搜索电影…",
        "rankEntry.searchShows": "搜索剧集…",
        "rankEntry.searchBooks": "搜索书籍…",
        "rankEntry.sectionMatches": "匹配结果",
        "rankEntry.sectionDemo": "示例结果",
        "rankEntry.sectionShows": "剧集",
        "rankEntry.sectionBooks": "书籍",
        "rankEntry.basedOnTaste": "根据你的口味",      // web ceremony.basedOnTaste
        "rankEntry.popularNow": "当下热门",           // web ceremony.popularNow
        "rankEntry.refresh": "换一批",               // web ceremony.refresh
        "rankEntry.suggestionsLoadFailed": "推荐没加载出来",
        "rankEntry.retry": "重试",
        "rankEntry.searchShowHint": "搜索一部剧来给某一季排名",
        "rankEntry.seasonsLoadFailed": "分季没加载出来，返回重试",
        "rankEntry.pickSeason": "选一季",
        "rankEntry.whichSeason": "哪一季？",
        "rankEntry.loadingSeasons": "分季加载中…",
        "rankEntry.searching": "搜索中…",
        "rankEntry.noResults": "未找到结果",          // web search.noResults
        "rankEntry.signInShows": "登录后给剧集排名",
        "rankEntry.signInBooks": "登录后给书籍排名",
        "rankEntry.signInHint": "剧集和书籍会存到你的账号，先登录一下。",
        "rankEntry.signIn": "登录",                   // web auth.signIn register
        "rankEntry.onList": "已在片单",
        "rankEntry.tvYear": "剧集 · {year}",
        "rankEntry.episodeSingular": "{n} 集",
        "rankEntry.episodePlural": "{n} 集",
        "rankEntry.ranked": "已排名",

        // App chrome (SpoolAppRoot). Preview-mode banner (iOS-only). Recast
        // without an em dash per the owner-voice rule; lowercase register to
        // match the web zh toast copy.
        "app.previewBanner": "预览模式，登录后才能保存你的排名",

        // Settings → language row (C6-iOS Task 2). Row label is faithful zh
        // (语言 = "language"); the two option glyphs stay 'EN' / '中文' identical
        // to en so the picker names each language in its own script on both
        // surfaces (matches web `LanguageToggle`).
        "settings.language": "语言",
        "settings.languageEnglish": "EN",
        "settings.languageChinese": "中文",

        // Settings sheet (SettingsScreen). iOS-only surface. Web zh reused where
        // the copy matches a web key (cited); the rest is new zh in the web
        // lowercase-neutral register, dash-free.
        "settings.close": "关闭",                    // web detail.close
        "settings.title": "设置",
        "settings.sectionAccount": "账号",
        "settings.editProfile": "编辑资料",           // web profile.editProfile
        "settings.signedIn": "已登录",
        "settings.profileNotLoadedRetry": "资料还没加载出来，下拉重试",
        "settings.profileNotLoaded": "资料还没加载出来",
        "settings.previewMode": "预览模式",
        "settings.previewModeHint": "在主屏登录后才能保存你的排名",
        "settings.sectionAppearance": "外观",
        "settings.themeSystem": "跟随系统",
        "settings.themePaper": "纸张",
        "settings.themeDark": "深色",
        "settings.sectionPrivacy": "隐私",           // web landing.privacy register
        "settings.profileVisibility": "主页可见性",    // web public.profileVisibility
        "settings.visPublic": "公开",                // web public.visibilityPublic
        "settings.visFriends": "好友",                // web journal.visFriends
        "settings.visPrivate": "私密",                // web public.visibilityPrivate
        "settings.visibilityExploreHint": "公开后你的动态会出现在探索里",
        "settings.visibilityA11y": "{label}可见性",
        "settings.sectionAbout": "关于",             // web landing.about
        "settings.privacy": "隐私",                  // web landing.privacy
        "settings.terms": "条款",                    // web landing.terms
        "settings.version": "版本",
        "settings.signingOut": "退出中…",
        "settings.signOut": "退出登录",
    ]
}
