// Synthetic planning model, not production telemetry. The caller supplies the
// observed average number of relevant matches per connected client.
export function modelLiveDelivery({ clients, matches, changesPerMatch,
  relevantMatchesPerClient, devicesPerClient = 1 }) {
  for (const [name, value] of Object.entries({ clients, matches, changesPerMatch,
    relevantMatchesPerClient, devicesPerClient })) {
    if (!Number.isInteger(value) || value < 0) throw new RangeError(name);
  }
  if (matches === 0 || clients === 0 || changesPerMatch === 0) {
    return { globalMessages: 0, scopedMessages: 0, currentOutboxRows: 0,
      topicEventRows: 0, channels: 0 };
  }
  const eventRows = matches * changesPerMatch;
  const scopedMatches = Math.min(matches, relevantMatchesPerClient, 100);
  return {
    globalMessages: clients * eventRows,
    scopedMessages: clients * scopedMatches * changesPerMatch,
    // Worst case if every change warrants a personalized push. Real policy
    // should be measured; no topic delivery is assumed to be authorized.
    currentOutboxRows: clients * devicesPerClient * eventRows,
    topicEventRows: eventRows,
    channels: scopedMatches > 0 ? clients : 0,
  };
}
