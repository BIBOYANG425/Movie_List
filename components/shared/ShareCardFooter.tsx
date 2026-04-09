import React from 'react';

interface ShareCardFooterProps {
  username: string;
}

/** Branded footer for share/export cards (html2canvas-safe, uses inline styles) */
export const ShareCardFooter: React.FC<ShareCardFooterProps> = ({ username }) => (
  <div
    style={{
      marginTop: 16,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
    }}
  >
    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
      <div
        style={{
          width: 18,
          height: 18,
          borderRadius: '50%',
          background: '#D4C5B0',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: 9,
          fontWeight: 800,
          color: '#0F1419',
        }}
      >
        S
      </div>
      <span style={{ fontSize: 11, color: '#6B7280', fontWeight: 600 }}>spool</span>
    </div>
    <div style={{ fontSize: 10, color: '#4B5563' }}>spool.app/u/{username}</div>
  </div>
);
