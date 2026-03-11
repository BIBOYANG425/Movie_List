import React, { useState } from 'react';
import { Link } from 'react-router-dom';
import SpoolLogo from './SpoolLogo';
import {
  Film, MessageSquare, Bookmark, BarChart3, User,
  Users, BookOpen, Award, Compass, ChevronLeft,
  ChevronRight
} from 'lucide-react';

interface NavItem {
  path: string;
  label: string;
  icon: React.ElementType;
  mobileTab?: boolean;
}

const NAV_ITEMS: NavItem[] = [
  { path: 'ranking', label: 'Board', icon: Film, mobileTab: true },
  { path: 'feed', label: 'Feed', icon: MessageSquare, mobileTab: true },
  { path: 'watchlist', label: 'Watchlist', icon: Bookmark, mobileTab: true },
  { path: 'discover', label: 'Discover', icon: Compass },
  { path: 'stats', label: 'Insights', icon: BarChart3, mobileTab: true },
  { path: 'groups', label: 'Groups', icon: Users },
  { path: 'journal', label: 'Journal', icon: BookOpen },
  { path: 'achievements', label: 'Achievements', icon: Award },
];

interface AppLayoutProps {
  activeView: string;
  onViewChange: (view: string) => void;
  children: React.ReactNode;
  topBar?: React.ReactNode;
  unreadNotificationCount?: number;
}

export default function AppLayout({ activeView, onViewChange, children, topBar, unreadNotificationCount = 0 }: AppLayoutProps) {
  const [collapsed, setCollapsed] = useState(false);
  const mobileTabs = NAV_ITEMS.filter(n => n.mobileTab);

  return (
    <div className="h-screen flex bg-background">
      {/* Desktop Sidebar (>=1024px) */}
      <aside className={`hidden lg:flex flex-col border-r border-border/30 transition-all duration-200 ${
        collapsed ? 'w-16' : 'w-60'
      }`}>
        {/* Logo */}
        <div className="p-4 flex items-center justify-between border-b border-border/20">
          <Link to="/">
            <SpoolLogo size={collapsed ? 'sm' : 'md'} showWordmark={!collapsed} />
          </Link>
          <button
            onClick={() => setCollapsed(!collapsed)}
            className="w-7 h-7 rounded-lg bg-secondary/40 flex items-center justify-center text-muted-foreground hover:text-foreground transition-colors"
          >
            {collapsed ? <ChevronRight className="w-4 h-4" /> : <ChevronLeft className="w-4 h-4" />}
          </button>
        </div>

        {/* Nav Items */}
        <nav className="flex-1 py-2 overflow-y-auto">
          {NAV_ITEMS.map((item) => {
            const active = activeView === item.path;
            return (
              <button
                key={item.path}
                onClick={() => onViewChange(item.path)}
                className={`w-full flex items-center gap-3 px-4 py-2.5 transition-all ${
                  active
                    ? 'text-gold bg-gold/8 border-r-2 border-gold'
                    : 'text-muted-foreground hover:text-foreground hover:bg-secondary/30'
                } ${collapsed ? 'justify-center px-0' : ''}`}
              >
                <item.icon className="w-5 h-5 flex-shrink-0" />
                {!collapsed && <span className="text-sm">{item.label}</span>}
              </button>
            );
          })}
        </nav>

        {/* Bottom: Profile */}
        <div className="border-t border-border/20 p-2">
          <button
            onClick={() => onViewChange('profile')}
            className={`w-full flex items-center gap-3 px-4 py-2.5 rounded-lg transition-colors ${
              activeView === 'profile' ? 'text-gold' : 'text-muted-foreground hover:text-foreground'
            } ${collapsed ? 'justify-center px-0' : ''}`}
          >
            <User className="w-5 h-5" />
            {!collapsed && <span className="text-sm">Profile</span>}
            {unreadNotificationCount > 0 && (
              <span className="w-4 h-4 rounded-full bg-red-500 text-[9px] font-bold text-white flex items-center justify-center">
                {unreadNotificationCount > 9 ? '9+' : unreadNotificationCount}
              </span>
            )}
          </button>
        </div>
      </aside>

      {/* Main Content */}
      <div className="flex-1 flex flex-col min-w-0">
        {topBar && topBar}
        <main className="flex-1 overflow-y-auto">
          {children}
        </main>

        {/* Mobile Bottom Tab Bar (<1024px) */}
        <nav className="lg:hidden flex-shrink-0 bg-background/95 backdrop-blur-xl border-t border-border/20 pb-[max(0.5rem,env(safe-area-inset-bottom))]">
          <div className="flex items-end justify-around px-2 pt-2">
            {[...mobileTabs, { path: 'profile', label: 'Profile', icon: User, mobileTab: true }].map((item) => {
              const active = activeView === item.path;
              return (
                <button
                  key={item.path}
                  onClick={() => onViewChange(item.path)}
                  className={`flex flex-col items-center gap-1 px-3 py-2 transition-all active:scale-90 min-w-[56px] ${
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
    </div>
  );
}
