import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import SpoolLogo from '../components/layout/SpoolLogo';

const AuthPage = () => {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [username, setUsername] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [oauthSubmitting, setOauthSubmitting] = useState(false);

  const { signIn, signUp, signInWithGoogle } = useAuth();
  const navigate = useNavigate();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSubmitting(true);

    if (mode === 'signin') {
      const { error } = await signIn(email, password);
      if (error) {
        setError(error.message);
      } else {
        navigate('/app');
      }
    } else {
      if (username.length < 3) {
        setError('Username must be at least 3 characters.');
        setSubmitting(false);
        return;
      }
      const { error } = await signUp(email, password, username);
      if (error) {
        setError(error.message);
      } else {
        navigate('/app');
      }
    }

    setSubmitting(false);
  };

  const handleGoogleSignIn = async () => {
    setError(null);
    setOauthSubmitting(true);
    const { error } = await signInWithGoogle();
    if (error) {
      setError(error.message);
      setOauthSubmitting(false);
    }
  };

  return (
    <div className="min-h-screen bg-background text-foreground flex items-center justify-center px-4">
      <div className="w-full max-w-sm space-y-6">
        <div className="flex flex-col items-center gap-3">
          <SpoolLogo size="lg" />
          <div className="text-center">
            <h1 className="font-serif text-2xl text-foreground">
              {mode === 'signin' ? 'Welcome back' : 'Create your account'}
            </h1>
            <p className="text-sm text-muted-foreground mt-1">
              {mode === 'signin' ? 'Sign in to your movie archive' : 'Start building your movie archive'}
            </p>
          </div>
        </div>

        <div className="bg-card border border-border/30 rounded-2xl p-6 space-y-5">
          <form onSubmit={handleSubmit} className="space-y-4">
            <button
              type="button"
              onClick={handleGoogleSignIn}
              disabled={submitting || oauthSubmitting}
              className="w-full flex items-center justify-center gap-2 border border-border hover:bg-secondary/50 disabled:opacity-50 disabled:cursor-not-allowed text-foreground font-semibold rounded-xl h-12 text-sm transition-colors"
            >
              <span className="inline-flex items-center justify-center w-5 h-5 rounded-full bg-foreground text-background text-xs font-bold">
                G
              </span>
              {oauthSubmitting ? 'Redirecting…' : 'Continue with Google'}
            </button>

            <div className="relative">
              <div className="h-px bg-border/40" />
              <span className="absolute left-1/2 -translate-x-1/2 -top-2 bg-card px-2 text-center text-[10px] tracking-wider uppercase text-muted-foreground">
                Or
              </span>
            </div>

            <div className="space-y-1">
              <label className="text-xs font-semibold text-muted-foreground">Email</label>
              <input
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="w-full bg-input-background border border-border text-foreground rounded-xl h-12 px-3 text-sm placeholder-muted-foreground focus:outline-none focus:border-gold transition-colors"
                placeholder="you@example.com"
              />
            </div>

            {mode === 'signup' && (
              <div className="space-y-1">
                <label className="text-xs font-semibold text-muted-foreground">Username</label>
                <input
                  type="text"
                  required
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  className="w-full bg-input-background border border-border text-foreground rounded-xl h-12 px-3 text-sm placeholder-muted-foreground focus:outline-none focus:border-gold transition-colors"
                  placeholder="cinephile42"
                  minLength={3}
                  maxLength={32}
                  pattern="^[a-zA-Z0-9_]{3,32}$"
                />
              </div>
            )}

            <div className="space-y-1">
              <label className="text-xs font-semibold text-muted-foreground">Password</label>
              <input
                type="password"
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="w-full bg-input-background border border-border text-foreground rounded-xl h-12 px-3 text-sm placeholder-muted-foreground focus:outline-none focus:border-gold transition-colors"
                placeholder="••••••••"
                minLength={6}
              />
            </div>

            {error && (
              <p className="text-sm text-red-400 bg-red-950/50 border border-red-900 rounded-xl px-3 py-2">
                {error}
              </p>
            )}

            <button
              type="submit"
              disabled={submitting || oauthSubmitting}
              className="w-full bg-gold hover:bg-gold-muted disabled:opacity-50 disabled:cursor-not-allowed text-background font-semibold rounded-xl h-12 text-sm transition-colors active:scale-95"
            >
              {submitting ? 'Loading…' : mode === 'signin' ? 'Sign In' : 'Create Account'}
            </button>
          </form>
        </div>

        <p className="text-center text-sm text-muted-foreground">
          {mode === 'signin' ? "Don't have an account? " : 'Already have an account? '}
          <button
            onClick={() => { setMode(mode === 'signin' ? 'signup' : 'signin'); setError(null); }}
            className="text-gold hover:underline"
          >
            {mode === 'signin' ? 'Sign Up' : 'Sign In'}
          </button>
        </p>
      </div>
    </div>
  );
};

export default AuthPage;
