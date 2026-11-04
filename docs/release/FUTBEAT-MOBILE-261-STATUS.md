# MOBILE261 — checkpoint verificable

## Continuación programada 01 — N08/A07, 04-nov-2026 UTC

Sobre base `dadd5a1`, se reprodujo un defecto P1 restante: tras guardar una
alerta de B desde una pantalla que había cargado A, la persistencia era correcta
pero los demás interruptores seguían mostrando las preferencias de A.
La regresión exige que el interruptor no editado coincida con B después del
guardado real simulado; antes: 1 FAIL, después: **62 focales PASS** (7 archivos)
y analyze limpio, 12,9 s. Logs `scheduled01-alert-display-before.log`,
`scheduled01-alert-display-after.log` y `scheduled01-analyze.log` en
`artifacts/mobile261/`. No se repitió la suite global recién aprobada por este
cambio de estado de una pantalla; sus 1882 PASS de abajo son evidencia de la
base anterior, no del nuevo commit.

La pantalla reutiliza el perfil fresco que ya produjo la edición serializada;
no añade lecturas ni solicitudes. Conserva las guardias de última edición,
cuenta activa y ruta desmontada. LOCAL_PASS, sin QA física/conectada, publicación
ni aceptación final. El estado anterior se conserva debajo como historial;
el ledger de reanudaciones se actualiza al cerrar esta invocación.

Corte UTC: 2026-11-04T00:44:01.364145+00:00. Código probado: `185e51186f86efcc51010a3b744e9b48c4d566d9` en `codex/mobile-261-integration`.
Ventana manual observada: 114.5 minutos desde 2026-11-03T16:49:30.073554-06:00; incluye coordinación y espera de pruebas. No equivale a horas CPU, no se suman agentes y no se acreditan 24 horas.

## Resultado local

Suite completa: **1882 PASS**, goldens incluidos; analyze sin avisos. Evidencia: `artifacts/mobile261/full-final.log` y `analyze-final.log`. Referencias PNG intactas. SQLite real local y autenticación/HTTP simulados; QA física, OAuth/FCM real y conexión productiva NOT VERIFIED.

Correcciones integradas: frescura de observaciones LIVE; caché SQLite concurrente y evicción; recuperación de precarga; identidad canónica y revisiones de actividad del jugador; errores de lectura/escritura de preferencias; restauración y cierre local de sesión; aislamiento de favoritos y nombre entre cuentas. A9 conserva procedencia en el registro local existente (campos opcionales, sin nueva clave ni SQL). A10 guarda alertas/hora por campo dentro del FIFO existente y protege la edición explícita del nombre. Se conservaron los fallos anteriores, incluidos los del harness; no se presentan como defectos de producto ni como PASS.

Recorrido local de dos cuentas con cierre/reapertura de SQLite y preferencias: PASS. Los handlers de alertas y edición de nombre se prueban localmente; no se describen como gestos físicos del A32. El widget horario completo queda NOT VERIFIED: su harness se bloqueó antes de construir el selector y se conservó en artifacts/mobile261/unverified-hour-harness (commit original8fdae7bd; retiro documentado ecc731d), sin reducir expectativas ni atribuir fallo al producto. La actualización por campo de hora se valida a nivel de servicio, no como recorrido de pantalla. La llamada API de reemplazo completo de perfil continúa siendo explícitamente completa; no se promete que una intención ambigua modifique solo un campo.

## Publicación y release

[PR Draft244](https://github.com/henguido/FutBeat/pull/244), publicada únicamente con MOBILE260/1719ecb. [CI41733921175](https://github.com/henguido/FutBeat/actions/runs/41733921175) SUCCESS: mobile1731 portables; seis visual_test excluidos por workflow existente; contracts SUCCESS por no requerir backend, npm test/check omitidos. Ese CI NO valida el nuevo HEAD261, que permanece local y necesita autorización separada de publicación.

RC NO-GO: certificado upload/configuración/versionado aprobados pendientes; CI Linux del nuevo código pendiente; aceptación del artefacto exacto y contrato conectado pendientes. No APK/AAB nuevo, instalación, teléfono/ADB, QA123, producción, Supabase, GOAL, migraciones, despliegues, merge o push adicional.

## Continuidad autorizada

Una sola automatización: `futbeat-mobile261-reanudaciones-locales-limitadas`, ACTIVE verificada; máximo24 invocaciones, STOP absoluto2026-11-04T22:49:30Z. Ledger observado: 0 intentadas, 0 completadas; sesión manual no consume invocaciones. Registro no garantiza ejecución futura, disponibilidad del equipo/app ni 24 horas efectivas. Respetar el bloqueo atómico y liberar solo el propio.

Último dato agregado de recursos: 62% restante en ventana semanal compartida, sin reinicios ni créditos adicionales consumidos; no atribuir consumo al chat ni garantizar saldo futuro.

Siguiente tarea segura: revisar el roadmap desde este HEAD, reproducir un P0/P1 pendiente antes de editar y conservar las pruebas nuevas. Si solo quedan dependencias externas o no hay defecto demostrado, registrar el bloqueo sin fabricar trabajo ni publicar. 43 issues iniciales/20 abiertos al inicio; 0 cierres remotos por esta operación. LOCAL_PASS no equivale a DONE.
