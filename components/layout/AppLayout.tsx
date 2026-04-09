import React from 'react';
import { Link } from 'react-router-dom';
import SpoolLogo from './SpoolLogo';
import {
  Film, MessageSquare, Bookmark, Compass, User,
} from 'lucide-react';

interface NavItem {
  path: string;
  label: string;
  icon: React.ElementType;
}

const NAV_ITEMS: NavItem[] = [
  { path: 'ranking', label: 'Board', icon: Film },
  { path: 'feed', label: 'Feed', icon: MessageSquare },
  { path: 'watchlist', label: 'Watchlist', icon: Bookmark },
  { path: 'discover', label: 'Discover', icon: Compass },
  { path: 'profile', label: 'Profile', icon: User },
];

interface AppLayoutProps {
  activeView: string;
  onViewChange: (view: string) => void;
  children: React.ReactNode;
  headerActions?: React.ReactNode;
  unreadNotificationCount?: number;
}

export default function AppLayout({ activeView, onViewChange, children, headerActions, unreadNotificationCount = 0 }: AppLayoutProps) {
  return (
    <div className="h-dvh flex flex-col bg-background">
      {/* Top Bar — all screen sizes */}
      <header className="flex-shrink-0 flex items-center justify-between px-4 py-2.5 border-b border-border/20">
        <div className="flex items-center gap-1">
          <Link to="/" className="mr-2">
            <SpoolLogo size="sm" />
          </Link>

          {/* Desktop horizontal nav (>=768px) */}
          <nav className="hidden md:flex items-center gap-0.5">
            {NAV_ITEMS.map((item) => {
              const active = activeView === item.path;
              return (
                <button
                  key={item.path}
                  onClick={() => onViewChange(item.path)}
                  className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm transition-all duration-[var(--duration-normal)] ${
                    active
                      ? 'text-gold bg-gold/8'
                      : 'text-muted-foreground hover:text-foreground hover:bg-secondary/30'
                  }`}
                >
                  <item.icon className="w-4 h-4" />
                  <span>{item.label}</span>
                  {item.path === 'profile' && unreadNotificationCount > 0 && (
                    <span className="w-4 h-4 rounded-full bg-red-500 text-[9px] font-bold text-white flex items-center justify-center">
                      {unreadNotificationCount > 9 ? '9+' : unreadNotificationCount}
                    </span>
                  )}
                </button>
              );
            })}
          </nav>
        </div>

        {headerActions && <div className="hidden md:flex items-center gap-2">{headerActions}</div>}
      </header>

      {/* Main Content */}
      <main className="flex-1 overflow-y-auto">
        {children}
      </main>

      {/* Bottom Tab Bar — mobile (<768px) */}
      <nav className="md:hidden flex-shrink-0 bg-background/95 backdrop-blur-xl border-t border-border/20 pb-[max(0.5rem,env(safe-area-inset-bottom))]">
        <div className="flex items-end justify-around px-2 pt-2">
          {NAV_ITEMS.map((item) => {
            const active = activeView === item.path;
            return (
              <button
                key={item.path}
                onClick={() => onViewChange(item.path)}
                className={`flex flex-col items-center gap-1 px-3 py-2 transition-all duration-[var(--duration-fast)] active:scale-90 min-w-[56px] ${
                  active ? 'text-gold' : 'text-muted-foreground'
                }`}
              >
                <div className="relative">
                  <item.icon className="w-6 h-6" strokeWidth={active ? 2.2 : 1.8} />
                  {item.path === 'profile' && unreadNotificationCount > 0 && (
                    <span className="absolute -top-1 -right-1 w-3 h-3 rounded-full bg-red-500" />
                  )}
                </div>
                <span className="text-[10px]">{item.label}</span>
              </button>
            );
          })}
        </div>
      </nav>
    </div>
  );
}
