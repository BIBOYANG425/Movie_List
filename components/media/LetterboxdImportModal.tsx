import React, { useState, useRef, useCallback } from 'react';
import FocusTrap from 'focus-trap-react';
import { X, Upload, Loader2, CheckCircle, AlertTriangle } from 'lucide-react';
import { TIER_COLORS } from '../../constants';
import { Tier } from '../../types';
import {
  extractLetterboxdZip,
  mergeEntries,
  buildPreview,
  resolveAllWithTMDB,
  assignPositions,
  persistImport,
  fetchExistingIds,
  mapRatingToTier,
  type LetterboxdMergedEntry,
  type ImportPreview,
  type ImportResult,
  type ResolvedEntry,
} from '../../services/letterboxdImportService';

interface LetterboxdImportModalProps {
  isOpen: boolean;
  onClose: () => void;
  userId: string;
  onImportComplete: () => void;
}

type Step = 'upload' | 'preview' | 'resolving' | 'results';

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB

export const LetterboxdImportModal: React.FC<LetterboxdImportModalProps> = ({
  isOpen,
  onClose,
  userId,
  onImportComplete,
}) => {
  const [step, setStep] = useState<Step>('upload');
  const [error, setError] = useState<string | null>(null);
  const [parsing, setParsing] = useState(false);

  // Preview state
  const [preview, setPreview] = useState<ImportPreview | null>(null);
  const [mergedData, setMergedData] = useState<LetterboxdMergedEntry[]>([]);
  const [watchlistData, setWatchlistData] = useState<LetterboxdMergedEntry[]>([]);

  // Resolving state
  const [progress, setProgress] = useState(0);
  const [progressTotal, setProgressTotal] = useState(0);
  const [currentTitle, setCurrentTitle] = useState('');
  const abortRef = useRef<AbortController | null>(null);

  // Results state
  const [importResult, setImportResult] = useState<ImportResult | null>(null);

  const reset = useCallback(() => {
    setStep('upload');
    setError(null);
    setParsing(false);
    setPreview(null);
    setMergedData([]);
    setWatchlistData([]);
    setProgress(0);
    setProgressTotal(0);
    setCurrentTitle('');
    setImportResult(null);
    if (abortRef.current) {
      abortRef.current.abort();
      abortRef.current = null;
    }
  }, []);

  const handleClose = useCallback(() => {
    if (step === 'resolving' && abortRef.current) {
      abortRef.current.abort();
    }
    reset();
    onClose();
  }, [step, reset, onClose]);

  const handleFileSelect = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    if (!file.name.endsWith('.zip')) {
      setError('Please select a .zip file exported from Letterboxd.');
      return;
    }

    if (file.size > MAX_FILE_SIZE) {
      setError('File is too large. Maximum size is 10MB.');
      return;
    }

    setError(null);
    setParsing(true);

    try {
      const parsed = await extractLetterboxdZip(file);
      const { merged, watchlist } = mergeEntries(parsed);

      if (merged.length === 0 && watchlist.length === 0) {
        setError('No movie data found in the ZIP file. Make sure this is a Letterboxd export.');
        setParsing(false);
        return;
      }

      setMergedData(merged);
      setWatchlistData(watchlist);
      setPreview(buildPreview(merged, watchlist, parsed));
      setStep('preview');
    } catch (err) {
      setError('Failed to parse the ZIP file. Make sure this is a valid Letterboxd export.');
      console.error('ZIP parse error:', err);
    } finally {
      setParsing(false);
    }
  }, []);

  const handleStartImport = useCallback(async () => {
    setStep('resolving');
    setProgress(0);

    const allEntries = [...mergedData, ...watchlistData];
    setProgressTotal(allEntries.length);

    const controller = new AbortController();
    abortRef.current = controller;

    try {
      // Resolve all entries against TMDB
      const { resolved, failed } = await resolveAllWithTMDB(
        allEntries,
        (completed, total, title) => {
          setProgress(completed);
          setProgressTotal(total);
          setCurrentTitle(title);
        },
        controller.signal,
      );

      if (controller.signal.aborted) return;

      // Split resolved back into ranked vs watchlist
      const mergedNames = new Set(mergedData.map(m => `${m.name.toLowerCase().trim()}|${m.year ?? ''}`));
      const resolvedRanked: ResolvedEntry[] = [];
      const resolvedWatchlist: ResolvedEntry[] = [];

      for (const entry of resolved) {
        const key = `${entry.name.toLowerCase().trim()}|${entry.year ?? ''}`;
        if (mergedNames.has(key)) {
          resolvedRanked.push(entry);
        } else {
          resolvedWatchlist.push(entry);
        }
      }

      // Only rank entries that have a rating
      const ratedEntries = resolvedRanked.filter(e => e.rating != null);
      const ranked = assignPositions(ratedEntries);

      // Fetch existing IDs
      const { rankingIds, watchlistIds } = await fetchExistingIds(userId);

      // Persist
      const result = await persistImport(userId, ranked, resolvedWatchlist, rankingIds, watchlistIds);
      result.failedResolutions = failed;

      setImportResult(result);
      setStep('results');
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') return;
      setError(`Import failed: ${err instanceof Error ? err.message : 'Unknown error'}`);
      setStep('preview');
      console.error('Import error:', err);
    }
  }, [mergedData, watchlistData, userId]);

  const handleDone = useCallback(() => {
    onImportComplete();
    handleClose();
  }, [onImportComplete, handleClose]);

  if (!isOpen) return null;

  const progressPct = progressTotal > 0 ? Math.round((progress / progressTotal) * 100) : 0;

  return (
    <FocusTrap focusTrapOptions={{ allowOutsideClick: true }}>
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm">
      <div className="bg-background border border-border w-full max-w-lg rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
        {/* Header */}
        <div className="flex items-center justify-between p-5 border-b border-border bg-card/30 flex-shrink-0">
          <h2 className="text-lg font-bold text-foreground">Import from Letterboxd</h2>
          <button
            onClick={handleClose}
            className="p-1.5 rounded-lg text-muted-foreground hover:text-foreground hover:bg-secondary transition-colors"
          >
            <X size={18} />
          </button>
        </div>

        {/* Content */}
        <div className="p-5 overflow-y-auto space-y-4">
          {/* Step: Upload */}
          {step === 'upload' && (
            <div className="space-y-4">
              <p className="text-sm text-muted-foreground">
                Upload your Letterboxd data export (.zip). You can export your data from{' '}
                <a
                  href="https://letterboxd.com/settings/data/"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-accent hover:text-accent underline"
                >
                  Letterboxd Settings &rarr; Import & Export
                </a>.
              </p>

              <label className="flex flex-col items-center justify-center gap-3 p-8 border-2 border-dashed border-border rounded-xl cursor-pointer hover:border-gold/50 hover:bg-card/30 transition-colors">
                {parsing ? (
                  <>
                    <Loader2 className="w-8 h-8 text-gold animate-spin" />
                    <span className="text-sm text-muted-foreground">Parsing export...</span>
                  </>
                ) : (
                  <>
                    <Upload className="w-8 h-8 text-muted-foreground" />
                    <span className="text-sm text-muted-foreground">Click to select your Letterboxd export (.zip)</span>
                    <span className="text-xs text-muted-foreground/60">Max 10MB</span>
                  </>
                )}
                <input
                  type="file"
                  accept=".zip"
                  onChange={handleFileSelect}
                  disabled={parsing}
                  className="hidden"
                />
              </label>

              {error && (
                <div className="flex items-start gap-2 p-3 rounded-lg bg-red-500/10 border border-red-500/20">
                  <AlertTriangle size={16} className="text-red-400 mt-0.5 flex-shrink-0" />
                  <p className="text-sm text-red-300">{error}</p>
                </div>
              )}
            </div>
          )}

          {/* Step: Preview */}
          {step === 'preview' && preview && (
            <div className="space-y-4">
              <p className="text-sm text-muted-foreground">
                Found the following data in your Letterboxd export:
              </p>

              <div className="grid grid-cols-2 gap-3">
                <StatCard label="Rated Movies" value={preview.ratedCount} />
                <StatCard label="Watchlist" value={preview.watchlistCount} />
                <StatCard label="Reviews" value={preview.reviewCount} />
                <StatCard label="Diary Entries" value={preview.diaryCount} />
              </div>

              {preview.ratedCount > 0 && (
                <div className="space-y-2">
                  <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">Tier Distribution</p>
                  <div className="flex gap-2">
                    {(['S', 'A', 'B', 'C', 'D'] as Tier[]).map(tier => (
                      <div
                        key={tier}
                        className={`flex-1 rounded-lg border p-2 text-center ${TIER_COLORS[tier]}`}
                      >
                        <div className="text-lg font-bold">{preview.tierDistribution[tier] ?? 0}</div>
                        <div className="text-xs font-semibold">{tier}</div>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {preview.sampleTitles.length > 0 && (
                <div className="space-y-1">
                  <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">Sample Titles</p>
                  <p className="text-sm text-muted-foreground">{preview.sampleTitles.join(', ')}</p>
                </div>
              )}

              {preview.ratedCount === 0 && preview.watchlistCount === 0 && (
                <p className="text-sm text-muted-foreground">
                  No rated movies or watchlist items found. Only unrated diary/watched entries will not be imported as rankings.
                </p>
              )}

              {error && (
                <div className="flex items-start gap-2 p-3 rounded-lg bg-red-500/10 border border-red-500/20">
                  <AlertTriangle size={16} className="text-red-400 mt-0.5 flex-shrink-0" />
                  <p className="text-sm text-red-300">{error}</p>
                </div>
              )}
            </div>
          )}

          {/* Step: Resolving */}
          {step === 'resolving' && (
            <div className="space-y-4 py-4">
              <p className="text-sm text-muted-foreground text-center">
                Matching movies against TMDB...
              </p>

              <div className="space-y-2">
                <div className="h-3 rounded-full bg-secondary overflow-hidden">
                  <div
                    className="h-full rounded-full bg-gold transition-all duration-300 ease-out"
                    style={{ width: `${progressPct}%` }}
                  />
                </div>
                <div className="flex justify-between text-xs text-muted-foreground">
                  <span>{progress} / {progressTotal}</span>
                  <span>{progressPct}%</span>
                </div>
              </div>

              {currentTitle && (
                <p className="text-xs text-muted-foreground text-center truncate">
                  Resolving: {currentTitle}
                </p>
              )}

              <button
                onClick={() => {
                  abortRef.current?.abort();
                  setStep('preview');
                }}
                className="w-full rounded-lg border border-border px-4 py-2 text-sm text-muted-foreground hover:text-foreground hover:border-border transition-colors"
              >
                Cancel
              </button>
            </div>
          )}

          {/* Step: Results */}
          {step === 'results' && importResult && (
            <div className="space-y-4">
              <div className="flex items-center gap-2 text-emerald-400">
                <CheckCircle size={20} />
                <span className="font-semibold">Import Complete</span>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <StatCard label="Rankings Imported" value={importResult.rankingsImported} />
                <StatCard label="Rankings Skipped" value={importResult.rankingsSkipped} />
                <StatCard label="Watchlist Imported" value={importResult.watchlistImported} />
                <StatCard label="Journal Entries" value={importResult.journalImported} />
              </div>

              {importResult.failedResolutions.length > 0 && (
                <div className="space-y-2">
                  <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
                    Failed to Resolve ({importResult.failedResolutions.length})
                  </p>
                  <div className="max-h-32 overflow-y-auto rounded-lg border border-border bg-card/30 p-3">
                    <p className="text-xs text-muted-foreground">
                      {importResult.failedResolutions.join(', ')}
                    </p>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="p-5 border-t border-border bg-card/30 flex-shrink-0">
          {step === 'preview' && (
            <div className="flex gap-3">
              <button
                onClick={handleClose}
                className="flex-1 rounded-lg border border-border px-4 py-2.5 text-sm text-muted-foreground hover:text-foreground hover:border-border transition-colors"
              >
                Cancel
              </button>
              <button
                onClick={handleStartImport}
                className="flex-1 rounded-lg bg-gold px-4 py-2.5 text-sm font-semibold text-foreground hover:bg-gold-muted transition-colors"
              >
                Start Import
              </button>
            </div>
          )}

          {step === 'results' && (
            <button
              onClick={handleDone}
              className="w-full rounded-lg bg-gold px-4 py-2.5 text-sm font-semibold text-foreground hover:bg-gold-muted transition-colors"
            >
              Done
            </button>
          )}
        </div>
      </div>
    </div>
    </FocusTrap>
  );
};

function StatCard({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-lg border border-border bg-card/30 p-3 text-center">
      <div className="text-xl font-bold text-foreground">{value}</div>
      <div className="text-xs text-muted-foreground mt-0.5">{label}</div>
    </div>
  );
}
