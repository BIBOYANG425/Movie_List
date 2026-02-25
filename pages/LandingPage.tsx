import React, { useState, useEffect, useRef } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";

/* ─── palette ─── */
const C = {
  bg: "#08080B",
  surface: "#111116",
  card: "#16161D",
  elevated: "#1C1C25",
  tierS: "#A855F7",
  tierA: "#3B82F6",
  tierB: "#10B981",
  tierC: "#F59E0B",
  tierD: "#EF4444",
  cream: "#F0EBE3",
  text: "#C8C3BC",
  dim: "#706D67",
  muted: "#4A4843",
  border: "rgba(240,235,227,0.06)",
  glow: "rgba(168,85,247,0.08)",
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

function Reveal({ children, delay = 0, y = 30, style = {} }: { children: React.ReactNode, delay?: number, y?: number, style?: React.CSSProperties }) {
  const [ref, vis] = useInView(0.08);
  return (
    <div ref={ref} style={{
      opacity: vis ? 1 : 0, transform: vis ? "none" : `translateY(${y}px)`,
      transition: `opacity 0.65s cubic-bezier(0.16,1,0.3,1) ${delay}s, transform 0.65s cubic-bezier(0.16,1,0.3,1) ${delay}s`,
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
          transition: "width 0.6s cubic-bezier(0.16,1,0.3,1)",
        }} />
      ))}
    </div>
  );
}

/* ─── nav ─── */
function Nav({ onAuth }: { onAuth: (mode: string) => void }) {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const h = () => setScrolled(window.scrollY > 30);
    window.addEventListener("scroll", h); return () => window.removeEventListener("scroll", h);
  }, []);
  return (
    <nav style={{
      position: "fixed", top: 0, left: 0, right: 0, zIndex: 200,
      height: 56, padding: "0 32px", display: "flex", alignItems: "center", justifyContent: "space-between",
      background: scrolled ? "rgba(8,8,11,0.88)" : "transparent",
      backdropFilter: scrolled ? "blur(24px) saturate(1.4)" : "none",
      borderBottom: scrolled ? `1px solid ${C.border}` : "1px solid transparent",
      transition: "all 0.35s ease",
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
        <SpoolLogo size={22} />
        <span style={{ fontFamily: "var(--serif)", fontSize: 19, color: C.cream, letterSpacing: "-0.03em" }}>spool</span>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <button onClick={() => onAuth("login")} style={{
          background: "transparent", border: "none", color: C.text, padding: "7px 18px",
          fontFamily: "var(--sans)", fontSize: 13, fontWeight: 500, cursor: "pointer",
          borderRadius: 8, transition: "color 0.2s",
        }}
          onMouseOver={e => e.currentTarget.style.color = C.cream} onMouseOut={e => e.currentTarget.style.color = C.text}
        >Log in</button>
        <button onClick={() => onAuth("signup")} style={{
          background: C.cream, color: C.bg, border: "none", borderRadius: 8,
          padding: "7px 18px", fontFamily: "var(--sans)", fontSize: 13, fontWeight: 600,
          cursor: "pointer", transition: "transform 0.15s, opacity 0.15s",
        }}
          onMouseOver={e => e.currentTarget.style.opacity = "0.88"} onMouseOut={e => e.currentTarget.style.opacity = "1"}
        >Sign up</button>
      </div>
    </nav>
  );
}

/* ─── logo ─── */
function SpoolLogo({ size = 28 }: { size?: number }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: "50%",
      background: `conic-gradient(from 180deg, ${C.tierS}, ${C.tierA}, ${C.tierB}, ${C.tierC}, ${C.tierD}, ${C.tierS})`,
      display: "flex", alignItems: "center", justifyContent: "center",
      boxShadow: `0 0 ${size * 0.6}px ${C.tierS}25`,
    }}>
      <div style={{ width: size * 0.4, height: size * 0.4, borderRadius: "50%", background: C.bg }} />
    </div>
  );
}

