import React, { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';

const MAX_RETRIES = 12;
const RETRY_DELAY_MS = 300;

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

const AuthCallbackPage = () => {
  const navigate = useNavigate();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    const finishLogin = async () => {
      const searchParams = new URLSearchParams(window.location.search);
      const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ''));
      const authError =
        searchParams.get('error_description')
        ?? searchParams.get('error')
        ?? hashParams.get('error_description')
        ?? hashParams.get('error');
      if (authError) {
        setError(safeDecode(authError));
        return;
      }

      for (let attempt = 0; attempt < MAX_RETRIES; attempt += 1) {
        const { data, error: sessionError } = await supabase.auth.getSession();
        if (sessionError) {
          setError(sessionError.message);
          return;
        }

        if (data.session?.user) {
          navigate('/app', { replace: true });
          return;
        }

        await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS));
        if (cancelled) return;
      }

      if (!cancelled) {
        setError('Google sign-in did not complete. Please try again.');
      }
    };

    finishLogin();
    return () => {
      cancelled = true;
    };
  }, [navigate]);

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100 flex items-center justify-center px-4">
      <div className="w-full max-w-md rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-center space-y-4">
        {!error ? (
          <>
            <div className="mx-auto w-8 h-8 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
            <h1 className="text-lg font-bold">Finalizing sign-in</h1>
            <p className="text-sm text-zinc-400">Please wait while we complete your Google login.</p>
          </>
        ) : (
          <>
            <h1 className="text-lg font-bold">Google sign-in failed</h1>
            <p className="text-sm text-red-300 bg-red-950/40 border border-red-900 rounded-lg px-3 py-2">
              {error}
            </p>
            <Link
              to="/auth"
              className="inline-flex items-center justify-center rounded-lg bg-indigo-600 hover:bg-indigo-500 px-4 py-2 text-sm font-semibold text-white transition-colors"
            >
              Back to Sign In
            </Link>
          </>
        )}
      </div>
    </div>
  );
};

export default AuthCallbackPage;
