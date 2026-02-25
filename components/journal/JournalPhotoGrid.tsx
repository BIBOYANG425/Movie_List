import React, { useRef } from 'react';
import { Plus, X } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { JOURNAL_PHOTO_BUCKET, JOURNAL_PHOTO_MAX_BYTES } from '../../constants';

interface JournalPhotoGridProps {
  photoPaths: string[];
  onAdd: (file: File) => void;
  onRemove: (path: string) => void;
  maxPhotos: number;
}

function getPublicUrl(path: string): string {
  const { data } = supabase.storage.from(JOURNAL_PHOTO_BUCKET).getPublicUrl(path);
  return data.publicUrl;
}

export const JournalPhotoGrid: React.FC<JournalPhotoGridProps> = ({ photoPaths, onAdd, onRemove, maxPhotos }) => {
  const fileRef = useRef<HTMLInputElement>(null);

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
              <img
                src={getPublicUrl(path)}
                alt={`Photo ${i + 1}`}
                className="w-full h-full object-cover"
              />
              <button
                type="button"
                onClick={() => onRemove(path)}
                className="absolute top-1 right-1 w-5 h-5 rounded-full bg-black/70 flex items-center justify-center text-white hover:bg-red-500/80 transition-colors"
              >
                <X size={12} />
              </button>
            </>
          ) : i === photoPaths.length ? (
            <button
              type="button"
              onClick={() => fileRef.current?.click()}
              className="w-full h-full border-2 border-dashed border-zinc-800 rounded-lg flex flex-col items-center justify-center text-zinc-600 hover:border-zinc-600 hover:text-zinc-400 transition-colors"
            >
              <Plus size={20} />
              <span className="text-[10px] mt-1">Add</span>
            </button>
          ) : (
            <div className="w-full h-full border-2 border-dashed border-zinc-900 rounded-lg" />
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
