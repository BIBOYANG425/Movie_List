import React, { useEffect, useState } from 'react';
import { Award, Lock, Star, Trophy, Users, Zap } from 'lucide-react';
import { BadgeDefinition, UserAchievement } from '../types';
import { getUserAchievements, checkAndGrantBadges } from '../services/friendsService';

// ── Badge Catalog ───────────────────────────────────────────────────────────

const BADGE_CATALOG: BadgeDefinition[] = [
    // Milestones
    { key: 'first_rank', name: 'First Pick', description: 'Ranked your first movie', icon: '🎬', category: 'milestone', requirement: '1 ranking' },
    { key: 'rank_10', name: 'Cinephile', description: 'Ranked 10 movies', icon: '🎞️', category: 'milestone', requirement: '10 rankings' },
    { key: 'rank_25', name: 'Film Buff', description: 'Ranked 25 movies', icon: '🍿', category: 'milestone', requirement: '25 rankings' },
    { key: 'rank_50', name: 'Movie Maven', description: 'Ranked 50 movies', icon: '🏆', category: 'milestone', requirement: '50 rankings' },
    { key: 'rank_100', name: 'Century Club', description: 'Ranked 100 movies', icon: '💯', category: 'milestone', requirement: '100 rankings' },
    { key: 'first_review', name: 'First Words', description: 'Wrote your first review', icon: '✍️', category: 'milestone', requirement: '1 review' },
    { key: 'review_10', name: 'Critic', description: 'Wrote 10 reviews', icon: '📝', category: 'milestone', requirement: '10 reviews' },

    // Social
    { key: 'first_follow', name: 'Social Butterfly', description: 'Followed your first person', icon: '🦋', category: 'social', requirement: '1 follow' },
    { key: 'followers_10', name: 'Rising Star', description: 'Gained 10 followers', icon: '⭐', category: 'social', requirement: '10 followers' },
    { key: 'followers_50', name: 'Influencer', description: 'Gained 50 followers', icon: '🌟', category: 'social', requirement: '50 followers' },
    { key: 'first_party', name: 'Party Host', description: 'Hosted a watch party', icon: '🎉', category: 'social', requirement: '1 watch party' },
    { key: 'first_poll', name: 'Decision Maker', description: 'Created a movie poll', icon: '🗳️', category: 'social', requirement: '1 poll' },
    { key: 'first_list', name: 'Curator', description: 'Created a movie list', icon: '📋', category: 'social', requirement: '1 list' },

    // Taste
    { key: 'genre_5', name: 'Versatile', description: 'Ranked movies in 5+ genres', icon: '🎨', category: 'taste', requirement: '5 genres' },
    { key: 'genre_10', name: 'Eclectic', description: 'Ranked movies in 10+ genres', icon: '🌈', category: 'taste', requirement: '10 genres' },
    { key: 's_tier_10', name: 'Elite Eye', description: 'Gave 10 movies S-tier', icon: '👑', category: 'taste', requirement: '10 S-tier' },
    { key: 'd_tier_5', name: 'Honest Critic', description: "Gave 5 movies D-tier — not everything's great", icon: '💀', category: 'taste', requirement: '5 D-tier' },

    // Special
    { key: 'early_adopter', name: 'Early Adopter', description: 'Joined during beta', icon: '🚀', category: 'special', requirement: 'Beta signup' },
];

const CATEGORY_STYLES: Record<string, { label: string; color: string; icon: React.ReactNode }> = {
    milestone: { label: 'Milestones', color: 'text-amber-400', icon: <Trophy size={14} /> },
    social: { label: 'Social', color: 'text-blue-400', icon: <Users size={14} /> },
    taste: { label: 'Taste', color: 'text-purple-400', icon: <Star size={14} /> },
    special: { label: 'Special', color: 'text-emerald-400', icon: <Zap size={14} /> },
};

interface AchievementsViewProps {
    userId: string;
    isOwnProfile?: boolean;
}

export const AchievementsView: React.FC<AchievementsViewProps> = ({ userId, isOwnProfile = true }) => {
    const [achievements, setAchievements] = useState<UserAchievement[]>([]);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        if (!userId) return;
        const load = async () => {
            setLoading(true);
            if (isOwnProfile) {
                // Check for new badges before loading
                await checkAndGrantBadges(userId);
            }
            const data = await getUserAchievements(userId);
            setAchievements(data);
            setLoading(false);
        };
        load();
    }, [userId, isOwnProfile]);

    const unlockedKeys = new Set(achievements.map((a) => a.badgeKey));
    const categories = ['milestone', 'social', 'taste', 'special'] as const;

    if (loading) {
        return (
            <div className="flex items-center justify-center py-12">
                <div className="w-6 h-6 border-2 border-amber-500 border-t-transparent rounded-full animate-spin" />
            </div>
        );
    }

    return (
        <div className="space-y-6">
            {/* Summary */}
            <div className="flex items-center gap-3">
                <Award size={20} className="text-amber-500" />
                <h2 className="text-lg font-bold">Achievements</h2>
                <span className="text-xs text-zinc-500">
                    {achievements.length}/{BADGE_CATALOG.length} unlocked
                </span>
            </div>

            {/* Progress bar */}
            <div className="bg-zinc-800 rounded-full h-2 overflow-hidden">
                <div
                    className="h-full bg-gradient-to-r from-amber-500 to-amber-400 rounded-full transition-all duration-500"
                    style={{ width: `${(achievements.length / BADGE_CATALOG.length) * 100}%` }}
                />
            </div>

            {/* Badge grid by category */}
            {categories.map((cat) => {
                const catStyle = CATEGORY_STYLES[cat];
                const badges = BADGE_CATALOG.filter((b) => b.category === cat);
                return (
                    <div key={cat}>
                        <h3 className={`text-sm font-semibold ${catStyle.color} flex items-center gap-1.5 mb-3`}>
                            {catStyle.icon} {catStyle.label}
                        </h3>
                        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2">
                            {badges.map((badge) => {
                                const unlocked = unlockedKeys.has(badge.key);
                                const achievement = achievements.find((a) => a.badgeKey === badge.key);
                                return (
                                    <div
                                        key={badge.key}
                                        className={`relative rounded-xl p-3 border transition-all ${unlocked
                                                ? 'bg-zinc-900/80 border-zinc-700 hover:border-zinc-600'
                                                : 'bg-zinc-900/30 border-zinc-800/30 opacity-50'
                                            }`}
                                    >
                                        <div className="text-2xl mb-1.5">
                                            {unlocked ? badge.icon : <Lock size={20} className="text-zinc-700" />}
                                        </div>
                                        <h4 className={`text-xs font-semibold ${unlocked ? 'text-zinc-200' : 'text-zinc-600'}`}>
                                            {badge.name}
                                        </h4>
                                        <p className="text-[10px] text-zinc-500 mt-0.5 leading-tight">
                                            {badge.description}
                                        </p>
                                        {unlocked && achievement && (
                                            <p className="text-[9px] text-zinc-600 mt-1">
                                                {new Date(achievement.unlockedAt).toLocaleDateString()}
                                            </p>
                                        )}
                                        {!unlocked && (
                                            <p className="text-[9px] text-zinc-700 mt-1">{badge.requirement}</p>
                                        )}
                                    </div>
                                );
                            })}
                        </div>
                    </div>
                );
            })}
        </div>
    );
};

export default AchievementsView;
