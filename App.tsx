import React from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import LandingPage from './pages/LandingPage';
import RankingAppPage from './pages/RankingAppPage';
import AuthPage from './pages/AuthPage';
import ProfilePage from './pages/ProfilePage';
import { useAuth } from './contexts/AuthContext';

const App = () => {
  const { user, loading } = useAuth();

  if (loading) {
    return (
      <div className="min-h-screen bg-zinc-950 flex items-center justify-center">
        <div className="w-8 h-8 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  return (
    <Routes>
      <Route path="/" element={<LandingPage />} />
      <Route path="/auth" element={user ? <Navigate to="/app" replace /> : <AuthPage />} />
      <Route
        path="/app"
        element={user ? <RankingAppPage /> : <Navigate to="/auth" replace />}
      />
      <Route
        path="/profile/:profileId"
        element={user ? <ProfilePage /> : <Navigate to="/auth" replace />}
      />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
};

export default App;
