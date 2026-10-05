# Acciones remotas pendientes (turno nocturno 2026-10-05)

Nada de esto se ejecutó. Cada paso necesita autorización explícita. Va en orden de valor y riesgo, uno a la vez, con medición entre pasos (CHANGE → MEASURE → DECIDE).

> **Nunca** `supabase db push`: el historial de migraciones está desincronizado. Se aplica cada archivo con `supabase db query --linked --file <archivo>` y después `supabase migration repair --status applied <version>`, el mismo método autorizado el 2026-10-04.

| # | Acción | Archivo / objeto | Riesgo | Verificación |
| --- | --- | --- | --- | --- |
| 1 | Aplicar la reserva por kind del ingest | `20261005070000_goal_ingest_reservation_per_kind.sql` | Medio: el ingest vuelve a escribir unos 2.100 fixtures por corrida hot (como antes del 19-sep). Vigilar PostgREST/CPU | La próxima corrida de "FutBeat global fixtures" imprime `GLOBAL_INGEST_OK accepted=<n>` y el ledger muestra filas `global-ingest`. Los SCHEDULED vencidos de ayer/hoy bajan |
| 2 | Aplicar el catch-up de resultados | `20261005010000_results_catch_up.sql` | Bajo: crea funciones y el cron de resultados pasa a cada 30 min, con los mismos guards de cuota | `cron.job` 17: `13,43 * * * *`. `results_date_attempts` de hoy/ayer sin backoff escalado |
| 3 | Deploy de `futbeat-goal-live-sync` | chunks del link, fallback `/fixtures/date`, búsqueda ASCII, `image_url`, placeholder `"0"` | Medio: el worker es crítico. El fallback tiene un tope de 15 páginas y no baja de 150 unidades | Metadata `linkChunks`/`fallbackRequests` en el ledger. `player-search` deja de responder 400 |
| 4 | Aplicar el placeholder de lineup | `20261005040000_lineup_placeholder_player_id.sql` | Bajo | `lineup_rows` sin `playerKey "0"` |
| 5 | Borrar el mapping `'0'` | `delete from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id ~ '^0+$'` (1 fila) | Bajo (datos) | 0 filas. Las alineaciones con `"0"` quedan solo con nombre |
| 6 | Aplicar el guard de identidad | `20261005020000_identity_same_provider_guard.sql` | Bajo: solo afecta resoluciones nuevas | Un id nuevo con el mismo nombre crea su propia entidad |
| 7 | Split de identidades (65 equipos y 1 competición) | `supabase/manual/20261005020000_identity_split_proposal.sql` (dry run A, luego B/C/C2) | **Alto (datos)**: revisar a mano el dry run, por ejemplo River Plate AR/UY | River Plate sin partidos de Uruguay. Rollback D |
| 8 | Aplicar los sub-grupos de tablas | `20261005030000_standings_subgroups.sql` | Bajo: re-guarda solo las tablas unresolved y reemplaza el overlay provisional | UEFA NL con `groupsResolved=true` y `subgroup` en las filas |
| 9 | Aplicar las sugerencias de jugadores | `20261005050000_player_suggestions.sql` | Bajo (lectura) | `select public.futbeat_read_player_suggestions('{}','CR')` devuelve 30 |
| 10 | Aplicar el feed de noticias | `20261005060000_news_feed.sql` | Bajo: columna nueva más funciones | `select public.futbeat_read_news_feed('{}','CR')` |
| 11 | Deploy de `futbeat-api` | rutas `/v1/player-suggestions` y `/v1/news`, más el dedupe de lineups | Medio: es la API pública | GET con 200. Explorar muestra "Jugadores sugeridos" |
| 12 | Reabrir los días con tope | `supabase/manual/20261005080000_results_reopen_capped_days.sql` (después de 1–3) | Bajo: solo cambia el estado a `unresolved`, nunca a FINAL | 09-26/09-27 bajan sus SCHEDULED |
| 13 | Key de NewsData | vault `futbeat_newsdata_api_key` (humano) | Requiere cuenta | El ledger muestra `NewsData.io` |
| 14 | Política de cuota | `docs/LIVE-V1-DECISION.md` §4 | Decisión del dueño | — |
| 15 | Migración vieja pendiente | `20261003135824_match_preview_scored_form.sql` (sesión anterior, no aplicada) | Revisar antes | — |

Orden sugerido para mañana:

1. Paso 1, medir carga una corrida.
2. Pasos 2 y 3, medir.
3. Pasos 4, 5 y 6.
4. Pasos 8, 9, 10 y 11.
5. Paso 12.
6. El paso 7 cuando haya revisión humana del dry run.
