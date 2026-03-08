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
import { MIN_MOVIES_FOR_SCORES } from '../constants';
import SpoolLogo from '../components/SpoolLogo';

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

    // Skip movie step if picks were already made during anonymous onboarding
    let hasLocalPicks = false;
    try {
      const stored = JSON.parse(localStorage.getItem('spool_onboarding_picks') || '[]');
      hasLocalPicks = stored.length >= MIN_MOVIES_FOR_SCORES;
    } catch { /* ignore */ }

    navigate(hasLocalPicks ? '/app' : '/onboarding/movies', { replace: true });
  };

  return (
    <div className="min-h-screen bg-background text-foreground">
      <main className="max-w-2xl mx-auto px-4 py-10 space-y-6">
        <div className="space-y-3">
          <SpoolLogo size="md" />
          <p className="text-xs uppercase tracking-[0.2em] text-gold">Welcome to Spool</p>
          <h1 className="text-3xl font-serif font-bold">Set up your profile</h1>
          <p className="text-muted-foreground text-sm">
            Friends can discover you by username, see your profile, and follow your ranking activity.
          </p>
        </div>

        <section className="rounded-2xl border border-border/30 bg-card/50 p-6 space-y-5">
          <div className="flex items-center gap-4">
            <img
              src={avatarPreview}
              alt={profile?.username ?? 'profile'}
              className="w-20 h-20 rounded-2xl object-cover border border-border/30 bg-secondary"
            />
            <div className="space-y-2">
              <div className="text-sm text-muted-foreground flex items-center gap-2">
                <Camera size={14} />
                Upload avatar photo
              </div>
              <input
                type="file"
                accept="image/jpeg,image/png,image/webp,image/gif"
                onChange={(e) => handleFileChange(e.target.files?.[0] ?? null)}
                className="block text-xs text-muted-foreground file:mr-3 file:rounded-md file:border-0 file:bg-secondary file:px-3 file:py-1.5 file:text-xs file:font-semibold file:text-foreground hover:file:bg-secondary/80"
              />
              <p className="text-xs text-muted-foreground/60">JPG, PNG, WEBP, or GIF up to 5MB.</p>
            </div>
          </div>

          <div className="space-y-1">
            <label className="text-xs font-semibold text-muted-foreground">Username</label>
            <input
              value={`@${profile?.username ?? ''}`}
              disabled
              className="w-full bg-background border border-border rounded-xl px-3 py-2 text-sm text-muted-foreground"
            />
          </div>

          <div className="space-y-1">
            <label className="text-xs font-semibold text-muted-foreground">Display Name</label>
            <input
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value.slice(0, 60))}
              placeholder="How friends should see your name"
              className="w-full bg-input-background border border-border text-foreground rounded-xl px-3 py-2 text-sm placeholder-muted-foreground focus:outline-none focus:border-gold transition-colors"
              maxLength={60}
            />
          </div>

          <div className="space-y-1">
            <label className="text-xs font-semibold text-muted-foreground">Bio</label>
            <textarea
              value={bio}
              onChange={(e) => setBio(e.target.value.slice(0, MAX_BIO_LENGTH))}
              placeholder="Tell people what kind of movies you love"
              className="w-full h-24 resize-none bg-input-background border border-border text-foreground rounded-xl px-3 py-2 text-sm placeholder-muted-foreground focus:outline-none focus:border-gold transition-colors"
            />
            <p className="text-[11px] text-muted-foreground/60 text-right">{bio.length}/{MAX_BIO_LENGTH}</p>
          </div>

          {error && (
            <p className="text-sm text-red-300 bg-red-950/40 border border-red-900 rounded-xl px-3 py-2">{error}</p>
          )}

          <div className="flex items-center justify-between gap-3 pt-2">
            <Link to="/" className="text-sm text-muted-foreground hover:text-foreground transition-colors">
              Back to home
            </Link>
            <button
              onClick={completeOnboarding}
              disabled={submitting}
              className="inline-flex items-center gap-2 rounded-xl bg-gold px-4 py-2 text-sm font-semibold text-background hover:bg-gold-muted transition-colors disabled:opacity-50 active:scale-95"
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
