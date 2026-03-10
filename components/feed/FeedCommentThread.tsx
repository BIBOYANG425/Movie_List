import React, { useState } from 'react';
import { Link } from 'react-router-dom';
import { MessageCircle, Reply, Trash2, ChevronDown, ChevronUp, Send } from 'lucide-react';
import { FeedComment } from '../../types';

function relativeDate(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  return `${days}d ago`;
}

function renderBody(body: string): React.ReactNode {
  const parts = body.split(/(@\w+)/g);
  return parts.map((part, i) =>
    /^@\w+$/.test(part) ? <strong key={i}>{part}</strong> : part
  );
}

interface FeedCommentThreadProps {
  comments: FeedComment[];
  commentCount: number;
  currentUserId?: string;
  onAddComment: (body: string, parentCommentId?: string) => void;
  onDeleteComment: (commentId: string) => void;
  onToggleOpen: () => void;
  isOpen: boolean;
  loading?: boolean;
}

export const FeedCommentThread: React.FC<FeedCommentThreadProps> = ({
  comments,
  commentCount,
  currentUserId,
  onAddComment,
  onDeleteComment,
  onToggleOpen,
  isOpen,
  loading,
}) => {
  const [draft, setDraft] = useState('');
  const [replyToId, setReplyToId] = useState<string | null>(null);
  const [replyToUsername, setReplyToUsername] = useState<string | null>(null);

  const handleSubmit = (parentCommentId?: string) => {
    const text = draft.trim();
    if (!text) return;
    onAddComment(text, parentCommentId);
    setDraft('');
    setReplyToId(null);
    setReplyToUsername(null);
  };

  const handleReply = (commentId: string, username: string) => {
    setReplyToId(commentId);
    setReplyToUsername(username);
    setDraft('');
  };

  const cancelReply = () => {
    setReplyToId(null);
    setReplyToUsername(null);
    setDraft('');
  };

  const renderComment = (comment: FeedComment, isReply = false) => (
    <div key={comment.id} className={`flex gap-2.5 ${isReply ? 'ml-8' : ''}`}>
      <Link to={`/profile/${comment.userId}`}>
        {comment.avatarUrl ? (
          <img
            src={comment.avatarUrl}
            alt={comment.username}
            className="w-7 h-7 rounded-full"
          />
        ) : (
          <div className="w-7 h-7 rounded-full bg-secondary flex items-center justify-center text-xs text-muted-foreground">
            {comment.username.charAt(0).toUpperCase()}
          </div>
        )}
      </Link>

      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <Link
            to={`/profile/${comment.userId}`}
            className="text-sm font-medium text-foreground hover:text-foreground transition-colors"
          >
            {comment.displayName || comment.username}
          </Link>
          <span className="text-[11px] text-muted-foreground/60">
            {relativeDate(comment.createdAt)}
          </span>
        </div>

        <p className="text-sm text-muted-foreground leading-relaxed mt-0.5">
          {renderBody(comment.body)}
        </p>

        <div className="flex items-center gap-3 mt-1">
          {!isReply && (
            <button
              onClick={() => handleReply(comment.id, comment.username)}
              className="flex items-center gap-1 text-xs text-muted-foreground hover:text-muted-foreground transition-colors"
            >
              <Reply className="w-3 h-3" />
              Reply
            </button>
          )}
          {currentUserId === comment.userId && (
            <button
              onClick={() => onDeleteComment(comment.id)}
              className="flex items-center gap-1 text-xs text-muted-foreground hover:text-red-400 transition-colors"
            >
              <Trash2 className="w-3 h-3" />
            </button>
          )}
        </div>

        {replyToId === comment.id && (
          <div className="mt-2">
            <div className="flex items-center gap-2 mb-1">
              <span className="text-xs text-muted-foreground">
                Replying to <span className="text-muted-foreground">@{replyToUsername}</span>
              </span>
              <button
                onClick={cancelReply}
                className="text-xs text-muted-foreground hover:text-muted-foreground transition-colors"
              >
                Cancel
              </button>
            </div>
            <div className="flex gap-2">
              <textarea
                value={draft}
                onChange={(e) => setDraft(e.target.value.slice(0, 500))}
                placeholder="Write a reply..."
                maxLength={500}
                rows={1}
                className="flex-1 rounded-lg border border-border bg-background px-3 py-2 text-sm resize-none focus:outline-none focus:ring-2 focus:ring-accent/40"
              />
              <button
                onClick={() => handleSubmit(comment.id)}
                disabled={!draft.trim() || loading}
                className="p-2 rounded-lg bg-gold text-foreground hover:bg-gold-muted disabled:opacity-50 transition-colors"
              >
                <Send className="w-4 h-4" />
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );

  return (
    <div>
      <button
        onClick={onToggleOpen}
        className="flex items-center gap-1.5 text-xs text-muted-foreground hover:text-muted-foreground transition-colors"
      >
        <MessageCircle className="w-4 h-4" />
        {commentCount}
        {isOpen ? <ChevronUp className="w-3 h-3" /> : <ChevronDown className="w-3 h-3" />}
      </button>

      {isOpen && (
        <div className="mt-3 pt-3 border-t border-border/50 space-y-3">
          {comments.map((comment) => (
            <div key={comment.id}>
              {renderComment(comment)}
              {comment.replies?.map((reply) => renderComment(reply, true))}
            </div>
          ))}

          {!replyToId && (
            <div className="flex gap-2 mt-3">
              <textarea
                value={draft}
                onChange={(e) => setDraft(e.target.value.slice(0, 500))}
                placeholder="Write a comment..."
                maxLength={500}
                rows={1}
                className="flex-1 rounded-lg border border-border bg-background px-3 py-2 text-sm resize-none focus:outline-none focus:ring-2 focus:ring-accent/40"
              />
              <button
                onClick={() => handleSubmit()}
                disabled={!draft.trim() || loading}
                className="p-2 rounded-lg bg-gold text-foreground hover:bg-gold-muted disabled:opacity-50 transition-colors"
              >
                <Send className="w-4 h-4" />
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  );
};
