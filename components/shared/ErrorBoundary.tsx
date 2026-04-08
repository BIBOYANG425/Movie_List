import React, { Component, ErrorInfo, ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { RefreshCw, Home } from 'lucide-react';

interface ErrorBoundaryProps {
  children: ReactNode;
  fallback?: ReactNode;
  onError?: (error: Error, errorInfo: ErrorInfo) => void;
}

interface ErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
}

export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { hasError: false, error: null };

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error('[ErrorBoundary]', error, errorInfo);
    this.props.onError?.(error, errorInfo);
  }

  private handleReset = () => {
    this.setState({ hasError: false, error: null });
  };

  render() {
    if (!this.state.hasError) {
      return this.props.children;
    }

    if (this.props.fallback) {
      return this.props.fallback;
    }

    return (
      <div className="rounded-xl bg-card border border-border p-8 text-center max-w-sm mx-auto my-8">
        <div className="w-10 h-10 rounded-full bg-secondary flex items-center justify-center mx-auto mb-4">
          <span className="font-serif text-lg text-gold">oo</span>
        </div>
        <p className="text-foreground font-medium text-sm mb-1">Something hit a snag</p>
        <p className="text-muted-foreground text-xs mb-4">Your rankings are safe. Try refreshing, or come back in a minute.</p>
        <div className="flex items-center justify-center gap-3">
          <button
            onClick={this.handleReset}
            className="flex items-center gap-1.5 px-4 py-2 text-sm rounded-lg bg-gold text-background font-medium hover:opacity-90 transition-opacity"
          >
            <RefreshCw size={14} />
            Try again
          </button>
          <Link
            to="/"
            className="flex items-center gap-1.5 px-4 py-2 text-sm rounded-lg bg-secondary text-muted-foreground hover:text-foreground transition-colors"
          >
            <Home size={14} />
            Go home
          </Link>
        </div>
      </div>
    );
  }
}
