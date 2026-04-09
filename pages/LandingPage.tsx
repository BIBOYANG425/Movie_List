import React, { useState, useEffect, useRef } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import { useTranslation } from "../contexts/LanguageContext";
import SpoolLogo from "../components/layout/SpoolLogo";

/* ─── palette (references theme.css variables so theme changes propagate) ─── */
const C = {
  bg: "var(--background)",
  surface: "var(--card)",
  card: "var(--card)",
  elevated: "var(--secondary)",
  /* tier colors kept as hex — used in alpha composition (e.g. `${tierS}20`) */
  tierS: "#A855F7",
  tierA: "#3B82F6",
  tierB: "#10B981",
  tierC: "#F59E0B",
  tierD: "#EF4444",
  cream: "var(--foreground)",
  text: "var(--muted-foreground)",
  dim: "var(--muted-foreground)",
  muted: "var(--secondary)",
  border: "var(--border)",
  glow: "rgba(212,197,176,0.08)",
};

const TIER_COLORS: Record<string, string> = { S: C.tierS, A: C.tierA, B: C.tierB, C: C.tierC, D: C.tierD };

/* ─── mock data ─── */
const TRENDING = [
  { title: "Anora", year: "2024", tierDist: { S: 42, A: 35, B: 15, C: 6, D: 2 }, avg: "8.7", bracket: "Artisan / Indie", reviews: 4821 },
  { title: "The Brutalist", year: "2024", tierDist: { S: 38, A: 30, B: 18, C: 10, D: 4 }, avg: "8.3", bracket: "Artisan / Indie", reviews: 3190 },
  { title: "Dune: Part Two", year: "2024", tierDist: { S: 35, A: 40, B: 18, C: 5, D: 2 }, avg: "8.5", bracket: "Commercial", reviews: 12740 },
  { title: "Nosferatu", year: "2024", tierDist: { S: 28, A: 34, B: 22, C: 12, D: 4 }, avg: "7.9", bracket: "Commercial", reviews: 8450 },
  { title: "The Substance", year: "2024", tierDist: { S: 31, A: 29, B: 20, C: 13, D: 7 }, avg: "7.6", bracket: "Artisan / Indie", reviews: 6320 },
  { title: "Conclave", year: "2024", tierDist: { S: 22, A: 38, B: 28, C: 9, D: 3 }, avg: "7.8", bracket: "Commercial", reviews: 5100 },
];

const FEED_ITEMS = [
  { user: "maya_k", tier: "S", movie: "Anora", score: "9.2", mood: "Overwhelmed", time: "2m", review: "Sean Baker outdid himself. The third act is a gut punch that recontextualizes everything before it." },
  { user: "alexchen", tier: "A", movie: "Nosferatu", score: "8.1", mood: "Haunted", time: "8m", review: null },
  { user: "jordan.f", tier: "S", movie: "The Brutalist", score: "9.5", mood: "Moved", time: "14m", review: "3.5 hours and I wanted more. Adrien Brody gives the performance of the decade." },
  { user: "samira.r", tier: "B", movie: "The Substance", score: "6.4", mood: "Disturbed", time: "22m", review: null },
  { user: "devpatel", tier: "A", movie: "Conclave", score: "8.0", mood: "Thrilled", time: "31m", review: "A Vatican thriller shouldn't work this well, but Ralph Fiennes makes you believe every second." },
  { user: "linapark", tier: "A", movie: "Dune: Part Two", score: "8.6", mood: "Amazed", time: "45m", review: null },
];

/* ─── hooks ─── */
function useInView(threshold = 0.12): [React.RefObject<HTMLDivElement>, boolean] {
  const ref = useRef<HTMLDivElement>(null);
  const [vis, setVis] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const o = new IntersectionObserver(([e]) => { if (e.isIntersecting) setVis(true); }, { threshold });
    o.observe(el);
    return () => o.disconnect();
  }, [threshold]);
  return [ref, vis];
}

function useReducedMotion(): boolean {
  const [reduced, setReduced] = useState(() =>
    typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    const handler = (e: MediaQueryListEvent) => setReduced(e.matches);
    mq.addEventListener("change", handler);
    return () => mq.removeEventListener("change", handler);
  }, []);
  return reduced;
}

