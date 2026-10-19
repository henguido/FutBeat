# Paquetes backend locales — 2026-10-19

Rama: `claude/futbeat-backend-local-d2nnav` (push solo a esta rama; **sin PR,
merge ni despliegue**). Base: `main` @ `b1c8dea`.

Reglas cumplidas: no se consultó ni modificó Supabase producción; ninguna
migración aplicada; no se tocaron C1, Quota36, Push (código de envío,
triggers, outbox), cron, mappings ni fixtures productivos; cero llamadas a
proveedores (todo con fixtures sintéticos).

Cada paquete se puede revisar, desplegar y revertir **por separado**. Orden
sugerido: P1 → P2 → P3 → P4 (sin dependencias entre ellos salvo el orden de
timestamps de migración).

---

## P1 — Perfil de jugador club + selección (#222 QA81, #217)

**Causa raíz demostrada (reproducida en PGlite):**

1. `futbeat_store_team_squad` (capa de `20260919042500`) asume "un jugador = un
   plantel GOAL": al guardar el plantel de la selección **borra la membresía
   del club** y registra un `ROSTER_CHANGE` (traspaso falso) club → selección.
2. La capa de `20260922041454` sobrescribe `payload.teamId` con el plantel
   guardado: el "equipo" del jugador alterna club/selección en cada refresco.
3. El perfil (`futbeat_read_entity_detail` y el filtro Flutter en
   `entity_screen.dart`) lista solo los partidos de `payload.teamId`.

Si el último plantel refrescado fue el de Costa Rica, el goleador de club
pierde sus partidos de club: el caso de Sebastián Acuña es consistente con
esto, pero su id canónico y sus filas **no están verificados** (ver
diagnóstico solo-lectura abajo).

| | |
|---|---|
| Commits | `5fefc1c` |
| Migración | `20261019100000_player_club_national_membership.sql` |
| Flutter | `player_profile.dart` (`playerTeamIds`, `playerMatches`), `entity_screen.dart` |
| Pruebas | `backend/test/player_club_national_membership.test.mjs` (8), `apps/mobile/test/player_club_national_matches_test.dart` (5), `player_profile_test.dart` (+1) |
| Rollback | `supabase/manual/20261019100000_player_club_national_membership_rollback.sql` |

Comportamiento nuevo: un par club ↔ selección (o selección mayor ↔ juvenil)
es contexto, no traspaso: se conservan ambas membresías, se retira el
`ROSTER_CHANGE` de esa misma llamada, `teamId` queda en el club (con su
dorsal y números de temporada) y `nationalTeamId` nombra la selección. Club →
club sigue siendo traspaso; la membresía de selección sobrevive. El perfil
une partidos de todas las membresías **más** partidos con eventos canónicos
propios del jugador (cubre datos previos al arreglo, cuya membresía de club
ya fue borrada).

Compatibilidad: la app nueva funciona con servidor viejo (usa `teamId` +
`nationalTeamId`) y la vieja con servidor nuevo (ignora `teamIds`).

**Riesgos**
- "Es selección" = mapa cacheado de selecciones o nombre = país del catálogo
  (con sufijo U23/W). Un club llamado exactamente como un país se trataría
  como selección (efecto: no se registra traspaso). Aceptado y documentado.
- Crea `canonical_events_player_idx` (índice parcial): bloqueo de escritura
  en `canonical_events` mientras se construye → **aplicar fuera de ventana de
  partidos en vivo**.
- Datos ya dañados (membresías de club borradas, `ROSTER_CHANGE` falsos) **no
  se reescriben**; las membresías vuelven con el próximo refresco del plantel
  del club. Los traspasos falsos existentes requieren decisión de producto
  (consulta 3 del diagnóstico los lista).

## P2 — Fixture duplicado en perfil de equipo (#222 QA81)

