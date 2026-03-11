import React, { useState, useCallback, useRef, useEffect } from 'react';
import { Search, X } from 'lucide-react';
import { UserSearchResult } from '../../types';
import { searchUsers, getProfilesByIds } from '../../services/friendsService';

interface FriendTagInputProps {
  currentUserId: string;
  selectedUserIds: string[];
  onChange: (userIds: string[]) => void;
  /** When true, only show users the current user follows. */
  friendsOnly?: boolean;
}

export const FriendTagInput: React.FC<FriendTagInputProps> = ({ currentUserId, selectedUserIds, onChange, friendsOnly }) => {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<UserSearchResult[]>([]);
  const [searching, setSearching] = useState(false);
  const [selectedUsers, setSelectedUsers] = useState<Map<string, UserSearchResult>>(new Map());
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Clear debounce timeout on unmount
  useEffect(() => {
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, []);

  // Hydrate usernames for pre-existing selectedUserIds
  useEffect(() => {
    const unknownIds = selectedUserIds.filter((id) => !selectedUsers.has(id));
    if (unknownIds.length === 0) return;

    getProfilesByIds(unknownIds).then((profileMap) => {
      setSelectedUsers((prev) => {
        const next = new Map(prev);
        for (const [id, profile] of profileMap) {
          next.set(id, {
            id,
            username: profile.username,
            displayName: profile.displayName,
            avatarUrl: profile.avatarUrl,
            isFollowing: true,
          });
        }
        return next;
      });
    });
  }, [selectedUserIds.join(',')]);

  const handleSearch = useCallback((q: string) => {
    setQuery(q);
    if (q.trim().length < 2) {
      setResults([]);
      if (debounceRef.current) clearTimeout(debounceRef.current);
      return;
    }
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(async () => {
      setSearching(true);
      try {
        const res = await searchUsers(currentUserId, q.trim());
        setResults(res.filter((u) => !selectedUserIds.includes(u.id) && (!friendsOnly || u.isFollowing)));
      } catch {
        setResults([]);
      } finally {
        setSearching(false);
      }
    }, 300);
  }, [currentUserId, selectedUserIds]);

  const addUser = (user: UserSearchResult) => {
    const newMap = new Map(selectedUsers);
    newMap.set(user.id, user);
    setSelectedUsers(newMap);
    onChange([...selectedUserIds, user.id]);
    setQuery('');
    setResults([]);
  };

  const removeUser = (userId: string) => {
    const newMap = new Map(selectedUsers);
    newMap.delete(userId);
    setSelectedUsers(newMap);
    onChange(selectedUserIds.filter((id) => id !== userId));
  };

  return (
    <div className="space-y-2">
      {/* Selected chips */}
      {selectedUserIds.length > 0 && (
        <div className="flex gap-1.5 flex-wrap">
          {selectedUserIds.map((id) => {
            const user = selectedUsers.get(id);
            return (
              <span
                key={id}
                className="inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs bg-purple-500/20 text-purple-300 border border-purple-500/30"
              >
                @{user?.username ?? id.slice(0, 8)}
                <button type="button" onClick={() => removeUser(id)}>
                  <X size={12} />
                </button>
              </span>
            );
          })}
        </div>
      )}

      {/* Search */}
      <div className="relative">
        <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-muted-foreground" />
        <input
          type="text"
          placeholder="Search friends..."
          value={query}
          onChange={(e) => handleSearch(e.target.value)}
          className="w-full bg-card border border-border rounded-lg pl-8 pr-3 py-2 text-sm text-foreground placeholder-muted-foreground focus:outline-none focus:border-border"
        />
      </div>

      {/* Results */}
      {searching && <p className="text-xs text-muted-foreground/60 py-1">Searching...</p>}
      {results.length > 0 && (
        <div className="max-h-36 overflow-y-auto space-y-0.5">
          {results.map((user) => (
            <button
              key={user.id}
              type="button"
              className="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-lg text-left text-muted-foreground hover:bg-secondary/30 transition-colors"
              onClick={() => addUser(user)}
            >
              {user.avatarUrl ? (
                <img src={user.avatarUrl} alt={user.username} className="w-6 h-6 rounded-full object-cover" />
              ) : (
                <div className="w-6 h-6 rounded-full bg-secondary flex items-center justify-center text-[10px] text-muted-foreground">
                  {user.username[0]?.toUpperCase()}
                </div>
              )}
              <div className="min-w-0">
                <p className="text-xs font-medium truncate">@{user.username}</p>
                {user.displayName && <p className="text-[10px] text-muted-foreground truncate">{user.displayName}</p>}
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
};
