# Control FutBeat — Fase 3 (despliegue controlado)

Proyecto Supabase enlazado: el de producción (ref en `supabase/.temp/project-ref`). Main desplegado desde `a95ba9e`.

## Preflight (2026-10-01 03:00 UTC)

- Git: `main` = `origin/main` = `a95ba9e`, árbol limpio.
- `migration list --linked`:
  - Alineado desde `20260924200000` hasta `20260929150000`.
  - Pendientes solo locales: `20260930100000`, `110000`, `120000`, `130000`.
  - Drift #133 ya reparado: `20260926174500` figura en local y remoto; las versiones `20260926180523` y `20260926183939` ya no existen.
  - Drift histórico previo a `20260924200000` (decenas de versiones solo locales / solo remotas): conocido e intacto.
  - **Por eso `supabase db push` está prohibido**: re-ejecutaría migraciones históricas solo locales. Método: cada archivo con `db query` en una transacción explícita (`lock_timeout`/`statement_timeout`) y, solo si valida, `migration repair --status applied <version>`.
- Ventana: 2 estados LIVE vistos en 15 min, 1 fila realtime LIVE (madrugada europea / noche americana tardía). Ventana segura.
- Funciones Edge antes:
  - `futbeat-goal-live-sync` v36 (2026-09-29 04:47Z, código = `e71a124`, `verify_jwt=false`).
  - `futbeat-api` v35 (2026-09-29 22:08Z, index = `ce16cb1`, `verify_jwt=false`).
  - `config.toml` NO declara `futbeat-goal-live-sync`: el deploy debe pasar `--no-verify-jwt` para conservar la configuración vigente (el cron llama con token propio, sin JWT).

## Baseline pre-deploy (2026-10-01T03:00:55Z)

| Métrica | Valor |
|---|---:|
| Última migración | 20260929150000 |
| Partidos canónicos | 35 687 |
| Mapeos GOAL de partido | 35 674 |
| Creados por discovery / re-enlazados / con marcador corregido | 0 / 0 / 0 |
| Observaciones | 69 929 |
| Canonical events / live events | 36 859 / 95 064 |
| Partidos hoy (UTC) / terminales hoy | 81 / 0 |
| LIVE: estados vistos 15 min / realtime / payload | 2 / 1 / 10 (payloads viejos, caducados por el read model) |
| LIVE sin partido canónico: 24 h / ahora | 136 / 1 |
| Recuperaciones: RESOLVED / EXHAUSTED / CANCELLED / PENDING | 265 / 35 / 1 / 0 |
| EXHAUSTED sin intento (72 h) | 28 |
| Demandas results-date | 8 |
| Intentos results-date (14 días) | SUCCEEDED 7, PARTIAL 3, FAILED 4 |
| `compact_calendar_cache` | 137 filas, 23 vigentes, 12,3 MB |
| Ledger GOAL 24 h | live 279, match-detail 564, results 8+1 fallo, team-squad 112, standings 3+5 fallos, team-fixtures 8+3 fallos, player-search 2+4 fallos |
| Cuota restante (último dato) | 436 |
| Cron | 7 jobs activos, 0 fallos en 1 h |
| Locks en espera | 0 |
| Candidatas de la reparación legada de #169 | 0 (no retraerá nada) |

## Rollback operativo

