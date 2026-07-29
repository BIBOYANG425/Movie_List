// Fullscreen portal for the Curator's Walk. The gallery is a place you enter,
// not a panel in the page: body scroll locks while mounted, and a ✕ (plus
// hall-mode Esc, wired inside GalleryView so it never steals inspect's Esc)
// exits back to the grid. Rendered into document.body so page chrome
// (header/search/filter chips) is fully covered.
import React, { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';

interface GalleryOverlayProps {
  onExit: () => void;
  children: React.ReactNode;
}

export const GalleryOverlay: React.FC<GalleryOverlayProps> = ({ onExit, children }) => {
  // Remember what had focus on entry (the GalleryModeToggle button) so we can
  // hand focus back on exit; GalleryView focuses the canvas for us. Captured at
  // render time, not in the mount effect: the child GalleryView's canvas-focus
  // effect runs before this parent effect (children mount first), so an
  // effect-time read on warm re-entry would capture the canvas instead of the
  // toggle. Render-time capture happens before any child effect fires.
  const [previouslyFocused] = useState(
    () => document.activeElement as HTMLElement | null,
  );

  useEffect(() => {
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';

    // Fullscreen takeover: mark the app root inert so the covered grid drops
    // out of the tab order and the accessibility tree. The overlay portals to
    // document.body (a sibling of #root), so it stays interactive. This is the
    // inert-background equivalent of the FocusTrap the other modals use.
    const appRoot = document.getElementById('root');
    appRoot?.setAttribute('inert', '');

    return () => {
      document.body.style.overflow = prev;
      appRoot?.removeAttribute('inert');
      if (
        previouslyFocused &&
        previouslyFocused.isConnected &&
        typeof previouslyFocused.focus === 'function'
      ) {
        previouslyFocused.focus({ preventScroll: true });
      }
    };
  }, []);

  // z-[70]: above page chrome and the z-50 modals/tier-fullscreen, but below
  // the z-[100] toasts so status toasts stay visible over the Walk.
  return createPortal(
    <div className="fixed inset-0 z-[70] bg-background animate-fade-in-up">
      {children}
      <button
        onClick={onExit}
        aria-label="Exit gallery"
        className="absolute top-5 right-5 z-10 p-2 text-muted-foreground hover:text-foreground transition-colors"
      >
        <X size={20} />
      </button>
    </div>,
    document.body,
  );
};
