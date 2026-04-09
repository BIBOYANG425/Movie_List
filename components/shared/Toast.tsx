import React, { useEffect, useState } from 'react';
import { Check } from 'lucide-react';

interface ToastProps {
  message: string;
  onDone: () => void;
  duration?: number;
}

export const Toast: React.FC<ToastProps> = ({ message, onDone, duration = 2500 }) => {
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    // Trigger enter animation
    requestAnimationFrame(() => setVisible(true));
    const timer = setTimeout(() => {
      setVisible(false);
      setTimeout(onDone, 300);
    }, duration);
    return () => clearTimeout(timer);
  }, [duration, onDone]);

  return (
    <div
      className={`fixed bottom-6 left-1/2 -translate-x-1/2 z-[100] flex items-center gap-2 rounded-full bg-secondary border border-border px-4 py-2.5 shadow-lg transition-all duration-[var(--duration-normal)] ${
        visible ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-3'
      }`}
    >
      <div className="w-5 h-5 rounded-full bg-gold/20 flex items-center justify-center">
        <Check size={12} className="text-gold" />
      </div>
      <span className="text-sm text-foreground">{message}</span>
    </div>
  );
};