/* ─── hero ─── */
function Hero({ onAuth }: { onAuth: (mode: string) => void }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => { requestAnimationFrame(() => setMounted(true)); }, []);
  const t = (d: number) => `opacity 0.7s cubic-bezier(0.16,1,0.3,1) ${d}s, transform 0.7s cubic-bezier(0.16,1,0.3,1) ${d}s`;
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
            opacity: mounted ? 1 : 0, transform: mounted ? "none" : "translateY(18px)", transition: t(0.15),
          }}>
            <h1 style={{
              fontFamily: "var(--serif)", fontSize: "clamp(40px, 5.5vw, 64px)", color: C.cream,
              lineHeight: 1.05, margin: "0 0 20px", fontWeight: 400, letterSpacing: "-0.03em",
            }}>
              Your movies,<br />
              <span style={{ color: C.tierS }}>ranked</span> and <span style={{ color: C.tierA }}>remembered.</span>
            </h1>
          </div>
          <div style={{
            opacity: mounted ? 1 : 0, transform: mounted ? "none" : "translateY(18px)", transition: t(0.35),
          }}>
            <p style={{
              fontFamily: "var(--sans)", fontSize: 16, color: C.text, lineHeight: 1.65,
              maxWidth: 420, margin: "0 0 32px",
            }}>
              Tier-based rankings. Friend-powered discovery. A personal film journal. Built for people who care about movies — not algorithms.
            </p>
          </div>
          <div style={{
            opacity: mounted ? 1 : 0, transform: mounted ? "none" : "translateY(18px)", transition: t(0.5),
            display: "flex", gap: 10, flexWrap: "wrap",
          }}>
            <button onClick={() => onAuth("signup")} style={{
              background: C.cream, color: C.bg, border: "none", borderRadius: 10,
              padding: "13px 32px", fontFamily: "var(--sans)", fontSize: 15, fontWeight: 600,
              cursor: "pointer", transition: "transform 0.15s, box-shadow 0.25s",
            }}
              onMouseOver={e => { e.currentTarget.style.transform = "translateY(-1px)"; e.currentTarget.style.boxShadow = "0 6px 24px rgba(168,85,247,0.12)"; }}
              onMouseOut={e => { e.currentTarget.style.transform = "none"; e.currentTarget.style.boxShadow = "none"; }}
            >Create your account</button>
            <button onClick={() => onAuth("login")} style={{
              background: "transparent", color: C.cream, border: `1px solid ${C.border}`,
              borderRadius: 10, padding: "13px 28px", fontFamily: "var(--sans)", fontSize: 15,
              fontWeight: 500, cursor: "pointer", transition: "all 0.15s",
            }}
              onMouseOver={e => { e.currentTarget.style.background = "rgba(255,255,255,0.03)"; e.currentTarget.style.borderColor = "rgba(255,255,255,0.12)"; }}
              onMouseOut={e => { e.currentTarget.style.background = "transparent"; e.currentTarget.style.borderColor = C.border; }}
            >Log in</button>
          </div>
          {/* social proof line */}
          <div style={{
            opacity: mounted ? 1 : 0, transition: t(0.7),
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
              Join 48,000+ movie lovers ranking right now
            </span>
          </div>
        </div>

        {/* right — live feed preview */}
        <div style={{
          flex: "1 1 380px", minWidth: 320, maxWidth: 440,
          opacity: mounted ? 1 : 0, transform: mounted ? "none" : "translateY(24px)", transition: t(0.6),
        }}>
          <LiveFeedPreview />
        </div>
      </div>
    </section>
  );
}

