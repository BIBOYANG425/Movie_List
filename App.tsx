import React from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import LandingPage from './pages/LandingPage';
import RankingAppPage from './pages/RankingAppPage';
import AuthPage from './pages/AuthPage';
import AuthCallbackPage from './pages/AuthCallbackPage';
import ProfilePage from './pages/ProfilePage';
import ProfileOnboardingPage from './pages/ProfileOnboardingPage';
import MovieOnboardingPage from './pages/MovieOnboardingPage';
import { useAuth } from './contexts/AuthContext';
import { Grain } from './components/Grain';

const App = () => {
  const { user, profile, loading } = useAuth();
  const needsOnboarding = Boolean(user) && Boolean(profile) && !profile.onboardingCompleted;

  if (loading) {
    return (
      <div className="min-h-screen bg-zinc-950 flex items-center justify-center">
        <div className="w-8 h-8 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  return (
    <>
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
          element={user ? (needsOnboarding ? <Navigate to="/onboarding/profile" replace /> : <MovieOnboardingPage />) : <Navigate to="/auth" replace />}
        />
        <Route
          path="/app"
          element={user ? (needsOnboarding ? <Navigate to="/onboarding/profile" replace /> : <RankingAppPage />) : <Navigate to="/auth" replace />}
        />
        <Route
          path="/profile/:profileId"
          element={user ? (needsOnboarding ? <Navigate to="/onboarding/profile" replace /> : <ProfilePage />) : <Navigate to="/auth" replace />}
        />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </>
  );
};

export default App;
