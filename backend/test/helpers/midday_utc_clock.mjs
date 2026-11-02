// Import first in a test file whose offsets (ledger rows at now()-N minutes,
// kickoffs N minutes apart) must stay inside one UTC day. The process clock is
// shifted to 12:00 UTC of the real day and keeps ticking. PGlite reads the same
// JS clock, so SQL now() moves with it (midday_utc_clock.test.mjs guards that).
import { installUtcTestClock } from './utc_test_clock.mjs';
installUtcTestClock(12 * 3600000);