/* ─── live feed preview card ─── */
function LiveFeedPreview() {
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
        <span style={{ fontFamily: "var(--sans)", fontSize: 13, fontWeight: 600, color: C.cream }}>Live Activity</span>
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <div style={{ width: 6, height: 6, borderRadius: "50%", background: C.tierB, boxShadow: `0 0 6px ${C.tierB}`, animation: "pulse 2s infinite" }} />
          <span style={{ fontFamily: "var(--sans)", fontSize: 11, color: C.dim }}>Real-time</span>
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
        <span style={{ fontFamily: "var(--sans)", fontSize: 11, color: C.dim, letterSpacing: "0.04em" }}>Sign up to see your friends' feed →</span>
      </div>
      <style>{`@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }`}</style>
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
        transition: "background 0.2s", cursor: "default",
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
                fontFamily: "var(--sans)", fontSize: 10, color: C.muted,
                padding: "1px 8px", borderRadius: 8, background: "rgba(255,255,255,0.03)",
              }}>{item.mood}</span>
            </div>
          </div>
        </div>
        <span style={{ fontFamily: "var(--sans)", fontSize: 10, color: C.muted, flexShrink: 0, marginTop: 2 }}>{item.time}</span>
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
function TrendingSection() {
  const [hoveredIdx, setHoveredIdx] = useState<number | null>(null);
  return (
    <section style={{ padding: "60px 32px 80px", maxWidth: 1120, margin: "0 auto" }}>
      <Reveal>
        <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", marginBottom: 28 }}>
          <div>
            <h2 style={{ fontFamily: "var(--serif)", fontSize: 32, color: C.cream, margin: "0 0 4px", letterSpacing: "-0.02em", fontWeight: 400 }}>Trending this week</h2>
            <p style={{ fontFamily: "var(--sans)", fontSize: 13, color: C.dim, margin: 0 }}>See how the community is ranking right now</p>
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
                transition: "all 0.25s ease", cursor: "pointer",
              }}
            >
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 14 }}>
                <div>
                  <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 4 }}>
                    <span style={{ fontFamily: "var(--sans)", fontSize: 15, fontWeight: 600, color: C.cream }}>{m.title}</span>
                    <span style={{ fontFamily: "var(--sans)", fontSize: 12, color: C.muted }}>{m.year}</span>
                  </div>
                  <span style={{
                    fontFamily: "var(--sans)", fontSize: 10.5, color: C.dim,
                    padding: "2px 8px", borderRadius: 6, background: "rgba(255,255,255,0.03)", border: `1px solid ${C.border}`,
                  }}>{m.bracket}</span>
                </div>
                <div style={{ textAlign: "right" }}>
                  <div style={{ fontFamily: "var(--serif)", fontSize: 24, color: C.cream, lineHeight: 1, letterSpacing: "-0.02em" }}>{m.avg}</div>
                  <div style={{ fontFamily: "var(--sans)", fontSize: 10, color: C.dim, marginTop: 2 }}>{m.reviews.toLocaleString()} rankings</div>
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
function HowSection({ onAuth }: { onAuth: (mode: string) => void }) {
  const steps = [
    { num: "1", label: "Pick your tier", desc: "S, A, B, C, or D. One tap, gut feeling.", color: C.tierS, icon: "◆" },
    { num: "2", label: "Quick comparisons", desc: "3–4 smart matchups within your tier. 15 seconds.", color: C.tierA, icon: "⟷" },
    { num: "3", label: "Journal it", desc: "Capture moods, moments, and why it resonated.", color: C.tierB, icon: "✎" },
    { num: "4", label: "Share & discover", desc: "Your friends see it. You discover what they're watching.", color: C.tierC, icon: "◎" },
  ];
  return (
    <section style={{ padding: "60px 32px 80px", maxWidth: 1120, margin: "0 auto" }}>
      <Reveal>
        <h2 style={{ fontFamily: "var(--serif)", fontSize: 32, color: C.cream, margin: "0 0 40px", letterSpacing: "-0.02em", fontWeight: 400 }}>How Spool works</h2>
      </Reveal>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))", gap: 12 }}>
        {steps.map((s, i) => (
          <Reveal key={i} delay={i * 0.08}>
            <div style={{
              background: C.card, border: `1px solid ${C.border}`, borderRadius: 14,
              padding: "28px 22px", position: "relative", overflow: "hidden", height: "100%",
            }}>
              <div style={{
                position: "absolute", top: -20, right: -20, width: 80, height: 80, borderRadius: "50%",
                background: `radial-gradient(circle, ${s.color}0C 0%, transparent 70%)`, pointerEvents: "none",
              }} />
              <div style={{
                fontFamily: "var(--sans)", fontSize: 22, color: s.color, marginBottom: 16,
                width: 36, height: 36, display: "flex", alignItems: "center", justifyContent: "center",
                background: `${s.color}10`, borderRadius: 10,
              }}>{s.icon}</div>
              <div style={{ fontFamily: "var(--sans)", fontSize: 11, fontWeight: 700, color: s.color, letterSpacing: "0.06em", marginBottom: 6 }}>STEP {s.num}</div>
              <h3 style={{ fontFamily: "var(--sans)", fontSize: 16, color: C.cream, margin: "0 0 6px", fontWeight: 600 }}>{s.label}</h3>
              <p style={{ fontFamily: "var(--sans)", fontSize: 13, color: C.text, lineHeight: 1.55, margin: 0 }}>{s.desc}</p>
            </div>
          </Reveal>
        ))}
      </div>
      <Reveal delay={0.35}>
        <div style={{ textAlign: "center", marginTop: 40 }}>
          <button onClick={() => onAuth("signup")} style={{
            background: C.cream, color: C.bg, border: "none", borderRadius: 10,
            padding: "13px 36px", fontFamily: "var(--sans)", fontSize: 15, fontWeight: 600,
            cursor: "pointer", transition: "transform 0.15s, box-shadow 0.25s",
          }}
            onMouseOver={e => { e.currentTarget.style.transform = "translateY(-1px)"; e.currentTarget.style.boxShadow = "0 6px 24px rgba(168,85,247,0.12)"; }}
            onMouseOut={e => { e.currentTarget.style.transform = "none"; e.currentTarget.style.boxShadow = "none"; }}
          >Start ranking</button>
        </div>
      </Reveal>
    </section>
  );
}

