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
| 1 cierre de `fix/matches-screen-regression` (dedup, marcador, orden) | HECHO — commit `5960d50` |
| 2 fiabilidad LIVE | HECHO (backend) — ver commit del bloque 2 |
| 3 rendimiento de partidos históricos | EN CURSO |
| 4 QA pantalla de partidos | pendiente |
| 5 UX: swipe de fecha (ya existe #128, verificar) y tabla de posiciones | pendiente |
| 6 Match Center deuda pequeña | pendiente |
| 7 validación final | pendiente |

## Tarea activa

Bloque 3: medir primero (qué bloquea el primer render del Match Center de un partido pasado), luego optimizar.

Nota de entorno: el chequeo de permisos del shell falla a ratos de forma transitoria; reintentar el mismo comando.

## Bloque 2 — hallazgos (diagnóstico de SOLO LECTURA en producción, 2026-09-30 14:00 UTC)

1. Resultados por fecha: los días con >= 500 resultados fallaban enteros con `GOAL results pagination cannot make progress` (la página 2 repetía la 1) y se descartaban los 500 resultados ya leídos; 3 intentos y fecha agotada (26 y 27 de septiembre en `FAILED`). Arreglo en el worker: si una página no aporta nada nuevo, o se llega a 5 páginas, se PARA y se procesa lo leído (`truncatedBy`); solo falla si no se leyó nada.
2. Recuperación terminal: 278 de 282 filas agotadas en 72 h tenían `attempts=0` (`expired`). Necesita cuota por encima del piso protegido (150) y la fila vence a las 6 h, antes del reinicio diario de cuota (00:00 UTC). Arreglo: una recuperación pendiente > 10 min pide la fecha a la vía de resultados (`results_date_user_demand`, como cuando un usuario abre el partido), máximo una vez por hora y fecha.
3. Partidos en juego invisibles: 67 estados LIVE de GOAL en 24 h sin partido canónico; en 37 la competición y ambos equipos YA estaban mapeados pero el fixture no existía en el calendario (no hay ingesta periódica de calendario; las entidades vienen de la ingesta del 18-sep). Arreglo: descubrimiento con identidad fuerte (`discover_goal_live_match`): re-enlaza el fantasma programado de la misma competición y equipos a <= 24 h (corrige el saque, retira el id viejo y lo guarda en `provenance.previousExternalIds`) o crea el partido canónico (estado SCHEDULED; LIVE/final llega por observaciones). Nunca por nombres; ambiguo = sigue sin mapear.
4. Sin arreglo posible desde FutBeat: competiciones que GOAL no incluye en `/fixtures/live` (15 de 19 partidos en juego sin observaciones eran de una sola competición menor). Se muestran "Por confirmar" hasta que llegue el resultado por fecha.
5. Cuota GOAL ~1000/día: `match-detail` gasta 400-550/día, `live-goal` 160-245. No se cambió ninguna política de cuota.

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

- `5960d50` fix: harden match feed reconciliation (bloque 1)
- bloque 2: fix: stabilize live match lifecycle (ver `git log`)

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
- Producción: solo consultas `SELECT` de diagnóstico (duplicados, ciclo LIVE, recuperaciones, cuota, estados sin mapear). Ninguna escritura.
- `CONTROL_FUTBEAT_4H.md` (de otra sesión) no se tocó ni se versiona.

## Cómo reanudar

1. `git checkout fix/matches-screen-regression` y `git status` (si hay cambios sin commit, son del bloque en curso).
2. Migraciones locales nuevas, en orden: `20260930110000_calendar_fixture_dedup.sql`, `20260930120000_terminal_score_correction.sql`, `20260930130000_live_lifecycle_reliability.sql`. Ninguna aplicada en remoto. El worker `futbeat-goal-live-sync` cambió (paginación de resultados) y tampoco está desplegado.
3. Seguir con el bloque 3 (rendimiento de históricos): medir el camino de apertura del Match Center (`matchContextSnapshotProvider`, `matchDetailProvider`, `matchPreviewProvider`) antes de tocar nada.
