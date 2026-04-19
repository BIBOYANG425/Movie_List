import SwiftUI

/// Dark "theater" palette used by the Cold Open and Season screens.
/// Ported from the HTML prototype's inline constants — these sit outside the
/// regular paper/dark token sets because they're onboarding-specific.
public enum OnbTheater {
    public static let bg        = Color(hex: 0x0E0E10)
    public static let cream     = Color(hex: 0xF2ECDC)
    public static let gold      = Color(hex: 0xF5C33B)
    public static let curtainA  = Color(red: 180/255, green: 40/255,  blue: 35/255, opacity: 0.55)
    public static let curtainB  = Color(red: 120/255, green: 25/255,  blue: 22/255, opacity: 0.65)
}

/// Progress dots at the top of every onboarding screen.
struct OnbDots: View {
    let step: Int
    var total: Int = 9

    var body: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(i <= step ? t.ink : t.rule)
                        .frame(width: i == step ? 18 : 6, height: 6)
                        .animation(.easeInOut(duration: 0.2), value: step)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        }
    }
}

/// Sticky bottom CTA used on screens 02–07. Lives as an overlay so content
/// above can scroll without moving the button.
struct OnbFoot: View {
    let label: String
    var disabled: Bool = false
    var onNext: () -> Void
    var onSkip: (() -> Void)? = nil

    var body: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 6) {
                Button(action: { if !disabled { onNext() } }) {
                    Text(label)
                        .font(SpoolFonts.serif(18))
                        .tracking(0.5)
                        .foregroundStyle(disabled ? t.inkSoft : t.cream)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                        .background(
                            Capsule().fill(disabled ? Color.clear : t.ink)
                        )
                        .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
                        .shadow(color: .black.opacity(disabled ? 0 : 0.15),
                                radius: 0, x: 0, y: 3)
                        .opacity(disabled ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(disabled)

                if let onSkip {
                    Button("skip", action: onSkip)
                        .font(SpoolFonts.hand(12))
                        .foregroundStyle(t.inkSoft)
                        .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 40)
        }
    }
}

/// Marquee bulb row used in Cold Open.
struct MarqueeBulbs: View {
    var count: Int = 14
    var body: some View {
        HStack {
            ForEach(0..<count, id: \.self) { _ in
                Circle()
                    .fill(OnbTheater.gold)
                    .frame(width: 5, height: 5)
                    .shadow(color: OnbTheater.gold.opacity(0.6), radius: 3)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
    }
}
