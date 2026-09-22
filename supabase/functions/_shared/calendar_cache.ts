// SQL owns invalidation. An independent HTTP stale-while-revalidate layer can
// otherwise hide corrected scores even after the database cache is invalidated.
export function calendarCacheControl(date: string, timezone: string, partial: boolean, now = new Date()): string {
  return 'private, no-cache, must-revalidate';
}
