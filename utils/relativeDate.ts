/**
 * Shared relative-date utility with i18n support.
 *
 * Expects translation keys: feed.justNow, feed.minsAgo, feed.hrsAgo, feed.daysAgo
 * with `{n}` placeholder for the numeric value.
 */
export function relativeDate(
  iso: string,
  t: (key: string) => string,
  locale?: string,
): string {
  try {
    const diff = Date.now() - new Date(iso).getTime();
    const mins = Math.floor(diff / 60000);
    if (mins < 1) return t('feed.justNow');
    if (mins < 60) return t('feed.minsAgo').replace('{n}', String(mins));
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return t('feed.hrsAgo').replace('{n}', String(hrs));
    const days = Math.floor(hrs / 24);
    if (days < 7) return t('feed.daysAgo').replace('{n}', String(days));
    return new Date(iso).toLocaleDateString(locale, { month: 'short', day: 'numeric' });
  } catch {
    return iso || t('feed.justNow');
  }
}
