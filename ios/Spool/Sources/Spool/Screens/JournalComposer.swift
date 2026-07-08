import SwiftUI
import PhotosUI

/// The full manual journal COMPOSER (plan Task 6) — a single scrolling paper
/// sheet (`SpoolScreen` idiom) over a `JournalDraftModel`. It renders NOTHING
/// editable until the model's probe resolves (`.loading` → `.ready`), so a save
/// can never wipe a not-yet-hydrated `personal_takeaway` (the model enforces
/// this by construction; the view just shows a spinner meanwhile).
///
/// Collapsible sections, top to bottom:
///  - **the moment** — review text editor + spoiler toggle
///  - **the feeling** — mood tags [23] + vibe tags [11] as selectable stamps
///    (labels from `JournalConstants`)
///  - **the details** — favorite moments (≤5), standout performances (add /
///    remove), watch context (location / platform picker [13] / with-whom
///    friend picker writing `watchedWithUserIds`), rewatch toggle + note
///  - **private** — personal takeaway, labeled owner-only
///  - **photos** — PHPicker up to 6 (the sanctioned PhotosUI use), thumbnails
///    via the model's photo paths + `PhotoStore` signing, remove
///  - **visibility** — public / friends / private / default picker ("default" =
///    nil override, "default follows your profile")
///
/// The Save button is disabled while `model.saving`. Photos flow through the
/// model's `addPhoto`/`removePhoto` (which mint a side-effect-free entry when
/// needed), never touching storage directly here.
public struct JournalComposer: View {
    @ObservedObject private var model: JournalDraftModel
    private let onClose: () -> Void
    /// Provide the friend list for the with-whom picker. Injected so previews
    /// render without a live client; defaults to the signed-in user's follows.
    private let loadFriends: () async -> [FollowedProfile]

    // PHPicker selection buffer — the ONLY UIKit-adjacent surface (PhotosUI is
    // the sanctioned exception). Cleared as each item's bytes are handed to the
    // model.
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var friends: [FollowedProfile] = []

    // Collapsible section state — the "the moment" section starts open.
    @State private var openSections: Set<Section> = [.moment]

    public init(
        model: JournalDraftModel,
        onClose: @escaping () -> Void,
        loadFriends: @escaping () async -> [FollowedProfile] = {
            guard let me = await SpoolClient.currentUserID() else { return [] }
            return (try? await FollowRepository.shared.getFollowing(userID: me)) ?? []
        }
    ) {
        self.model = model
        self.onClose = onClose
        self.loadFriends = loadFriends
    }

    enum Section: Hashable { case moment, feeling, details, priv, photos, visibility }

    public var body: some View {
        SpoolScreen {
            if model.phase == .loading {
                loadingState
            } else {
                readyState
            }
        }
        .task { friends = await loadFriends() }
    }

    // MARK: - Loading