function Reveal({ children, delay = 0, y = 30, style = {} }: { children: React.ReactNode, delay?: number, y?: number, style?: React.CSSProperties }) {
  const [ref, vis] = useInView(0.08);
  const reduced = useReducedMotion();
  return (
    <div ref={ref} style={{
      opacity: reduced || vis ? 1 : 0,
      transform: reduced || vis ? "none" : `translateY(${y}px)`,
      transition: reduced ? "none" : `opacity 0.65s var(--ease-out) ${delay}s, transform 0.65s var(--ease-out) ${delay}s`,
      ...style,
    }}>{children}</div>
  );
}

/* ─── tier bar mini ─── */
function TierBar({ dist, height = 6 }: { dist: any, height?: number }) {
  const tiers = ["S", "A", "B", "C", "D"];
  return (
    <div style={{ display: "flex", borderRadius: height / 2, overflow: "hidden", width: "100%", height, gap: 1 }}>
      {tiers.map(t => (
        <div key={t} style={{
          width: `${dist[t]}%`, background: TIER_COLORS[t], opacity: 0.8,
          transition: "width 0.6s var(--ease-out)",
        }} />
      ))}
    </div>
  );
}

/* ─── nav ─── */
function Nav({ onAuth, t, locale, toggleLocale }: { onAuth: (mode: string) => void; t: (key: any) => string; locale: string; toggleLocale: () => void }) {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const h = () => setScrolled(window.scrollY > 30);
    window.addEventListener("scroll", h); return () => window.removeEventListener("scroll", h);
  }, []);
  return (
    <nav aria-label="Main navigation" style={{
      position: "fixed", top: 0, left: 0, right: 0, zIndex: 200,
      height: 56, padding: "0 32px", display: "flex", alignItems: "center", justifyContent: "space-between",
      background: scrolled ? "rgba(8,8,11,0.88)" : "transparent",
      backdropFilter: scrolled ? "blur(24px) saturate(1.4)" : "none",
      borderBottom: scrolled ? `1px solid ${C.border}` : "1px solid transparent",
      transition: "all var(--duration-slow) var(--ease-out)",
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
        <SpoolLogo size="sm" showWordmark={false} />
        <span style={{ fontFamily: "var(--serif)", fontSize: 19, color: C.cream, letterSpacing: "-0.03em" }}>Spool</span>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <button onClick={toggleLocale} style={{
          background: "transparent", border: `1px solid ${C.border}`, color: C.text, padding: "10px 14px",
          fontFamily: "var(--sans)", fontSize: 12, fontWeight: 600, cursor: "pointer",
          borderRadius: 8, transition: "color var(--duration-normal) var(--ease-out), border-color var(--duration-normal) var(--ease-out)", display: "flex", alignItems: "center", gap: 4, minHeight: 44,
        }}
          onMouseOver={e => { e.currentTarget.style.color = C.cream; e.currentTarget.style.borderColor = "rgba(255,255,255,0.12)"; }}
          onMouseOut={e => { e.currentTarget.style.color = C.text; e.currentTarget.style.borderColor = C.border; }}
        >{locale === 'en' ? '中文' : 'EN'}</button>
        <button onClick={() => onAuth("login")} style={{
          background: "transparent", border: "none", color: C.text, padding: "12px 18px",
          fontFamily: "var(--sans)", fontSize: 13, fontWeight: 500, cursor: "pointer",
          borderRadius: 8, transition: "color var(--duration-normal) var(--ease-out)", minHeight: 44,
        }}
          onMouseOver={e => e.currentTarget.style.color = C.cream} onMouseOut={e => e.currentTarget.style.color = C.text}
        >{t('landing.logIn')}</button>
        <button onClick={() => onAuth("signup")} style={{
          background: C.cream, color: C.bg, border: "none", borderRadius: 8,
          padding: "12px 18px", fontFamily: "var(--sans)", fontSize: 13, fontWeight: 600,
          cursor: "pointer", transition: "transform var(--duration-fast) var(--ease-out), opacity var(--duration-fast) var(--ease-out)", minHeight: 44,
        }}
          onMouseOver={e => e.currentTarget.style.opacity = "0.88"} onMouseOut={e => e.currentTarget.style.opacity = "1"}
        >{t('landing.startRanking')}</button>
      </div>
    </nav>
  );
}

/* ─── hero ─── */
function Hero({ onAuth, t }: { onAuth: (mode: string) => void; t: (key: any) => string }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => { requestAnimationFrame(() => setMounted(true)); }, []);
  const tr = (d: number) => `opacity 0.7s var(--ease-out) ${d}s, transform 0.7s var(--ease-out) ${d}s`;
  return (
    <section style={{
      minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center",
      position: "relative", overflow: "hidden", padding: "80px 32px 60px",
    }}>
      {/* bg glow */}
      <div style={{ position: "absolute", inset: 0, pointerEvents: "none" }}>
        <div style={{ position: "absolute", top: "-15%", left: "42%", width: 700, height: 700, borderRadius: "50%", background: `radial-gradient(circle, ${C.tierS}0A 0%, transparent 65%)` }} />
        <div style={{ position: "absolute", bottom: "5%", right: "30%", width: 500, height: 500, borderRadius: "50%", background: `radial-gradient(circle, ${C.tierA}06 0%, transparent 65%)` }} />
      </div>

      <div style={{ display: "flex", gap: 72, alignItems: "center", maxWidth: 1120, width: "100%", position: "relative", zIndex: 1, flexWrap: "wrap" }}>
        {/* left - copy */}
        <div style={{ flex: "1 1 400px", minWidth: 340 }}>
          <div style={{
            opacity: mounted ? 1 : 0, transform: mounted ? "none" : "translateY(18px)", transition: tr(0.15),
          }}>
            <h1 style={{
              fontFamily: "var(--serif)", fontSize: "clamp(40px, 5.5vw, 64px)", color: C.cream,
              lineHeight: 1.05, margin: "0 0 20px", fontWeight: 400, letterSpacing: "-0.03em",
            }}>
              {t('landing.tagline')}
            </h1>
          </div>
          <div style={{
            opacity: mounted ? 1 : 0, transform: mounted ? "none" : "translateY(18px)", transition: tr(0.35),
          }}>
            <p style={{
              fontFamily: "var(--sans)", fontSize: 16, color: C.text, lineHeight: 1.65,
              maxWidth: 420, margin: "0 0 32px",
            }}>
              {t('landing.subtitle')}
            </p>
          </div>
          <div style={{
            opacity: mounted ? 1 : 0, transform: mounted ? "none" : "translateY(18px)", transition: tr(0.5),
            display: "flex", gap: 10, flexWrap: "wrap",
          }}>
            <button onClick={() => onAuth("signup")} style={{
              background: C.cream, color: C.bg, border: "none", borderRadius: 10,
              padding: "13px 32px", fontFamily: "var(--sans)", fontSize: 15, fontWeight: 600,
              cursor: "pointer", transition: "transform var(--duration-fast) var(--ease-out), box-shadow var(--duration-normal) var(--ease-out)",
            }}
              onMouseOver={e => { e.currentTarget.style.transform = "translateY(-1px)"; e.currentTarget.style.boxShadow = "0 6px 24px rgba(212,197,176,0.18)"; }}
              onMouseOut={e => { e.currentTarget.style.transform = "none"; e.currentTarget.style.boxShadow = "none"; }}
            >{t('landing.startRanking')}</button>
            <button onClick={() => onAuth("login")} style={{
              background: "transparent", color: C.cream, border: `1px solid ${C.border}`,
              borderRadius: 10, padding: "13px 28px", fontFamily: "var(--sans)", fontSize: 15,
              fontWeight: 500, cursor: "pointer", transition: "all var(--duration-fast) var(--ease-out)",
            }}
              onMouseOver={e => { e.currentTarget.style.background = "rgba(255,255,255,0.03)"; e.currentTarget.style.borderColor = "rgba(255,255,255,0.12)"; }}
              onMouseOut={e => { e.currentTarget.style.background = "transparent"; e.currentTarget.style.borderColor = C.border; }}
            >{t('landing.logIn')}</button>
          </div>
          {/* social proof line */}
          <div style={{
            opacity: mounted ? 1 : 0, transition: tr(0.7),
            display: "flex", alignItems: "center", gap: 10, marginTop: 28,
          }}>
            <div style={{ display: "flex" }}>
              {["#A855F7", "#3B82F6", "#10B981", "#F59E0B"].map((c, i) => (
                <div key={i} style={{
                  width: 24, height: 24, borderRadius: "50%", background: `${c}30`, border: `2px solid ${C.bg}`,
                  marginLeft: i > 0 ? -8 : 0, display: "flex", alignItems: "center", justifyContent: "center",
                  fontFamily: "var(--sans)", fontSize: 10, color: c, fontWeight: 700,
                }}>{["S", "A", "J", "M"][i]}</div>
              ))}
            </div>
            <span style={{ fontFamily: "var(--sans)", fontSize: 12, color: C.dim }}>
              {t('landing.socialProof')}
            </span>
          </div>
        </div>

        {/* right — live feed preview */}
        <div style={{
          flex: "1 1 380px", minWidth: 320, maxWidth: 440,
          opacity: mounted ? 1 : 0, transform: mounted ? "none" : "translateY(24px)", transition: tr(0.6),
        }}>
          <LiveFeedPreview t={t} />
        </div>
      </div>
    </section>
  );
}

