import React, { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { en, zh } from '../i18n';
import type { TranslationKey } from '../i18n';

export type Locale = 'en' | 'zh';

const TRANSLATIONS: Record<Locale, Record<string, string>> = { en, zh };
const STORAGE_KEY = 'spool_locale';

interface LanguageContextValue {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (key: TranslationKey) => string;
}

const LanguageContext = createContext<LanguageContextValue>({
  locale: 'en',
  setLocale: () => {},
  t: (key) => key,
});

export const LanguageProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [locale, setLocaleState] = useState<Locale>(() => {
    const saved = localStorage.getItem(STORAGE_KEY);
    return saved === 'zh' ? 'zh' : 'en';
  });

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, locale);
  }, [locale]);

  const setLocale = useCallback((next: Locale) => {
    setLocaleState(next);
  }, []);

  const t = useCallback(
    (key: TranslationKey): string => {
      return TRANSLATIONS[locale]?.[key] ?? TRANSLATIONS.en[key] ?? key;
    },
    [locale],
  );

  return (
    <LanguageContext.Provider value={{ locale, setLocale, t }}>
      {children}
    </LanguageContext.Provider>
  );
};

export const useTranslation = () => useContext(LanguageContext);
