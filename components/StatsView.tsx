import React, { useEffect, useState } from 'react';
import { ResponsiveContainer, PieChart, Pie, Cell, Tooltip, BarChart, Bar, XAxis, YAxis } from 'recharts';
import { RankedItem, Tier, GenreProfileItem } from '../types';
import { TIER_COLORS } from '../constants';
import { GenreRadarChart } from './GenreRadarChart';
import { getGenreProfile } from '../services/friendsService';
import { Star } from 'lucide-react';
import { useTranslation } from '../contexts/LanguageContext';

interface StatsViewProps {
  items: RankedItem[];
  userId: string;
}

export const StatsView: React.FC<StatsViewProps> = ({ items, userId }) => {
  const { t } = useTranslation();
  const [genreProfile, setGenreProfile] = useState<GenreProfileItem[]>([]);

  useEffect(() => {
    if (!userId) return;
    getGenreProfile(userId).then(setGenreProfile).catch(console.error);
  }, [userId]);
  const tierCounts = Object.values(Tier).map(tier => ({
    name: tier,
    value: items.filter(i => i.tier === tier).length,
    color: TIER_COLORS[tier].split(' ')[0].replace('text-', '#').replace('400', '4ADE80').replace('blue-', '#60A5FA').replace('yellow-', '#FCD34D').replace('red-', '#F87171').replace('zinc-', '#A1A1AA') // Quick hack to extract hex from tailwind class name logic for demo
  }));

  // Normalized hex colors for recharts
  const COLORS = ['#FCD34D', '#4ADE80', '#60A5FA', '#A1A1AA', '#F87171'];

  const typeData = [
    { name: 'Movies', value: items.filter(i => i.type === 'movie').length },
  ];

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-6 animate-fade-in">
      <div className="bg-zinc-900 border border-zinc-800 p-6 rounded-xl">
        <h3 className="text-lg font-bold text-zinc-100 mb-4">{t('stats.tierDistribution')}</h3>
        <div className="h-64">
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={tierCounts}>
              <XAxis dataKey="name" stroke="#71717a" />
              <YAxis stroke="#71717a" />
              <Tooltip
                contentStyle={{ backgroundColor: '#18181b', borderColor: '#27272a', color: '#fff' }}
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

      <div className="bg-zinc-900 border border-zinc-800 p-6 rounded-xl">
        <h3 className="text-lg font-bold text-zinc-100 mb-4">{t('stats.mediaSplit')}</h3>
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
                <Cell fill="#818cf8" />
                <Cell fill="#f472b6" />
              </Pie>
              <Tooltip contentStyle={{ backgroundColor: '#18181b', borderColor: '#27272a', color: '#fff' }} />
            </PieChart>
          </ResponsiveContainer>
        </div>
        <div className="flex justify-center gap-6 mt-4 text-sm text-zinc-400">
          <div className="flex items-center gap-2">
            <div className="w-3 h-3 rounded-full bg-indigo-400"></div>
            <span>{t('stats.movies')}</span>
          </div>
        </div>
      </div>

      {/* Your Taste DNA */}
      <div className="md:col-span-2 bg-zinc-900 border border-zinc-800 p-6 rounded-xl">
        <div className="flex items-center gap-2 mb-4">
          <Star size={18} className="text-amber-500" />
          <h3 className="text-lg font-bold text-zinc-100">{t('stats.tasteDNA')}</h3>
          <span className="text-xs text-zinc-500">{t('stats.genreDistribution')}</span>
        </div>
        <GenreRadarChart genres={genreProfile} />
      </div>
    </div>
  );
};
