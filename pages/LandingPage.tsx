import React, { useState, useEffect, useRef, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import { useTranslation } from "../contexts/LanguageContext";

/* ─── inline spool logo ─── */
function SpoolIcon({ w, h, sw = 6 }: { w: number; h: number; sw?: number }) {
  return (
    <svg width={w} height={h} viewBox="0 0 140 100" fill="none">
      <circle cx="48" cy="50" r="36" stroke="#D4C5B0" strokeWidth={sw} />
      <circle cx="92" cy="50" r="36" stroke="#D4C5B0" strokeWidth={sw} />
    </svg>
  );
}

/* ─── nav ─── */
function Nav({ onAuth }: { onAuth: (mode: string) => void }) {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const h = () => setScrolled(window.scrollY > 30);
    window.addEventListener("scroll", h, { passive: true });
    return () => window.removeEventListener("scroll", h);
  }, []);
  return (
    <nav style={{
      position: "fixed", top: 0, left: 0, right: 0, zIndex: 200, height: 64,
      display: "flex", alignItems: "center", justifyContent: "space-between", padding: "0 36px",
      background: scrolled ? "rgba(15,20,25,.72)" : "rgba(15,20,25,.72)",
      backdropFilter: "blur(20px) saturate(1.3)",
      borderBottom: "1px solid rgba(255,255,255,.06)",
    }}>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <SpoolIcon w={28} h={20} />
        <span style={{ fontFamily: "'Cormorant Garamond',serif", fontSize: 20, color: "#F5F3EF", letterSpacing: "-0.03em" }}>Spool</span>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <button onClick={() => onAuth("login")} style={{
          whiteSpace: "nowrap", fontSize: 13, fontWeight: 500, color: "#9BA3AB", padding: "10px 16px",
          cursor: "pointer", borderRadius: 8, background: "transparent", border: "none",
          fontFamily: "'Source Sans 3',sans-serif",
        }}
          onMouseOver={e => e.currentTarget.style.color = "#F5F3EF"}
          onMouseOut={e => e.currentTarget.style.color = "#9BA3AB"}
        >Log in</button>
        <button onClick={() => onAuth("signup")} style={{
          whiteSpace: "nowrap", display: "inline-flex", alignItems: "center",
          fontSize: 13, fontWeight: 600, color: "#0F1419", background: "#F5F3EF",
          padding: "10px 18px", borderRadius: 999, cursor: "pointer", border: "none",
          fontFamily: "'Source Sans 3',sans-serif",
        }}
          onMouseOver={e => e.currentTarget.style.opacity = "0.88"}
          onMouseOut={e => e.currentTarget.style.opacity = "1"}
        >Start ranking</button>
      </div>
    </nav>
  );
}

