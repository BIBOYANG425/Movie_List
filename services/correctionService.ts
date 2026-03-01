import { supabase } from '../lib/supabase';
import { UserCorrection, CorrectionType } from '../types';

// ── Pure Functions ───────────────────────────────────────────────────────────

/**
 * Compute the Levenshtein edit distance between two strings.
 */
export function computeEditDistance(a: string, b: string): number {
  const m = a.length;
  const n = b.length;

  // Edge cases
  if (m === 0) return n;
  if (n === 0) return m;

  // Use a 2-row DP approach for space efficiency
  let prev = new Array<number>(n + 1);
  let curr = new Array<number>(n + 1);

  for (let j = 0; j <= n; j++) {
    prev[j] = j;
  }

  for (let i = 1; i <= m; i++) {
    curr[0] = i;
    for (let j = 1; j <= n; j++) {
      if (a[i - 1] === b[j - 1]) {
        curr[j] = prev[j - 1];
      } else {
        curr[j] = 1 + Math.min(prev[j - 1], prev[j], curr[j - 1]);
      }
    }
    [prev, curr] = [curr, prev];
  }

  return prev[n];
}

/**
 * Compare two arrays by value, returning which items were added, removed, or kept.
 */
export function computeArrayDiff(
  original: string[],
  final: string[]
): { added: string[]; removed: string[]; kept: string[] } {
  const originalSet = new Set(original);
  const finalSet = new Set(final);

  const kept = original.filter((item) => finalSet.has(item));
  const added = final.filter((item) => !originalSet.has(item));
  const removed = original.filter((item) => !finalSet.has(item));

  return { added, removed, kept };
}

/**
 * Returns true if the two strings are different.
 */
export function hasChanged(original: string, final: string): boolean {
  return original !== final;
}

/**
 * Detect the type of correction a user made.
 *
 * - 'accept': original === final (identical)
 * - 'add': original is empty, final has content
 * - 'remove': original has content, final is empty
 * - 'rewrite': for text: edit_distance > 80% of original length;
 *              for array: completely different sets (no overlap)
 * - 'edit': partial change (anything else that changed)
 */
export function detectCorrectionType(
  original: string,
  final: string,
  fieldType: 'text' | 'array'
): CorrectionType {
  // Identical => accept
  if (original === final) return 'accept';

  if (fieldType === 'array') {
    let origArr: string[];
    let finalArr: string[];
    try {
      origArr = JSON.parse(original) as string[];
      finalArr = JSON.parse(final) as string[];
    } catch {
      // If parsing fails, fall through to text-based logic
      return detectTextCorrectionType(original, final);
    }

    // Empty original array to non-empty => add
    if (origArr.length === 0 && finalArr.length > 0) return 'add';
    // Non-empty original to empty => remove
    if (origArr.length > 0 && finalArr.length === 0) return 'remove';

    const { kept } = computeArrayDiff(origArr, finalArr);
    // No overlap => rewrite
    if (kept.length === 0) return 'rewrite';
    // Some overlap => edit
    return 'edit';
  }

  // Text field type
  return detectTextCorrectionType(original, final);
}

function detectTextCorrectionType(original: string, final: string): CorrectionType {
  // Empty to content => add
  if (original === '' && final !== '') return 'add';
  // Content to empty => remove
  if (original !== '' && final === '') return 'remove';

  // Compute edit distance to determine rewrite vs edit
  const distance = computeEditDistance(original, final);
  const threshold = original.length * 0.8;

  if (distance > threshold) return 'rewrite';
  return 'edit';
}

// ── Supabase Functions ──────────────────────────────────────────────────────

/**
 * Record a single user correction for a generated field.
 */
export async function recordCorrection(
  generationId: string,
  userId: string,
  fieldName: string,
  originalValue: string,
  finalValue: string,
  editDistance?: number,
  timeSpentMs?: number
): Promise<UserCorrection | null> {
  const correctionType = detectCorrectionType(
    originalValue,
    finalValue,
    'text'
  );

  const distance = editDistance ?? computeEditDistance(originalValue, finalValue);

  const { data, error } = await supabase
    .from('user_corrections')
    .insert({
      generation_id: generationId,
      user_id: userId,
      field_name: fieldName,
      correction_type: correctionType,
      original_value: originalValue,
      final_value: finalValue,
      edit_distance: distance,
      time_spent_editing_ms: timeSpentMs ?? null,
    })
    .select()
    .single();

  if (error) {
    console.error('recordCorrection error:', error);
    return null;
  }

  return mapRow(data);
}

/**
 * Compare each field between generatedFields and finalFields,
 * creating a correction record for EVERY field (even accepts).
 */
export async function recordAllCorrections(
  generationId: string,
  userId: string,
  generatedFields: Record<string, string>,
  finalFields: Record<string, string>,
  fieldTimings?: Record<string, number>
): Promise<UserCorrection[]> {
  const results: UserCorrection[] = [];

  for (const fieldName of Object.keys(generatedFields)) {
    const original = generatedFields[fieldName] ?? '';
    const final = finalFields[fieldName] ?? '';
    const timeSpent = fieldTimings?.[fieldName];

    const correction = await recordCorrection(
      generationId,
      userId,
      fieldName,
      original,
      final,
      undefined,
      timeSpent
    );

    if (correction) {
      results.push(correction);
    }
  }

  return results;
}

/**
 * Fetch all corrections for a given generation.
 */
export async function getCorrectionsByGeneration(
  generationId: string
): Promise<UserCorrection[]> {
  const { data, error } = await supabase
    .from('user_corrections')
    .select('*')
    .eq('generation_id', generationId)
    .order('created_at', { ascending: true });

  if (error) {
    console.error('getCorrectionsByGeneration error:', error);
    return [];
  }

  return (data ?? []).map(mapRow);
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function mapRow(row: Record<string, unknown>): UserCorrection {
  return {
    id: row.id as string,
    generationId: row.generation_id as string,
    userId: row.user_id as string,
    fieldName: row.field_name as string,
    correctionType: row.correction_type as CorrectionType,
    originalValue: row.original_value as string,
    finalValue: row.final_value as string,
    editDistance: row.edit_distance as number | undefined,
    timeSpentEditingMs: row.time_spent_editing_ms as number | undefined,
    createdAt: row.created_at as string,
  };
}
