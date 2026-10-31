# MOBILE 229 — integración Android

Rama: codex/mobile-229-integration. Base QA228 72c5856. Fuente de ambas APK: 89012d1912ddac69f16fc274f6b2d1bfdcf9f979. No cambios en producción, ramas de Claude, migraciones, cron o FCM real.

## Cambios funcionales

- Cronología: conserva IDs de entrante/saliente y asistente; navegación por identidad canónica cuando existe evidencia. Evita puentes de identidad arbitrarios entre sustituciones simultáneas. Integración 12c48b2 desde 0ed1e1f.
- LIVE: detiene el pulso visual al quedar inactiva/suspendida la app y lo reanuda al volver; regresión pasa de un callback pendiente a cero. Estados LIVE/descanso/segundo tiempo/prórroga/penales/final y corrección de gol con regresiones sintéticas. Commit 38dcc2f.
- Notificaciones: no navega una respuesta inicial que llega tras destruir el router; rechaza destinos malformados. Nueve tipos de alerta cubiertos localmente sin enviar FCM. Integración 501f1c9 desde 321f0f7.
- Lectura QA candidata: caducidad <=3 horas y cancelación de todas las lecturas pendientes si falta el reconocimiento del contrato. Integración 89012d1 desde 2f107bc. Permanece desconectada de repositoryProvider y no activada en servidor.
- Ensayo físico reutiliza los scripts/launcher/watchdog QA228 con ID de ensayo y hash explícitos (c1746e8); ningún task nuevo.

## Pruebas ejecutadas

- Suite portátil equivalente CI, 105 archivos excluyendo visual_test.dart: 1359 PASS, 1 omitida, 2 FAIL golden. No se presenta como suite totalmente verde.
- Los seis PNG generados por los dos casos fallidos son byte a byte idénticos (SHA-256) a la base sin cambios de Match Center/LIVE. No se actualizaron referencias. Evidencia artifacts/mobile229/lineups-golden-comparison.json.
- Focales LIVE, fotos y tablas/temporadas/grupos: 118 PASS.
- Cronología: 29 PASS con seis goldens existentes (rama de origen); las regresiones fallaron antes.
- Notificaciones: 43 PASS (rama de origen).
- QA final integrada: 16 PASS, incluidos ocho casos de socket local; analyze final sin incidencias.
- Backend local: 5 PASS (PGlite, handler y HTTP loopback). Política controlador 42 PASS, failsafe mock 4 PASS. Sintaxis PowerShell y diff-check sin errores.

No sumar estas cifras como pruebas únicas: hay solapamiento. La nueva prueba de socket se ejecutó tras integrarse, separada de la suite portátil ya iniciada.

## Lectura conectada: límite y condición de activación

Medidos en localhost: 60 peticiones aceptadas y seis bloqueadas antes de llegar al servidor; tercera simultánea bloqueada, máximo dos; STOP y caducidad de 300 ms cancelan sockets pendientes. Siete HTTP al handler local generan exactamente cuatro RPC permitidas. PGlite verifica la consulta de calendario en transacción de solo lectura.

El test de transporte usa adaptador SOLO de test que lleva HTTPS lógico a HTTP en 127.0.0.1. TLS real NO VERIFICADO; no se añadió bypass. El límite de API no cubre descargas independientes de imágenes. Claude debe revisar las funciones realmente desplegadas, dependencias, rutas y política de imágenes antes de activar lectura conectada. No hubo comprobación remota de salud ni apertura conectada.

## Cronología 26 frente a 22

Handoff local QA216: 26 eventos de entidad y 25 canónicos. Fixture real guardado: 22 IDs deportivos (4 goles, 8 tarjetas, 10 sustituciones) +3 fases =25; todos preservados. No hay evidencia de cuatro incidencias perdidas. El ID exacto de la diferencia de proyección 26→25 permanece NOT VERIFIED sin el export original; no requiere inventar eventos ni fusionar por nombre.

## Rendimiento y fotos

No se rehizo D1/D2 ni el cache de imágenes. Conserva TTL7 días, 32MiB, 400 entradas y 2MiB/imagen; clave por ID canónico+URL HTTPS. La mejora medida nueva es la pausa de cuadros LIVE en background (1→0 callbacks). Los tiempos físicos QA228 son baseline histórico, no mediciones nuevas. No hay comparación release contra debug.

## Artefactos

Ambas variantes son debug arm64-v8a, 1.0.0+33, com.futbeat.futbeat.qa, certificado SHA-256 6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362. DEMO=false; Ads/OAuth/Push desactivados; diagnóstico QA activo. App Links qa.invalid y esquema .qa. Configuración de entrada: solo URL API y token público; sin claves privadas de servidor. Se preservan +32 y APK conectada +33; el ensayo instala solamente la variante con bloqueo HTTP.

- Conectada (NO instalada/abierta): artifacts/mobile229/futbeat-qa-1.0.0+33-arm64-89012d1.apk; SHA-256 33B820609A6FECA6EE36CB51C88AE6A089A85B1A5245A5FF9FE830AEF282008B; 111095428 bytes. Firma v2 válida, libflutter/libdartjni/libsqlite3 presentes.


## QA física final — datos reales guardados, sin conexión

Ensayo final aprobado, no una ejecución conectada. Sesiones locales únicas QADEV-QA229-20261031T063445Z-NORMAL y QADEV-QA229-20261031T064238Z-FAILSAFE. El watchdog publicó READY antes de abrir. La variante instalada tiene bloqueo global de HTTP y el A32 estuvo sin red durante la navegación.

