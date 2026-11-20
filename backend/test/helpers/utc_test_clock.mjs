// Test-only ticking clock. Explicit Date arguments, parse and UTC stay native.
// Return a restore hook so isolated clock tests do not leak global state.
export function installUtcTestClock(millisecondsIntoDay) {
  if (!Number.isInteger(millisecondsIntoDay) || millisecondsIntoDay < 0 || millisecondsIntoDay >= 86400000) {
    throw new RangeError('UTC offset must be inside one day');
  }
  const RealDate = globalThis.Date;
  const startedAt = RealDate.now();
  const offset = Math.floor(startedAt / 86400000) * 86400000 + millisecondsIntoDay - startedAt;
  globalThis.Date = class extends RealDate {
    constructor(...args) {
      if (args.length) super(...args);
      else super(RealDate.now() + offset);
    }
    static now() { return RealDate.now() + offset; }
  };
  return () => { globalThis.Date = RealDate; };
}
