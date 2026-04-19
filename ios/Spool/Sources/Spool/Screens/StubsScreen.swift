import SwiftUI

public struct StubsScreen: View {
    public var onOpenDetail: (WatchedDay) -> Void

    public init(onOpenDetail: @escaping (WatchedDay) -> Void = { _ in }) {
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                SpoolHeader(title: "my stubs") {
                    HStack(spacing: 6) {
                        SpoolPill("2026", size: .sm)
                        SpoolPill("april", active: true, size: .sm)
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("14 WATCHED · 3 RE-WATCHES")
                            .font(SpoolFonts.mono(10))
                            .tracking(2)
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .padding(.top, 2)

                        FilmStripCalendar(onTap: onOpenDetail)
                            .padding(.top, 10)

                        SpoolThemeReader { t, _ in
                            Text("tap a day to see the stub ↑")
                                .font(SpoolFonts.script(13))
                                .foregroundStyle(t.inkSoft)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 6)
                        }

                        Text("LAST WATCHED")
                            .font(SpoolFonts.mono(10))
                            .tracking(2)
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .padding(.top, 16)

                        AdmitStub(
                            movie: .init(id: "past-lives", title: "Past Lives", year: 2023,
                                         director: "celine song", seed: 0),
                            tier: .S, line: "cried on the 6 train.",
                            moods: ["tender","devastating"],
                            date: "APR · 18 · 2026", stubNo: "#0127",
                            compact: true
                        )
                        .rotationEffect(.degrees(-0.5))
                        .padding(.top, 6)

                        MonthRecapBox().padding(.top, 16)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 110)
                }
            }
        }
    }
}

struct FilmStripCalendar: View {
    let onTap: (WatchedDay) -> Void
    let days: Int = 30

    private var byDay: [Int: WatchedDay] {
        Dictionary(uniqueKeysWithValues: SpoolData.aprilWatched.map { ($0.day, $0) })
    }

    var body: some View {
        SpoolThemeReader { t, mode in
            VStack(spacing: 4) {
                SprocketRow()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                    ForEach(1...days, id: \.self) { day in
                        let w = byDay[day]
                        Button { if let w = w { onTap(w) } } label: {
                            VStack {
                                Text("\(day)")
                                    .font(SpoolFonts.mono(7))
                                    .foregroundStyle(t.cream.opacity(0.6))
                                Spacer(minLength: 0)
                                if let w = w {
                                    Text(w.tier.rawValue)
                                        .font(SpoolFonts.serif(9))
                                        .foregroundStyle(t.cream)
                                        .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 1)
                                }
                            }
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(2.0/3.0, contentMode: .fit)
                            .background((w != nil) ? tierColor(w!.tier, mode: mode) : Color(hex: 0x2A2A2A))
                            .cornerRadius(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(w == nil)
                    }
                }
                SprocketRow()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(t.ink)
            .cornerRadius(6)
        }
    }
}

struct SprocketRow: View {
    var body: some View {
        SpoolThemeReader { t, _ in
            HStack {
                ForEach(0..<14, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(t.cream)
                        .frame(width: 6, height: 6)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct MonthRecapBox: View {
    var body: some View {
        SpoolThemeReader { t, mode in
            VStack(alignment: .leading, spacing: 0) {
                Text("april, in letters.")
                    .font(SpoolFonts.serif(20))
                    .foregroundStyle(t.ink)
                Text("a pretty stacked month.")
                    .font(SpoolFonts.script(20))
                    .foregroundStyle(t.inkSoft)
                    .padding(.top, 4)

                HStack(spacing: 10) {
                    ForEach(tierCounts(), id: \.tier) { item in
                        VStack(spacing: -4) {
                            TierStamp(tier: item.tier, size: 34)
                            Text("× \(item.count)")
                                .font(SpoolFonts.mono(11))
                                .foregroundStyle(t.inkSoft)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 12)

                HStack {
                    Spacer()
                    SpoolPill("🎞 make april recap", filled: true, size: .sm)
                    Spacer()
                }
                .padding(.top, 10)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(t.ink)
            )
        }
    }

    struct TierCount { let tier: Tier; let count: Int }
    private func tierCounts() -> [TierCount] {
        [.init(tier: .S, count: 3), .init(tier: .A, count: 5),
         .init(tier: .B, count: 4),          .init(tier: .C, count: 1), .init(tier: .D, count: 0)]
    }
}

#Preview {
    StubsScreen(onOpenDetail: { _ in }).spoolMode(.paper)
}
