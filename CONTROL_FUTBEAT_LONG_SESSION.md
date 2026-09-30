# Control FutBeat — sesión larga (orquestada)

Documento operativo para que otra sesión continúe exactamente donde esta termina.

## Estado

- Inicio: 2026-09-30 07:38 (hora local CR).
- HEAD inicial: `7702e4e` (main = origin/main, PR #170).
- Rama de trabajo: `fix/matches-screen-regression` (local, SIN push, SIN PR).
- Al iniciar, el checkout estaba en `main` con los cambios sin commit del bloque; se volvió a la rama sin perder nada.
- Reglas: no deploy, no migraciones remotas, no push, no PR, no merge. Producción solo lectura (diagnóstico).

## Cola de bloques

| Bloque | Estado |
|---|---|
| 1A dedup de fixtures por niveles de evidencia | hecho (pendiente commit del bloque 1) |
| 1B correcciones de marcador | hecho |
| 1C orden definitivo del feed | hecho |
| 1D cierre (suite completa + commit local) | EN CURSO |
| 2 fiabilidad LIVE | pendiente |
| 3 rendimiento de partidos históricos | pendiente |
| 4 QA pantalla de partidos | pendiente |
| 5 UX: swipe de fecha (ya existe #128, verificar) y tabla de posiciones | pendiente |
| 6 Match Center deuda pequeña | pendiente |
| 7 validación final | pendiente |

## Tarea activa

1D: correr `flutter analyze`, `flutter test`, `npm test`, `npm run check`, `git diff --check` y crear el commit local del bloque 1.

Nota de entorno: el chequeo de permisos del shell falló de forma transitoria a media sesión (no es un fallo del código); reintentar el comando.

## Decisiones técnicas (bloque 1)

### Dedup de fixtures (`20260930110000_calendar_fixture_dedup.sql`, `dedupeFixtures` en Flutter)

Evidencia real (diagnóstico de SOLO LECTURA en producción, 12 965 partidos de calendario en 28 días): 5 pares duplicados, TODOS en la misma competición canónica.
- 2 copias entre proveedores (GOAL + TheSportsDB), mismo marcador, saque igual o a 1 h.
- 2 fixtures re-emitidos por GOAL con id nuevo, saque a 2 h.
- 1 fixture re-emitido a 18 h (gemelo jugado + fantasma programado).
- El fantasma siempre tenía procedencia `PROVISIONAL` y cero `provider_observations`.
- Cero duplicados entre competiciones distintas.

Regla (solo ids canónicos):
- Base obligatoria: misma competición, mismo local, mismo visitante, local ≠ visitante.
- `exact_kickoff`: saque a ≤ 5 min.
- `single_evidence_3h`: saque a ≤ 3 h y como mucho uno de los dos tiene observaciones propias.
- `ghost_24h`: saque a ≤ 24 h, uno programado sin evidencia y el otro finalizado o en vivo (busca al gemelo en cualquier día por el índice de equipo local).
- Nunca: dos finalizados con marcador distinto; competición distinta (solo se reporta como `cross_competition_review`).
- Sobrevive: finalizado > en vivo > con evidencia > programado > suspendido; luego procedencia `VERIFIED`; luego evidencia más reciente; luego id.
- No borra nada. `duplicate_calendar_fixtures(desde, hasta)` es el diagnóstico de solo lectura.

Limitación conocida: dos entidades programadas sin evidencia a ≤ 3 h en la misma competición se fusionan (es exactamente uno de los duplicados reales; un doble amistoso programado se vería como uno hasta que ambos tengan observaciones).

### Corrección de finales (`20260930120000_terminal_score_correction.sql`)

Trigger `futbeat_terminal_score_correction` sobre `provider_observations` (insert / update de `canonical_match_id`). Escribe solo si:
- el payload canónico ya es FPV o VERIFIED;
- la observación es terminal, del proveedor PRIMARY del Provider Hub (`primary_result_provider()`, hoy `goal_api`) y con marcador completo;
- no es anterior al saque, ni a la evidencia canónica, ni a otra observación terminal ya guardada;
- el marcador o el estado realmente cambian (una confirmación no escribe).
No toma bloqueo de fila salvo que aplique (UPDATE condicionado). Guarda `provenance.scoreCorrectedFrom`.

### Orden del feed (`orderMatchCompetitions`)

1 FAVORITOS (solo equipos) → 2 fijadas (modo personalizado) → 3 seguidas → 4 principal del país → 5 globales → 6 secundarias del país → 7 resto. Usa `competitionFeedCategory`. El país reordena, nunca filtra ni duplica. La preferencia "global primero" NO se aplica: no tiene UI (solo existe la columna), se trató como legacy accidental.

## Tests / resultados

- `backend/test/matches_feed_integrity.test.mjs`: 14/14.
- Flutter `feed_v2_test` + `matches_feed_test`: 51/51 antes del último ajuste (España en el test de cambio de país; re-ejecutar).
- Último global antes de los ajustes de esta sesión: Flutter 652/652, backend 964/965.
- Fallo preexistente: `#131 planner profiles…` en `backend/test/match_detail_planner_scale.test.mjs` (busca `'loop\n'`; el checkout Windows tiene CRLF). Falla igual en `7702e4e` limpio. No se tocó.

## Commits locales de la sesión

(ninguno todavía; el primero será el del bloque 1)

## Archivos del bloque 1

Nuevos: las dos migraciones `20260930110000`, `20260930120000`; `backend/test/matches_feed_integrity.test.mjs`; `apps/mobile/test/score_correction_test.dart`; este archivo.
Modificados: `apps/mobile/lib/features/matches/matches_screen.dart`, `apps/mobile/test/feed_v2_test.dart`, `apps/mobile/test/matches_feed_test.dart`, `apps/mobile/test/goldens/matches.png`, `backend/test/competition_editorial_contract.test.mjs`, `backend/test/live_detail_pipeline.test.mjs`.

## Riesgos

- El dedup cubre el calendario de Partidos; perfil de equipo, cara a cara y tablas leen entidades directamente (un duplicado real contaría dos veces). Solución de fondo: fusión a nivel de partido.
- El trigger de finales solo se probó en PGlite, sin carga concurrente real.
- Las dos migraciones redefinen `build_compact_calendar` y añaden un trigger: aplicar fuera de ventana de partidos en vivo.

## NO realizado

- Deploy, migraciones remotas, push, PR, merge: 0.
- Llamadas a proveedores: 0.
- Producción: solo 3 consultas `SELECT` de diagnóstico (duplicados, detalle de los pares, clases de competición).
- `CONTROL_FUTBEAT_4H.md` (de otra sesión) no se tocó ni se versiona.

## Cómo reanudar

1. `git checkout fix/matches-screen-regression` y `git status` (si hay cambios sin commit, son del bloque en curso).
2. Correr la validación del bloque 1D. Si todo lo propio está verde, commit local `fix: harden match feed reconciliation`.
3. Seguir con el bloque 2 (fiabilidad LIVE): trazar proveedor → ingest → lifecycle → snapshots → API → realtime → Flutter.
