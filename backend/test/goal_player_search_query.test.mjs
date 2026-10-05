import test from 'node:test';
import assert from 'node:assert/strict';
import { GOAL_PLAYER_ENDPOINTS, goalPlayerSearchQuery } from '../../supabase/functions/_shared/goal_players.ts';

// GOAL answers HTTP 400 to a player search with a non-ASCII letter
// (production ledger: 27/27 failures accented, 27/27 successes ASCII).

test('accented and special letters are folded to ASCII', () => {
  assert.equal(goalPlayerSearchQuery('Lukáš Hrádecký'), 'Lukas Hradecky');
  assert.equal(goalPlayerSearchQuery('Srđan Babić'), 'Srdan Babic');
  assert.equal(goalPlayerSearchQuery('Victor Lindelöf'), 'Victor Lindelof');
  assert.equal(goalPlayerSearchQuery('Roberts Savaļnieks'), 'Roberts Savalnieks');
  assert.equal(goalPlayerSearchQuery('Adam Ståhl'), 'Adam Stahl');
  assert.equal(goalPlayerSearchQuery('Óscar Acevedo'), 'Oscar Acevedo');
  assert.equal(goalPlayerSearchQuery('Martin Ødegaard'), 'Martin Odegaard');
  assert.equal(goalPlayerSearchQuery('Ilkay Gündoğan'), 'Ilkay Gundogan');
  assert.equal(goalPlayerSearchQuery('Vanja Milinković-Savić'), 'Vanja Milinkovic-Savic');
});

test('plain ASCII queries are unchanged (the ones GOAL already answered 200)', () => {
  for (const q of ['Jonathan Tah', 'costarica', 'Garven-Michee Metusala', "N'Golo Kante"]) {
    assert.equal(goalPlayerSearchQuery(q), q);
  }
});

test('the search endpoint sends the folded, URL-encoded query', () => {
  assert.equal(GOAL_PLAYER_ENDPOINTS.search('Pau Cubarsí'), '/players/search?q=Pau%20Cubarsi');
  assert.match(GOAL_PLAYER_ENDPOINTS.search('Juho Lähteenmäki'), /^\/players\/search\?q=[\x21-\x7E]+$/);
});