    private var loadingState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 12) {
                ProgressView()
                    .tint(t.ink)
                Text("loading your entry…")
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(t.inkSoft)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Ready

    private var readyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 0) {
                topBar(t: t)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        titleHeader(t: t)
                        momentSection(t: t)
                        feelingSection(t: t)
                        detailsSection(t: t)
                        privateSection(t: t)
                        photosSection(t: t)
                        visibilitySection(t: t)
                        if let err = model.inlineError {
                            Text(err)
                                .font(SpoolFonts.hand(13))
                                .foregroundStyle(t.accent)
                        }
                        saveButton(t: t)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 60)
                }
            }
        }
    }

    // MARK: top bar

    @ViewBuilder
    private func topBar(t: SpoolPalette) -> some View {
        HStack {
            Button("× close", action: onClose)
                .font(SpoolFonts.hand(15))
                .foregroundStyle(t.inkSoft)
            Spacer()
            Text("write about it")
                .font(SpoolFonts.serif(18))
                .foregroundStyle(t.ink)
            Spacer()
            // Balance the leading close button so the title stays centered.
            Text("× close").font(SpoolFonts.hand(15)).foregroundStyle(.clear)
        }
        .padding(.horizontal, 18)
        .padding(.top, 50)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func titleHeader(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.draft.title)
                .font(SpoolFonts.serif(24))
                .foregroundStyle(t.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("your journal entry")
                .font(SpoolFonts.mono(10))
                .tracking(2)
                .foregroundStyle(t.inkSoft)
        }
    }

    // MARK: - the moment

    @ViewBuilder
    private func momentSection(t: SpoolPalette) -> some View {
        sectionCard(.moment, title: "the moment", t: t) {
            VStack(alignment: .leading, spacing: 10) {
                paperEditor(text: $model.draft.reviewText, placeholder: "what did it stir in you?", t: t)
                Toggle(isOn: $model.draft.containsSpoilers) {
                    Text("contains spoilers")
                        .font(SpoolFonts.hand(14))
                        .foregroundStyle(t.ink)
                }
                .tint(t.accent)
            }
        }
    }

    // MARK: - the feeling

    @ViewBuilder
    private func feelingSection(t: SpoolPalette) -> some View {
        sectionCard(.feeling, title: "the feeling", t: t) {
            VStack(alignment: .leading, spacing: 12) {
                stampLabel("moods", t: t)
                stampGrid(
                    ids: JournalConstants.moodTagIDs,
                    label: JournalConstants.moodLabel,
                    selected: model.draft.moodTags,
                    t: t
                ) { id in toggleMood(id) }

                stampLabel("vibes", t: t)
                stampGrid(
                    ids: JournalConstants.vibeTagIDs,
                    label: JournalConstants.vibeLabel,
                    selected: model.draft.vibeTags,
                    t: t
                ) { id in toggleVibe(id) }
            }
        }
    }

    // MARK: - the details

    @ViewBuilder
    private func detailsSection(t: SpoolPalette) -> some View {
        sectionCard(.details, title: "the details", t: t) {
            VStack(alignment: .leading, spacing: 16) {
                favoriteMoments(t: t)
                standoutPerformances(t: t)
                watchContext(t: t)
                rewatch(t: t)
            }
        }
    }

    @ViewBuilder
    private func favoriteMoments(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            stampLabel("favorite moments", t: t)
            ForEach(Array(model.draft.favoriteMoments.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: 8) {
                    TextField("a moment you loved", text: momentBinding(idx))
                        .font(SpoolFonts.hand(14))
                        .foregroundStyle(t.ink)
                        .textFieldStyle(.plain)
                    Button {
                        model.draft.favoriteMoments = JournalComposerLogic.removeMoment(model.draft.favoriteMoments, at: idx)
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: 15)).foregroundStyle(t.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.rule, lineWidth: 1))
            }
            if model.draft.favoriteMoments.count < JournalConstants.journalMaxMoments {
                Button {
                    model.draft.favoriteMoments = JournalComposerLogic.addMoment(model.draft.favoriteMoments)
                } label: {
                    Label("add a moment", systemImage: "plus")
                        .font(SpoolFonts.hand(13))
                        .foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @State private var newPerfName: String = ""
    @State private var newPerfCharacter: String = ""

    @ViewBuilder
    private func standoutPerformances(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            stampLabel("standout performances", t: t)
            ForEach(Array(model.draft.standoutPerformances.enumerated()), id: \.offset) { idx, perf in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(perf.name).font(SpoolFonts.hand(14)).foregroundStyle(t.ink)
                        if let c = perf.character, !c.isEmpty {
                            Text("as \(c)").font(SpoolFonts.mono(10)).foregroundStyle(t.inkSoft)
                        }
                    }
                    Spacer()
                    Button {
                        model.draft.standoutPerformances = JournalComposerLogic.removePerformance(model.draft.standoutPerformances, at: idx)
                    } label: {
                        Image(systemName: "minus.circle").font(.system(size: 15)).foregroundStyle(t.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.rule, lineWidth: 1))
            }
            HStack(spacing: 8) {
                TextField("actor", text: $newPerfName)
                    .font(SpoolFonts.hand(14)).foregroundStyle(t.ink).textFieldStyle(.plain)
                TextField("as… (optional)", text: $newPerfCharacter)
                    .font(SpoolFonts.hand(14)).foregroundStyle(t.inkSoft).textFieldStyle(.plain)
                Button {
                    model.draft.standoutPerformances = JournalComposerLogic.addPerformance(
                        model.draft.standoutPerformances, name: newPerfName, character: newPerfCharacter
                    )
                    newPerfName = ""; newPerfCharacter = ""
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 17)).foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
                .disabled(newPerfName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.rule, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func watchContext(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            stampLabel("watch context", t: t)
            // location
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 13)).foregroundStyle(t.inkSoft)
                TextField("where did you watch?", text: $model.draft.watchedLocation)
                    .font(SpoolFonts.hand(14)).foregroundStyle(t.ink).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.rule, lineWidth: 1))

            // platform picker
            Menu {
                Button("none") { model.draft.watchedPlatform = nil }
                ForEach(JournalConstants.platformIDs, id: \.self) { id in
                    Button(JournalConstants.platformLabel(id)) { model.draft.watchedPlatform = id }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tv").font(.system(size: 13)).foregroundStyle(t.inkSoft)
                    Text(model.draft.watchedPlatform.map(JournalConstants.platformLabel) ?? "platform")
                        .font(SpoolFonts.hand(14))
                        .foregroundStyle(model.draft.watchedPlatform == nil ? t.inkSoft : t.ink)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(t.inkSoft)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.rule, lineWidth: 1))
            }

            // with whom
            withWhomPicker(t: t)
        }
    }

    @ViewBuilder
    private func withWhomPicker(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.2").font(.system(size: 13)).foregroundStyle(t.inkSoft)
                Text("watched with")
                    .font(SpoolFonts.hand(13)).foregroundStyle(t.inkSoft)
            }
            if friends.isEmpty {
                Text("no friends to tag yet")
                    .font(SpoolFonts.mono(10)).foregroundStyle(t.inkSoft)
            } else {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(friends) { f in
                        let picked = model.draft.watchedWithUserIds.contains(f.profile.id)
                        Button { toggleFriend(f.profile.id) } label: {
                            Text(f.profile.handle)
                                .font(SpoolFonts.hand(12))
                                .foregroundStyle(picked ? t.cream : t.ink)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(picked ? t.ink : Color.clear))
                                .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rewatch(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.draft.isRewatch) {
                Text("this was a rewatch")
                    .font(SpoolFonts.hand(14)).foregroundStyle(t.ink)
            }
            .tint(t.accent)
            if model.draft.isRewatch {
                TextField("what changed this time?", text: $model.draft.rewatchNote)
                    .font(SpoolFonts.hand(14)).foregroundStyle(t.ink).textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.rule, lineWidth: 1))
            }
        }
    }

    // MARK: - private

    @ViewBuilder
    private func privateSection(t: SpoolPalette) -> some View {
        sectionCard(.priv, title: "private", t: t) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(t.inkSoft)
                    Text("only you will ever see this")
                        .font(SpoolFonts.mono(10)).tracking(1).foregroundStyle(t.inkSoft)
                }
                paperEditor(text: $model.draft.personalTakeaway, placeholder: "a note to your future self…", t: t)
            }
        }
    }

    // MARK: - photos

    @ViewBuilder
    private func photosSection(t: SpoolPalette) -> some View {
        sectionCard(.photos, title: "photos", t: t) {
            VStack(alignment: .leading, spacing: 10) {
                if !model.draft.photoPaths.isEmpty {
                    photoThumbs(t: t)
                }
                if model.draft.photoPaths.count < JournalConstants.journalMaxPhotos {
                    PhotosPicker(
                        selection: $pickedItems,
                        maxSelectionCount: JournalConstants.journalMaxPhotos - model.draft.photoPaths.count,
                        matching: .images
                    ) {
                        Label("add photos", systemImage: "camera")
                            .font(SpoolFonts.hand(14))
                            .foregroundStyle(t.accent)
                    }
                    .onChange(of: pickedItems) { items in
                        Task { await ingest(items) }
                    }
                } else {
                    Text("6 photos max")
                        .font(SpoolFonts.mono(10)).foregroundStyle(t.inkSoft)
                }
            }
        }
    }

    @ViewBuilder
    private func photoThumbs(t: SpoolPalette) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.draft.photoPaths, id: \.self) { path in
                    ZStack(alignment: .topTrailing) {
                        signedThumb(path: path, t: t)
                        Button { model.removePhoto(path: path) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, t.ink)
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func signedThumb(path: String, t: SpoolPalette) -> some View {
        ComposerPhotoThumb(path: path, t: t)
    }

    // MARK: - visibility

    @ViewBuilder
    private func visibilitySection(t: SpoolPalette) -> some View {
        sectionCard(.visibility, title: "visibility", t: t) {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(JournalComposerLogic.visibilityOptions, id: \.label) { opt in
                        let picked = model.draft.visibilityOverride == opt.value
                        Button { model.draft.visibilityOverride = opt.value } label: {
                            Text(opt.label)
                                .font(SpoolFonts.hand(13))
                                .foregroundStyle(picked ? t.cream : t.ink)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Capsule().fill(picked ? t.ink : Color.clear))
                                .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if model.draft.visibilityOverride == nil {
                    Text("default follows your profile")
                        .font(SpoolFonts.mono(10)).foregroundStyle(t.inkSoft)
                }
            }
        }
    }

    // MARK: - save

    @ViewBuilder
    private func saveButton(t: SpoolPalette) -> some View {
        HStack {
            Spacer()
            SpoolPill(model.saving ? "saving…" : "save entry ✓", filled: true) {
                Task {
                    if await model.save() != nil { onClose() }
                }
            }
            .disabled(model.saving)
            .opacity(model.saving ? 0.5 : 1)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - shared section chrome

    @ViewBuilder
    private func sectionCard<C: View>(
        _ section: Section, title: String, t: SpoolPalette,
        @ViewBuilder content: () -> C
    ) -> some View {
        let open = openSections.contains(section)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { openSections.remove(section) } else { openSections.insert(section) }
            } label: {
                HStack {
                    Text(title)
                        .font(SpoolFonts.serif(18))
                        .foregroundStyle(t.ink)
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.inkSoft)
                }
            }
            .buttonStyle(.plain)
            if open {
                content()
                    .padding(.top, 12)
            }
        }
        .padding(14)
        .background(t.cream2)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.rule, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func stampLabel(_ s: String, t: SpoolPalette) -> some View {
        Text(s.uppercased())
            .font(SpoolFonts.mono(9)).tracking(2)
            .foregroundStyle(t.inkSoft)
    }

    @ViewBuilder
    private func stampGrid(
        ids: [String], label: @escaping (String) -> String, selected: [String],
        t: SpoolPalette, toggle: @escaping (String) -> Void
    ) -> some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(ids, id: \.self) { id in
                let picked = selected.contains(id)
                Button { toggle(id) } label: {
                    Text(label(id).lowercased())
                        .font(SpoolFonts.hand(13))
                        .foregroundStyle(picked ? t.cream : t.ink)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(picked ? t.ink : Color.clear))
                        .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func paperEditor(text: Binding<String>, placeholder: String, t: SpoolPalette) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .padding(.top, 8).padding(.leading, 5)
            }
            TextEditor(text: text)
                .font(SpoolFonts.hand(15))
                .foregroundStyle(t.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90)
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.rule, lineWidth: 1))
    }

    // MARK: - mutation helpers

    private func momentBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { idx < model.draft.favoriteMoments.count ? model.draft.favoriteMoments[idx] : "" },
            set: { v in if idx < model.draft.favoriteMoments.count { model.draft.favoriteMoments[idx] = v } }
        )
    }

    private func toggleMood(_ id: String) {
        if let i = model.draft.moodTags.firstIndex(of: id) { model.draft.moodTags.remove(at: i) }
        else { model.draft.moodTags.append(id) }
    }

    private func toggleVibe(_ id: String) {
        if let i = model.draft.vibeTags.firstIndex(of: id) { model.draft.vibeTags.remove(at: i) }
        else { model.draft.vibeTags.append(id) }
    }

    private func toggleFriend(_ id: UUID) {
        if let i = model.draft.watchedWithUserIds.firstIndex(of: id) { model.draft.watchedWithUserIds.remove(at: i) }
        else { model.draft.watchedWithUserIds.append(id) }
    }

    private func ingest(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard model.draft.photoPaths.count < JournalConstants.journalMaxPhotos else { break }
            if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = JournalComposerLogic.photoExtension(
                    fromIdentifier: item.supportedContentTypes.first?.preferredFilenameExtension
                        ?? item.supportedContentTypes.first?.identifier
                )
                await model.addPhoto(data: data, ext: ext)
            }
        }
        pickedItems = []
    }
}

