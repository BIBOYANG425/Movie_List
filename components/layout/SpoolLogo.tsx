import React from 'react';

interface SpoolLogoProps {
  size?: 'sm' | 'md' | 'lg' | 'xl';
  showWordmark?: boolean;
  className?: string;
}

const sizes = {
  sm: { icon: 20, text: 'text-lg', gap: 'gap-1.5' },
  md: { icon: 28, text: 'text-2xl', gap: 'gap-2' },
  lg: { icon: 36, text: 'text-4xl', gap: 'gap-3' },
  xl: { icon: 48, text: 'text-5xl', gap: 'gap-3' },
};

export default function SpoolLogo({ size = 'md', showWordmark = true, className = '' }: SpoolLogoProps) {
  const s = sizes[size];
  const maskId = React.useId();

  return (
    <div className={`flex items-center ${s.gap} ${className}`}>
      {/* Interlocking OO mark */}
      <svg
        width={Math.round(s.icon * 1.4)}
        height={s.icon}
        viewBox="0 0 140 100"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        className="flex-shrink-0"
      >
        <defs>
          <mask id={maskId}>
            <rect width="140" height="100" fill="white" />
            {/* Mask out right ring where left ring crosses in front (bottom) */}
            <path
              d="M 70 78.5 A 36 36 0 0 1 84 50"
              stroke="black"
              strokeWidth="10"
              fill="none"
            />
          </mask>
        </defs>

        {/* Left ring (full, bottom layer) */}
        <circle cx="48" cy="50" r="36" stroke="#D4C5B0" strokeWidth="6" />

        {/* Right ring (masked at bottom crossing so left ring appears in front) */}
        <circle cx="92" cy="50" r="36" stroke="#D4C5B0" strokeWidth="6" mask={`url(#${maskId})`} />
      </svg>

      {showWordmark && (
        <span className={`font-serif ${s.text} tracking-tight text-gold`}>
          Spool
        </span>
      )}
    </div>
  );
}
