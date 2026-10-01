import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/features/profile/profile_screen.dart';

void main() {
  test('Perfil favorites summary: singular only for exactly one', () {
    expect(
      favoritesSummary(teams: 1, competitions: 0, players: 0),
      '1 equipo · 0 ligas · 0 jugadores',
    );
    expect(
      favoritesSummary(teams: 1, competitions: 1, players: 1),
      '1 equipo · 1 liga · 1 jugador',
    );
    expect(
      favoritesSummary(teams: 2, competitions: 3, players: 11),
      '2 equipos · 3 ligas · 11 jugadores',
    );
  });
}
