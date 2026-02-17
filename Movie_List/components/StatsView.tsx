import React from 'react';
import { ResponsiveContainer, PieChart, Pie, Cell, Tooltip, BarChart, Bar, XAxis, YAxis } from 'recharts';
import { RankedItem, Tier } from '../types';
import { TIER_COLORS } from '../constants';

interface StatsViewProps {
  items: RankedItem[];
}

export const StatsView: React.FC<StatsViewProps> = ({ items }) => {
  const tierCounts = Object.values(Tier).map(tier => ({
    name: tier,
    value: items.filter(i => i.tier === tier).length,
    color: TIER_COLORS[tier].split(' ')[0].replace('text-', '#').replace('400', '4ADE80').replace('blue-', '#60A5FA').replace('yellow-', '#FCD34D').replace('red-', '#F87171').replace('zinc-', '#A1A1AA') // Quick hack to extract hex from tailwind class name logic for demo
  }));
  
  // Normalized hex colors for recharts
  const COLORS = ['#FCD34D', '#4ADE80', '#60A5FA', '#A1A1AA', '#F87171'];

  const typeData = [
    { name: 'Movies', value: items.filter(i => i.type === 'movie').length },
    { name: 'Theater', value: items.filter(i => i.type === 'theater').length },
  ];

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-6 animate-fade-in">
      <div className="bg-zinc-900 border border-zinc-800 p-6 rounded-xl">
        <h3 className="text-lg font-bold text-zinc-100 mb-4">Tier Distribution</h3>
        <div className="h-64">
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={tierCounts}>
              <XAxis dataKey="name" stroke="#71717a" />
              <YAxis stroke="#71717a" />
              <Tooltip 
                contentStyle={{ backgroundColor: '#18181b', borderColor: '#27272a', color: '#fff' }}
                cursor={{fill: 'rgba(255,255,255,0.05)'}}
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
        <h3 className="text-lg font-bold text-zinc-100 mb-4">Media Split</h3>
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
            <span>Movies</span>
          </div>
           <div className="flex items-center gap-2">
            <div className="w-3 h-3 rounded-full bg-pink-400"></div>
            <span>Theater</span>
          </div>
        </div>
      </div>
    </div>
  );
};
