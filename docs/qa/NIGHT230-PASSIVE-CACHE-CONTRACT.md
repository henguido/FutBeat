# NIGHT230 — API pasiva, caché real y límite de retractación

## E2E local ejecutado

Nuevo test `apps/mobile/test/night230_passive_real_cache_e2e_test.dart`: usa los eventos/incidentes reales del export QA225-C sin modificarlos. Solo el sobre de snapshot tiene metadatos de prueba; las etiquetas necesarias de entidades son sus IDs, no datos deportivos inventados.

Flujo probado: política QaStoredReadInterceptor → sockets HTTP de loopback → ApiRepository → fichero SQLite → cierre de Dio/servidor/base → nueva conexión SQLite y repositorio sin red.

- Cinco llamadas del consumidor producen **3 GET**: calendar 1, match-context 1, match-detail 1. Dos llamadas simultáneas de calendario y dos de detalle se comparten: **2 sharedFlight**.
- Solo llegan las rutas `/v1/qa-stored/...`, ninguna ruta ordinaria de hidratación ni método de escritura.
- Concurrencia máxima observada: **2**; contadores de política 3 requests, 0 active, 0 blocked al terminar.
- Tras reiniciar el repositorio: **0 intentos de transporte**, 0 requests de política. Un hit SQLite instrumentado de calendario y otro de detalle; contexto recuperado de disco en un repositorio nuevo, marcado stale.
- Se conservan 25 eventos canónicos, los 22 providerEventId deportivos y los cuatro marcadores estructurados 1–0, 2–0, 3–0, 3–1.
- Fichero SQLite con esquema y un encuentro: **61.440 bytes**; no es estimación del almacenamiento global.
- Test PASS y análisis estático del archivo sin incidencias. No se repitieron suites históricas.

Límites: el servidor de prueba es HTTP loopback detrás de un origen HTTPS lógico; **no se probó TLS ni producción**. El consumidor offline corta en la primera emisión guardada (`.first`) y usa `readStoredMatchDetail`; no se afirma que una suscripción normal completa omita su revalidación. Este test no activa el adaptador en la aplicación ni demuestra ausencia de escrituras en un servidor remoto.

## Límite real: detalle antiguo después de una retractación LIVE

El fixture tiene **25 eventos canónicos**, de los cuales **22** llevan `providerEventKey` únicos, todos `fallback:...`; los tres restantes son marcadores de fase. Detalle lleva **22 providerEventId únicos**. Intersección de ambas colecciones: **0 claves**.

Evidencia de código local, no verificación del despliegue:

- `supabase/functions/_shared/live_events.ts:142–157`: GOAL cambia sus IDs por respuesta; la identidad estable usa hash del contenido y ocurrencia. El ID del proveedor queda para auditoría.
- `supabase/migrations/20260926030000_canonical_event_dedup_timeline.sql:505`: el evento canónico conserva `providerEventKey` y `provider`, no el providerEventId del detalle.
- `supabase/functions/_shared/match_detail.ts:400`: el incidente expone providerEventId; no la misma clave estable/canónica.
- `apps/mobile/lib/core/models.dart:529`: una lista LIVE completa reemplaza correctamente los eventos poseídos por ese proveedor.
- `apps/mobile/lib/core/providers.dart:2065`: un nuevo detalle reemplaza correctamente incidents incluso con lista vacía; pero no establece correspondencia entre una revisión LIVE y el detalle anterior.
- `apps/mobile/lib/features/matches/match_screen.dart:253`: la revisión LIVE se aplica al partido, sin invalidar automáticamente el detalle por esa revisión.

Un replay sintético local con un gol real previamente guardado muestra el límite: tras una lista LIVE completa vacía, quedan **0 goles canónicos pero 1 gol en el detalle antiguo** que puede seguir presentándose. Es un diagnóstico del contrato, **no PASS funcional ni afirmación de que ocurrió en producción**. El probe temporal está en `apps/mobile/artifacts/night230/retraction_probe_test.dart`, fuera de la suite de aceptación.

No se añadió un filtro por ausencia, nombre, minuto ni un workaround de claves parciales. Para resolverlo con seguridad, acordar con Claude una referencia compartida por ocurrencia (`canonicalEventId` o provider + eventKey estable) y una revisión monotónica/comparable de la lista de incidentes. Deben distinguirse lista completa actual, lista parcial y detalle anterior; una retractación solo puede retirar la ocurrencia identificada del mismo proveedor. No se solicita ni se aplica ninguna migración desde este trabajo.