/* ─── live feed preview card ─── */
function LiveFeedPreview({ t }: { t: (key: any) => string }) {
  return (
    <div style={{
      background: C.surface, border: `1px solid ${C.border}`, borderRadius: 16,
      overflow: "hidden", boxShadow: "0 24px 80px rgba(0,0,0,0.4)",
    }}>
      {/* feed header */}
      <div style={{
        padding: "14px 20px", borderBottom: `1px solid ${C.border}`,
        display: "flex", alignItems: "center", justifyContent: "space-between",
      }}>
        <span style={{ fontFamily: "var(--sans)", fontSize: 13, fontWeight: 600, color: C.cream }}>{t('landing.liveActivity')}</span>
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <div className="pulse-dot" style={{ width: 6, height: 6, borderRadius: "50%", background: C.tierB, boxShadow: `0 0 6px ${C.tierB}`, animation: "pulse 2s infinite" }} />
          <span style={{ fontFamily: "var(--sans)", fontSize: 11, color: C.dim }}>{t('landing.realTime')}</span>
        </div>
      </div>
      {/* feed items */}
      <div style={{ maxHeight: 420, overflow: "hidden" }}>
        {FEED_ITEMS.map((item, i) => (
          <FeedItem key={i} item={item} index={i} />
        ))}
      </div>
      {/* fade overlay */}
      <div style={{
        height: 60, background: `linear-gradient(transparent, ${C.surface})`,
        marginTop: -60, position: "relative", zIndex: 2,
        display: "flex", alignItems: "flex-end", justifyContent: "center", paddingBottom: 14,
      }}>
        <span style={{ fontFamily: "var(--sans)", fontSize: 11, color: C.dim, letterSpacing: "0.04em" }}>{t('landing.signUpCTA')}</span>
      </div>
      <style>{`@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } } @media (prefers-reduced-motion: reduce) { .pulse-dot { animation: none !important; } }`}</style>
    </div>
  );
}

