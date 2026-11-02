// Import first where a test needs the process at 00:05 UTC, with yesterday five
// minutes behind it. PGlite reads the same JS clock.
import { installUtcTestClock } from './utc_test_clock.mjs';
installUtcTestClock(5 * 60000);
