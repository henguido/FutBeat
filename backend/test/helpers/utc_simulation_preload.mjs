// Opt-in subprocess preload for the UTC matrix; never imported by production.
import { installUtcTestClock } from './utc_test_clock.mjs';
const time = process.env.FUTBEAT_TEST_UTC_TIME;
if (!/^\d{2}:\d{2}:\d{2}$/.test(time ?? '')) throw new Error('Expected test UTC HH:mm:ss');
const [h, m, s] = time.split(':').map(Number);
if (h > 23 || m > 59 || s > 59) throw new Error('Invalid test UTC time');
installUtcTestClock((h * 3600 + m * 60 + s) * 1000);