function FeedItem({ item, index }: { item: any; index: number }) {
  const [hovered, setHovered] = useState(false);
  const tierColor = TIER_COLORS[item.tier];
  return (
    <div
      onMouseOver={() => setHovered(true)} onMouseOut={() => setHovered(false)}
      style={{
        padding: "14px 20px", borderBottom: `1px solid ${C.border}`,
        background: hovered ? "rgba(255,255,255,0.015)" : "transparent",
        transition: "background var(--duration-normal) var(--ease-out)", cursor: "default",
      }}
    >
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: item.review ? 8 : 0 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          {/* avatar */}
          <div style={{
            width: 28, height: 28, borderRadius: "50%", background: `${tierColor}20`,
            display: "flex", alignItems: "center", justifyContent: "center",
            fontFamily: "var(--sans)", fontSize: 11, fontWeight: 700, color: tierColor,
            flexShrink: 0,
          }}>{item.user[0].toUpperCase()}</div>
          <div>
            <div style={{ display: "flex", alignItems: "center", gap: 6, flexWrap: "wrap" }}>
              <span style={{ fontFamily: "var(--sans)", fontSize: 12.5, fontWeight: 600, color: C.cream }}>{item.user}</span>
              <span style={{ fontFamily: "var(--sans)", fontSize: 11, color: C.dim }}>ranked</span>
              <span style={{ fontFamily: "var(--sans)", fontSize: 12.5, fontWeight: 600, color: C.cream }}>{item.movie}</span>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 3 }}>
              <span style={{
                fontFamily: "var(--sans)", fontSize: 10, fontWeight: 800, color: tierColor,
                background: `${tierColor}15`, padding: "1px 6px", borderRadius: 3,
              }}>{item.tier}</span>
              <span style={{ fontFamily: "var(--sans)", fontSize: 11, color: C.text }}>{item.score}</span>
              <span style={{
                fontFamily: "var(--sans)", fontSize: 10, color: C.dim,
                padding: "1px 8px", borderRadius: 8, background: "rgba(255,255,255,0.03)",
              }}>{item.mood}</span>
            </div>
          </div>
        </div>
        <span style={{ fontFamily: "var(--sans)", fontSize: 10, color: C.dim, flexShrink: 0, marginTop: 2 }}>{item.time}</span>
      </div>
      {item.review && (
        <p style={{
          fontFamily: "var(--sans)", fontSize: 12, color: C.text, lineHeight: 1.55,
          margin: "6px 0 0 38px", opacity: 0.8, fontStyle: "italic",
        }}>"{item.review}"</p>
      )}
    </div>
  );
}

