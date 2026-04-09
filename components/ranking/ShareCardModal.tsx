import React, { useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import FocusTrap from 'focus-trap-react';
import { Download, Share2, X } from 'lucide-react';
import { exportCardImage } from '../../utils/exportCardImage';
import { RankedItem, GenreProfileItem } from '../../types';
import { TIERS, TIER_HEX, TIER_RADAR_HEX } from '../../constants';
import { useTranslation } from '../../contexts/LanguageContext';
import { ShareCardFooter } from '../shared/ShareCardFooter';
import { Toast } from '../shared/Toast';

type CardType = 'top5' | 'tasteDna';

interface ShareCardModalProps {
  open: boolean;
  onClose: () => void;
  items: RankedItem[];
  genreProfile: GenreProfileItem[];
  username: string;
  displayName?: string;
}

export const ShareCardModal: React.FC<ShareCardModalProps> = ({
  open,
  onClose,
  items,
  genreProfile,
  username,
  displayName,
}) => {
  const { t } = useTranslation();
  const [activeCard, setActiveCard] = useState<CardType>('top5');
  const [exporting, setExporting] = useState(false);
  const [toastMessage, setToastMessage] = useState<string | null>(null);
  const cardRef = useRef<HTMLDivElement>(null);

  if (!open) return null;

  const topItems = items
    .filter((i) => i.tier === 'S' || i.tier === 'A')
    .slice(0, 5);

  const tierCounts = TIERS.map((tier) => ({
    tier,
    count: items.filter((i) => i.tier === tier).length,
  }));

  const topGenres = genreProfile.slice(0, 6);
  const name = displayName || username;

  const handleExport = async () => {
    if (!cardRef.current) return;
    setExporting(true);
    try {
      await exportCardImage(cardRef.current, `spool-${activeCard}.png`, `${name} on Spool`);
    } catch (err) {
      console.error('Share card export failed:', err);
      setToastMessage(t('share.exportFailed'));
    } finally {
      setExporting(false);
    }
  };

  return createPortal(
    <FocusTrap focusTrapOptions={{ allowOutsideClick: true }}>
      <div
        className="fixed inset-0 z-[9999] flex items-center justify-center bg-black/70 backdrop-blur-sm p-4"
        onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
        role="dialog"
        aria-modal="true"
        aria-label={t('share.title')}
      >
        <div className="w-full max-w-md bg-card border border-border/30 rounded-2xl overflow-hidden">
          {/* Header */}
          <div className="flex items-center justify-between px-4 py-3 border-b border-border/30">
            <h2 className="text-sm font-semibold text-foreground">{t('share.title')}</h2>
            <button onClick={onClose} className="text-muted-foreground hover:text-foreground">
              <X size={18} />
            </button>
          </div>

          {/* Card type tabs */}
          <div className="flex gap-1 px-4 pt-3">
            {([
              { key: 'top5' as CardType, label: t('share.top5') },
              { key: 'tasteDna' as CardType, label: t('share.tasteDna') },
            ]).map(({ key, label }) => (
              <button
                key={key}
                onClick={() => setActiveCard(key)}
                className={`px-3 py-1.5 rounded-lg text-xs font-medium transition-colors ${
                  activeCard === key
                    ? 'bg-gold/20 text-gold'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                {label}
              </button>
            ))}
          </div>

          {/* Card preview */}
          <div className="p-4">
            <div className="flex justify-center">
              {activeCard === 'top5' && (
                <Top5Card
                  ref={cardRef}
                  items={topItems}
                  name={name}
                  username={username}
                  tierHex={TIER_HEX}
                  t={t}
                />
              )}
              {activeCard === 'tasteDna' && (
                <TasteDnaCard
                  ref={cardRef}
                  genreProfile={topGenres}
                  tierCounts={tierCounts}
                  name={name}
                  username={username}
                  totalRanked={items.length}
                  tierRadarHex={TIER_RADAR_HEX}
                  t={t}
                />
              )}
            </div>
          </div>

          {/* Actions */}
          <div className="px-4 pb-4 flex gap-2">
            <button
              onClick={handleExport}
              disabled={exporting}
              className="flex-1 flex items-center justify-center gap-2 px-4 py-2.5 bg-gold text-foreground font-semibold rounded-xl text-sm hover:bg-gold-muted transition-colors disabled:opacity-50"
            >
              {navigator.share ? <Share2 size={14} /> : <Download size={14} />}
              {exporting
                ? t('share.exporting')
                : navigator.share
                  ? t('share.shareImage')
                  : t('share.downloadImage')
              }
            </button>
          </div>
        </div>
        {toastMessage && (
          <Toast message={toastMessage} onDone={() => setToastMessage(null)} />
        )}
      </div>
    </FocusTrap>,
    document.body,
  );
};

/* ─── Top 5 Card ─── */

const Top5Card = React.forwardRef<
  HTMLDivElement,
  {
    items: RankedItem[];
    name: string;
    username: string;
    tierHex: Record<string, string>;
    t: (key: string) => string;
  }
>(({ items, name, username, tierHex, t }, ref) => (
  <div
    ref={ref}
    style={{
      width: 360,
      padding: 24,
      background: 'linear-gradient(145deg, #0F1419 0%, #1C2128 100%)',
      borderRadius: 16,
      fontFamily: "'Source Sans 3', sans-serif",
    }}
  >
    {/* Header */}
    <div style={{ marginBottom: 16 }}>
      <div
        style={{
          fontSize: 20,
          fontWeight: 700,
          color: '#D4C5B0',
          fontFamily: "'Cormorant Garamond', serif",
          marginBottom: 2,
        }}
      >
        {name}
      </div>
      <div style={{ fontSize: 11, color: '#6B7280' }}>
        @{username} · spool.app
      </div>
    </div>

    {/* Title */}
    <div
      style={{
        fontSize: 13,
        fontWeight: 600,
        color: '#9BA3AB',
        textTransform: 'uppercase',
        letterSpacing: '0.08em',
        marginBottom: 12,
      }}
    >
      {t('share.myTopPicks')}
    </div>

    {/* Poster grid */}
    <div style={{ display: 'flex', gap: 8 }}>
      {items.map((item, i) => (
        <div key={item.id} style={{ flex: 1, position: 'relative' }}>
          <img
            src={item.posterUrl}
            alt={item.title}
            crossOrigin="anonymous"
            style={{
              width: '100%',
              aspectRatio: '2/3',
              objectFit: 'cover',
              borderRadius: 8,
              border: `1px solid rgba(255,255,255,0.08)`,
            }}
          />
          <div
            style={{
              position: 'absolute',
              top: 4,
              left: 4,
              background: tierHex[item.tier] || '#71717a',
              color: '#000',
              fontSize: 9,
              fontWeight: 800,
              padding: '1px 5px',
              borderRadius: 4,
            }}
          >
            {item.tier}
          </div>
          <div
            style={{
              marginTop: 4,
              fontSize: 9,
              color: '#9BA3AB',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
            }}
          >
            {item.title}
          </div>
        </div>
      ))}
      {/* Empty slots */}
      {Array.from({ length: Math.max(0, 5 - items.length) }).map((_, i) => (
        <div
          key={`empty-${i}`}
          style={{
            flex: 1,
            aspectRatio: '2/3',
            borderRadius: 8,
            border: '1px dashed rgba(255,255,255,0.1)',
            background: 'rgba(255,255,255,0.02)',
          }}
        />
      ))}
    </div>

    <ShareCardFooter username={username} />
  </div>
));

Top5Card.displayName = 'Top5Card';

/* ─── Taste DNA Card ─── */

const TasteDnaCard = React.forwardRef<
  HTMLDivElement,
  {
    genreProfile: GenreProfileItem[];
    tierCounts: { tier: string; count: number }[];
    name: string;
    username: string;
    totalRanked: number;
    tierRadarHex: Record<string, string>;
    t: (key: string) => string;
  }
>(({ genreProfile, tierCounts, name, username, totalRanked, tierRadarHex, t }, ref) => {
  const size = 180;
  const cx = size / 2;
  const cy = size / 2;
  const radius = size / 2 - 28;
  const maxCount = Math.max(...genreProfile.map((g) => g.count), 1);
  const angleStep = genreProfile.length > 0 ? (2 * Math.PI) / genreProfile.length : 0;

  const points = genreProfile.map((g, i) => {
    const angle = angleStep * i - Math.PI / 2;
    const r = (g.count / maxCount) * radius;
    return `${cx + r * Math.cos(angle)},${cy + r * Math.sin(angle)}`;
  });

  const rings = [0.33, 0.66, 1.0];

  return (
    <div
      ref={ref}
      style={{
        width: 360,
        padding: 24,
        background: 'linear-gradient(145deg, #0F1419 0%, #1C2128 100%)',
        borderRadius: 16,
        fontFamily: "'Source Sans 3', sans-serif",
      }}
    >
      {/* Header */}
      <div style={{ marginBottom: 16 }}>
        <div
          style={{
            fontSize: 20,
            fontWeight: 700,
            color: '#D4C5B0',
            fontFamily: "'Cormorant Garamond', serif",
            marginBottom: 2,
          }}
        >
          {name}
        </div>
        <div style={{ fontSize: 11, color: '#6B7280' }}>
          @{username} · {totalRanked} {t('share.ranked')}
        </div>
      </div>

      {/* Title */}
      <div
        style={{
          fontSize: 13,
          fontWeight: 600,
          color: '#9BA3AB',
          textTransform: 'uppercase',
          letterSpacing: '0.08em',
          marginBottom: 12,
        }}
      >
        {t('share.tasteDna')}
      </div>

      {/* Mini radar */}
      {genreProfile.length > 0 && (
        <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 16 }}>
          <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
            {/* Rings */}
            {rings.map((scale) => (
              <polygon
                key={scale}
                points={genreProfile
                  .map((_, i) => {
                    const angle = angleStep * i - Math.PI / 2;
                    const r = scale * radius;
                    return `${cx + r * Math.cos(angle)},${cy + r * Math.sin(angle)}`;
                  })
                  .join(' ')}
                fill="none"
                stroke="rgba(113,113,122,0.2)"
                strokeWidth="0.5"
              />
            ))}
            {/* Axes */}
            {genreProfile.map((_, i) => {
              const angle = angleStep * i - Math.PI / 2;
              return (
                <line
                  key={i}
                  x1={cx}
                  y1={cy}
                  x2={cx + radius * Math.cos(angle)}
                  y2={cy + radius * Math.sin(angle)}
                  stroke="rgba(113,113,122,0.12)"
                  strokeWidth="0.5"
                />
              );
            })}
            {/* Filled polygon */}
            <polygon
              points={points.join(' ')}
              fill="rgba(245,158,11,0.15)"
              stroke="#f59e0b"
              strokeWidth="1.5"
            />
            {/* Labels */}
            {genreProfile.map((g, i) => {
              const angle = angleStep * i - Math.PI / 2;
              const labelR = radius + 16;
              const lx = cx + labelR * Math.cos(angle);
              const ly = cy + labelR * Math.sin(angle);
              const anchor =
                Math.abs(Math.cos(angle)) < 0.1
                  ? 'middle'
                  : Math.cos(angle) > 0
                    ? 'start'
                    : 'end';
              return (
                <text
                  key={i}
                  x={lx}
                  y={ly}
                  textAnchor={anchor}
                  dominantBaseline="middle"
                  fill="#9BA3AB"
                  fontSize="8"
                  fontWeight="500"
                >
                  {g.genre}
                </text>
              );
            })}
          </svg>
        </div>
      )}

      {/* Tier distribution bar */}
      <div style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', gap: 2, height: 20, borderRadius: 6, overflow: 'hidden' }}>
          {tierCounts.map(({ tier, count }) => {
            if (count === 0) return null;
            const pct = totalRanked > 0 ? (count / totalRanked) * 100 : 0;
            return (
              <div
                key={tier}
                style={{
                  width: `${pct}%`,
                  background: tierRadarHex[tier] || '#71717a',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: 9,
                  fontWeight: 700,
                  color: '#000',
                  minWidth: count > 0 ? 16 : 0,
                }}
              >
                {tier}
              </div>
            );
          })}
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 4 }}>
          {tierCounts.map(({ tier, count }) => (
            <div key={tier} style={{ fontSize: 9, color: '#6B7280', textAlign: 'center', flex: 1 }}>
              {count}
            </div>
          ))}
        </div>
      </div>

      {/* Top genres list */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6 }}>
        {genreProfile.map((g) => (
          <div
            key={g.genre}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 6,
              padding: '4px 8px',
              borderRadius: 6,
              background: 'rgba(255,255,255,0.03)',
            }}
          >
            <div
              style={{
                width: 18,
                height: 18,
                borderRadius: 4,
                background: tierRadarHex[g.avgTier] || '#71717a',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 8,
                fontWeight: 800,
                color: '#000',
              }}
            >
              {g.avgTier}
            </div>
            <div>
              <div style={{ fontSize: 10, color: '#E5E7EB', fontWeight: 500 }}>{g.genre}</div>
              <div style={{ fontSize: 8, color: '#6B7280' }}>{g.percentage}%</div>
            </div>
          </div>
        ))}
      </div>

      <ShareCardFooter username={username} />
    </div>
  );
});

TasteDnaCard.displayName = 'TasteDnaCard';
