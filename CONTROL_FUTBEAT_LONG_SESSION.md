# Control FutBeat — sesión larga (orquestada)

Documento operativo para que otra sesión continúe exactamente donde esta termina.

## Estado

- Inicio: 2026-09-30 07:38 (hora local CR). Cierre de la sesión: mismo día.
- HEAD inicial: `7702e4e` (main = origin/main, PR #170).
- Rama de trabajo: `fix/matches-screen-regression` (local, SIN push, SIN PR). 5 commits de código sobre `7702e4e`, más el de este archivo.
- Árbol limpio al cerrar. `CONTROL_FUTBEAT_4H.md` (otra sesión, sin versionar) se retiró en la Fase 1 tras migrar lo vigente; copia íntegra en `F:\FutBeat\backups\`.
- Reglas cumplidas: no deploy, no migraciones remotas, no push, no PR, no merge. Producción solo lectura.

## Cola de bloques

| Bloque | Estado |
|---|---|
| 1 cierre de la corrección de Partidos (dedup, marcador, orden) | HECHO — `5960d50` |
| 2 fiabilidad LIVE | HECHO (backend + worker) — `8e83134` |
| 3 rendimiento de partidos históricos | HECHO — `463fe81` |
| 4 QA pantalla de Partidos | HECHO — incluido en `2f53f5a` |
| 5 UX: swipe de fecha y tabla de posiciones | HECHO — `2f53f5a` (transición); la tabla ya cumplía |
| 6 deuda pequeña | HECHO — `2039de4` (#168) |
| 7 validación final | HECHO |

## Commits locales de la sesión

- `5960d50` fix: harden match feed reconciliation
- `8e83134` fix: stabilize live match lifecycle
- `463fe81` perf: paint historical match center from known data
- `2f53f5a` feat: slide between days and cap long team names in the match feed
- `2039de4` fix: clear the live filter when leaving today (#168)
- el commit de este archivo de control (`docs: close the long session control file`)

## Validación final

- `flutter analyze`: sin issues. `flutter test`: 660/660.
- `npm test`: 977/978. `npm run check`: OK. `git diff --check`: limpio.
- Deno check de `futbeat-goal-live-sync` y `futbeat-api`: exit 0.
- Único fallo entonces: `#131 planner profiles…` (CRLF), preexistente. Corregido en la Fase 1 junto con `team_match_coverage` (zona horaria): la Fase 1 cierra con `npm test` 989/989.

## Migraciones locales nuevas (NINGUNA aplicada en remoto)

Orden de aplicación:
1. `20260930110000_calendar_fixture_dedup.sql` — redefine `build_compact_calendar` (solo la selección de partidos) y añade helpers + `duplicate_calendar_fixtures()`.
2. `20260930120000_terminal_score_correction.sql` — trigger sobre `provider_observations` + `primary_result_provider()`.
3. `20260930130000_live_lifecycle_reliability.sql` — `discover_goal_live_match`, `link_and_discover_goal_live_matches`, `public.futbeat_link_goal_live_matches` (ahora envuelve al enlazador), `settle_terminal_recovery` (demanda de resultados).

También cambiaron y NO están desplegados: `futbeat-goal-live-sync` (paginación de resultados) y `futbeat-api` (demandas en paralelo). La migración 3 depende de helpers de la 1. Aplicar fuera de ventana de partidos en vivo (la 1 redefine el constructor del calendario; la 2 añade un trigger).

## Decisiones técnicas

### Dedup de fixtures

Evidencia (producción, solo lectura, 12 965 partidos de calendario en 28 días): 5 pares duplicados, TODOS en la misma competición: 2 copias entre proveedores (GOAL + TheSportsDB), 2 fixtures re-emitidos por GOAL a 2 h, 1 re-emitido a 18 h. El fantasma siempre tenía procedencia `PROVISIONAL` y cero observaciones. Cero duplicados entre competiciones distintas.

Regla (solo ids canónicos): base obligatoria = misma competición + mismo local + mismo visitante. Niveles: `exact_kickoff` (≤ 5 min); `single_evidence_3h` (≤ 3 h y como mucho uno con observaciones propias); `ghost_24h` (≤ 24 h, uno programado sin evidencia y el otro finalizado o en vivo). Nunca: dos finalizados con marcador distinto, ni competiciones distintas (solo se listan como `cross_competition_review`). Sobrevive: finalizado > en vivo > con evidencia > programado > suspendido; luego `VERIFIED`; luego evidencia más reciente; luego id. Flutter (`dedupeFixtures`) aplica lo mismo con la evidencia que tiene el cliente.

Limitación aceptada: dos entidades programadas sin observaciones a ≤ 3 h en la misma competición se fusionan (es uno de los duplicados reales observados; un doble amistoso programado se vería como uno hasta que ambos tengan observaciones).

### Corrección de finales

Trigger `futbeat_terminal_score_correction`. Escribe solo si: payload ya FPV/VERIFIED; observación terminal del proveedor PRIMARY del hub con marcador completo; no anterior al saque, ni a la evidencia canónica, ni a otra terminal más nueva; y algo cambia. UPDATE condicionado (sin bloqueo de fila salvo que aplique). Auditoría en `provenance.scoreCorrectedFrom`. Generalizable a otro proveedor cambiando el rol PRIMARY en `provider_hub_config`; `reconcile_goal_results_local` sigue siendo específico de GOAL.

### Orden del feed

FAVORITOS (solo equipos) → fijadas (modo personalizado) → seguidas → principal del país → globales → secundarias del país → resto, con `competitionFeedCategory`. La preferencia "global primero" no tiene UI y ya no se aplica.

### LIVE

- Resultados por fecha: si una página no aporta nada nuevo o se llega a 5 páginas, el worker para y procesa lo leído (`truncatedBy`). Antes descartaba los 500 resultados leídos y la fecha fallaba 3 veces (26 y 27-sep en `FAILED`).
- Recuperación terminal pendiente > 10 min pide su fecha a la vía de resultados (`results_date_user_demand`), máximo una vez por hora y fecha. Antes: 278 de 282 filas agotadas con `attempts=0`.
- Descubrimiento: fixture LIVE sin partido canónico pero con competición y ambos equipos ya mapeados → re-enlaza el único fantasma programado de la misma competición/equipos a ≤ 24 h (corrige saque, retira el id viejo a `provenance.previousExternalIds`) o crea el partido canónico (estado SCHEDULED). Nunca por nombres; ambiguo = sin mapear. Antes: 37 de 67 estados LIVE sin partido en 24 h cumplían esas condiciones.

### Rendimiento de históricos

Medido (producción, solo lectura): `read_match_context` 6-204 ms, `read_match_detail` 6-24 ms, `read_match_preview` 16-57 ms. La base de datos no era el cuello de botella. Cambios: perfil de jugador y filas de Cara a cara abren el Match Center con los datos que ya tienen (cabecera inmediata); `match-context` hace sus dos demandas en paralelo.

## Riesgos reales

- El dedup cubre el calendario de Partidos. Perfil de equipo, cara a cara y tablas leen entidades directamente: un duplicado real contaría dos veces. Solución de fondo: fusión a nivel de partido.
- Descubrimiento: crea partidos canónicos en producción desde el feed LIVE (solo con competición y equipos ya mapeados). Medir tras el despliegue cuántos crea por día.
- Re-enlace: borra el mapeo del id viejo de GOAL (queda en la procedencia). Si GOAL volviera a usar ese id, el enlazador lo re-asociaría por equipos y saque.
- La demanda de resultados por recuperación añade unas pocas llamadas `results-date` por fecha y día (dentro de su tope y backoff). Vigilar el consumo de cuota los primeros días.
- Competiciones que GOAL no incluye en `/fixtures/live` (15 de 19 partidos en juego sin observaciones eran de una sola competición menor): siguen como "Por confirmar" hasta el resultado por fecha. No hay arreglo desde FutBeat.
- Cuota GOAL ~1000/día: `match-detail` consume 400-550/día. No se tocó ninguna política; es la causa de fondo de que la recuperación por detalle casi nunca corra.
- Triggers y funciones nuevas probados solo en PGlite, sin carga concurrente real.

## NO realizado

- Deploy, migraciones remotas, push, PR, merge: 0. Llamadas a proveedores: 0.
- Producción: solo consultas `SELECT` de diagnóstico. Ninguna escritura.
- No se ejecutó la app en emulador (no hay en este entorno); el QA visual fue con renders de tests.
- No se midió la latencia extremo a extremo de la API (llamarla dispara demandas = escrituras).
- No se cambió la tabla de posiciones (ya cumplía lo pedido con tests de #166 y fase 1).
- `CONTROL_FUTBEAT_4H.md`: retirado en la Fase 1 (ver "Contexto operativo heredado").

## Próximos pasos (por prioridad)

1. Revisar y decidir push/PR único de `fix/matches-screen-regression`.
2. Despliegue controlado: primero `20260930100000_event_reconciliation` (#169, pendiente en prod), luego migraciones 1→2→3, y después `futbeat-goal-live-sync` + `futbeat-api`, fuera de ventana de partidos. Revisar antes el drift de #133 (ver contexto heredado). Una vez aplicada la migración 1, correr (solo lectura) `select * from futbeat_private.duplicate_calendar_fixtures(current_date-14,current_date+7)`.
3. Tras el despliegue, medir 48 h: partidos creados/re-enlazados por descubrimiento, fechas de resultados con `truncatedBy`, recuperaciones `EXHAUSTED` con `attempts=0`, consumo de cuota.
4. Revisar el reparto de cuota GOAL (`match-detail` 400-550/día frente a finales que no llegan).
5. Fusión a nivel de partido para los duplicados reales (perfil, H2H y tablas). (El test CRLF #131 quedó arreglado en la Fase 1.)

## Fase 1 — auditoría preproducción (2026-09-30, tarde)

Auditoría de la rama antes de push/PR. Cambios en un commit local aparte, sin reescribir los seis anteriores.

Hallazgos corregidos:

1. **Calendario cuadrático.** `build_compact_calendar` comparaba cada par del día dentro de `same_fixture_level` (sin igualdades en SQL). Bench PGlite, 1000 partidos: 1754 ms frente a 288 ms antes del dedup. Con las igualdades comp/local/visita explícitas: 353 ms (lineal). El día de hoy, todo programado: +12 %.
2. **Secuestro de un segundo partido.** El re-enlace y la regla `ghost_24h` actuaban en ±24 h, en ambas direcciones. Un partido programado DESPUÉS del que se juega (doble partido) se movía o se ocultaba. Ahora solo un fantasma ANTERIOR (su hora pasó sin evidencia), o hasta 3 h después en el re-enlace. Mismo cambio en Flutter (`_sameFixture`).
3. **Fantasma vivo.** Un fantasma cuyo propio id de proveedor viene en el mismo lote no se re-enlaza (`ghost_still_reported`).
4. **Creación doble.** El descubrimiento y el resolver de la ingesta (`futbeat_resolve_global_entity`) no compartían lock y mapeaban con "el último gana" (entidad huérfana). Ahora usan el lock por id `match:goal_api:<id>`, en orden ascendente, y mapean con DO NOTHING + relectura. El lock se toma después de los chequeos baratos: las filas sin identidad no bloquean nada.
5. **Corrección de finales no monotónica ante escritores concurrentes.** La guarda del UPDATE exigía "payload igual al leído": una corrección más nueva podía perderse si la conciliación escribía entre la lectura y el UPDATE. Ahora la guarda se reevalúa sobre la fila escrita: terminal, evidencia canónica no más nueva que la observación, y algo cambia. Además se comparan siempre tiempos de FutBeat (`received_at`), no el reloj del proveedor.
6. **Snapshots viejos.** Los días completos se cachean hasta 30 días con una versión que solo sigue los datos, así que el constructor nuevo no los habría reconstruido. La migración 1 los expira (sin borrar nada).
7. **Test #131 dependiente de CRLF.** Corregido en el test (regex `loop\r?\n` + guarda).
7b. **`team_match_coverage` dependiente de la zona horaria.** La ventana usa `current_date`: PGlite toma la zona local del host (CR) y el test espera fechas UTC (como prod). Fallaba de 00:00 a 06:00 UTC, también en `origin/main`. El test fija `timezone='UTC'` en su sesión.
8. **Transición de día.** Sin fecha elegida usaba el reloj y no el ancla del feed (dirección errónea en demo).

Evidencia de producción (solo lectura):
- 134 días, 27 420 partidos: 6 pares de misma competición/equipos a ≤ 24 h, todos duplicados reales a ≤ 3 h; ningún doble partido legítimo.
- Por fecha de resultados: 8-40 fixtures sin mapear. `max_locks_per_transaction` 64, `max_connections` 60.
- EXPLAIN ANALYZE de la búsqueda de gemelo jugado: índice `entities_match_away_team_idx`, ~1,1 ms por fantasma. No hacen falta índices nuevos.
- Última migración aplicada en prod: `20260929150000`. `20260930100000_event_reconciliation` (#169, ya en main) TAMBIÉN está pendiente y va antes que las tres nuevas.

Límites de la verificación:
- No hay Postgres real ni Docker en este host. La concurrencia se probó con interleavings deterministas en PGlite y con el razonamiento READ COMMITTED (detalle en el informe de la fase).
- Riesgo residual aceptado: dos programados sin evidencia a ≤ 3 h de la misma competición se muestran como uno (así son todos los re-emitidos observados).

## Contexto operativo heredado (de `CONTROL_FUTBEAT_4H.md`, 27-28 sep)

Copia íntegra en `F:\FutBeat\backups\CONTROL_FUTBEAT_4H_2026-09-29.md`. Lo que sigue vigente para el próximo despliegue:
- Método del último despliegue controlado (28-sep): migraciones aplicadas con `db query` transaccional + `migration repair` exacto, comprobando local/remoto.
- Drift conocido: #133 está aplicada pero registrada en remoto como `20260926180523` y `20260926183939` (md5 idéntico a la local `20260926174500`). Revisar `migration list --linked` antes de aplicar nada.
- Backup lógico previo a ese despliegue: `F:\FutBeat\backups\2026-09-28-predeploy\futbeat_private_account_tables.json`.
- Móvil: NO publicado. La firma release requiere la upload key autorizada. Gradle/PKIX falló en este host (AVG intercepta TLS).

## Cómo reanudar

1. `git checkout fix/matches-screen-regression` y `git status` (debe estar limpio salvo `CONTROL_FUTBEAT_4H.md`).
2. `git log --oneline -7` debe mostrar los commits de arriba sobre `7702e4e`.
3. Validar: `cd apps/mobile && flutter analyze && flutter test` (660/660); en la raíz `npm test` (989/989 tras la Fase 1) y `npm run check`.
