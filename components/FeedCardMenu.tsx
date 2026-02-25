import React, { useState, useEffect, useRef } from 'react';
import { MoreHorizontal } from 'lucide-react';

interface FeedCardMenuProps {
  onMuteUser: () => void;
  onMuteMovie?: () => void;
  username: string;
  movieTitle?: string;
}

export const FeedCardMenu: React.FC<FeedCardMenuProps> = ({
  onMuteUser,
  onMuteMovie,
  username,
  movieTitle,
}) => {
  const [open, setOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };

    document.addEventListener('click', handleClickOutside);
    return () => document.removeEventListener('click', handleClickOutside);
  }, [open]);

  return (
    <div className="relative" ref={menuRef}>
      <button
        onClick={() => setOpen((prev) => !prev)}
        className="p-1 rounded-lg text-zinc-500 hover:text-zinc-300 hover:bg-zinc-800 transition-colors"
      >
        <MoreHorizontal size={16} />
      </button>

      {open && (
        <div className="absolute right-0 top-full mt-1 bg-zinc-900 border border-zinc-700 rounded-lg shadow-xl py-1 min-w-[180px] z-50">
          <button
            onClick={() => {
              onMuteUser();
              setOpen(false);
            }}
            className="px-3 py-2 text-sm text-zinc-300 hover:bg-zinc-800 cursor-pointer w-full text-left"
          >
            Mute @{username}
          </button>

          {onMuteMovie && movieTitle && (
            <button
              onClick={() => {
                onMuteMovie();
                setOpen(false);
              }}
              className="px-3 py-2 text-sm text-zinc-300 hover:bg-zinc-800 cursor-pointer w-full text-left"
            >
              Mute {movieTitle}
            </button>
          )}
        </div>
      )}
    </div>
  );
};
