import React, { useEffect, useState } from 'react';
import { ResponsiveContainer, PieChart, Pie, Cell, Tooltip, BarChart, Bar, XAxis, YAxis } from 'recharts';
import { RankedItem, Tier, GenreProfileItem } from '../../types';
import { TIER_COLORS } from '../../constants';
import { GenreRadarChart } from './GenreRadarChart';
import { ShareCardModal } from './ShareCardModal';
import { getGenreProfile } from '../../services/friendsService';
import { Share2, Star } from 'lucide-react';
import { useTranslation } from '../../contexts/LanguageContext';
import { useAuth } from '../../contexts/AuthContext';
import { StreakBadge } from '../shared/StreakBadge';

interface StatsViewProps {
  items: RankedItem[];
  userId: string;
  mediaMode?: 'movies' | 'tv' | 'books';
  streakStats?: { currentStreak: number; longestStreak: number };
}

export const StatsView: React.FC<StatsViewProps> = ({ items, userId, mediaMode = 'movies', streakStats }) => {
  const { t } = useTranslation();
  const { profile } = useAuth();
  const [genreProfile, setGenreProfile] = useState<GenreProfileItem[]>([]);
  const [shareOpen, setShareOpen] = useState(false);

  useEffect(() => {
    if (!userId) return;
    const mediaType = mediaMode === 'books' ? 'book' : mediaMode === 'tv' ? 'tv_season' : 'movie';
    getGenreProfile(userId, mediaType).then(setGenreProfile).catch(console.error);
  }, [userId, mediaMode]);
  const tierCounts = Object.values(Tier).map(tier => ({
    name: tier,
    value: items.filter(i => i.tier === tier).length,
    color: TIER_COLORS[tier].split(' ')[0].replace('text-', '#').replace('400', '4ADE80').replace('blue-', '#60A5FA').replace('yellow-', '#FCD34D').replace('red-', '#F87171').replace('zinc-', '#A1A1AA') // Quick hack to extract hex from tailwind class name logic for demo
  }));

  // Normalized hex colors for recharts
  const COLORS = ['#FCD34D', '#4ADE80', '#60A5FA', '#A1A1AA', '#F87171'];

  const mediaLabel = mediaMode === 'books' ? t('stats.books') : mediaMode === 'tv' ? t('stats.tvSeasons') : t('stats.movies');
  const typeData = [
    { name: mediaLabel, value: items.length },
  ];

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-6 animate-fade-in">
      {/* Streak + Share row */}
      <div className="md:col-span-2 flex items-center justify-between">
        {streakStats ? (
          <StreakBadge currentStreak={streakStats.currentStreak} longestStreak={streakStats.longestStreak} />
        ) : <div />}
        <button
          onClick={() => setShareOpen(true)}
          className="flex items-center gap-2 px-4 py-2 rounded-xl border border-border/30 text-sm font-medium text-muted-foreground hover:text-foreground hover:border-border transition-colors"
        >
          <Share2 size={14} />
          {t('share.createCard')}
        </button>
      </div>

      {profile && (
        <ShareCardModal
          open={shareOpen}
          onClose={() => setShareOpen(false)}
          items={items}
          genreProfile={genreProfile}
          username={profile.username}
          displayName={profile.displayName}
        />
      )}

      <div className="bg-card border border-border p-6 rounded-xl">
        <h3 className="text-lg font-bold text-foreground mb-4">{t('stats.tierDistribution')}</h3>
        <div className="h-64">
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={tierCounts}>
              <XAxis dataKey="name" stroke="#252C35" tick={{ fill: '#9BA3AB' }} />
              <YAxis stroke="#252C35" tick={{ fill: '#9BA3AB' }} />
              <Tooltip
                contentStyle={{ backgroundColor: '#1C2128', borderColor: '#252C35', color: '#fff' }}
                cursor={{ fill: 'rgba(255,255,255,0.05)' }}
              />
              <Bar dataKey="value" radius={[4, 4, 0, 0]}>
                {tierCounts.map((entry, index) => (
                  <Cell key={`cell-${index}`} fill={COLORS[index]} />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>

      <div className="bg-card border border-border p-6 rounded-xl">
        <h3 className="text-lg font-bold text-foreground mb-4">{t('stats.mediaSplit')}</h3>
        <div className="h-64">
          <ResponsiveContainer width="100%" height="100%">
            <PieChart>
              <Pie
                data={typeData}
                cx="50%"
                cy="50%"
                innerRadius={60}
                outerRadius={80}
                paddingAngle={5}
                dataKey="value"
              >
                <Cell fill="#D4C5B0" />
                <Cell fill="#8BA8BA" />
              </Pie>
              <Tooltip contentStyle={{ backgroundColor: '#1C2128', borderColor: '#252C35', color: '#fff' }} />
            </PieChart>
          </ResponsiveContainer>
        </div>
        <div className="flex justify-center gap-6 mt-4 text-sm text-muted-foreground">
          <div className="flex items-center gap-2">
            <div className="w-3 h-3 rounded-full bg-accent"></div>
            <span>{mediaLabel}</span>
          </div>
        </div>
      </div>

      {/* Your Taste DNA */}
      <div className="md:col-span-2 bg-card border border-border p-6 rounded-xl">
        <div className="flex items-center gap-2 mb-4">
          <Star size={18} className="text-gold" />
          <h3 className="text-lg font-bold text-foreground">{t('stats.tasteDNA')}</h3>
          <span className="text-xs text-muted-foreground">{t('stats.genreDistribution')}</span>
        </div>
        <GenreRadarChart genres={genreProfile} />
      </div>
    </div>
  );
};
