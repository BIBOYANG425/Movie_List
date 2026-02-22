import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';

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
    <div className="min-h-screen bg-zinc-950 text-zinc-100 flex items-center justify-center px-4">
      <div className="w-full max-w-sm space-y-6">
        <div className="flex items-center gap-2 justify-center">
          <div className="w-9 h-9 bg-indigo-500 rounded-lg flex items-center justify-center font-bold text-white shadow-lg shadow-indigo-500/20">
            M
          </div>
          <span className="font-bold text-2xl tracking-tight">Marquee</span>
        </div>

        <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-6 space-y-5">
          <div className="flex bg-zinc-800 rounded-lg p-1">
            <button
              onClick={() => { setMode('signin'); setError(null); }}
              className={`flex-1 py-1.5 rounded-md text-sm font-semibold transition-all ${
                mode === 'signin' ? 'bg-zinc-700 text-white shadow' : 'text-zinc-400 hover:text-zinc-200'
              }`}
            >
              Sign In
            </button>
            <button
              onClick={() => { setMode('signup'); setError(null); }}
              className={`flex-1 py-1.5 rounded-md text-sm font-semibold transition-all ${
                mode === 'signup' ? 'bg-zinc-700 text-white shadow' : 'text-zinc-400 hover:text-zinc-200'
              }`}
            >
              Sign Up
            </button>
          </div>

          <form onSubmit={handleSubmit} className="space-y-4">
            <button
              type="button"
              onClick={handleGoogleSignIn}
              disabled={submitting || oauthSubmitting}
              className="w-full flex items-center justify-center gap-2 bg-white hover:bg-zinc-100 disabled:opacity-50 disabled:cursor-not-allowed text-zinc-900 font-semibold rounded-lg py-2 text-sm transition-colors"
            >
              <span className="inline-flex items-center justify-center w-5 h-5 rounded-full bg-zinc-900 text-white text-xs font-bold">
                G
              </span>
              {oauthSubmitting ? 'Redirecting…' : 'Continue with Google'}
            </button>

            <div className="relative">
              <div className="h-px bg-zinc-800" />
              <span className="absolute left-1/2 -translate-x-1/2 -top-2 bg-zinc-900 px-2 text-center text-[10px] tracking-wider uppercase text-zinc-500">
                Or
              </span>
            </div>

            <div className="space-y-1">
              <label className="text-xs font-semibold text-zinc-400">Email</label>
              <input
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white placeholder-zinc-500 focus:outline-none focus:border-indigo-500 transition-colors"
                placeholder="you@example.com"
              />
            </div>

            {mode === 'signup' && (
              <div className="space-y-1">
                <label className="text-xs font-semibold text-zinc-400">Username</label>
                <input
                  type="text"
                  required
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  className="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white placeholder-zinc-500 focus:outline-none focus:border-indigo-500 transition-colors"
                  placeholder="cinephile42"
                  minLength={3}
                  maxLength={32}
                  pattern="^[a-zA-Z0-9_]{3,32}$"
                />
              </div>
            )}

            <div className="space-y-1">
              <label className="text-xs font-semibold text-zinc-400">Password</label>
              <input
                type="password"
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="w-full bg-zinc-800 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-white placeholder-zinc-500 focus:outline-none focus:border-indigo-500 transition-colors"
                placeholder="••••••••"
                minLength={6}
              />
            </div>

            {error && (
              <p className="text-sm text-red-400 bg-red-950/50 border border-red-900 rounded-lg px-3 py-2">
                {error}
              </p>
            )}

            <button
              type="submit"
              disabled={submitting || oauthSubmitting}
              className="w-full bg-indigo-600 hover:bg-indigo-500 disabled:opacity-50 disabled:cursor-not-allowed text-white font-semibold rounded-lg py-2 text-sm transition-colors"
            >
              {submitting ? 'Loading…' : mode === 'signin' ? 'Sign In' : 'Create Account'}
            </button>
          </form>
        </div>
      </div>
    </div>
  );
};

export default AuthPage;