/* ─── trending section ─── */
function TrendingSection({ t }: { t: (key: any) => string }) {
  const [hoveredIdx, setHoveredIdx] = useState<number | null>(null);
  return (
    <section style={{ padding: "60px 32px 80px", maxWidth: 1120, margin: "0 auto" }}>
      <Reveal>
        <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", marginBottom: 28 }}>
          <div>
            <h2 style={{ fontFamily: "var(--serif)", fontSize: 32, color: C.cream, margin: "0 0 4px", letterSpacing: "-0.02em", fontWeight: 400 }}>{t('landing.trendingTitle')}</h2>
            <p style={{ fontFamily: "var(--sans)", fontSize: 13, color: C.dim, margin: 0 }}>{t('landing.trendingHint')}</p>
          </div>
        </div>
      </Reveal>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(320px, 1fr))", gap: 12 }}>
        {TRENDING.map((m, i) => (
          <Reveal key={i} delay={i * 0.06}>
            <div
              onMouseOver={() => setHoveredIdx(i)} onMouseOut={() => setHoveredIdx(null)}
              style={{
                background: hoveredIdx === i ? C.elevated : C.card,
                border: `1px solid ${hoveredIdx === i ? "rgba(240,235,227,0.08)" : C.border}`,
                borderRadius: 14, padding: "20px 22px",
                transition: "all var(--duration-normal) var(--ease-out)", cursor: "pointer",
              }}
            >
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 14 }}>
                <div>
                  <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
                    <span style={{ fontFamily: "var(--sans)", fontSize: 15, fontWeight: 600, color: C.cream }}>{m.title}</span>
                    <span style={{ fontFamily: "var(--sans)", fontSize: 12, color: C.dim }}>{m.year}</span>
                  </div>
                  <span style={{
                    fontFamily: "var(--sans)", fontSize: 10.5, color: C.dim,
                    padding: "2px 8px", borderRadius: 6, background: "rgba(255,255,255,0.03)", border: `1px solid ${C.border}`,
                  }}>{m.bracket}</span>
                </div>
                <div style={{ textAlign: "right" }}>
                  <div style={{ fontFamily: "var(--serif)", fontSize: 24, color: C.cream, lineHeight: 1, letterSpacing: "-0.02em" }}>{m.avg}</div>
                  <div style={{ fontFamily: "var(--sans)", fontSize: 10, color: C.dim, marginTop: 2 }}>{m.reviews.toLocaleString()} {t('landing.rankings')}</div>
                </div>
              </div>
              <TierBar dist={m.tierDist as any} height={5} />
              <div style={{ display: "flex", gap: 12, marginTop: 10 }}>
                {(["S", "A", "B", "C", "D"] as const).map(t => (
                  <div key={t} style={{ display: "flex", alignItems: "center", gap: 3 }}>
                    <span style={{ fontFamily: "var(--sans)", fontSize: 9, fontWeight: 800, color: TIER_COLORS[t], opacity: 0.7 }}>{t}</span>
                    <span style={{ fontFamily: "var(--sans)", fontSize: 10, color: C.dim }}>{(m.tierDist as any)[t]}%</span>
                  </div>
                ))}
              </div>
            </div>
          </Reveal>
        ))}
      </div>
    </section>
  );
}

