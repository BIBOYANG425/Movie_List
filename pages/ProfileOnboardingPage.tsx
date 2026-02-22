import React, { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Camera, CheckCircle2 } from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import {
  AVATAR_ACCEPTED_MIME_TYPES,
  AVATAR_MAX_FILE_BYTES,
  updateMyProfile,
  uploadAvatarPhoto,
} from '../services/friendsService';

const MAX_BIO_LENGTH = 280;

const ProfileOnboardingPage = () => {
  const { user, profile, refreshProfile } = useAuth();
  const navigate = useNavigate();

  const [displayName, setDisplayName] = useState('');
  const [bio, setBio] = useState('');
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    setDisplayName(profile?.displayName ?? profile?.username ?? '');
    setBio(profile?.bio ?? '');
  }, [profile?.displayName, profile?.bio, profile?.username]);

  const avatarPreview = useMemo(() => {
    if (avatarFile) return URL.createObjectURL(avatarFile);
    if (profile?.avatarUrl) return profile.avatarUrl;
    return `https://api.dicebear.com/8.x/thumbs/svg?seed=${encodeURIComponent(profile?.username ?? user?.id ?? 'user')}`;
  }, [avatarFile, profile?.avatarUrl, profile?.username, user?.id]);

  useEffect(() => () => {
    if (avatarPreview?.startsWith('blob:')) URL.revokeObjectURL(avatarPreview);
  }, [avatarPreview]);

  if (!user) return null;

  const handleFileChange = (nextFile: File | null) => {
    if (!nextFile) {
      setAvatarFile(null);
      return;
    }

    if (!AVATAR_ACCEPTED_MIME_TYPES.includes(nextFile.type)) {
      setError('Use JPG, PNG, WEBP, or GIF for your avatar.');
      return;
    }

    if (nextFile.size > AVATAR_MAX_FILE_BYTES) {
      setError('Avatar must be 5MB or smaller.');
      return;
    }

    setError(null);
    setAvatarFile(nextFile);
  };

  const completeOnboarding = async () => {
    setError(null);
    setSubmitting(true);

    let avatarUrl = profile?.avatarUrl ?? null;
    let avatarPath = profile?.avatarPath ?? null;

    if (avatarFile) {
      const upload = await uploadAvatarPhoto(user.id, avatarFile);
      if (!upload) {
        setSubmitting(false);
        setError('Avatar upload failed. Please try a different photo.');
        return;
      }
      avatarUrl = upload.avatarUrl;
      avatarPath = upload.avatarPath;
    }

    const ok = await updateMyProfile(user.id, {
      displayName,
      bio,
      avatarUrl,
      avatarPath,
      onboardingCompleted: true,
    });

    if (!ok) {
      setSubmitting(false);
      setError('Could not save your profile right now. Please try again.');
      return;
    }

    await refreshProfile();
    navigate('/onboarding/movies', { replace: true });
  };

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100">
      <main className="max-w-2xl mx-auto px-4 py-10 space-y-6">
        <div className="space-y-2">
          <p className="text-xs uppercase tracking-[0.2em] text-indigo-300">Welcome to Marquee</p>
          <h1 className="text-3xl font-bold">Set up your profile</h1>
          <p className="text-zinc-400 text-sm">
            Friends can discover you by username, see your profile, and follow your ranking activity.
          </p>
        </div>

        <section className="rounded-2xl border border-zinc-800 bg-zinc-900/80 p-6 space-y-5">
          <div className="flex items-center gap-4">
            <img
              src={avatarPreview}
              alt={profile?.username ?? 'profile'}
              className="w-20 h-20 rounded-2xl object-cover border border-zinc-700 bg-zinc-800"
            />
            <div className="space-y-2">
              <div className="text-sm text-zinc-300 flex items-center gap-2">
                <Camera size={14} />
                Upload avatar photo
              </div>
              <input
                type="file"
                accept="image/jpeg,image/png,image/webp,image/gif"
                onChange={(e) => handleFileChange(e.target.files?.[0] ?? null)}
                className="block text-xs text-zinc-400 file:mr-3 file:rounded-md file:border-0 file:bg-zinc-700 file:px-3 file:py-1.5 file:text-xs file:font-semibold file:text-white hover:file:bg-zinc-600"
              />
              <p className="text-xs text-zinc-500">JPG, PNG, WEBP, or GIF up to 5MB.</p>
            </div>
          </div>

          <div className="space-y-1">
            <label className="text-xs font-semibold text-zinc-400">Username</label>
            <input
              value={`@${profile?.username ?? ''}`}
              disabled
              className="w-full bg-zinc-950 border border-zinc-800 rounded-lg px-3 py-2 text-sm text-zinc-400"
            />
          </div>

          <div className="space-y-1">
            <label className="text-xs font-semibold text-zinc-400">Display Name</label>
            <input
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value.slice(0, 60))}
              placeholder="How friends should see your name"
              className="w-full bg-zinc-950 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white placeholder-zinc-500 focus:outline-none focus:border-indigo-500 transition-colors"
              maxLength={60}
            />
          </div>

          <div className="space-y-1">
            <label className="text-xs font-semibold text-zinc-400">Bio</label>
            <textarea
              value={bio}
              onChange={(e) => setBio(e.target.value.slice(0, MAX_BIO_LENGTH))}
              placeholder="Tell people what kind of movies you love"
              className="w-full h-24 resize-none bg-zinc-950 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white placeholder-zinc-500 focus:outline-none focus:border-indigo-500 transition-colors"
            />
            <p className="text-[11px] text-zinc-500 text-right">{bio.length}/{MAX_BIO_LENGTH}</p>
          </div>

          {error && (
            <p className="text-sm text-red-300 bg-red-950/40 border border-red-900 rounded-lg px-3 py-2">{error}</p>
          )}

          <div className="flex items-center justify-between gap-3 pt-2">
            <Link to="/" className="text-sm text-zinc-400 hover:text-zinc-200 transition-colors">
              Back to home
            </Link>
            <button
              onClick={completeOnboarding}
              disabled={submitting}
              className="inline-flex items-center gap-2 rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-black hover:bg-emerald-400 transition-colors disabled:opacity-50"
            >
              <CheckCircle2 size={14} />
              {submitting ? 'Saving...' : 'Complete Profile'}
            </button>
          </div>
        </section>
      </main>
    </div>
  );
};

export default ProfileOnboardingPage;