// MARK: - Photo thumbnail (owner's own photo, signed on appear)

/// One composer photo thumbnail: mints a fresh signed URL for the stored path on
/// appear (owner-only this cycle). Split into its own view so the `@State` for
/// the resolved URL doesn't churn the whole composer.
private struct ComposerPhotoThumb: View {
    let path: String
    let t: SpoolPalette
    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rule, lineWidth: 1))
        .task(id: path) { url = try? await PhotoStore.shared.signedURL(forPath: path) }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 18))
            .foregroundStyle(t.inkSoft)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(t.cream3)
    }
}

// MARK: - Pure presentation logic (tested — JournalComposerLogicTests)

/// The network-free / UIKit-free decisions the composer leans on. Extracted so
/// the moment/performance/photo/visibility rules are unit-tested without
/// building the SwiftUI view. Mirrors web `JournalConversation.tsx`
/// (`addMoment`/`removeMoment` clamped at `JOURNAL_MAX_MOMENTS`, standout
/// `personId` by index).
public enum JournalComposerLogic {

    /// Append a blank moment, clamped at `journalMaxMoments` (web `addMoment`).
    public static func addMoment(_ moments: [String]) -> [String] {
        guard moments.count < JournalConstants.journalMaxMoments else { return moments }
        return moments + [""]
    }

