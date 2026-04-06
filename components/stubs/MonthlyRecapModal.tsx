import React, { useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import FocusTrap from 'focus-trap-react';
import html2canvas from 'html2canvas';
import { Download, Share2, X } from 'lucide-react';
import { MovieStub } from '../../types';
import { useTranslation } from '../../contexts/LanguageContext';
import { MonthlyRecapCard } from './MonthlyRecapCard';

interface MonthlyRecapModalProps {
  open: boolean;
  onClose: () => void;
  stubs: MovieStub[];
  monthLabel: string;
  totalStubs: number;
  sTierCount: number;
  topMood?: [string, number];
  username: string;
  displayName?: string;
  currentStreak?: number;
}

export const MonthlyRecapModal: React.FC<MonthlyRecapModalProps> = ({
  open,
  onClose,
  stubs,
  monthLabel,
  totalStubs,
  sTierCount,
  topMood,
  username,
  displayName,
  currentStreak,
}) => {
  const { t } = useTranslation();
  const cardRef = useRef<HTMLDivElement>(null);
  const [exporting, setExporting] = useState(false);

  if (!open) return null;

  const handleExport = async () => {
    if (!cardRef.current) return;
    setExporting(true);
    try {
      const canvas = await html2canvas(cardRef.current, {
        backgroundColor: null,
        scale: 2,
        useCORS: true,
        logging: false,
      });

      canvas.toBlob(async (blob) => {
        if (!blob) return;
        const file = new File([blob], `spool-recap-${monthLabel.replace(/\s/g, '-')}.png`, {
          type: 'image/png',
        });

        if (navigator.share && navigator.canShare?.({ files: [file] })) {
          try {
            await navigator.share({ files: [file], title: `${monthLabel} on Spool` });
          } catch {
            // User cancelled
          }
        } else {
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.href = url;
          a.download = file.name;
          a.click();
          URL.revokeObjectURL(url);
        }
        setExporting(false);
      }, 'image/png');
    } catch {
      setExporting(false);
    }
  };

  return createPortal(
    <FocusTrap focusTrapOptions={{ allowOutsideClick: true }}>
      <div
        className="fixed inset-0 z-[9999] flex items-center justify-center bg-black/70 backdrop-blur-sm p-4"
        onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
        role="dialog"
        aria-modal="true"
        aria-label={t('recap.title')}
      >
        <div className="w-full max-w-md bg-card border border-border/30 rounded-2xl overflow-hidden">
          {/* Header */}
          <div className="flex items-center justify-between px-4 py-3 border-b border-border/30">
            <h2 className="text-sm font-semibold text-foreground">{t('recap.title')}</h2>
            <button onClick={onClose} className="text-muted-foreground hover:text-foreground">
              <X size={18} />
            </button>
          </div>

          {/* Card preview */}
          <div className="p-4 flex justify-center">
            <MonthlyRecapCard
              ref={cardRef}
              stubs={stubs}
              monthLabel={monthLabel}
              totalStubs={totalStubs}
              sTierCount={sTierCount}
              topMood={topMood}
              username={username}
              displayName={displayName}
              currentStreak={currentStreak}
            />
          </div>

          {/* Actions */}
          <div className="px-4 pb-4">
            <button
              onClick={handleExport}
              disabled={exporting}
              className="w-full flex items-center justify-center gap-2 px-4 py-2.5 bg-gold text-foreground font-semibold rounded-xl text-sm hover:bg-gold-muted transition-colors disabled:opacity-50"
            >
              {navigator.share ? <Share2 size={14} /> : <Download size={14} />}
              {exporting
                ? t('share.exporting')
                : navigator.share
                  ? t('share.shareImage')
                  : t('share.downloadImage')
              }
            </button>
          </div>
        </div>
      </div>
    </FocusTrap>,
    document.body,
  );
};
