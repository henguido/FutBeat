import { writeFile } from 'node:fs/promises';
import { fetchSofaScoreSchedule } from '../providers/sofascore.mjs';

function costaRicaDate(offsetDays = 0) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Costa_Rica',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  const noonUtc = new Date(`${values.year}-${values.month}-${values.day}T12:00:00Z`);
  noonUtc.setUTCDate(noonUtc.getUTCDate() + offsetDays);
  return noonUtc.toISOString().slice(0, 10);
}

const output = process.argv[2] ?? 'global_schedule_payload.json';
const dates = [-1, 0, 1].map(costaRicaDate);
const raw = await fetchSofaScoreSchedule({ dates });
await writeFile(output, JSON.stringify(raw), 'utf8');
console.log(
  JSON.stringify({
    output,
    dates,
    events: raw.results,
    competitions: new Set(
      raw.days.flatMap((day) =>
        day.events.map((event) => event?.tournament?.uniqueTournament?.name ?? event?.tournament?.name),
      ).filter(Boolean),
    ).size,
  }),
);