Respaldo previo (fuera del repo), en `F:\FutBeat\backups\2026-10-01-phase3-predeploy\`:
- `functions_before.sql`: definición en producción de las 17 funciones SQL que se reemplazan, y los triggers de las tablas tocadas.
- `edge\`: código desplegado de `futbeat-goal-live-sync` v36 y `futbeat-api` v35.

| Migración | Cambio | Rollback posible | Rollback no trivial | Datos afectados |
|---|---|---|---|---|
| 100000 (#169) | DDL aditivo: columnas en `live_events` / `canonical_events`, índice, tabla `canonical_event_revisions`; reemplaza la ingesta de eventos, la publicación realtime y el read model | Reaplicar `functions_before.sql`; las columnas y la tabla nuevas pueden quedarse (aditivas) | El comportamiento de retracciones ya escrito (`retracted_at`) se conserva auditado; se revierte por evento desde `canonical_event_revisions` | Reparación legada: 0 filas. Después, eventos retraídos o corregidos según el tráfico real |
| 110000 | Constructor del calendario + helpers; expira `compact_calendar_cache` | Reaplicar `build_compact_calendar` de `functions_before.sql`; el caché se reconstruye solo | — | Solo `expires_at` del caché (137 filas) |
| 120000 | Trigger `futbeat_terminal_score_correction` | `alter table futbeat_private.provider_observations disable trigger futbeat_terminal_score_correction;` (inmediato) | Revertir una corrección: `provenance.scoreCorrectedFrom` guarda el final anterior | Solo partidos terminales con corrección real del PRIMARY |
| 130000 | Discovery/relink, demanda de resultados, lock en el resolver | `create or replace function public.futbeat_link_goal_live_matches(p_fixtures jsonb) … select futbeat_private.futbeat_link_goal_live_matches(p_fixtures)` (enlazador anterior); `settle_terminal_recovery` y `futbeat_resolve_global_entity` desde `functions_before.sql` | Partidos creados (`provenance.discoveredVia='live-feed'`) y re-enlazados (`provenance.previousExternalIds`) son identificables; deshacer un re-enlace exige restaurar el mapeo viejo a mano | `entities` (nuevas / saque corregido), `provider_entities` (mapeos), `results_date_user_demand` |
| Funciones | `futbeat-goal-live-sync`, `futbeat-api` | Redesplegar el código de `edge\` con `--no-verify-jwt` | — | — |

Umbral de alarma tras la 130000: más de 20 partidos creados por discovery en la primera hora, o cualquier re-enlace de un partido con observaciones, desactiva el discovery (vuelta al enlazador anterior) antes de seguir.

## Registro de operaciones

| Hora UTC | Operación | Resultado |
|---|---|---|
| 03:03:57 | `20260930100000` aplicada (transacción, ~7 s) | OK. Columnas, tabla, índices y funciones presentes, sin `anon`. 0 retracciones, conteos intactos, cron 0 fallos. `repair` → applied |
| 03:05:13 | `20260930110000` aplicada (~5 s) | OK. 0 ids repetidos. Ocultos: 19-ago 5 pares, 20-sep 1, 8-oct 1. Caché expirado (8/137 reconstruidos por tráfico). Hoy 198-299 ms. Día de 1084 partidos: 1,2-2,5 s (antes 0,96-1,6 s). `repair` → applied |
| 03:10:33 | `20260930120000` aplicada (~4 s) | Instalada sin reescribir nada (`scoreCorrected`=0). **NO registrada en el historial** (`repair` pendiente) por el P0 de abajo |
| ~03:14 | Intento de desactivar el trigger `futbeat_terminal_score_correction` | **Denegado** por el control de permisos de la sesión. Trigger previsiblemente ACTIVO |
| — | `20260930130000`, funciones Edge | NO aplicadas |

## P0 — el trigger de corrección de finales puede escribir 0-0 falsos

Evidencia (solo lectura):
- `fb_match_57538478…` (Oberliga Hamburg, GOAL 772616): final 6-3. El 1-oct 02:06Z match-detail devolvió `matchStatus=FINISHED`, `homeTeamScore=0`, `awayTeamScore=0`, pero `homeTeamFtScore=6`, `awayTeamFtScore=3` y el descanso intacto.
- `fb_match_f699bd51…` (Oberliga Schleswig-Holstein, GOAL 772401): final 1-2 → misma respuesta 0-0 con `*FtScore` 1-2.

Causa: GOAL reinicia los campos de marcador en vivo tras el partido y deja el final en `*FtScore`. El normalizador del worker lee `homeTeamScore`/`awayTeamScore` y registra un "FINISHED 0-0" falso.

Impacto: con el trigger activo, cualquier observación de este tipo posterior a la evidencia canónica reescribe el final guardado a 0-0, con la "procedencia de corrección". El cron de match-detail corre cada minuto. Las dos observaciones existentes son anteriores a la instalación y no se reprocesan; el riesgo es para respuestas nuevas.

Riesgo PREEXISTENTE relacionado (ya en prod antes de la Fase 3): `reconcile_goal_results_local` también adopta la última observación terminal con el mismo criterio. Si la vía de resultados vuelve a procesar 2026-09-29, escribiría 0-0 en estos dos partidos.

### Contención (autorizada por el usuario)

- 03:31:02-03:31:06 UTC: `alter table futbeat_private.provider_observations disable trigger futbeat_terminal_score_correction;`. Verificado `tgenabled = D`.
- Ventana de exposición: 03:10:33 → 03:31:06 (~20 min).
- Corrupción: **0 filas afectadas**. Ningún partido con `provenance.scoreCorrected`, ningún final con `receivedAt` dentro de la ventana. Las 6 observaciones terminales de la ventana tenían total = FT y coincidían con lo guardado (o el partido seguía programado).

### Semántica GOAL (medida sobre ~70 000 observaciones guardadas)

- `homeTeamScore`/`awayTeamScore`: total corriente, prórroga incluida, penales excluidos. Es la única fuente en LIVE, descanso, prórroga y penales.
- `*FtScore`: marcador reglamentario (90'), se rellena al terminar el tiempo reglamentario.
- `*ExtraScore`: solo goles de la prórroga. En prórroga se cumple total = FT + Extra.
- `*PenaltyScore`: tanda de penales, nunca suma al marcador.
- Tras el partido GOAL puede reiniciar el total a 0-0 (147 respuestas terminales guardadas).

### Corrección en el repo (sin desplegar)

- Regla única: `goalFixtureScore` (`_shared/live_events.ts`) para todos los escritores TS: worker LIVE/detalle/resultados, `live-ingest` de `futbeat-global-ingest` y el normalizador de calendario `backend/providers/goal_api.mjs`.
- Gemela SQL `futbeat_private.goal_fixture_score`, con test de paridad TS↔SQL.
- Migración correctiva `20260930125000_goal_terminal_score_semantics.sql`: `observation_score()` relee las respuestas GOAL desde el raw. La usan el trigger, `reconcile_goal_results_local` (bug PREEXISTENTE, ya en prod) y el read model (rama de observaciones y caché de detalle). No reactiva el trigger.
- `futbeat-global-ingest` también cambia (calendario y live-ingest): habrá que desplegarlo además de las dos funciones previstas.

### Historial de `120000` (decisión)

1. NO editar `120000`. Es exactamente lo que se ejecutó en prod; editarla haría mentir al historial.
2. Registrar `120000` como aplicada (su archivo no cambia).
3. Aplicar `20260930125000` (correctiva, ordenada antes de `130000`) en una transacción y registrarla.
4. Reactivar el trigger solo tras una mini auditoría (`enable trigger`), como decisión operativa explícita.

Instalaciones nuevas: `120000` + `125000` producen el mismo estado final (trigger activo con la semántica corregida).

### Fase 3B.1 — auditoría del fix (rama `fix/goal-terminal-score-semantics`)

- Lecturas directas restantes de `homeTeamScore` en SQL vigente (escaneo de `pg_proc` tras todas las migraciones):
  - `futbeat_private.futbeat_read_calendar_range` (+ `_before_field_merge`): solo la llama `futbeat_read_calendar_range_before_cache`, que no tiene llamadores. Código muerto; no se toca.
  - `store_match_detail_before_media`: VIVA (vía `store_match_detail`). Su guarda de goles usaba el total; con un reset 0-0 dejaba de proteger los goles guardados. Corregida en `125000`.
- Coste: el read model evaluaba la regla sobre todas las observaciones y releía el detalle por campo. Corregido: evaluación perezosa en orden (barreras `OFFSET 0`) y una sola lectura del payload (`jsonb_to_record`). Bench PGlite, peor caso sintético (1000 partidos de hoy, 30 observaciones, 70 % con detalle de 30 kB): 660 ms sin `125000` → 806 ms con ella (antes de optimizar: 1658 ms). En prod los partidos terminales toman el marcador del payload y no entran en esta ruta.
- Deno `futbeat-global-ingest`: 2 errores TS2345 preexistentes (`existing` en las llamadas a `normalizeGoalApiFixtures`): en `main` limpio `a95ba9e`, líneas 332 y 349; en la rama, 326 y 343 (desplazadas al quitar el helper viejo). No se tocan.

### Acción original propuesta (histórico)
1. Desactivar YA el trigger: `alter table futbeat_private.provider_observations disable trigger futbeat_terminal_score_correction;`.
2. Comprobar `select count(*) from futbeat_private.entities where kind='match' and payload#>>'{provenance,scoreCorrected}'='true';` (debe ser 0; si no, revertir con `provenance.scoreCorrectedFrom`).
3. NO seguir con la 130000 ni con las funciones hasta corregir el normalizador (preferir `*FtScore` cuando el estado es terminal y los campos en vivo vienen a 0 / inconsistentes) y añadir a la guarda del trigger y de la conciliación el rechazo de un final que contradice `*FtScore` del mismo payload.
