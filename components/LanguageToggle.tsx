import React from 'react';
import { useTranslation, Locale } from '../contexts/LanguageContext';
import { Globe } from 'lucide-react';

export const LanguageToggle: React.FC = () => {
  const { locale, setLocale } = useTranslation();

  const toggle = () => {
    setLocale(locale === 'en' ? 'zh' : 'en');
  };

  return (
    <button
      onClick={toggle}
      title={locale === 'en' ? 'Switch to Chinese' : '切换到英文'}
      className="flex items-center gap-1 px-2 py-1.5 rounded-lg text-xs font-semibold text-text hover:text-cream hover:bg-card transition-colors border border-transparent hover:border-border"
    >
      <Globe size={14} />
      <span>{locale === 'en' ? '中文' : 'EN'}</span>
    </button>
  );
};
