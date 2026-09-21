// Complete past days are cheap to revisit; incomplete recovery remains short-lived.
export function calendarCacheControl(date: string, timezone: string, partial: boolean, now = new Date()): string {
  const today = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(now);
  return !partial && date < today
    ? 'public, max-age=300, stale-while-revalidate=900'
    : 'public, max-age=20, stale-while-revalidate=30';
}