/* ─── floating decorative elements ─── */
function FloatingElements() {
  return (
    <div className="landing-floats">
      {/* ticket stub — Hamnet (top-left) */}
      <div style={{ position: "absolute", left: "5%", top: "18%", animation: "drift1 7s ease-in-out infinite", zIndex: 2 }}>
        <div style={{
          width: 230, borderRadius: 12, overflow: "hidden", display: "flex",
          background: "linear-gradient(135deg,#7a2d3add,#2c1520cc)",
          border: "1px solid rgba(255,255,255,0.1)", boxShadow: "0 24px 60px rgba(0,0,0,.5)",
        }}>
          <div style={{ flex: 1, padding: 12, display: "flex", flexDirection: "column", gap: 6 }}>
            <div style={{ fontFamily: "'Cormorant Garamond',serif", fontSize: 15, fontWeight: 600, color: "#fff" }}>Hamnet</div>
            <div style={{ fontFamily: "'Space Mono',monospace", fontSize: 9, color: "rgba(255,255,255,.55)" }}>FEB 14 2026 · 9:40PM</div>
            <div style={{ display: "flex", gap: 4 }}>
              <span style={{ fontSize: 9, padding: "2px 7px", borderRadius: 999, background: "rgba(255,255,255,.15)", color: "rgba(255,255,255,.8)" }}>Moved</span>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 5 }}>
              <span style={{ fontSize: 10, fontWeight: 800, background: "#A855F7", color: "#fff", padding: "1px 6px", borderRadius: 3 }}>S</span>
              <span style={{ fontSize: 10, color: "rgba(255,255,255,.5)" }}>Canon</span>
            </div>
          </div>
          <div style={{ flex: "0 0 64px", background: "linear-gradient(180deg,#5a1a28,#3a1520)", minWidth: 0 }} />
        </div>
      </div>

      {/* movie poster — Dune (bottom-left) */}
      <div style={{ position: "absolute", left: "12%", top: "58%", animation: "drift3 8.5s ease-in-out infinite", zIndex: 1 }}>
        <div style={{
          width: 195, height: 292, transform: "rotate(-8deg)", borderRadius: 10, overflow: "hidden",
          border: "1px solid rgba(255,255,255,.1)", boxShadow: "0 18px 44px rgba(0,0,0,.5)",
          background: "linear-gradient(160deg,#1a3550,#0a1a2e)",
        }} />
      </div>

      {/* movie poster — Brutalist (top-right) */}
      <div style={{ position: "absolute", right: "6%", top: "20%", animation: "drift4 7.5s ease-in-out infinite", zIndex: 1 }}>
        <div style={{
          width: 185, height: 278, transform: "rotate(6deg)", borderRadius: 10, overflow: "hidden",
          border: "1px solid rgba(255,255,255,.1)", boxShadow: "0 18px 44px rgba(0,0,0,.5)",
          background: "linear-gradient(160deg,#2a2a35,#141418)",
        }} />
      </div>

      {/* ticket stub with flip — Minions (mid-right) */}
      <div style={{ position: "absolute", right: "8%", top: "60%", perspective: 900, zIndex: 2 }}>
        <div style={{
          width: 240, height: 118, position: "relative", transformStyle: "preserve-3d",
          animation: "stubflip 9s cubic-bezier(.6,0,.2,1) infinite",
        }}>
          {/* front */}
          <div style={{
            position: "absolute", inset: 0, backfaceVisibility: "hidden", borderRadius: 12, overflow: "hidden",
            display: "flex", background: "linear-gradient(135deg,#1f4d43dd,#0d241fcc)",
            border: "1px solid rgba(255,255,255,.1)", boxShadow: "0 24px 60px rgba(0,0,0,.5)",
          }}>
            <div style={{ flex: 1, padding: 12, display: "flex", flexDirection: "column", gap: 5 }}>
              <div style={{ fontFamily: "'Cormorant Garamond',serif", fontSize: 15, fontWeight: 600, color: "#fff" }}>Minions: Rise of Gru</div>
              <div style={{ fontFamily: "'Space Mono',monospace", fontSize: 9, color: "rgba(255,255,255,.55)" }}>JAN 03 2026 · 7:15PM</div>
              <div style={{ fontFamily: "'Cormorant Garamond',serif", fontStyle: "italic", fontSize: 11, color: "rgba(255,255,255,.7)", lineHeight: 1.35 }}>&ldquo;Chaotic, dumb, and I laughed the whole way.&rdquo;</div>
              <div style={{ display: "flex", alignItems: "center", gap: 5 }}>
                <span style={{ fontSize: 10, fontWeight: 800, background: "#3B82F6", color: "#fff", padding: "1px 6px", borderRadius: 3 }}>A</span>
                <span style={{ fontSize: 10, color: "rgba(255,255,255,.5)" }}>Great</span>
              </div>
            </div>
            <div style={{ flex: "0 0 66px", borderLeft: "2px dotted rgba(0,0,0,.45)", background: "linear-gradient(180deg,#1a3a30,#0d241f)" }} />
          </div>
          {/* back */}
          <div style={{
            position: "absolute", inset: 0, backfaceVisibility: "hidden", transform: "rotateY(180deg)",
            borderRadius: 12, border: "1px solid rgba(212,197,176,.35)",
            background: "linear-gradient(160deg,#1C2128,#0F1419)",
            boxShadow: "0 24px 60px rgba(0,0,0,.5)",
            display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 6,
          }}>
            <SpoolIcon w={42} h={30} />
            <div style={{ fontFamily: "'Space Mono',monospace", fontSize: 9, letterSpacing: ".2em", color: "#B8A998" }}>ADMIT ONE</div>
          </div>
        </div>
      </div>

      {/* open book journal — Pachinko (bottom-right) */}
      <div style={{ position: "absolute", right: "14%", top: "74%", animation: "drift2 8s ease-in-out infinite", zIndex: 2 }}>
        <div style={{
          display: "flex", width: 250, height: 150, transform: "rotate(4deg)",
          filter: "drop-shadow(0 24px 40px rgba(0,0,0,.55))",
        }}>
          <div style={{
            flex: 1, background: "linear-gradient(100deg,#e8e2d6,#f2ede2)", borderRadius: "8px 2px 2px 8px",
            borderRight: "1px solid rgba(0,0,0,.18)", boxShadow: "inset -12px 0 18px rgba(0,0,0,.14)",
            padding: "14px 12px 12px 16px", display: "flex", flexDirection: "column", gap: 6,
          }}>
            <div style={{ fontFamily: "'Space Mono',monospace", fontSize: 8, letterSpacing: ".18em", color: "#8a8272" }}>MAR 09 2026</div>
            <div style={{ fontFamily: "'Cormorant Garamond',serif", fontStyle: "italic", fontSize: 12.5, lineHeight: 1.45, color: "#3a362e" }}>
              &ldquo;Finished at 2am. Couldn&rsquo;t put it down &mdash; straight into the canon.&rdquo;
            </div>
          </div>
          <div style={{
            flex: 1, background: "linear-gradient(260deg,#e8e2d6,#f2ede2)", borderRadius: "2px 8px 8px 2px",
            boxShadow: "inset 12px 0 18px rgba(0,0,0,.14)", padding: "14px 16px 12px 12px",
            display: "flex", flexDirection: "column", justifyContent: "space-between",
          }}>
            <div>
              <div style={{ fontFamily: "'Cormorant Garamond',serif", fontSize: 15, fontWeight: 600, color: "#2c2822" }}>Pachinko</div>
              <div style={{ fontFamily: "'Space Mono',monospace", fontSize: 8, letterSpacing: ".12em", color: "#8a8272", marginTop: 2 }}>MIN JIN LEE</div>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 5 }}>
              <span style={{ fontSize: 10, fontWeight: 800, background: "#A855F7", color: "#fff", padding: "1px 6px", borderRadius: 3 }}>S</span>
              <span style={{ fontSize: 10, color: "#8a8272" }}>Canon</span>
            </div>
          </div>
        </div>
      </div>

      {/* book cover (bottom-left) */}
      <div style={{ position: "absolute", left: "5%", top: "72%", animation: "drift4 9s ease-in-out infinite", zIndex: 1 }}>
        <div style={{ position: "relative", width: 132, height: 198, transform: "rotate(-7deg)" }}>
          <div style={{
            position: "absolute", top: 3, left: 6, width: "100%", height: "100%",
            borderRadius: "4px 10px 10px 4px",
            background: "linear-gradient(90deg,#d8d2c4,#efe9dc 30%,#d8d2c4)",
          }} />
          <div style={{
            position: "absolute", inset: 0, borderRadius: "4px 10px 10px 4px", overflow: "hidden",
            border: "1px solid rgba(255,255,255,.12)", boxShadow: "0 20px 48px rgba(0,0,0,.55)",
            background: "linear-gradient(160deg,#2a3540,#1a2028)",
          }} />
          <div style={{
            position: "absolute", top: 0, bottom: 0, left: 0, width: 7,
            background: "linear-gradient(90deg,rgba(0,0,0,.45),transparent)", pointerEvents: "none", zIndex: 2,
          }} />
        </div>
      </div>

      {/* clapperboard (upper mid-left) */}
      <div style={{ position: "absolute", left: "24%", top: "9%", animation: "drift2 7.5s ease-in-out infinite", zIndex: 1 }}>
        <div style={{ width: 150, transform: "rotate(-5deg)", filter: "drop-shadow(0 18px 36px rgba(0,0,0,.5))" }}>
          <div style={{
            height: 22, borderRadius: "6px 6px 0 0",
            background: "repeating-linear-gradient(115deg,#F5F3EF 0 14px,#14181e 14px 28px)",
            border: "1px solid rgba(255,255,255,.14)", borderBottom: "none",
            transform: "rotate(-3deg)", transformOrigin: "left bottom",
          }} />
          <div style={{
            height: 64, borderRadius: "0 0 8px 8px",
            background: "linear-gradient(160deg,#1C2128,#12161c)",
            border: "1px solid rgba(255,255,255,.14)",
            padding: "9px 12px", boxSizing: "border-box",
            display: "flex", flexDirection: "column", gap: 4,
          }}>
            <div style={{ fontFamily: "'Space Mono',monospace", fontSize: 8, letterSpacing: ".2em", color: "#B8A998" }}>SPOOL · TAKE 01</div>
            <div style={{ fontFamily: "'Cormorant Garamond',serif", fontStyle: "italic", fontSize: 12, color: "rgba(245,243,239,.75)" }}>movie night</div>
          </div>
        </div>
      </div>
    </div>
  );
}