**Hechos verificados (export 17-10, comentario de #222):** la copia
TheSportsDB del 13-oct usa una identidad de Puntarenas distinta de la que usan
los fixtures GOAL. **No verificado:** el id GOAL de la fila 3-1.

Dos brechas, ambas reproducidas con ids genéricos:
1. **Identidad de equipo duplicada entre proveedores.** No se fusiona nada.
   `team_identity_twin_candidates(desde, hasta)` lista pares con evidencia
   **estructural** (misma competición, mismo rival y lado, saque ≤ 24 h,
   mapeos de proveedores disjuntos, nunca rivales entre sí). Es una cola de
   revisión para un operador, que decide con `futbeat_register_entity_redirect`.
2. **El perfil de equipo no deduplicaba** aunque se registrara el redirect
   (riesgo abierto en `CONTROL_FUTBEAT_LONG_SESSION.md`).
   `futbeat_read_team_matches` ahora omite un partido que tiene un gemelo
   mejor clasificado con la **misma regla del calendario** (`20260930110000`):
   ids canónicos, nunca dos finales con distinto marcador, nunca otra
   competición, nunca un programado posterior.

| | |
|---|---|
| Commits | `2505bea`, `7e57e5b` (test existente: un rival por partido) |
| Migración | `20261019110000_team_profile_fixture_twins.sql` |
| Diagnóstico | `backend/diagnostics/qa81_identity_read_only.sql` (solo SELECT, para operador autorizado) |
| Pruebas | `backend/test/team_profile_fixture_dedup.test.mjs` (5; la prueba del redirect falla sin el cambio) |
| Rollback | `supabase/manual/20261019110000_team_profile_fixture_twins_rollback.sql` |

**Riesgos**
- Costo de lectura: una búsqueda indexada extra por fila listada (índices
  `entities_match_home/away_team_idx`). Medir `/v1/team-matches` tras desplegar.
- Igual que el calendario: dos partidos programados sin observaciones a ≤ 3 h
  en la misma competición y mismos equipos se ven como uno (limitación ya
  aceptada en `20260930110000`).
- El duplicado de QA81 **persiste** hasta que un operador revise el
  candidato y registre el redirect (no autorizado en esta sesión).

## P3 — Noticias v2 (#104)

**Evidencia en v1 (reproducida):** cada refresco reescribe todos los
artículos y vuelve a actualizar `news_subjects`, cuyo UPDATE re-dispara el
trigger de push; la deduplicación es solo por id de proveedor; no hay rol de
fuente, derechos, categoría ni estado de historia.

| | |
|---|---|
| Commits | `023053a`, `4ee8793`, `830ac5f` |
| Migración | `20261019120000_news_pipeline_v2.sql` (aditiva; v1 intacto) |
| Código | `_shared/news_pipeline.ts` (puro), `_shared/news_collector.ts`, `futbeat-news-collect/index.ts`, ruta `/v1/news` en `futbeat-api`, entrada en `supabase/config.toml` |
| Contrato | `packages/contracts/news-feed-v2.md` |
| Pruebas | `news_pipeline_v2.test.mjs` (12), `news_pipeline_v2_store.test.mjs` (11), `news_collector_v2.test.mjs` (7), `news_api_v2.test.mjs` (3) |
| Rollback | `supabase/manual/20261019120000_news_pipeline_v2_rollback.sql` (borra solo datos v2) |

Diseño:
- **Colector central** (`futbeat-news-collect`, token interno, `dryRun` por
  defecto, **no programado**): Currents (una consulta por sujeto de interés
  central, clave solo en header) o feeds RSS/Atom (GET condicional, 2 MB máx.,
  ítems de otro dominio descartados). Presupuesto y salud propios
  (`news_collector_calls`, `futbeat_news_health`), nunca el ledger deportivo.
- **Gobernanza**: `news_sources` (rol + derechos por dominio, sembrado con
  FCRF, clubes, Concacaf, FIFA, Teletica, La Nación) y `news_provider_config`.
  Snippet/imagen exigen permiso de proveedor **y** fuente con fecha de
  revisión (CHECK). Todo nace **deshabilitado** y como titular + enlace.
- **Identidad**: URL canónica (sin tracking/www/amp) → una fila por artículo
  entre proveedores. `content_hash` → sin escrituras si nada visible cambió.
- **Historias**: agrupación determinista (misma URL, titular similar,
  entidad + categoría) con guardas (dos fichajes del mismo club son dos
  historias). Estado `OFFICIAL/REPORT/DEVELOPING`; traspaso `CONFIRMED` solo
  desde fuente oficial.
- **Push sin tocar Push**: solo el **ancla** de cada historia (primer miembro
  oficial o de medio establecido, fijada una vez) se escribe en
  `news_subjects`, con `DO NOTHING`. Una historia = una clave de
  notificación; una historia solo de fuentes no verificadas no notifica.
- **Etiquetado** por mención explícita (jugador: nombre de 2+ palabras;
  nombre ambiguo no etiqueta a nadie). Nunca fusiona entidades.

**Riesgos y decisiones pendientes (producto/legal)**
- Activar cualquier proveedor/feed requiere revisar términos y fijar
  `terms_reviewed_at`/`rights_reviewed_at`; hasta entonces no hay snippets ni
  imágenes.
- Programar el colector (cron) queda fuera de alcance (prohibido tocar cron).
- La pestaña Noticias de Flutter aún no consume `/v1/news` (contrato listo).
- Los perfiles (lector v1 de `news_subjects`) muestran el ancla de cada
  historia, no necesariamente su miembro más confiable.
- Clasificación por léxico es/en: precisión razonable, sin ML; revisar con
  datos reales antes de usar categorías para notificar.

## P4 — Resúmenes de partido deterministas (contrato v1)

El "prototipo" existente en Flutter es `PlayerMatchSummary` (resumen por
jugador) + "Resumen oficial" (video). No hay prototipo de resumen narrativo
de partido en el repositorio ni en ramas remotas; el contrato se construyó
sobre los mismos principios.

| | |
|---|---|
| Commit | `bd41ab1` |
| Migración | `20261019130000_match_summary_cache.sql` |
| Código | `_shared/match_summary.ts`, ruta `/v1/match-summary` |
| Contrato | `packages/contracts/match-summary-v1.md` |
| Pruebas | `match_summary_contract.test.mjs` (11), `match_summary_cache.test.mjs` (3) |
| Rollback | `supabase/manual/20261019130000_match_summary_cache_rollback.sql` |

Garantías: sin goleador si los eventos de gol no cuadran con el marcador;
nunca goles sintéticos; asistencias solo en finales verificados; sin
estadísticas; cada frase con sus `facts`; omisiones explícitas. Caché
compartida que se reescribe solo ante cambio de huella significativa; un
generador viejo no pisa uno nuevo.

**Riesgos**
- La primera lectura de cada partido escribe una fila de caché (una vez por
  cambio significativo). Si preocupa la escritura en lectura, se puede
  mover a un worker sin cambiar el contrato.
- Formato de fecha con `Intl` (`es-CR`): depende de ICU del runtime (Deno y
  Node lo traen completo).

---

## Validación local

- Backend: suite completa con todas las migraciones nuevas: **1251/1264**;
  los 4 fallos son preexistentes en `main` y ajenos a esto:
  `v39_canary_preflight` (3, requiere PowerShell) y `news_transfers_v1` #1
  (fecha fija 2026-09-19 fuera de la ventana de 30 días).
- Flutter 3.47.4: `flutter analyze` sin issues; `flutter test` 932 ok, 4
  goldens de `visual_test.dart` fallan por rasterización Linux vs Windows
  (pantallas no tocadas).
- `deno check`: `futbeat-api`, `futbeat-news-collect`, `_shared/*` nuevos.
- Rollbacks: `backend/test/rollback_20261019.test.mjs`.

## Despliegue sugerido (cuando se autorice)

1. Diagnóstico solo-lectura de QA81 (`backend/diagnostics/qa81_identity_read_only.sql`).
2. P1 fuera de ventana de partidos (índice). Luego build de app con el filtro nuevo.
3. P2. Revisar `team_identity_twin_candidates(current_date-60,current_date+7)`
   y decidir redirects caso por caso.
4. P3 (migración + `futbeat-news-collect` + `futbeat-api`). Habilitar
   proveedores/feeds solo tras revisión de términos; probar con `dryRun`.
5. P4 (migración + `futbeat-api`).

## Supuestos documentados

- "No fusionar por nombres" se aplicó también a equipos: los gemelos solo se
  reportan; nadie se redirige automáticamente.
- Sin acceso a datos de producción, los ids concretos de QA81 quedan sin
  verificar; los arreglos atacan las causas demostradas en código.
- El P2 del autogol en la cabecera no se tocó: requiere reproducción y existe
  trabajo de Codex relacionado (`codex/match-player-own-goal-context`).
- El monitor del gate (causa del STOP) lo corrige Claude producción; no se tocó.
