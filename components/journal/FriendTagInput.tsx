import React, { useState, useCallback } from 'react';
import { Search, X } from 'lucide-react';
import { UserSearchResult } from '../../types';
import { searchUsers } from '../../services/friendsService';

interface FriendTagInputProps {
  currentUserId: string;
  selectedUserIds: string[];
  onChange: (userIds: string[]) => void;
}

export const FriendTagInput: React.FC<FriendTagInputProps> = ({ currentUserId, selectedUserIds, onChange }) => {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<UserSearchResult[]>([]);
  const [searching, setSearching] = useState(false);
  const [selectedUsers, setSelectedUsers] = useState<Map<string, UserSearchResult>>(new Map());

  const handleSearch = useCallback(async (q: string) => {
    setQuery(q);
    if (q.trim().length < 2) {
      setResults([]);
      return;
    }
    setSearching(true);
    try {
      const res = await searchUsers(currentUserId, q.trim());
      setResults(res.filter((u) => !selectedUserIds.includes(u.id)));
    } catch {
      setResults([]);
    } finally {
      setSearching(false);
    }
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
        <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-zinc-500" />
        <input
          type="text"
          placeholder="Search friends..."
          value={query}
          onChange={(e) => handleSearch(e.target.value)}
          className="w-full bg-zinc-900 border border-zinc-800 rounded-lg pl-8 pr-3 py-2 text-sm text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-zinc-600"
        />
      </div>

      {/* Results */}
      {searching && <p className="text-xs text-zinc-600 py-1">Searching...</p>}
      {results.length > 0 && (
        <div className="max-h-36 overflow-y-auto space-y-0.5">
          {results.map((user) => (
            <button
              key={user.id}
              type="button"
              className="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-lg text-left text-zinc-300 hover:bg-zinc-800/50 transition-colors"
              onClick={() => addUser(user)}
            >
              {user.avatarUrl ? (
                <img src={user.avatarUrl} alt={user.username} className="w-6 h-6 rounded-full object-cover" />
              ) : (
                <div className="w-6 h-6 rounded-full bg-zinc-800 flex items-center justify-center text-[10px] text-zinc-500">
                  {user.username[0]?.toUpperCase()}
                </div>
              )}
              <div className="min-w-0">
                <p className="text-xs font-medium truncate">@{user.username}</p>
                {user.displayName && <p className="text-[10px] text-zinc-500 truncate">{user.displayName}</p>}
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
};
