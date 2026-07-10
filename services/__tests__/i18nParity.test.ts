import { describe, it, expect } from 'vitest';
import en from '../../i18n/en';
import zh from '../../i18n/zh';

// Bidirectional parity + hygiene guard for the hand-rolled en/zh copy tables.
//
// The zh table is typed `satisfies Record<TranslationKey, string>` (i18n/zh.ts),
// so missing/extra keys already fail `tsc`. This test is the runtime backstop
// and the machine-checkable fixture the future web<->iOS key-parity check reuses
// (engine-parity fixture convention). It also guards owner-voice rules that the
// type system can't see: no em dashes in zh copy, non-empty values, and matching
// interpolation placeholders so a `{n}` in en never silently drops out of zh.

const enKeys = Object.keys(en) as Array<keyof typeof en>;
const zhKeys = Object.keys(zh) as Array<keyof typeof zh>;

// U+2014 EM DASH, U+2015 HORIZONTAL BAR, and the CJK double-dash rendering "——".
const EM_DASH = /[—―]/;

// {name}-style interpolation tokens, e.g. {n} {tier} {label} {count} {rank} {score}.
const placeholders = (value: string): string[] =>
  (value.match(/\{[a-zA-Z]+\}/g) ?? []).sort();

describe('i18n en/zh parity', () => {
  it('every en key exists in zh', () => {
    const missing = enKeys.filter((k) => !(k in zh));
    expect(missing, `zh missing keys: ${missing.join(', ')}`).toEqual([]);
  });

  it('every zh key exists in en', () => {
    const extra = zhKeys.filter((k) => !(k in en));
    expect(extra, `zh has keys not in en: ${extra.join(', ')}`).toEqual([]);
  });

  it('en and zh have exactly the same number of keys', () => {
    expect(zhKeys.length).toBe(enKeys.length);
  });
});

describe('i18n value hygiene', () => {
  it('every en value is a non-empty string', () => {
    for (const key of enKeys) {
      const value = en[key];
      expect(typeof value, `en["${key}"] type`).toBe('string');
      expect((value as string).trim().length, `en["${key}"] empty`).toBeGreaterThan(0);
    }
  });

  it('every zh value is a non-empty string', () => {
    for (const key of zhKeys) {
      const value = zh[key];
      expect(typeof value, `zh["${key}"] type`).toBe('string');
      expect((value as string).trim().length, `zh["${key}"] empty`).toBeGreaterThan(0);
    }
  });

  it('no zh value contains an em dash (owner voice rule)', () => {
    const offenders = zhKeys.filter((k) => EM_DASH.test(zh[k] as string));
    expect(offenders, `zh values with em dashes: ${offenders.join(', ')}`).toEqual([]);
  });
});

describe('i18n interpolation parity', () => {
  it('every zh value carries the same {placeholders} as its en counterpart', () => {
    const mismatches: string[] = [];
    for (const key of enKeys) {
      const enPlaceholders = placeholders(en[key] as string);
      const zhPlaceholders = placeholders((zh[key] as string) ?? '');
      if (JSON.stringify(enPlaceholders) !== JSON.stringify(zhPlaceholders)) {
        mismatches.push(`${String(key)}: en[${enPlaceholders.join(',')}] zh[${zhPlaceholders.join(',')}]`);
      }
    }
    expect(mismatches, `placeholder mismatches:\n${mismatches.join('\n')}`).toEqual([]);
  });
});
