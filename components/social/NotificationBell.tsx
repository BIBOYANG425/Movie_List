import React, { useEffect, useRef, useState } from 'react';
import { Bell, Check, UserPlus, Heart, Tv, Vote, Award, List, MessageCircle, Film } from 'lucide-react';
import { AppNotification, NotificationType } from '../../types';
import { getNotifications, markNotificationsRead, getUnreadCount } from '../../services/friendsService';
import { useTranslation } from '../../contexts/LanguageContext';

const NOTIF_ICONS: Record<NotificationType, { icon: React.ReactNode; color: string }> = {
    new_follower: { icon: <UserPlus size={14} />, color: 'text-blue-400' },
    review_like: { icon: <Heart size={14} />, color: 'text-pink-400' },
    party_invite: { icon: <Tv size={14} />, color: 'text-violet-400' },
    party_rsvp: { icon: <Check size={14} />, color: 'text-emerald-400' },
    poll_vote: { icon: <Vote size={14} />, color: 'text-pink-400' },
    poll_closed: { icon: <Vote size={14} />, color: 'text-gold' },
    list_like: { icon: <List size={14} />, color: 'text-accent' },
    badge_unlock: { icon: <Award size={14} />, color: 'text-gold' },
    group_invite: { icon: <UserPlus size={14} />, color: 'text-accent' },
    ranking_comment: { icon: <MessageCircle size={14} />, color: 'text-emerald-400' },
    journal_tag: { icon: <Film size={14} />, color: 'text-purple-400' },
};

function timeAgo(dateStr: string): string {
    const diff = Date.now() - new Date(dateStr).getTime();
    const mins = Math.floor(diff / 60_000);
    if (mins < 1) return 'now';
    if (mins < 60) return `${mins}m`;
    const hours = Math.floor(mins / 60);
    if (hours < 24) return `${hours}h`;
    const days = Math.floor(hours / 24);
    return `${days}d`;
}

interface NotificationBellProps {
    userId: string;
    onUnreadCountChange?: (count: number) => void;
}

export const NotificationBell: React.FC<NotificationBellProps> = ({ userId, onUnreadCountChange }) => {
    const { t } = useTranslation();
    const [open, setOpen] = useState(false);
    const [notifications, setNotifications] = useState<AppNotification[]>([]);
    const [unreadCount, setUnreadCount] = useState(0);
    const [loading, setLoading] = useState(false);
    const dropdownRef = useRef<HTMLDivElement>(null);

    // Load unread count on mount and poll every 15s
    useEffect(() => {
        if (!userId) return;

        const pollCount = async () => {
            const count = await getUnreadCount(userId);
            setUnreadCount(count);
            onUnreadCountChange?.(count);
        };

        pollCount();
        const interval = setInterval(pollCount, 15_000);
        return () => clearInterval(interval);
    }, [userId]);

    // Close dropdown on outside click
    useEffect(() => {
        const handler = (e: MouseEvent) => {
            if (dropdownRef.current && !dropdownRef.current.contains(e.target as Node)) {
                setOpen(false);
            }
        };
        document.addEventListener('mousedown', handler);
        return () => document.removeEventListener('mousedown', handler);
    }, []);

    const handleOpen = async () => {
        setOpen(!open);
        if (!open) {
            setLoading(true);
            const data = await getNotifications(userId);
            setNotifications(data);
            setLoading(false);

            // Mark all as read
            const unreadIds = data.filter((n) => !n.isRead).map((n) => n.id);
            if (unreadIds.length > 0) {
                await markNotificationsRead(unreadIds);
                setUnreadCount(0);
                onUnreadCountChange?.(0);
            }
        }
    };

    return (
        <div className="relative" ref={dropdownRef}>
            <button
                onClick={handleOpen}
                className="p-2 rounded-lg text-muted-foreground hover:text-muted-foreground hover:bg-card transition-colors relative"
                title="Notifications"
            >
                <Bell size={20} />
                {unreadCount > 0 && (
                    <span className="absolute -top-0.5 -right-0.5 w-4 h-4 rounded-full bg-red-500 text-[9px] font-bold text-foreground flex items-center justify-center animate-pulse">
                        {unreadCount > 9 ? '9+' : unreadCount}
                    </span>
                )}
            </button>

            {open && (
                <div className="absolute right-0 top-full mt-2 w-80 max-h-[420px] overflow-y-auto bg-card border border-border rounded-xl shadow-2xl z-50">
                    <div className="sticky top-0 bg-card border-b border-border px-4 py-2.5 flex items-center justify-between">
                        <h3 className="text-sm font-bold">{t('notifications.title')}</h3>
                        <span className="text-[10px] text-muted-foreground">{notifications.length} {t('notifications.recent')}</span>
                    </div>

                    {loading ? (
                        <div className="flex items-center justify-center py-8">
                            <div className="w-5 h-5 border-2 border-border border-t-transparent rounded-full animate-spin" />
                        </div>
                    ) : notifications.length === 0 ? (
                        <div className="text-center py-8 text-muted-foreground">
                            <Bell size={24} className="mx-auto mb-2 opacity-40" />
                            <p className="text-xs">{t('notifications.empty')}</p>
                        </div>
                    ) : (
                        <div className="divide-y divide-border/50">
                            {notifications.map((notif) => {
                                const style = NOTIF_ICONS[notif.type] || NOTIF_ICONS.new_follower;
                                return (
                                    <div
                                        key={notif.id}
                                        className={`flex items-start gap-3 px-4 py-3 hover:bg-secondary/30 transition-colors ${!notif.isRead ? 'bg-secondary/20' : ''
                                            }`}
                                    >
                                        {/* Actor avatar or icon */}
                                        <div className="flex-shrink-0 mt-0.5">
                                            {notif.actorAvatar ? (
                                                <div className="w-8 h-8 rounded-full overflow-hidden">
                                                    <img src={notif.actorAvatar} alt="" className="w-full h-full object-cover" />
                                                </div>
                                            ) : (
                                                <div className={`w-8 h-8 rounded-full bg-secondary flex items-center justify-center ${style.color}`}>
                                                    {style.icon}
                                                </div>
                                            )}
                                        </div>

                                        <div className="flex-1 min-w-0">
                                            <p className="text-xs text-foreground leading-relaxed">
                                                {notif.actorUsername && (
                                                    <span className="font-semibold">{notif.actorUsername} </span>
                                                )}
                                                {notif.title}
                                            </p>
                                            {notif.body && (
                                                <p className="text-[11px] text-muted-foreground mt-0.5 truncate">{notif.body}</p>
                                            )}
                                        </div>

                                        <span className="text-[10px] text-muted-foreground/60 flex-shrink-0 mt-0.5">
                                            {timeAgo(notif.createdAt)}
                                        </span>

                                        {!notif.isRead && (
                                            <div className="w-1.5 h-1.5 rounded-full bg-blue-500 flex-shrink-0 mt-1.5" />
                                        )}
                                    </div>
                                );
                            })}
                        </div>
                    )}
                </div>
            )}
        </div>
    );
};

export default NotificationBell;
