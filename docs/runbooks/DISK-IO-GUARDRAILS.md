# Disk IO: reglas para agentes y auditorías (vigente mientras el presupuesto esté bajo)

Supabase avisó que el presupuesto de Disk IO del proyecto está casi agotado
(throttling a ~5 MB/s). Hasta que el propietario confirme que se recuperó:

## Prohibido sobre producción

- Pruebas de carga o de varios clientes (`scripts/load/*` ya rechaza producción).
- Auditorías que recorran tablas grandes: duplicados de partidos/jugadores,
  `count(*)` sin filtro, `select … from entities`, `provider_observations`,
  `match_detail_cache`, `canonical_events`, `compact_calendar_cache`.
- `pg_get_functiondef` en bucle sobre todo el catálogo, `analyze`/`vacuum`
  manuales, `create index` (incluido `concurrently`), `reindex`.
- Exportaciones completas (`imports`, snapshots).

## Permitido (ligero)

- Vistas de estadísticas: `pg_stat_statements`, `pg_stat_user_tables`,
  `pg_statio_user_tables`, `pg_stat_activity`, `pg_stat_wal`.
- `backend/diagnostics/disk_io_read_only.sql`, de bloque en bloque.
- Consultas por clave primaria de una fila concreta.

## Identificarse

Toda conexión de agente debe fijar `set application_name = '<agente>-<tarea>'`
para separar su consumo del de producción en `pg_stat_activity`.

## Cambios preparados (NO aplicados)

`supabase/migrations/20261108100000_disk_io_hot_paths.sql` reduce, en el
banco local `backend/bench/disk_io_hot_paths.mjs` (200 partidos hoy, 120
observaciones por partido jugado), las lecturas de cada reconstrucción del
calendario de 17 134 a 3 940 páginas (−77 %) y el WAL de un snapshot sin
cambios a 0, con resultados idénticos. Requiere antes los índices
`CONCURRENTLY` de `supabase/manual/20261108100000_observation_indexes_concurrently.sql`,
que solo deben crearse con presupuesto de IO disponible y fuera de partidos
en vivo. Rollback: `supabase/manual/20261108100000_disk_io_hot_paths_rollback.sql`.