/* ─── hero section ─── */
function HeroSection({ onAuth }: { onAuth: (mode: string) => void }) {
  return (
    <section style={{ position: "relative", minHeight: "100vh", overflow: "hidden" }}>
      {/* background glows */}
      <div style={{
        position: "absolute", top: 60, left: -120, width: 340, height: 340, borderRadius: 999,
        filter: "blur(54px)", background: "radial-gradient(circle, rgba(212,197,176,0.35) 0%, rgba(212,197,176,0.07) 45%, transparent 75%)",
        pointerEvents: "none",
      }} />
      <div style={{
        position: "absolute", top: 10, right: -110, width: 300, height: 300, borderRadius: 999,
        filter: "blur(54px)", background: "radial-gradient(circle, rgba(139,168,186,0.30) 0%, rgba(139,168,186,0.05) 48%, transparent 78%)",
        pointerEvents: "none",
      }} />
      <div style={{ position: "absolute", inset: 0, boxShadow: "inset 0 0 180px rgba(0,0,0,0.7)", pointerEvents: "none", zIndex: 5 }} />

      <FloatingElements />

      {/* center content */}
      <div style={{
        position: "relative", minHeight: "100vh", display: "flex", flexDirection: "column",
        alignItems: "center", justifyContent: "center", textAlign: "center", zIndex: 3,
        padding: "100px 32px 80px", boxSizing: "border-box",
      }}>
        <SpoolIcon w={86} h={62} />
        <h1 style={{
          fontFamily: "'Cormorant Garamond',serif",
          fontSize: "clamp(64px,9vw,110px)", fontWeight: 500, color: "#F5F3EF",
          letterSpacing: "-0.04em", lineHeight: 1, margin: "18px 0 22px",
        }}>Spool</h1>
        <div style={{
          fontFamily: "'Cormorant Garamond',serif",
          fontSize: "clamp(22px,2.6vw,30px)", fontWeight: 400, fontStyle: "italic",
          color: "#9BA3AB", letterSpacing: "-0.01em", marginBottom: 38,
          textWrap: "balance" as any,
        }}>Rank what you watch. Keep every movie night.</div>
        <div style={{ display: "flex", gap: 12, alignItems: "center", flexWrap: "wrap", justifyContent: "center" }}>
          <button onClick={() => onAuth("signup")} style={{
            whiteSpace: "nowrap", display: "inline-flex", alignItems: "center",
            fontSize: 15, fontWeight: 600, color: "#0F1419", background: "#D4C5B0",
            padding: "14px 32px", borderRadius: 999, cursor: "pointer", border: "none",
            fontFamily: "'Source Sans 3',sans-serif",
          }}
            onMouseOver={e => e.currentTarget.style.boxShadow = "0 0 24px rgba(212,197,176,.35)"}
            onMouseOut={e => e.currentTarget.style.boxShadow = "none"}
          >Start ranking</button>
          <AppStoreBadge />
        </div>
      </div>

      <div style={{
        position: "absolute", bottom: 22, left: 0, right: 0,
        display: "flex", justifyContent: "center", zIndex: 3,
      }}>
        <span style={{ fontFamily: "'Space Mono',monospace", fontSize: 10, letterSpacing: ".25em", color: "rgba(155,163,171,.5)" }}>
          MEET THE AGENT ↓
        </span>
      </div>
    </section>
  );
}

/* ─── app store badge ─── */
function AppStoreBadge() {
  return (
    <span style={{
      display: "flex", alignItems: "center", gap: 9, background: "#000",
      border: "1px solid rgba(255,255,255,.2)", borderRadius: 999,
      padding: "10px 20px", cursor: "pointer", whiteSpace: "nowrap",
    }}
      onMouseOver={e => (e.currentTarget.style.borderColor = "rgba(255,255,255,.4)")}
      onMouseOut={e => (e.currentTarget.style.borderColor = "rgba(255,255,255,.2)")}
    >
      <svg width="18" height="21" viewBox="0 0 384 512" fill="#fff">
        <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z" />
      </svg>
      <span style={{ display: "flex", flexDirection: "column", alignItems: "flex-start", lineHeight: 1.15 }}>
        <span style={{ fontSize: 9, color: "rgba(255,255,255,.7)" }}>Download on the</span>
        <span style={{ fontSize: 15, fontWeight: 600, color: "#fff" }}>App Store</span>
      </span>
    </span>
  );
}

