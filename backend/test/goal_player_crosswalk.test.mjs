import test from 'node:test';
import assert from 'node:assert/strict';
import {
  auditGoalPlayerCandidates,
  crosswalksFromGoalPlayerRows,
  resolveGoalPlayerExternalId,
  verifiedGoalPlayerCrosswalk,
} from '../identity/goal_player_crosswalk.mjs';

test('same provider row id/apiId is a deterministic bridge', () => {
  const rows = crosswalksFromGoalPlayerRows([{
    externalId: 'cmr7lunin', lineupExternalId: '779997858', name: 'ignored',
  }]);
  const map = verifiedGoalPlayerCrosswalk(rows);
  assert.equal(resolveGoalPlayerExternalId('779997858', map), 'cmr7lunin');
});

test('explicit provider bridge resolves numeric lineup id to catalog id', () => {
  const map = verifiedGoalPlayerCrosswalk([{
    lineupExternalId: '779997858', catalogExternalId: 'cmr7lunin',
    bridgeType: 'PROVIDER_CROSSWALK', sourceReference: 'goal:player-crosswalk:1',
  }]);
  assert.equal(resolveGoalPlayerExternalId('779997858', map), 'cmr7lunin');
  assert.equal(resolveGoalPlayerExternalId('123', map), '123');
});

test('name, team, shirt and position never authorize a bridge', () => {
  const candidates = auditGoalPlayerCandidates([{
    externalId: '77', canonicalId: 'lineup', name: 'Alex Same', teamId: 'club',
    shirtNumber: 7, position: 'Forward',
  }], [{
    externalId: 'cmr7alex', canonicalId: 'squad', name: 'Alex Same', teamId: 'club',
    shirtNumber: 7, position: 'Forward', photo: 'https://media.goal-api.com/a.png',
  }]);
  assert.deepEqual(candidates[0].signals, ['same_team','same_name','same_shirt','same_position']);
  assert.equal(candidates[0].verified, false);
  const map = verifiedGoalPlayerCrosswalk([{...candidates[0], bridgeType: 'NAME_TEAM_SHIRT', sourceReference: 'local'}]);
  assert.equal(resolveGoalPlayerExternalId('77', map), '77', 'must not borrow the squad photo');
});

test('homonyms, club/selection contexts and conflicting bridges stay unresolved', () => {
  const candidates = auditGoalPlayerCandidates([{
    externalId: '88', canonicalId: 'lineup', name: 'Juan Perez', teamId: 'club',
  }], [
    {externalId:'cmr7a',canonicalId:'a',name:'Juan Perez',teamId:'club'},
    {externalId:'cmr7b',canonicalId:'b',name:'Juan Perez',teamId:'club'},
    {externalId:'cmr7national',canonicalId:'n',name:'Juan Perez',teamId:'selection'},
  ]);
  assert.equal(candidates.length, 2);
  assert.ok(candidates.every((row) => row.decision === 'AMBIGUOUS' && !row.verified));
  const map = verifiedGoalPlayerCrosswalk([
    {lineupExternalId:'88',catalogExternalId:'cmr7a',bridgeType:'OFFICIAL_PROFILE',sourceReference:'official:1'},
    {lineupExternalId:'88',catalogExternalId:'cmr7b',bridgeType:'OFFICIAL_PROFILE',sourceReference:'official:2'},
  ]);
  assert.equal(resolveGoalPlayerExternalId('88', map), '88');
});

test('malformed namespaces and missing official reference are rejected', () => {
  const map = verifiedGoalPlayerCrosswalk([
    {lineupExternalId:'cmr7x',catalogExternalId:'cmr7y',bridgeType:'PROVIDER_CROSSWALK',sourceReference:'x'},
    {lineupExternalId:'99',catalogExternalId:'100',bridgeType:'PROVIDER_CROSSWALK',sourceReference:'x'},
    {lineupExternalId:'101',catalogExternalId:'cmr7z',bridgeType:'PROVIDER_CROSSWALK',sourceReference:''},
  ]);
  assert.equal(map.size, 0);
});

