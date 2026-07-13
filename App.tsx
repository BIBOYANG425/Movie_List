import React from 'react';
import { Navigate, Route, Routes, useLocation } from 'react-router-dom';
import LandingPage from './pages/LandingPage';
import RankingAppPage from './pages/RankingAppPage';
import AuthPage from './pages/AuthPage';
import AuthCallbackPage from './pages/AuthCallbackPage';
import ProfilePage from './pages/ProfilePage';
import ProfileOnboardingPage from './pages/ProfileOnboardingPage';
import PublicProfilePage from './pages/PublicProfilePage';
import MovieOnboardingPage from './pages/MovieOnboardingPage';
import AgentRankPage from './pages/AgentRankPage';
import AgentShowtimesPage from './pages/AgentShowtimesPage';
import AgentLoginPage from './pages/AgentLoginPage';
import { useAuth } from './contexts/AuthContext';
import { Grain } from './components/shared/Grain';
import { ErrorBoundary } from './components/shared/ErrorBoundary';

const App = () => {
  const { user, profile, loading } = useAuth();
  const location = useLocation();
  const needsOnboarding = Boolean(user) && Boolean(profile) && !profile.onboardingCompleted;

  if (loading) {
    return (
      <div className="min-h-screen bg-background flex items-center justify-center">
        <div className="w-8 h-8 border-2 border-gold border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  return (
    <ErrorBoundary key={location.key || location.pathname}>
      <Grain />
      <Routes>
        <Route path="/" element={<LandingPage />} />
        <Route path="/auth" element={user ? <Navigate to={needsOnboarding ? '/onboarding/profile' : '/app'} replace /> : <AuthPage />} />
        <Route path="/auth/callback" element={<AuthCallbackPage />} />
        <Route
          path="/onboarding/profile"
          element={user ? (needsOnboarding ? <ProfileOnboardingPage /> : <Navigate to="/onboarding/movies" replace />) : <Navigate to="/auth" replace />}
        />
        <Route
          path="/onboarding/movies"
          element={user ? (needsOnboarding ? <Navigate to="/onboarding/profile" replace /> : <MovieOnboardingPage />) : <MovieOnboardingPage />}
        />
        <Route
          path="/app"
          element={user ? (needsOnboarding ? <Navigate to="/onboarding/profile" replace /> : <RankingAppPage />) : <Navigate to="/auth" replace />}
        />
        <Route
          path="/profile/:profileId"
          element={user ? (needsOnboarding ? <Navigate to="/onboarding/profile" replace /> : <ProfilePage />) : <Navigate to="/auth" replace />}
        />
        <Route path="/u/:username" element={<PublicProfilePage />} />
        {/*
          Agent rank ceremony (P3-B). Opens inside iMessage via a Photon
          mini-app card; authenticated by a short-TTL JWT in the URL fragment,
          NOT the app session — so it renders regardless of `user`. Self-contained
          (own token-scoped client) and does not touch /u/* or any other route.
        */}
        <Route path="/agent-rank" element={<AgentRankPage />} />
        {/*
          Agent showtimes card (S2b). Opens inside iMessage via a Photon
          mini-app card; reads ONE unexpired row of PUBLIC showtimes data with
          the anon client (no JWT, unlike /agent-rank). Row id rides in the URL
          fragment (#c=<uuid>). Plain web route — does not touch /u/* or AASA.
        */}
        <Route path="/agent-showtimes" element={<AgentShowtimesPage />} />
        {/*
          Agent-initiated web login (P4, Slice B2). Chris texts an UNLINKED user
          a rich link with a single-use login token in the fragment (#lt=<token>).
          Opens REAL Safari: reuses the app's AuthPage for sign-in / sign-up, then
          calls the agent-link edge function under the fresh JWT to bind the
          texter's phone to their account. Renders regardless of `user` (it drives
          its own consume once a session exists). Does not touch AASA.
        */}
        <Route path="/agent-login" element={<AgentLoginPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </ErrorBoundary>
  );
};

export default App;
