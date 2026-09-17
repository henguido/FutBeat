import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futbeat/features/matches/match_screen.dart';

void main() {
  test('event visuals distinguish the supported football events', () {
    expect(eventIcon('GOAL'), Icons.sports_soccer);
    expect(eventIcon('YELLOW_CARD'), Icons.square_rounded);
    expect(eventIcon('RED_CARD'), Icons.square_rounded);
    expect(eventIcon('SUBSTITUTION'), Icons.swap_vert_rounded);
    expect(eventIcon('VAR'), Icons.tv_rounded);
    expect(eventIcon('MISSED_PENALTY'), Icons.cancel_outlined);
    expect(eventIcon('KICKOFF'), Icons.play_arrow_rounded);
    expect(eventIcon('HALFTIME'), Icons.pause_rounded);
    expect(eventIcon('FULL_TIME'), Icons.flag_rounded);
    expect(eventIcon('OTHER'), Icons.more_horiz_rounded);

    expect(eventColor('YELLOW_CARD'), Colors.amber);
    expect(eventColor('RED_CARD'), Colors.redAccent);
    expect(eventLabel('SUBSTITUTION'), 'Sustitución');
    expect(eventLabel('VAR'), 'VAR');
  });
}