    /// Remove the moment at `index` (out-of-range → unchanged; web `removeMoment`).
    public static func removeMoment(_ moments: [String], at index: Int) -> [String] {
        guard moments.indices.contains(index) else { return moments }
        var out = moments
        out.remove(at: index)
        return out
    }

    /// Mint a standout performance, assigning `personId` by index (mirrors web's
    /// AI path `personId: i`). A blank name is ignored; a blank character trims
    /// to nil. iOS has no TMDB cast selector this cycle — manual entry.
    public static func addPerformance(
        _ perfs: [StandoutPerformance], name: String, character: String?
    ) -> [StandoutPerformance] {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return perfs }
        let trimmedChar = character?.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = perfs
        out.append(StandoutPerformance(
            personId: perfs.count,
            name: trimmedName,
            character: (trimmedChar?.isEmpty ?? true) ? nil : trimmedChar
        ))
        return out
    }

    /// Remove the performance at `index` (out-of-range → unchanged).
    public static func removePerformance(_ perfs: [StandoutPerformance], at index: Int) -> [StandoutPerformance] {
        guard perfs.indices.contains(index) else { return perfs }
        var out = perfs
        out.remove(at: index)
        return out
    }

    /// Normalize a PHPicker content-type identifier / filename extension to a
    /// storage-path extension: lowercased, dot-stripped, defaulting to `jpg`
    /// (the web upload default) for anything unrecognized.
    public static func photoExtension(fromIdentifier identifier: String?) -> String {
        guard let raw = identifier?.lowercased() else { return "jpg" }
        // A UTType identifier like "public.jpeg" → its last dot-segment.
        let candidate = raw.split(separator: ".").last.map(String.init) ?? raw
        let known: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp"]
        return known.contains(candidate) ? candidate : "jpg"
    }

    /// The visibility picker options in display order: default (nil override)
    /// first, then public / friends / private.
    public static let visibilityOptions: [(label: String, value: JournalVisibility?)] = [
        ("default", nil),
        ("public", .pub),
        ("friends", .friends),
        ("private", .priv),
    ]

    /// The label for a visibility value (nil = "default").
    public static func visibilityLabel(_ value: JournalVisibility?) -> String {
        switch value {
        case .none: return "default"
        case .pub: return "public"
        case .friends: return "friends"
        case .priv: return "private"
        }
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func previewModel(
    seed: JournalRow?, phase ready: Bool = true, saving: Bool = false
) -> JournalDraftModel {
    let model = JournalDraftModel(
        probeOwnEntry: { _ in seed },
        seed: seed,
        resolveRatingTier: { _ in "A" },
        upsert: { p in
            JournalRow(
                id: UUID(), user_id: p.user_id, tmdb_id: p.tmdb_id, title: p.title,
                poster_url: p.poster_url, rating_tier: p.rating_tier, review_text: p.review_text,
                contains_spoilers: p.contains_spoilers, mood_tags: p.mood_tags, vibe_tags: p.vibe_tags,
                favorite_moments: p.favorite_moments, standout_performances: p.standout_performances,
                watched_date: p.watched_date, watched_location: p.watched_location,
                watched_with_user_ids: p.watched_with_user_ids, watched_platform: p.watched_platform,
                is_rewatch: p.is_rewatch, rewatch_note: p.rewatch_note, personal_takeaway: p.personal_takeaway,
                photo_paths: p.photo_paths, visibility_override: p.visibility_override,
                like_count: 0, created_at: ""
            )
        },
        uploadPhoto: { _, _, _, _ in "a/b/0.jpg" },
        fetchProfileVisibility: { "friends" },
        emitReviewEvent: { _ in }, emitJournalTag: { _ in },
        currentUserID: { UUID() }
    )
    if ready {
        // Populate the draft + flip to .ready for the preview (a synchronous
        // stand-in for openForEntry, which previews can't await).
        Task { await model.openForEntry(
            tmdbId: seed?.tmdb_id ?? "603",
            title: seed?.title ?? "The Matrix",
            posterUrl: nil, seed: seed
        ) }
    }
    return model
}

private func prefilledSeed(visibility: String?) -> JournalRow {
    JournalRow(
        id: UUID(), user_id: UUID(), tmdb_id: "603", title: "In the Mood for Love",
        poster_url: nil, rating_tier: "S",
        review_text: "cried on the 6 train. wong kar-wai understood longing.",
        contains_spoilers: false, mood_tags: ["moved", "melancholy"], vibe_tags: ["date_night"],
        favorite_moments: ["the noodle stall", "the hotel corridor"],
        standout_performances: [StandoutPerformance(personId: 0, name: "Tony Leung", character: "Chow")],
        watched_date: "2000-09-29", watched_location: "Metrograph", watched_with_user_ids: [],
        watched_platform: "theater", is_rewatch: true, rewatch_note: "hit harder this time",
        personal_takeaway: "trust the ache.", photo_paths: [], visibility_override: visibility,
        like_count: 0, created_at: ""
    )
}

#Preview("composer · fresh") {
    JournalComposer(model: previewModel(seed: nil), onClose: {}, loadFriends: { [] })
        .spoolMode(.paper)
}

#Preview("composer · loading") {
    JournalComposer(model: previewModel(seed: nil, phase: false), onClose: {}, loadFriends: { [] })
        .spoolMode(.paper)
}

#Preview("composer · prefilled (private)") {
    JournalComposer(model: previewModel(seed: prefilledSeed(visibility: "private")),
                    onClose: {}, loadFriends: { [] })
        .spoolMode(.paper)
}

#Preview("composer · prefilled (public)") {
    JournalComposer(model: previewModel(seed: prefilledSeed(visibility: "public")),
                    onClose: {}, loadFriends: { [] })
        .spoolMode(.paper)
}

#Preview("composer · prefilled (default)") {
    JournalComposer(model: previewModel(seed: prefilledSeed(visibility: nil)),
                    onClose: {}, loadFriends: { [] })
        .spoolMode(.dark)
}
#endif
