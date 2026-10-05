# Matriz de bugs conocidos (2026-10-05, turno nocturno)

Estados:

- **CLOSED**: fix en `main`, con evidencia.
- **FIXED-NOT-QA**: fix local o pendiente de deploy, con tests y sin QA en el dispositivo.
- **OPEN-P0/P1/P2**: abierto, según la prioridad.
- **CANNOT-REPRODUCE**: no se pudo reproducir.

La evidencia es de lecturas read-only de producción tomadas esta noche, salvo indicación.

| # | Bug | Estado | Evidencia / referencia |
| --- | --- | --- | --- |
| 1 | Partido pasado sigue "En vivo" | CLOSED | Prod: 0 filas `live_match_updates` LIVE con kickoff de hace más de 4 h. 1 payload LIVE viejo, pero el read model lo sirve FINISHED. #185, #127, prune cada 5 min |
| 2 | LIVE sale como "Próximo" | CLOSED | `isUpcoming` excluye LIVE y los vencidos. #193 (filtro LIVE coherente), #171 |
| 3 | "PROGRAMADO" después del kickoff | FIXED-NOT-QA | App: la pill del Match Center ahora dice "Por confirmar" (`040ee86`). Backend: catch-up de resultados `20261005010000` (no aplicada) |
| 4 | Miles de SCHEDULED vencidos | FIXED-NOT-QA (causa raíz) | **Causa principal:** el ingest de calendario se descarta en cada corrida desde ~19-sep (la reserva legacy cuenta las ~700 llamadas diarias de detalle). Fix en `3b527c0` (migración `20261005070000`). Secundario: tope de GOAL (500 resultados, 100 en vivo), mitigado en `040ee86`. Lo que GOAL no devuelve queda "Por confirmar" |
| 5 | `—` sin hora/estado/marcador | CLOSED | `feed_v2_test` ("dash + POR CONFIRMAR, no Programado"). #169 |
| 6 | Explorar no carga / vacío | CLOSED | #187 (primer pintado 3–5 s → 0,7 s; migración aplicada) |
| 7 | Retry | CLOSED | Explorar y Noticias tienen "Reintentar" con datos conservados (tests de explore_first_paint y news_screen) |
| 8 | Selector de país | CLOSED | #107, #173; QA del 2026-10-04: elegir el país sugerido guarda `selected_country` |
| 9 | Duplicados en el feed | CLOSED / P2 residual | #171, #126, dedup de calendario. Prod: 1 par mismo cruce con 2 h de diferencia (ambos vencidos, probable re-emisión) |
| 10 | Correcciones de goles | CLOSED | `terminal_score_correction`, `event_reconciliation`, #179 |
| 11 | Finales con marcador distinto (dedupe) | CLOSED | #172, #179 (score-after) |
| 12 | Datos viejos / lentos tras outage | FIXED-NOT-QA | Catch-up reciente y backoff sin escalar (`20261005010000`). La causa raíz del outage (PGRST002) se resolvió con el restart del 2026-10-04 |
| 13 | Tabla no disponible | FIXED-NOT-QA (parcial) | Sub-grupos desde fixtures (`20261005030000`): UEFA NL se resuelve. Argentina, MLS, Concacaf NL y CA Cup siguen fail-closed (correcto, sin evidencia) |
| 14 | Identidad club vs selección (Andorra) | FIXED-NOT-QA | Guard en el resolver (`20261005020000`). Producción: 65 canónicos y 143 ids pendientes de split autorizado. Ejemplo visible: "River Plate" (Argentina) muestra 22 partidos de la Segunda División de Uruguay y 4 de la Copa Uruguay (OPEN-P1 hasta el split) |
| 15 | Alineaciones: jugador equivocado o foto ajena | FIXED-NOT-QA | Placeholder `playerKey "0"` (530 filas): `ba42fe1` y `20261005040000`. Falta borrar el mapping `'0'` en prod |
| 16 | Alineación duplicada (22 titulares) | FIXED-NOT-QA | Dedupe por sección (`ba42fe1`, requiere deploy de `futbeat-api`) |
| 17 | Fotos de jugadores | CLOSED + (15) | #177. La foto ajena por id `"0"` queda cubierta por la fila 15 |
| 18 | Entrenador incorrecto o antiguo | CANNOT-REPRODUCE | El coach sale del detalle de cada partido. Datos: 360 equipos sin coach (el proveedor no lo envía) y 2 con 2 coaches (se muestra el primero) |
| 19 | Latencia LIVE | OPEN-P1 (decisión) | Poll cada 5 min. Propuesta en `docs/LIVE-V1-DECISION.md`: 2 min solo con partidos seguidos en vivo |
| 20 | Cuota consumida de madrugada | OPEN-P1 (decisión) | El 60–70 % de las 1000 unidades se gasta entre 00 y 03 UTC; coverage comparte floor con user. Ver `LIVE-V1-DECISION` |
| 21 | Búsqueda de jugador con acentos falla | FIXED-NOT-QA | 27/27 respuestas HTTP 400 con acentos; fold ASCII en `9996171` (requiere deploy del worker) |
| 22 | Sugerencias de jugadores vacías | FIXED-NOT-QA | `d939521` + `20261005050000` + deploy de `futbeat-api` |
| 23 | Noticias placeholder | FIXED-NOT-QA | `26cb79a`. Falta la key de NewsData (humano) para tener artículos |
| 24 | Match Center (hero, previa, tablas, h2h) | CLOSED | #198, #206–#208, h2h #155. La migración `20261003135824` (forma de la previa) está **pendiente** en prod |
| 25 | Auth (Google, email, recovery) | CLOSED | QA real del 2026-10-04. Facebook bloqueado por Meta (humano) |
| 26 | Ads | CLOSED | Hasta 5 banners, fail-closed en release, Premium 0 (`95924ad`) |
| 27 | Tabla de Tercera RFEF FETCH_FAILED | CANNOT-REPRODUCE (por diseño) | 5 reintentos el 30-sep. Reabrir el partido la re-encola |

## P0/P1 abiertos reproducibles

- **P1-4** SCHEDULED vencidos: causa raíz encontrada (ingest de calendario descartado). Fix preparado; falta aplicar `20261005070000` (autorización).
- **P1-19 / P1-20** LIVE y cuota: pendiente de la decisión del dueño (documento con números).

No hay P0 abiertos.