/* ─── footer ─── */
function Footer() {
  return (
    <footer style={{
      padding: "28px 32px", borderTop: `1px solid ${C.border}`,
      display: "flex", justifyContent: "space-between", alignItems: "center",
      maxWidth: 1120, margin: "0 auto", flexWrap: "wrap", gap: 16,
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
        <SpoolLogo size={18} />
        <span style={{ fontFamily: "var(--serif)", fontSize: 14, color: C.muted }}>spool</span>
      </div>
      <div style={{ display: "flex", gap: 24 }}>
        {["About", "Privacy", "Terms", "Contact"].map(link => (
          <a key={link} href="#" style={{ fontFamily: "var(--sans)", fontSize: 12, color: C.muted, textDecoration: "none", transition: "color 0.15s" }}
            onMouseOver={e => e.currentTarget.style.color = C.text} onMouseOut={e => e.currentTarget.style.color = C.muted}
          >{link}</a>
        ))}
      </div>
      <span style={{ fontFamily: "var(--sans)", fontSize: 11, color: C.muted }}>© 2026 Spool</span>
    </footer>
  );
}

/* ─── main ─── */
export default function LandingPage() {
  const navigate = useNavigate();
  const { user } = useAuth();

  const handleAuth = (mode: string) => {
    if (user) {
      navigate('/app');
    } else {
      // NOTE: AuthPage accepts 'mode' internally, but routing to AuthPage defaults to it.
      // We'll just push to '/auth' as a unified login/signup form.
      navigate('/auth');
    }
  };

  return (
    <div style={{
      background: C.bg, minHeight: "100vh", overflowX: "hidden",
      "--serif": "'Instrument Serif', Georgia, serif",
      "--sans": "'DM Sans', -apple-system, sans-serif",
    } as React.CSSProperties}>
      {/* We skip the <Grain /> since App.tsx already renders it globally! */}
      <Nav onAuth={handleAuth} />
      <Hero onAuth={handleAuth} />
      <TrendingSection />
      <HowSection onAuth={handleAuth} />
      <Footer />
    </div>
  );
}