/* ─── how it works ─── */
function HowSection({ onAuth, t }: { onAuth: (mode: string) => void; t: (key: any) => string }) {
  const steps = [
    { num: "1", labelKey: 'landing.step1Title', descKey: 'landing.step1Desc', color: C.tierS },
    { num: "2", labelKey: 'landing.step2Title', descKey: 'landing.step2Desc', color: C.tierA },
    { num: "3", labelKey: 'landing.step3Title', descKey: 'landing.step3Desc', color: C.tierB },
    { num: "4", labelKey: 'landing.step4Title', descKey: 'landing.step4Desc', color: C.tierC },
  ];
  return (
    <section style={{ padding: "60px 32px 80px", maxWidth: 720, margin: "0 auto" }}>
      <Reveal>
        <h2 style={{ fontFamily: "var(--serif)", fontSize: 32, color: C.cream, margin: "0 0 48px", letterSpacing: "-0.02em", fontWeight: 400 }}>{t('landing.howItWorks')}</h2>
      </Reveal>
      <div style={{ display: "flex", flexDirection: "column", gap: 0 }}>
        {steps.map((s, i) => (
          <Reveal key={i} delay={i * 0.08}>
            <div style={{
              display: "flex", gap: 24, alignItems: "flex-start",
              padding: "24px 0",
              borderTop: i === 0 ? `1px solid ${C.border}` : "none",
              borderBottom: `1px solid ${C.border}`,
            }}>
              <span style={{
                fontFamily: "var(--serif)", fontSize: 36, fontWeight: 400,
                color: s.color, lineHeight: 1, minWidth: 32, opacity: 0.7,
              }}>{s.num}</span>
              <div>
                <div style={{ fontFamily: "var(--serif)", fontSize: 20, color: C.cream, fontWeight: 500, marginBottom: 4 }}>{t(s.labelKey as any)}</div>
                <p style={{ fontFamily: "var(--sans)", fontSize: 14, color: C.text, lineHeight: 1.6, margin: 0 }}>{t(s.descKey as any)}</p>
              </div>
            </div>
          </Reveal>
        ))}
      </div>
      <Reveal delay={0.35}>
        <div style={{ marginTop: 40 }}>
          <button onClick={() => onAuth("signup")} style={{
            background: C.cream, color: C.bg, border: "none", borderRadius: 10,
            padding: "13px 36px", fontFamily: "var(--sans)", fontSize: 15, fontWeight: 600,
            cursor: "pointer", transition: "transform 0.15s, box-shadow 0.25s",
          }}
            onMouseOver={e => { e.currentTarget.style.transform = "translateY(-1px)"; e.currentTarget.style.boxShadow = "0 6px 24px rgba(212,197,176,0.18)"; }}
            onMouseOut={e => { e.currentTarget.style.transform = "none"; e.currentTarget.style.boxShadow = "none"; }}
          >{t('landing.startRanking')}</button>
        </div>
      </Reveal>
    </section>
  );
}

/* ─── footer ─── */
function Footer({ t }: { t: (key: any) => string }) {
  const links = [
    { key: 'landing.about', href: '#' },
    { key: 'landing.privacy', href: '#' },
    { key: 'landing.terms', href: '#' },
    { key: 'landing.contact', href: '#' },
  ];
  return (
    <footer style={{
      padding: "28px 32px", borderTop: `1px solid ${C.border}`,
      display: "flex", justifyContent: "space-between", alignItems: "center",
      maxWidth: 1120, margin: "0 auto", flexWrap: "wrap", gap: 16,
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
        <SpoolLogo size="sm" showWordmark={false} />
        <span style={{ fontFamily: "var(--serif)", fontSize: 14, color: C.dim }}>Spool</span>
      </div>
      <div style={{ display: "flex", gap: 24 }}>
        {links.map(link => (
          <a key={link.key} href={link.href} style={{ fontFamily: "var(--sans)", fontSize: 12, color: C.dim, textDecoration: "none", transition: "color var(--duration-fast) var(--ease-out)", padding: "12px 4px", display: "inline-block" }}
            onMouseOver={e => e.currentTarget.style.color = C.text} onMouseOut={e => e.currentTarget.style.color = C.dim}
          >{t(link.key as any)}</a>
        ))}
      </div>
      <span style={{ fontFamily: "var(--sans)", fontSize: 11, color: C.dim }}>{t('landing.copyright')}</span>
    </footer>
  );
}

/* ─── main ─── */
export default function LandingPage() {
  const navigate = useNavigate();
  const { user } = useAuth();
  const { t, locale, setLocale } = useTranslation();

  const toggleLocale = () => setLocale(locale === 'en' ? 'zh' : 'en');

  const handleAuth = (mode: string) => {
    if (user) {
      navigate('/app');
    } else if (mode === 'login') {
      navigate('/auth');
    } else {
      navigate('/onboarding/movies');
    }
  };

  return (
    <div style={{
      background: C.bg, minHeight: "100vh", overflowX: "hidden",
      "--serif": "var(--font-serif)",
      "--sans": "var(--font-sans)",
    } as React.CSSProperties}>
      <Nav onAuth={handleAuth} t={t} locale={locale} toggleLocale={toggleLocale} />
      <main>
        <Hero onAuth={handleAuth} t={t} />
        <TrendingSection t={t} />
        <HowSection onAuth={handleAuth} t={t} />
      </main>
      <Footer t={t} />
    </div>
  );
}