/* ─── iMessage mockup ─── */
function IMessageMockup() {
  const containerRef = useRef<HTMLDivElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const deadRef = useRef(false);
  const ranRef = useRef(false);
  const [inView, setInView] = useState(false);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const obs = new IntersectionObserver(([e]) => { if (e.isIntersecting) setInView(true); }, { threshold: 0.2 });
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  useEffect(() => {
    deadRef.current = false;
    return () => { deadRef.current = true; };
  }, []);

  const sleep = useCallback((ms: number) =>
    new Promise<void>(r => { setTimeout(r, ms); }), []);

  useEffect(() => {
    if (!inView || ranRef.current) return;
    ranRef.current = true;

    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    const el = scrollRef.current;
    if (!el) return;

    const seq = Array.from(el.querySelectorAll("[data-seq]")) as HTMLElement[];
    const reveal = (k: HTMLElement | undefined) => {
      if (!k) return;
      k.style.opacity = "1";
      k.style.transform = "none";
      if (el) el.scrollTop = el.scrollHeight;
    };

    if (reduced) { seq.forEach(reveal); return; }

    seq.forEach(k => {
      k.style.opacity = "0";
      k.style.transform = "translateY(10px)";
      k.style.transition = "opacity .45s ease, transform .45s ease";
    });
    el.scrollTop = 0;

    const screen = containerRef.current;
    if (!screen) return;
    const rs = screen.querySelector("[data-sheet='ranking']") as HTMLElement;
    const ts = screen.querySelector("[data-sheet='tickets']") as HTMLElement;

    (async () => {
      try {
        const s = async (ms: number) => { if (deadRef.current) throw 0; await sleep(ms); };
        await s(800);
        reveal(seq[0]);
        await s(950); reveal(seq[1]);
        await s(650); reveal(seq[2]);
        await s(850); if (rs) rs.style.transform = "translateY(0)";
        await s(950);
        const pick = rs?.querySelector("[data-pick='anora']") as HTMLElement;
        if (pick) { pick.style.borderColor = "#D4C5B0"; pick.style.boxShadow = "0 0 0 3px rgba(212,197,176,.35)"; }
        await s(650);
        const res = rs?.querySelector("[data-result]") as HTMLElement;
        if (res) { res.style.opacity = "1"; res.style.transform = "none"; }
        await s(1200);
        if (rs) rs.style.transform = "translateY(112%)";
        const l1 = seq[2];
        const t1 = l1?.querySelector("[data-title]") as HTMLElement;
        const s1 = l1?.querySelector("[data-sub]") as HTMLElement;
        if (t1) t1.textContent = "Anora — S tier";
        if (s1) s1.textContent = "Ranked ✓";
        if (l1) l1.style.borderColor = "rgba(212,197,176,.5)";
        await s(700); reveal(seq[3]);
        await s(1000); reveal(seq[4]);
        await s(950); reveal(seq[5]);
        await s(600); reveal(seq[6]);
        await s(800); if (ts) ts.style.transform = "translateY(0)";
        await s(850);
        const show = ts?.querySelector("[data-show='740']") as HTMLElement;
        if (show) { show.style.background = "#D4C5B0"; show.style.borderColor = "#D4C5B0"; show.style.color = "#0F1419"; }
        await s(650);
        const seats = ts?.querySelectorAll("[data-seat]") as NodeListOf<HTMLElement>;
        seats?.forEach((seat, i) => { setTimeout(() => { if (!deadRef.current) { seat.style.background = "#D4C5B0"; seat.style.borderColor = "#D4C5B0"; } }, i * 260); });
        await s(900);
        const pay = ts?.querySelector("[data-pay]") as HTMLElement;
        if (pay) { pay.style.transform = "scale(.95)"; await s(180); pay.style.transform = "none"; pay.textContent = "Booked ✓"; }
        await s(1000);
        if (ts) ts.style.transform = "translateY(112%)";
        const l2 = seq[6];
        const t2 = l2?.querySelector("[data-title]") as HTMLElement;
        const s2 = l2?.querySelector("[data-sub]") as HTMLElement;
        if (t2) t2.textContent = "2 tickets · Fri 7:40";
        if (s2) s2.textContent = "Booked ✓";
        if (l2) l2.style.borderColor = "rgba(212,197,176,.5)";
        await s(700); reveal(seq[7]);
      } catch { /* unmounted */ }
    })();
  }, [inView, sleep]);

  return (
    <div ref={containerRef} style={{
      width: 322, borderRadius: 46, background: "#000",
      border: "1px solid #23262b", padding: 11,
      boxShadow: "0 40px 100px rgba(0,0,0,.6), inset 0 0 0 2px #101216",
    }}>
      <div style={{
        position: "relative", borderRadius: 36, overflow: "hidden", background: "#000",
        fontFamily: "-apple-system,'SF Pro Text','Helvetica Neue',system-ui,sans-serif",
      }}>
        {/* status bar */}
        <div style={{
          position: "relative", height: 40, background: "#000",
          display: "flex", alignItems: "center", justifyContent: "space-between", padding: "0 26px",
        }}>
          <span style={{ fontSize: 12.5, fontWeight: 600, color: "#fff", letterSpacing: ".02em" }}>9:52</span>
          <div style={{ position: "absolute", left: "50%", top: 8, transform: "translateX(-50%)", width: 88, height: 24, background: "#000", borderRadius: 14 }} />
          <div style={{ display: "flex", alignItems: "center", gap: 5 }}>
            <svg width="16" height="11" viewBox="0 0 18 12" fill="#fff"><rect x="0" y="7" width="3" height="5" rx="1" /><rect x="4.5" y="5" width="3" height="7" rx="1" /><rect x="9" y="2.5" width="3" height="9.5" rx="1" /><rect x="13.5" y="0" width="3" height="12" rx="1" /></svg>
            <svg width="15" height="11" viewBox="0 0 16 12" fill="#fff"><path d="M8 2.2c2 0 3.9.8 5.3 2.1l1.1-1.2A9.3 9.3 0 0 0 8 .5 9.3 9.3 0 0 0 1.6 3.1l1.1 1.2A7.6 7.6 0 0 1 8 2.2Zm0 3c1.2 0 2.3.5 3.1 1.3l1.1-1.2A6 6 0 0 0 8 3.5a6 6 0 0 0-4.2 1.8l1.1 1.2A4.3 4.3 0 0 1 8 5.2Zm0 3c.5 0 1 .2 1.4.6L8 10.4 6.6 8.8c.4-.4.9-.6 1.4-.6Z" /></svg>
            <div style={{ display: "flex", alignItems: "center", gap: 2 }}>
              <div style={{ width: 22, height: 11, border: "1px solid rgba(255,255,255,.5)", borderRadius: 3, padding: 1 }}>
                <div style={{ width: "75%", height: "100%", background: "#fff", borderRadius: 1.5 }} />
              </div>
            </div>
          </div>
        </div>

        {/* chat header */}
        <div style={{
          padding: "6px 10px 12px", background: "rgba(18,18,20,.86)", backdropFilter: "blur(18px)",
          borderBottom: ".5px solid rgba(255,255,255,.08)", display: "flex", alignItems: "center", gap: 6,
        }}>
          <svg width="12" height="20" viewBox="0 0 12 20" fill="none" stroke="#0a84ff" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" style={{ flex: "none" }}>
            <path d="M10 2 3 10l7 8" />
          </svg>
          <div style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", gap: 3 }}>
            <div style={{
              width: 42, height: 42, borderRadius: "50%",
              background: "linear-gradient(160deg,#1C2128,#0F1419)",
              border: "1px solid rgba(212,197,176,.4)",
              display: "flex", alignItems: "center", justifyContent: "center",
            }}>
              <SpoolIcon w={25} h={18} sw={7} />
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 3 }}>
              <span style={{ fontSize: 11.5, color: "#fff", fontWeight: 500 }}>Spool</span>
              <svg width="8" height="8" viewBox="0 0 12 12" fill="none" stroke="#8a8f98" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M2 4l4 4 4-4" /></svg>
            </div>
          </div>
          <svg width="22" height="15" viewBox="0 0 24 16" fill="none" stroke="#0a84ff" strokeWidth="1.8" style={{ flex: "none" }}>
            <rect x="1" y="2" width="15" height="12" rx="3" /><path d="m17 6 6-3v10l-6-3Z" />
          </svg>
        </div>

        {/* messages */}
        <div ref={scrollRef} style={{
          padding: "14px 12px", display: "flex", flexDirection: "column", gap: 6,
          background: "#000", height: 498, overflow: "hidden",
        }}>
          <div style={{ textAlign: "center", fontSize: 10, color: "#8a8f98", marginBottom: 4 }}>
            <b style={{ color: "#c7ccd2" }}>iMessage</b> · Today 9:52 PM
          </div>

          {/* user: just watched Anora */}
          <div data-seq style={{ alignSelf: "flex-end", maxWidth: "76%", background: "linear-gradient(#2fa0ff,#0a7bff)", color: "#fff", fontSize: 14, lineHeight: 1.35, padding: "8px 13px", borderRadius: "19px 19px 5px 19px", boxShadow: "0 1px 1px rgba(0,0,0,.2)" }}>
            just watched Anora — absolutely loved it
          </div>

          {/* agent: logged it */}
          <div data-seq style={{ alignSelf: "flex-start", maxWidth: "80%", background: "#262628", color: "#fff", fontSize: 14, lineHeight: 1.35, padding: "8px 13px", borderRadius: "19px 19px 19px 5px" }}>
            Logged it 🎬 Let&rsquo;s place it against your canon 👇
          </div>

          {/* ranking launcher */}
          <div data-seq data-launch="ranking" style={{
            alignSelf: "flex-start", width: "80%", background: "#1C2128",
            border: ".5px solid rgba(212,197,176,.24)", borderRadius: 16,
            padding: "10px 12px", display: "flex", alignItems: "center", gap: 10,
            cursor: "pointer", transition: "border-color .4s ease",
          }}>
            <div style={{
              flex: "none", width: 38, height: 38, borderRadius: 10,
              background: "linear-gradient(160deg,#242b33,#0F1419)",
              border: "1px solid rgba(212,197,176,.3)",
              display: "flex", alignItems: "center", justifyContent: "center",
            }}><SpoolIcon w={22} h={16} sw={8} /></div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div data-title style={{ fontSize: 12.5, fontWeight: 600, color: "#F5F3EF" }}>Rank Anora</div>
              <div data-sub style={{ fontSize: 10, color: "#9BA3AB" }}>Anora vs Aftersun · tap to open</div>
            </div>
            <svg width="7" height="11" viewBox="0 0 8 12" fill="none" stroke="#6b7178" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ flex: "none" }}><path d="m2 2 4 4-4 4" /></svg>
          </div>

          {/* agent: placed in S tier */}
          <div data-seq style={{ alignSelf: "flex-start", maxWidth: "80%", background: "#262628", color: "#fff", fontSize: 14, lineHeight: 1.35, padding: "8px 13px", borderRadius: "19px 19px 19px 5px" }}>
            Logged — Anora&rsquo;s in your S tier 🔥 Want to note how it felt?
          </div>

          {/* user: nah */}
          <div data-seq style={{ alignSelf: "flex-end", maxWidth: "76%", background: "linear-gradient(#2fa0ff,#0a7bff)", color: "#fff", fontSize: 14, lineHeight: 1.35, padding: "8px 13px", borderRadius: "19px 19px 5px 19px", boxShadow: "0 1px 1px rgba(0,0,0,.2)" }}>
            nah I&rsquo;m good — what&rsquo;s playing near me tonight?
          </div>

          {/* agent: dune */}
          <div data-seq style={{ alignSelf: "flex-start", maxWidth: "80%", background: "#262628", color: "#fff", fontSize: 14, lineHeight: 1.35, padding: "8px 13px", borderRadius: "19px 19px 19px 5px" }}>
            Dune: Part Two, 7:40 at Metrograph 👇
          </div>

          {/* tickets launcher */}
          <div data-seq data-launch="tickets" style={{
            alignSelf: "flex-start", width: "80%", background: "#1C2128",
            border: ".5px solid rgba(212,197,176,.24)", borderRadius: 16,
            padding: "10px 12px", display: "flex", alignItems: "center", gap: 10,
            cursor: "pointer", transition: "border-color .4s ease",
          }}>
            <div style={{
              flex: "none", width: 38, height: 38, borderRadius: 10,
              background: "linear-gradient(160deg,#242b33,#0F1419)",
              border: "1px solid rgba(212,197,176,.3)",
              display: "flex", alignItems: "center", justifyContent: "center",
            }}>
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                <path d="M4 6h16v4a2 2 0 0 0 0 4v4H4v-4a2 2 0 0 0 0-4Z" /><path d="M13 6v12" />
              </svg>
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div data-title style={{ fontSize: 12.5, fontWeight: 600, color: "#F5F3EF" }}>Buy tickets</div>
              <div data-sub style={{ fontSize: 10, color: "#9BA3AB" }}>Dune: Part Two · tap to open</div>
            </div>
            <svg width="7" height="11" viewBox="0 0 8 12" fill="none" stroke="#6b7178" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ flex: "none" }}><path d="m2 2 4 4-4 4" /></svg>
          </div>

          {/* agent: booked */}
          <div data-seq style={{ alignSelf: "flex-start", maxWidth: "80%", background: "#262628", color: "#fff", fontSize: 14, lineHeight: 1.35, padding: "8px 13px", borderRadius: "19px 19px 19px 5px" }}>
            🎟️ Booked — 2 seats, Fri 7:40. Confirmation sent. Enjoy the show.
          </div>
        </div>

        {/* input bar */}
        <div style={{ padding: "9px 12px 16px", background: "#000", display: "flex", alignItems: "center", gap: 9 }}>
          <svg width="26" height="26" viewBox="0 0 26 26" fill="none" stroke="#8a8f98" strokeWidth="1.6" style={{ flex: "none" }}>
            <circle cx="13" cy="13" r="12" /><path d="M13 8v10M8 13h10" />
          </svg>
          <div style={{ flex: 1, height: 32, borderRadius: 999, border: "1px solid #2a2f36", display: "flex", alignItems: "center", padding: "0 14px", fontSize: 12.5, color: "#6b7178" }}>iMessage</div>
          <span style={{
            width: 30, height: 30, borderRadius: "50%", background: "#0a7bff",
            display: "flex", alignItems: "center", justifyContent: "center", flex: "none",
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
              <path d="M12 19V5" /><path d="m5 12 7-7 7 7" />
            </svg>
          </span>
        </div>

        {/* ranking app sheet */}
        <div data-sheet="ranking" style={{
          position: "absolute", left: 0, right: 0, bottom: 0, top: 120,
          background: "#0b0d10", borderRadius: "24px 24px 36px 36px",
          transform: "translateY(112%)", transition: "transform .55s cubic-bezier(.32,.72,0,1)",
          zIndex: 6, display: "flex", flexDirection: "column",
          boxShadow: "0 -24px 60px rgba(0,0,0,.6)",
        }}>
          <div style={{ padding: "8px 0 4px", display: "flex", justifyContent: "center" }}>
            <div style={{ width: 38, height: 5, borderRadius: 3, background: "rgba(255,255,255,.22)" }} />
          </div>
          <div style={{
            padding: "4px 16px 12px", display: "flex", alignItems: "center", justifyContent: "space-between",
            borderBottom: ".5px solid rgba(255,255,255,.07)",
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
              <SpoolIcon w={18} h={13} sw={8} />
              <span style={{ fontSize: 12, fontWeight: 600, color: "#F5F3EF" }}>Rank</span>
            </div>
            <span style={{ fontSize: 13, fontWeight: 600, color: "#D4C5B0" }}>Done</span>
          </div>
          <div style={{ flex: 1, padding: "20px 16px", display: "flex", flexDirection: "column" }}>
            <div style={{ display: "flex", justifyContent: "center", gap: 5, marginBottom: 16 }}>
              <span style={{ width: 18, height: 4, borderRadius: 2, background: "#D4C5B0" }} />
              <span style={{ width: 18, height: 4, borderRadius: 2, background: "rgba(255,255,255,.18)" }} />
              <span style={{ width: 18, height: 4, borderRadius: 2, background: "rgba(255,255,255,.18)" }} />
            </div>
            <div style={{ textAlign: "center", fontFamily: "'Cormorant Garamond',serif", fontStyle: "italic", fontSize: 22, color: "#F5F3EF", marginBottom: 20 }}>
              Which was better?
            </div>
            <div style={{ display: "flex", alignItems: "stretch", gap: 14 }}>
              <div data-pick="anora" style={{
                flex: 1, borderRadius: 14, overflow: "hidden",
                border: "2px solid rgba(255,255,255,.1)", background: "#0F1419",
                transition: "border-color .3s ease, box-shadow .3s ease",
              }}>
                <div style={{ height: 150, background: "linear-gradient(135deg,#7a2d3a,#2c1520)" }} />
                <div style={{ padding: "9px 10px" }}>
                  <div style={{ fontSize: 13, fontWeight: 600, color: "#F5F3EF" }}>Anora</div>
                  <div style={{ fontSize: 10, color: "#9BA3AB" }}>just watched</div>
                </div>
              </div>
              <div style={{ flex: "none", alignSelf: "center", fontFamily: "'Cormorant Garamond',serif", fontStyle: "italic", fontSize: 18, color: "#B8A998" }}>vs</div>
              <div style={{
                flex: 1, borderRadius: 14, overflow: "hidden",
                border: "2px solid rgba(255,255,255,.1)", background: "#0F1419",
              }}>
                <div style={{ height: 150, background: "linear-gradient(135deg,#1d3a5f,#0e1b30)" }} />
                <div style={{ padding: "9px 10px" }}>
                  <div style={{ fontSize: 13, fontWeight: 600, color: "#F5F3EF" }}>Aftersun</div>
                  <div style={{ fontSize: 10, color: "#9BA3AB" }}>your A tier</div>
                </div>
              </div>
            </div>
            <div data-result style={{
              opacity: 0, transform: "translateY(8px)",
              transition: "opacity .4s ease, transform .4s ease",
              marginTop: "auto", paddingTop: 16, textAlign: "center",
            }}>
              <span style={{ display: "inline-flex", alignItems: "center", gap: 7, fontSize: 13, color: "#F5F3EF" }}>
                <span style={{ fontSize: 11, fontWeight: 800, background: "#A855F7", color: "#fff", padding: "2px 8px", borderRadius: 4 }}>S</span>
                Placed in your S tier
              </span>
            </div>
          </div>
        </div>

        {/* tickets app sheet */}
        <div data-sheet="tickets" style={{
          position: "absolute", left: 0, right: 0, bottom: 0, top: 120,
          background: "#0b0d10", borderRadius: "24px 24px 36px 36px",
          transform: "translateY(112%)", transition: "transform .55s cubic-bezier(.32,.72,0,1)",
          zIndex: 6, display: "flex", flexDirection: "column",
          boxShadow: "0 -24px 60px rgba(0,0,0,.6)",
        }}>
          <div style={{ padding: "8px 0 4px", display: "flex", justifyContent: "center" }}>
            <div style={{ width: 38, height: 5, borderRadius: 3, background: "rgba(255,255,255,.22)" }} />
          </div>
          <div style={{
            padding: "4px 16px 12px", display: "flex", alignItems: "center", justifyContent: "space-between",
            borderBottom: ".5px solid rgba(255,255,255,.07)",
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                <path d="M4 6h16v4a2 2 0 0 0 0 4v4H4v-4a2 2 0 0 0 0-4Z" /><path d="M13 6v12" />
              </svg>
              <span style={{ fontSize: 12, fontWeight: 600, color: "#F5F3EF" }}>Tickets</span>
            </div>
            <span style={{ fontSize: 13, fontWeight: 600, color: "#D4C5B0" }}>Done</span>
          </div>
          <div style={{ flex: 1, padding: "18px 16px", display: "flex", flexDirection: "column", gap: 16 }}>
            <div>
              <div style={{ fontFamily: "'Cormorant Garamond',serif", fontSize: 22, color: "#F5F3EF" }}>Dune: Part Two</div>
              <div style={{ fontSize: 11, color: "#9BA3AB" }}>Metrograph · Fri, Jul 17</div>
            </div>
            <div>
              <div style={{ fontSize: 10, letterSpacing: ".14em", color: "#8BA8BA", fontFamily: "'Space Mono',monospace", marginBottom: 8 }}>SHOWTIME</div>
              <div style={{ display: "flex", gap: 8 }}>
                <span style={{ fontSize: 12, color: "#9BA3AB", border: "1px solid rgba(255,255,255,.14)", padding: "8px 14px", borderRadius: 10 }}>5:10</span>
                <span data-show="740" style={{ fontSize: 12, color: "#9BA3AB", border: "1px solid rgba(255,255,255,.14)", padding: "8px 14px", borderRadius: 10, transition: "all .3s ease" }}>7:40</span>
                <span style={{ fontSize: 12, color: "#9BA3AB", border: "1px solid rgba(255,255,255,.14)", padding: "8px 14px", borderRadius: 10 }}>9:55</span>
              </div>
            </div>
            <div>
              <div style={{ fontSize: 10, letterSpacing: ".14em", color: "#8BA8BA", fontFamily: "'Space Mono',monospace", marginBottom: 8 }}>SEATS</div>
              <div style={{ display: "flex", gap: 8 }}>
                <span data-seat style={{ width: 30, height: 30, borderRadius: 7, border: "1px solid rgba(255,255,255,.16)", transition: "all .3s ease" }} />
                <span data-seat style={{ width: 30, height: 30, borderRadius: 7, border: "1px solid rgba(255,255,255,.16)", transition: "all .3s ease" }} />
                <span style={{ width: 30, height: 30, borderRadius: 7, border: "1px solid rgba(255,255,255,.16)" }} />
                <span style={{ width: 30, height: 30, borderRadius: 7, border: "1px solid rgba(255,255,255,.16)" }} />
              </div>
            </div>
            <div style={{ marginTop: "auto", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <span style={{ fontSize: 13, color: "#9BA3AB" }}>2 tickets</span>
              <span style={{ fontFamily: "'Cormorant Garamond',serif", fontSize: 22, color: "#F5F3EF" }}>$28.00</span>
            </div>
            <div data-pay style={{
              textAlign: "center", fontSize: 14, fontWeight: 700, color: "#0F1419",
              background: "#D4C5B0", padding: "13px 0", borderRadius: 999,
              transition: "transform .15s ease",
            }}>Confirm &amp; Pay</div>
          </div>
        </div>
      </div>
    </div>
  );
}

/* ─── agent section ─── */
function AgentSection() {
  return (
    <section style={{ padding: "70px 32px 90px", maxWidth: 1120, margin: "0 auto" }}>
      <div style={{ display: "flex", gap: 72, alignItems: "center", flexWrap: "wrap" }}>
        {/* copy */}
        <div style={{ flex: "1 1 380px", minWidth: 320 }}>
          <div style={{
            display: "inline-flex", alignItems: "center", gap: 7, padding: "5px 12px",
            borderRadius: 999, background: "rgba(139,168,186,.1)", border: "1px solid rgba(139,168,186,.25)",
            marginBottom: 22,
          }}>
            <span style={{
              width: 16, height: 16, borderRadius: "50%", background: "#34C759",
              display: "inline-flex", alignItems: "center", justifyContent: "center",
            }}>
              <svg width="9" height="9" viewBox="0 0 24 24" fill="none">
                <path d="M12 2C6.5 2 2 5.9 2 10.8c0 2.8 1.5 5.3 3.8 6.9-.2 1.4-.9 2.7-1.8 3.6 1.6-.2 3.2-.8 4.5-1.7 1.1.3 2.3.5 3.5.5 5.5 0 10-3.9 10-8.8S17.5 2 12 2z" fill="#fff" />
              </svg>
            </span>
            <span style={{ fontFamily: "'Space Mono',monospace", fontSize: 10, letterSpacing: ".16em", color: "#8BA8BA" }}>
              NEW · WORKS IN iMESSAGE
            </span>
          </div>
          <h2 style={{
            fontFamily: "'Cormorant Garamond',serif", fontSize: "clamp(30px,3.6vw,42px)",
            color: "#F5F3EF", margin: "0 0 18px", letterSpacing: "-0.02em",
            fontWeight: 400, lineHeight: 1.1,
          }}>Text it like a friend who&rsquo;s seen everything</h2>
          <p style={{ fontSize: 16, color: "#9BA3AB", lineHeight: 1.65, maxWidth: 440, margin: "0 0 30px" }}>
            The Spool agent lives right in your Messages. Log a movie night, ask what to watch, and grab tickets — without leaving the thread.
          </p>
          <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
            {AGENT_FEATURES.map((f, i) => (
              <div key={i} style={{ display: "flex", gap: 14, alignItems: "flex-start" }}>
                <span style={{
                  flex: "none", width: 34, height: 34, borderRadius: 9,
                  background: "rgba(212,197,176,.1)", border: "1px solid rgba(212,197,176,.28)",
                  display: "flex", alignItems: "center", justifyContent: "center",
                }}>{f.icon}</span>
                <div>
                  <div style={{ fontSize: 15, fontWeight: 600, color: "#F5F3EF", marginBottom: 2 }}>{f.title}</div>
                  <p style={{ fontSize: 13.5, color: "#9BA3AB", lineHeight: 1.55, margin: 0 }}>{f.desc}</p>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* phone mockup */}
        <div style={{ flex: "0 1 340px", minWidth: 300, display: "flex", justifyContent: "center" }}>
          <IMessageMockup />
        </div>
      </div>
    </section>
  );
}

const AGENT_FEATURES = [
  {
    title: "Journal intakes by text",
    desc: "Just say what you watched — the agent files the entry, mood, and tier for you.",
    icon: <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 20h9" /><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" /></svg>,
  },
  {
    title: "Recommendations that know your taste",
    desc: "Built from your rankings and your friends’ — not a generic trending list.",
    icon: <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 2 15 9l7 .5-5.5 4.5L18 21l-6-4-6 4 1.5-7L2 9.5 9 9Z" /></svg>,
  },
  {
    title: "Buy tickets in the thread",
    desc: "Pick a showtime and check out — the agent hands back the confirmation.",
    icon: <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M4 6h16v4a2 2 0 0 0 0 4v4H4v-4a2 2 0 0 0 0-4Z" /><path d="M13 6v12" /></svg>,
  },
];

/* ─── features section ─── */
const FEATURES = [
  {
    title: "Tier-based ranking",
    desc: "S through D, placed by an adaptive head-to-head engine — not a guess at a star rating.",
    icon: <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="4" width="18" height="4" rx="1" /><rect x="5" y="10" width="14" height="4" rx="1" /><rect x="7" y="16" width="10" height="4" rx="1" /></svg>,
  },
  {
    title: "Movies, TV & books",
    desc: "One search bar, three media types. Your whole taste lives under a single canon.",
    icon: <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" /><path d="M7 3v18M17 3v18M3 8h4M3 16h4M17 8h4M17 16h4" /></svg>,
  },
  {
    title: "Journal & stubs",
    desc: "Every night mints a ticket stub — date, mood, and a line you’ll remember it by.",
    icon: <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M4 4a2 2 0 0 1 2-2h11a1 1 0 0 1 1 1v18a1 1 0 0 1-1 1H6a2 2 0 0 1-2-2Z" /><path d="M8 7h6M8 11h6" /></svg>,
  },
  {
    title: "Social feed",
    desc: "Follow friends, react to their rankings, and see who agrees with you — and who doesn’t.",
    icon: <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" /><circle cx="9" cy="7" r="4" /><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13A4 4 0 0 1 16 11" /></svg>,
  },
  {
    title: "Taste DNA",
    desc: "Genre radar, tier distribution, and a compatibility score with every friend you follow.",
    icon: <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><polygon points="12 2 20 7 20 17 12 22 4 17 4 7" /><path d="M12 2v20M4 7l16 10M20 7 4 17" /></svg>,
  },
  {
    title: "Bring your history",
    desc: "Import your Letterboxd rankings from CSV and pick up right where you left off.",
    icon: <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="#D4C5B0" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" /><path d="M7 10l5 5 5-5M12 15V3" /></svg>,
  },
];

function FeaturesSection() {
  return (
    <section style={{ padding: "80px 32px 90px", maxWidth: 1120, margin: "0 auto" }}>
      <div style={{ maxWidth: 600, marginBottom: 44 }}>
        <div style={{ fontFamily: "'Space Mono',monospace", fontSize: 11, letterSpacing: ".24em", color: "#B8A998", marginBottom: 16 }}>
          EVERYTHING IN ONE CANON
        </div>
        <h2 style={{
          fontFamily: "'Cormorant Garamond',serif", fontSize: "clamp(30px,3.8vw,44px)",
          color: "#F5F3EF", margin: 0, letterSpacing: "-0.02em", fontWeight: 400, lineHeight: 1.1,
        }}>A whole ritual around what you watch and read</h2>
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill,minmax(320px,1fr))", gap: 16 }}>
        {FEATURES.map((f, i) => (
          <FeatureCard key={i} {...f} />
        ))}
      </div>
    </section>
  );
}

function FeatureCard({ title, desc, icon }: { title: string; desc: string; icon: React.ReactNode }) {
  const [hovered, setHovered] = useState(false);
  return (
    <div
      onMouseOver={() => setHovered(true)} onMouseOut={() => setHovered(false)}
      style={{
        background: "#1C2128", border: "1px solid #252C35", borderRadius: 16,
        padding: "26px 24px", transition: "border-color .25s ease, transform .25s ease",
        ...(hovered ? { borderColor: "rgba(212,197,176,.4)", transform: "translateY(-3px)" } : {}),
      }}
    >
      <div style={{
        width: 40, height: 40, borderRadius: 11, background: "rgba(212,197,176,.1)",
        border: "1px solid rgba(212,197,176,.28)", display: "flex", alignItems: "center",
        justifyContent: "center", marginBottom: 18,
      }}>{icon}</div>
      <h3 style={{
        fontFamily: "'Cormorant Garamond',serif", fontSize: 21, color: "#F5F3EF",
        fontWeight: 500, margin: "0 0 8px",
      }}>{title}</h3>
      <p style={{ fontSize: 14, color: "#9BA3AB", lineHeight: 1.6, margin: 0 }}>{desc}</p>
    </div>
  );
}

/* ─── closing CTA ─── */
function ClosingCTA({ onAuth }: { onAuth: (mode: string) => void }) {
  return (
    <section style={{ position: "relative", padding: "100px 32px 110px", overflow: "hidden", borderTop: "1px solid #252C35" }}>
      <div style={{
        position: "absolute", top: "50%", left: "50%", transform: "translate(-50%,-50%)",
        width: 720, height: 420, borderRadius: 999, filter: "blur(80px)",
        background: "radial-gradient(circle, rgba(212,197,176,0.14) 0%, transparent 70%)",
        pointerEvents: "none",
      }} />
      <div style={{ position: "relative", maxWidth: 680, margin: "0 auto", textAlign: "center", zIndex: 1 }}>
        <SpoolIcon w={66} h={47} />
        <h2 style={{
          fontFamily: "'Cormorant Garamond',serif",
          fontSize: "clamp(38px,5.5vw,64px)", color: "#F5F3EF", margin: "24px 0 18px",
          letterSpacing: "-0.03em", fontWeight: 400, lineHeight: 1.05,
          textWrap: "balance" as any,
        }}>Start your canon tonight</h2>
        <p style={{ fontSize: 17, color: "#9BA3AB", lineHeight: 1.6, maxWidth: 460, margin: "0 auto 36px" }}>
          Rank the last thing you watched and let Spool build the rest — right from your Messages.
        </p>
        <div style={{ display: "flex", gap: 12, alignItems: "center", flexWrap: "wrap", justifyContent: "center" }}>
          <button onClick={() => onAuth("signup")} style={{
            whiteSpace: "nowrap", display: "inline-flex", alignItems: "center",
            fontSize: 16, fontWeight: 600, color: "#0F1419", background: "#D4C5B0",
            padding: "15px 36px", borderRadius: 999, cursor: "pointer", border: "none",
            fontFamily: "'Source Sans 3',sans-serif",
          }}
            onMouseOver={e => e.currentTarget.style.boxShadow = "0 0 28px rgba(212,197,176,.4)"}
            onMouseOut={e => e.currentTarget.style.boxShadow = "none"}
          >Start ranking</button>
          <AppStoreBadge />
        </div>
      </div>
    </section>
  );
}

/* ─── footer ─── */
function LandingFooter() {
  return (
    <footer style={{ borderTop: "1px solid #252C35" }}>
      <div style={{
        padding: "28px 32px", display: "flex", justifyContent: "space-between", alignItems: "center",
        maxWidth: 1120, margin: "0 auto", flexWrap: "wrap", gap: 16,
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 7 }}>
          <SpoolIcon w={24} h={17} />
          <span style={{ fontFamily: "'Cormorant Garamond',serif", fontSize: 14, color: "#9BA3AB" }}>Spool</span>
        </div>
        <div style={{ display: "flex", gap: 24 }}>
          {["About", "Privacy", "Terms", "Contact"].map(label => (
            <a key={label} href="#" style={{ fontSize: 12, color: "#9BA3AB", padding: "12px 4px", display: "inline-block", textDecoration: "none" }}
              onMouseOver={e => e.currentTarget.style.color = "#F5F3EF"}
              onMouseOut={e => e.currentTarget.style.color = "#9BA3AB"}
            >{label}</a>
          ))}
        </div>
        <span style={{ fontSize: 11, color: "#9BA3AB" }}>&copy; 2026 Spool</span>
      </div>
    </footer>
  );
}

/* ─── main ─── */
export default function LandingPage() {
  const navigate = useNavigate();
  const { user } = useAuth();

  const handleAuth = (mode: string) => {
    if (user) {
      navigate("/app");
    } else if (mode === "login") {
      navigate("/auth");
    } else {
      navigate("/onboarding/movies");
    }
  };

  return (
    <div style={{
      background: "radial-gradient(circle at 12% 18%, rgba(212,197,176,0.10), transparent 34%),radial-gradient(circle at 88% 6%, rgba(139,168,186,0.08), transparent 28%),linear-gradient(180deg,#0F1419 0%,#0F1419 42%,#0c1015 100%)",
      minHeight: "100vh", overflowX: "hidden",
    }}>
      <Nav onAuth={handleAuth} />
      <main>
        <HeroSection onAuth={handleAuth} />
        <AgentSection />
        <FeaturesSection />
        <ClosingCTA onAuth={handleAuth} />
      </main>
      <LandingFooter />
    </div>
  );
}
