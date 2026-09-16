# Eventos LIVE y notificaciones push

## Alcance implementado

El bloque cubre FB-US-005, FB-US-006, FB-US-008, FB-US-013,
FB-US-036, FB-US-037, FB-US-038, FB-US-039 y FB-US-071.

- El worker normaliza GOAL, YELLOW_CARD, RED_CARD, SUBSTITUTION, VAR y
  MISSED_PENALTY, además de KICKOFF, HALFTIME y FULL_TIME.
- Los partidos, equipos y jugadores usan IDs `fb_*` cuando existe un mapeo.
  Un equipo mapeado que no pertenece al partido se descarta.
- `canonical_events` conserva un evento una sola vez. Su ID se deriva del
  partido, proveedor, tipo, minuto, tiempo añadido, equipo, jugador y
  asistencia; no depende del orden de la respuesta ni de comentarios del
  proveedor.
- La primera observación crea la línea base sin notificaciones. Solo los
  cambios que llegan con `notifyCandidate` pueden entrar en la outbox.
- `notification_outbox` tiene una restricción única por
  evento + usuario + dispositivo. Dos dispositivos seguidos reciben dos filas;
  una reconexión o repetición del proveedor no crea filas nuevas.
- Flutter une el snapshot HTTP y Realtime por ID canónico, rechaza eventos de
  otro partido, conserva la revisión más reciente y recupera por HTTP cada vez
  que reconecta.

## Seguridad y entrega

Las observaciones raw, eventos internos, dispositivos, seguimientos y outbox
están en `futbeat_private`, con RLS y sin acceso directo de cliente. Las
operaciones del usuario derivan la identidad de `auth.uid()`; el cliente no
puede elegir el propietario de un token. Los secretos de FCM y APNs se leen
solo en la Edge Function.

El despachador empieza en `dry_run`. En ese modo procesa únicamente tokens
`test`, no abre conexiones con FCM/APNs y registra un recibo simulado. En
modo real, un resultado de red ambiguo queda `uncertain` y no se reenvía a
ciegas, evitando duplicados visibles.

La outbox garantiza idempotencia de procesamiento. Ningún proveedor externo
puede prometer entrega exactamente una vez: FCM/APNs pueden entregar tarde o
no entregar. FutBeat prioriza no repetir una notificación cuando el resultado
del proveedor es incierto.

## Activación real pendiente

El único paso manual externo es aprovisionar el proyecto de mensajería:

1. Crear o elegir un proyecto Firebase, registrar Android e iOS, y cargar la
   clave APNs de Apple en Firebase o configurar el transporte APNs directo.
2. Guardar las credenciales privadas únicamente como secretos de Supabase
   (`FCM_SERVICE_ACCOUNT_JSON` o `APNS_PRIVATE_KEY`,
   `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`).
3. Pasar las opciones públicas de Firebase al build de Flutter, activar
   `FUTBEAT_PUSH_ENABLED=true`, cambiar `FUTBEAT_PUSH_MODE=live` y
   `futbeat_private.push_settings.mode` a `live`.

No se requieren cambios de código. El usuario inicia sesión, acepta permisos
y FutBeat registra su dispositivo y sincroniza sus equipos/partidos seguidos.
Sin credenciales, los favoritos locales y Realtime continúan funcionando.

## Verificación

- Backend: detección nueva, primera observación, duplicados, segundo gol,
  tarjeta, partido sin mapeo, dos dispositivos, outbox y transporte seguro.
- Flutter: reconexión WebSocket, bootstrap HTTP posterior a reconexión,
  revisión antigua, evento ajeno y merge sin duplicados.
- Supabase: asesores de seguridad y rendimiento ejecutados después del DDL.
  Los únicos avisos son informativos: tablas privadas sin políticas públicas e
  índices nuevos todavía sin uso acumulado.
- Android: APK debug compilado con la configuración pública local ignorada por
  Git. iOS queda preparado; la firma final requiere macOS y la cuenta Apple.
