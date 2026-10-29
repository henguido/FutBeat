# LIVE 162 — implementación local y límites

Base exacta: QA +16 `58e188d` → LIVE 161 `8107eb1` → esta rama. Sin llamadas a Supabase, GOAL, API-Football ni FCM. Supabase Pro indicado por el propietario; límites efectivos del proyecto no consultados.

## Realtime móvil

Un único socket por cliente recibe `postgres_changes` de `live_match_updates` con `match_id=in.(...)` y hasta 100 IDs canónicos. El partido abierto tiene prioridad, después los partidos del calendario visible y de Favoritos. Las pantallas registran y retiran sus IDs al montarse y desmontarse; un cambio de conjunto cierra el socket anterior y se une de nuevo con debounce. Sin IDs no se abre canal. REST periódico conserva la reconciliación global y recupera cambios perdidos, estados terminales y partidos fuera de los 100 seleccionados. El Match Center observa solo su propio overlay para evitar reconstruirse por cambios de otros encuentros. No se hizo polling por teléfono a GOAL.

El filtro `in` tiene máximo documentado de 100 valores. Supabase cuenta cada cambio recibido por cliente como mensaje y Postgres Changes aún puede necesitar autorización por suscriptor; por ello 100.000 clientes conectados no quedan resueltos únicamente con este filtro. Para esa escala, Claude debe evaluar Broadcast agregado con autorización y medición real, sin sustituir a ciegas el REST de seguridad. [Filtros](https://supabase.com/docs/guides/realtime/postgres-changes), [mensajes](https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages), [escalabilidad](https://supabase.com/docs/guides/realtime/subscribing-to-database-changes).

## Capacidad sintética

`backend/notifications/capacity_model.mjs` genera `docs/LIVE-162-capacity.csv` para 100/1.000/10.000/100.000 usuarios y 10/50/100/300 partidos. **Supuestos:** cuatro cambios por partido, tres partidos relevantes por usuario, un dispositivo por usuario, todos los cambios notificables para calcular el peor caso del outbox. No son métricas de producción. Ejemplo: 100.000 usuarios × 300 partidos: 120 millones de entregas Realtime globales frente a 1,2 millones filtradas; un canal por cliente conectado; hasta 120 millones de filas de outbox si cada cambio generara un push personalizado. El número de llamadas al proveedor sigue independiente de usuarios. La memoria, latencia interna, reintentos FCM y bytes reales requieren medición en staging; no se infieren de esta aritmética.

## Push y ARCH 155

LIVE 161 mantiene evento canónico único, deduplicación, preferencias, claim acotado, `dry_run` y TTL. El outbox vigente conserva filas por destinatario/dispositivo y no se encontró una limpieza de retención general; tampoco se cambió su esquema aquí mientras Claude trabaja ARCH 155. Diseño propuesto para revisar con Claude: evento único; topics solo para alertas públicas idénticas con consentimiento y revocación verificable; entrega dirigida para preferencias privadas y correcciones; recibos mínimos por intento y ventana corta de retención; limpieza acotada y observable; límite por usuario; idempotencia persistente durante la ventana de reintentos. Un topic no sustituye las garantías actuales de correcciones ni permite datos privados. No se activó FCM ni se creó una migración competidora.

Catálogo actualmente conectado al push: inicio, gol, anulación después de envío, roja, final, titular y suplente confirmados, gol/asistencia/roja/sustitución de jugador cuando el evento y la identidad están verificados. Titular y suplente siguen disponibles para usuarios gratuitos. Descanso, segundo tiempo, resultado final corregido genérico, próximo encuentro y alertas de competición no tienen entrega fiable implementada; no se habilitaron. Los estados terminales y `*FtScore` conservan la reconciliación de LIVE 161.

## Integración y QA

No se modificaron permisos, OAuth, favoritos, diseño visual ni endpoints. La APK QA de esta rama debe usar paquete `.qa`, versionCode posterior a +16, `FUTBEAT_USE_DEMO=false` para futuro QA real, OAuth/Push/Ads desactivados y solamente credenciales públicas; no se instala ni abre sin gate de salud. Validar en dispositivo: cambio de fecha, partido abierto, retorno desde segundo plano, FT tras LIVE, Favoritos y reconexión. Para activar push real hacen falta la revisión de ARCH 155, migraciones y RLS por Claude, mediciones de volumen/latencia/cobertura, aprobación de FCM y ventana operativa específica.