| Verificación física | Resultado | Evidencia en artifacts/qa229/physical |
|---|---|---|
| Feed local y calendario (selección 29 octubre) | PASS | 12-feed-stable.png, 13-date-picker.png, 15-oct29-feed.png |
| Everton–Newcastle 3–1, Match Center y goleadores | PASS | 19-match-center.png |
| Cronología: goles/asistencias, tarjetas, sustituciones, fases hasta Final | PASS | 20-timeline-top.png, 21-timeline-1.png a 21-timeline-3.png |
| Alineaciones, fotos persistidas y placeholders | PASS en vistas abiertas | 22-lineups-top.png, 23-lineups-1.png a 23-lineups-3.png |
| Panel Joelinton, entrada y amarilla | PASS | 24-player-panel.png |
| Estadísticas guardadas (43/57 posesión, 11/28 tiros) | PASS | 26-statistics.png |
| Tabla | Estado vacío observado; posiciones NOT VERIFIED | 27-standings-state.png |
| LIVE/Realtime/corrección real en curso, videos reales, perfil completo del asistente | NOT VERIFIED físicamente | Regresiones locales para estados/navegación; no se simula validación real |

No se repitió un recuento completo de las 18 fotos/22 placeholders del QA225-C; se confirmaron fotos offline y placeholders en las vistas capturadas. No hubo overflow visible ni errores Flutter/RenderFlex en el diagnóstico final recogido. La cronología todavía presenta textos de asistencia repetidos en algunas tarjetas: mejora visual P2 pendiente, no pérdida de evento.

Métricas físicas finales (debug, sin comparación release): am start -W COLD 5091 ms y 5029 ms; SQLite match-detail 256 ms; reapertura calendar 379 ms. PSS después de pestañas 596826 KiB, RSS 690708 KiB; una observación, no prueba de fuga ni mejora de memoria. Caché de imágenes medida: 309 archivos y 6336 KiB de disco, dentro de los límites existentes.

Procesos finales 9907 y 17668: cero eventos httpSuccess; máximos 60 y 16 creaciones de HttpClient bloqueadas antes del socket. Son intentos de clientes (incluyendo imágenes), NO 76 solicitudes emitidas. El primer intento anterior a la corrección tuvo 51 clientes bloqueados y cero HTTP completados; no se mezcla con el ensayo final. No se realizó captura de paquetes ni consulta de salud productiva.

### Seguridad corregida y comprobada

El primer intento encontró que un PID de watchdog vivo no probaba que su bucle estuviera listo. Se detuvo la navegación y se cerró manualmente QA; ese intento NO cuenta como PASS de seguridad. Otro armado caducó su presencia inicial sin abrir la app. Se corrigieron:

- READY del watchdog ligado a sesión/nonce/PID, fresco <=15s, antes de conceder apertura. No se amplía el heartbeat de 8s.
- Reloj posterior a la lectura actual de autorización/STOP/heartbeat, para no tratar una señal recién escrita como futura por usar una hora anterior a las sondas.
- Señal de presencia mantenida únicamente mientras el proceso de armado está realmente esperando y el guard de rollback sigue vivo; no renueva la autorización ni sobrescribe STOP.
- Restauración que exige heartbeat del PID de la invocación actual de la tarea, no una señal reciente de un proceso muerto. Un resultado no confirmado nunca es PASS; no reinicia repetidamente una invocación original que aún está arrancando.

Validación adicional: 7 tests de reloj, 13 de readiness, 9 de propiedad de heartbeat, 42 de política y 4 del failsafe mock PASS. Sintaxis de candidatos y auxiliares sin errores. Espera inicial acotada a 180s con app cerrada; no se relajaron límites operativos.

Pruebas físicas después de esas correcciones:

- STOP explícito: cierre automático confirmado por PID en 1,666s (normal-stop-result.json).
- Terminación real del launcher: cierre automático en 6,780s. El watchdog independiente 46652 registró FORCE_STOP_CONFIRMED a 06:43:53.995 UTC, antes de iniciarse rollback a 06:44:01.083 UTC. No fue un cierre manual ni el fallback de restauración (independent-failsafe-proof.json, closure-proof-summary.json).

La tarea original FutBeat-QA123-Launcher quedó Running/DISARMED con heartbeat fresco y propiedad de proceso validada. XML, hashes y ACL originales idénticos. App .qa sin PID; aprobaciones/ledger/readiness temporales retirados; guard temporal finalizado. Se restauró airplane=0, wifi=1, mobile_data=0 después del cierre. No se registró otra tarea. El paquete oficial sigue ausente; no se modificó. Se observó un proceso de la antigua variante separada .qa181; no se le atribuye a este ensayo ni se modificó, y el teléfono se dejó en Inicio.

APK offline instalada: artifacts/mobile229/futbeat-qa-1.0.0+33-local-cache-89012d1.apk; SHA-256 02F2930721185B5BC5DC1E81502C58621323927A24BE20C3D0210ED4B0BCAF37; 148115138 bytes. Ambas APK son debug; no son artefactos de Play. UID 10319 y firstInstallTime 2026-10-30 00:42:17 conservados; SQLite idéntico antes/después de install-r (8178976b169b05b8f958c68d0a0c52c1532a7c1246c861987fb25f55854311df).

## Decisión y pendientes concretos

GO para revisar/integrar localmente los cambios y reutilizar el ensayo offline explícitamente autorizado. NO-GO para habilitar lectura conectada candidata o activación permanente de QA123 sin revisión/autorización correspondiente.

La APK conectada +33 conserva la API ordinaria: NO activa el adaptador sin hidratación y NO se instaló/abrió. Claude debe verificar las definiciones desplegadas y dependencias de los lectores, aprobar el namespace candidato y la política de imágenes. Falta el export original para explicar por ID la única diferencia 26→25; no hay evidencia de cuatro incidencias perdidas. Los seis goldens preexistentes y el texto repetido de asistencia quedan pendientes visuales, sin ocultarlos ni regenerar referencias.