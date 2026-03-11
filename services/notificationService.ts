import { supabase } from '../lib/supabase';
import { AppNotification } from '../types';
import { SUPABASE_URL } from './profileService';

export async function createNotification(params: {
  userId: string;
  type: string;
  title: string;
  body?: string;
  actorId?: string;
  referenceId?: string;
}): Promise<boolean> {
  const { error } = await supabase.from('notifications').insert({
    user_id: params.userId,
    type: params.type,
    title: params.title,
    body: params.body ?? null,
    actor_id: params.actorId ?? null,
    reference_id: params.referenceId ?? null,
  });
  if (error) { console.error('Failed to create notification:', error); return false; }
  return true;
}

export async function getNotifications(userId: string, limit = 30): Promise<AppNotification[]> {
  const { data } = await supabase
    .from('notifications')
    .select('*')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (!data) return [];

  // Get actor profiles
  const actorIds = [...new Set(data.filter((n: any) => n.actor_id).map((n: any) => n.actor_id))];
  let profileMap = new Map<string, any>();
  if (actorIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, username, avatar_path').in('id', actorIds);
    profileMap = new Map((profiles ?? []).map((p: any) => [p.id, p]));
  }

  return data.map((n: any) => {
    const actor = n.actor_id ? profileMap.get(n.actor_id) : null;
    return {
      id: n.id,
      userId: n.user_id,
      type: n.type,
      title: n.title,
      body: n.body,
      actorId: n.actor_id,
      actorUsername: actor?.username,
      actorAvatar: actor?.avatar_path ? `${SUPABASE_URL}/storage/v1/object/public/avatars/${actor.avatar_path}` : undefined,
      referenceId: n.reference_id,
      isRead: n.is_read,
      createdAt: n.created_at,
    };
  });
}

export async function markNotificationsRead(ids: string[]): Promise<boolean> {
  const { error } = await supabase
    .from('notifications')
    .update({ is_read: true })
    .in('id', ids);
  return !error;
}

export async function getUnreadCount(userId: string): Promise<number> {
  const { count } = await supabase
    .from('notifications')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', userId)
    .eq('is_read', false);
  return count ?? 0;
}
