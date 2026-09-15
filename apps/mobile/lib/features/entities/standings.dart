import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';

class Standings extends StatelessWidget {
  const Standings(this.data, this.competitionId, {super.key});
  final Snapshot data;
  final String competitionId;
  @override
  Widget build(BuildContext context) {
    final table = data.standings
        .where((s) => s['competitionId'] == competitionId)
        .firstOrNull;
    if (table == null) {
      return const EmptyState(
        'Tabla no disponible',
        'La clasificación aparecerá cuando exista una fuente disponible.',
      );
    }
    final rows = (table['rows'] as List).cast<Json>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading(context, 'Clasificación'),
        Text(
          data.demo
              ? 'Tabla de ejemplo · no se recalcula en vivo'
              : table['provisional'] == true
              ? 'Tabla provisional'
              : 'Última tabla publicada',
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 16,
            horizontalMargin: 12,
            columns: [
              for (final label in [
                '#',
                'Club',
                'PJ',
                'G',
                'E',
                'P',
                'GF',
                'GC',
                'DG',
                'PTS',
              ])
                DataColumn(label: Text(label)),
            ],
            rows: [
              for (var i = 0; i < rows.length; i++)
                DataRow(
                  cells: [
                    DataCell(Text('${i + 1}')),
                    DataCell(
                      Text(
                        data.team(rows[i]['teamId'] as String)?.name ??
                            'Equipo',
                      ),
                      onTap: () => context.push('/team/${rows[i]['teamId']}'),
                    ),
                    for (final key in [
                      'played',
                      'won',
                      'drawn',
                      'lost',
                      'gf',
                      'ga',
                    ])
                      DataCell(Text('${rows[i][key]}')),
                    DataCell(
                      Text(
                        '${(rows[i]['gf'] as int) - (rows[i]['ga'] as int)}',
                      ),
                    ),
                    DataCell(
                      Text(
                        '${rows[i]['points']}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: lime,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}
