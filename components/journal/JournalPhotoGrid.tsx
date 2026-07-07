import React, { useEffect, useRef, useState } from 'react';
import { Plus, X } from 'lucide-react';
import { JOURNAL_PHOTO_MAX_BYTES } from '../../constants';
import { getJournalPhotoUrls } from '../../services/journalService';

interface JournalPhotoGridProps {
  photoPaths: string[];
  onAdd: (file: File) => void;
  onRemove: (path: string) => void;
  maxPhotos: number;
}

export const JournalPhotoGrid: React.FC<JournalPhotoGridProps> = ({ photoPaths, onAdd, onRemove, maxPhotos }) => {
  const fileRef = useRef<HTMLInputElement>(null);

  // Audit B4: the journal-photos bucket is private — render via signed URLs
  // (30-day TTL), batch-minted fresh on every mount / photo-set change and
  // never persisted. Keyed by the stored value (path, or legacy URL via
  // extractJournalPhotoPath inside the service).
  const [signedUrls, setSignedUrls] = useState<Record<string, string>>({});
  const photoKey = photoPaths.join('\n');
  useEffect(() => {
    let cancelled = false;
    if (photoPaths.length === 0) {
      setSignedUrls({});
      return;
    }
    getJournalPhotoUrls(photoPaths).then((map) => {
      if (!cancelled) setSignedUrls(Object.fromEntries(map));
    });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- photoKey stands in for photoPaths' contents
  }, [photoKey]);

  const handleFile = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    if (file.size > JOURNAL_PHOTO_MAX_BYTES) {
      alert('Photo must be under 5MB');
      return;
    }
    onAdd(file);
    if (fileRef.current) fileRef.current.value = '';
  };

  const slots = Array.from({ length: maxPhotos }, (_, i) => photoPaths[i] ?? null);

  return (
    <div className="grid grid-cols-3 gap-2">
      {slots.map((path, i) => (
        <div key={i} className="aspect-square rounded-lg overflow-hidden relative">
          {path ? (
            <>
              {signedUrls[path] ? (
                <img
                  src={signedUrls[path]}
                  alt={`Photo ${i + 1}`}
                  className="w-full h-full object-cover"
                />
              ) : (
                <div className="w-full h-full bg-background animate-pulse" />
              )}
              <button
                type="button"
                onClick={() => onRemove(path)}
                className="absolute top-1 right-1 w-5 h-5 rounded-full bg-black/70 flex items-center justify-center text-foreground hover:bg-red-500/80 transition-colors"
              >
                <X size={12} />
              </button>
            </>
          ) : i === photoPaths.length ? (
            <button
              type="button"
              onClick={() => fileRef.current?.click()}
              className="w-full h-full border-2 border-dashed border-border rounded-lg flex flex-col items-center justify-center text-muted-foreground/60 hover:border-border hover:text-muted-foreground transition-colors"
            >
              <Plus size={20} />
              <span className="text-[10px] mt-1">Add</span>
            </button>
          ) : (
            <div className="w-full h-full border-2 border-dashed border-background rounded-lg" />
          )}
        </div>
      ))}
      <input
        ref={fileRef}
        type="file"
        accept="image/jpeg,image/png,image/webp"
        className="hidden"
        onChange={handleFile}
      />
    </div>
  );
};
