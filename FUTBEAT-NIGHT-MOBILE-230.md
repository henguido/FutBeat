# FUTBEAT — NIGHT MOBILE 230

- Rama: `codex/night-mobile-230`.
- Base: `175e1b33e6ae29a53fbd74758ec929d45a75743b`.
- Inicio verificable: 31-10-2026, 07:14:53 UTC. No se afirma haber trabajado ocho horas ni se promete continuidad desatendida.
- Código final de las APK: `d3ea1ab`; los commits posteriores del informe no modifican ese código.

## Funcionalidades corregidas

| Commit raíz | Cambio comprobado |
|---|---|
|2450201|Una respuesta REST en vuelo no resucita una fila borrada por Realtime; un INSERT posterior legítimo se conserva.|
|2dad0bf|Mantenimiento de caché de imágenes agrupado, sin ampliar TTL ni límites.|
|1a8eb89|Tabla explícitamente Clausura excluida de un partido Apertura aunque falte stage; grupos genéricos conservados.|
|c5baf6c|Aliases de proveedor reutilizan fotografía verificada y clave canónica de disco entre club y selección. Sin fusiones por nombre.|
|894b756|Marcadores estructurados preservados al combinar eventos; null explícito del detalle prevalece.|
|0caa36e|Decodificación de avatares limitada por tamaño visible y densidad; máximo 1024.|
|891b7dd|Cronología compacta sin duplicar asistencias/marcadores, fotos canónicas verificadas y anotaciones VAR conservadas. Alineaciones miden fuente/escalado/incidencias sin recortar información.|
|45d5bc4|E2E de lectura pasiva con eventos reales guardados y reinicio SQLite.|
|d3ea1ab|Logs de cuenta excluyen mensajes del servidor y códigos arbitrarios; no cambia autenticación ni Push.|

Los commits trasladados conservan trazabilidad de origen en sus mensajes: 059ad0d, 90ec507, 1e4796f, caab6af, 734bd7a, cdd36c9, 79c7952 y 0c19fa6. Sin merge, cherry-pick, rebase ni push.

## Pruebas ejecutadas

- Suite móvil portable: **1.405 PASS, 2 FAIL**, 4m56s. Incluye todos los `*_test.dart` salvo `visual_test.dart`, conforme a la convención portable previa. Fallan únicamente los dos casos golden históricos de alineaciones; no se omiten dentro de esta ejecución ni se cambian tolerancias.
- Focales integradas: 61 PASS. Conjunto posterior de densidad/media/marcadores/cronología: 38 PASS, incluidos seis goldens de cronología intactos.
- Privacidad: antes 3 FAIL / 2 PASS; después 5 PASS. Tras integrar, cuenta y notificaciones: **48/48 PASS**.
- Analyze posterior a privacidad: **PASS**, 18,9 s. Diff-check PASS.
- Backend local de notificaciones: **10/10 PASS**, 146,9 s; PGlite y transporte falso. Deduplicación, corrección/anulación, estado terminal, dry_run y separación de cuentas. Sin FCM ni Supabase. El resultado consta en el transcript del agente; no se inventa un archivo de log inexistente.
- Layout A32: 1080×2400, DPR 2,625, fuente física 1,1; regresiones con fuente real y escalas 1,0/1,1/1,3. Fila de cinco jugadores con cinco incidencias pasa sin overflow a 1,0 y 1,3.
- Cambio de día/reanudación: revisión puntual confirma comportamiento existente; no se añade polling ni se cambia la selección manual de fechas.

## Mediciones locales, no latencias Android

| Ensayo | Antes | Después |
|---|---:|---:|
|18 descargas concurrentes: recorridos completos de caché|18|2|
|18 peticiones de mantenimiento en la misma tanda|18|1|
|Imagen de 512×512 para avatar 20dp@3x: bytes RGBA decodificados|1.048.576|14.400 (60×60)|

E2E pasivo: cinco llamadas de consumidor → **3 GET** (calendar/context/detail), **2 sharedFlights**, máximo **2** simultáneas. Tras cerrar servidor/repositorio/SQLite y reabrir: **0 intentos HTTP**. Conserva 25 eventos canónicos, 22 IDs del detalle y cuatro marcadores. SQLite: **61.440 bytes** para ese ensayo. HTTP loopback bajo origen HTTPS lógico; TLS y producción **NO VERIFICADOS**. El adaptador no está activado en la aplicación.

## APK QA +34

Ambas desde `d3ea1ab`, `1.0.0`, versionCode **34**, paquete `com.futbeat.futbeat.qa`, arm64. Certificado SHA256: `6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362`. Verificadas libflutter/libdartjni/libsqlite3 y aislamiento App Links `qa.invalid` / esquema `.qa`.

| Variante | Archivo en artifacts/night230 | SHA256 | Bytes |
|---|---|---|---:|
|Conectada, NO instalada|futbeat-qa-1.0.0+34-arm64-d3ea1ab.apk|058F4AF4617B05ED20A3283F510ADCFB8DE54E528AE0AD2D3138F8D61702F2AF|111.109.080|
|Offline, instalada con install -r|futbeat-qa-1.0.0+34-local-cache-d3ea1ab.apk|A383EA04037F1A32B19CA181668584DFCFF101E9EF2FA4CE0F54A6F153DC7DC7|111.109.080|

DEMO=false, OAuth/Push/anuncios desactivados, diagnóstico QA activo. Configuración de compilación: solo URL HTTPS y token público anon; valores no publicados. La offline bloquea clientes HTTP antes de abrir conexiones; además se verificó ausencia de red activa en el teléfono.

Instalación offline PASS. Hash instalado coincide. SQLite antes e inmediatamente después conserva `c38f69df8b0723d4e18a363cb8d02d47f21e924a9cc7e11d493673e84a3efda4`. No se borraron datos. Artefactos +33 e intermedios 45d5bc4 conservados; usar las rutas finales d3ea1ab.

## Referencias visuales y límites reales

1. Dos casos golden comparan seis imágenes anteriores al arreglo 75f60b8. Se investigaron diferencias geométricas y se corrigió además un overflow real nuevo. Referencias intactas. La revisión automática rechazó `--update-goldens` por riesgo de ocultar regresiones y falta de autorización expresa; se solicitó autorización y sigue pendiente. Ver `docs/qa/NIGHT230-GOLDENS.md`.
2. Retractación LIVE: el fixture tiene 22 claves canónicas fallback y 22 IDs de detalle, con intersección cero. Un replay muestra 0 goles canónicos y 1 incidencia antigua. No se oculta por nombre/minuto. Hace falta identidad compartida por ocurrencia y revisión comparable; handoff preciso en `docs/qa/NIGHT230-PASSIVE-CACHE-CONTRACT.md`. No se afirma que ocurriera en producción.
3. API pasiva: contrato y caché probados localmente; no se instaló ni activó la variante conectada. Las rutas ordinarias no se declaran libres de hidratación sin aprobación backend.

## Controlador y ensayo físico

Primer intento: el candidato no emitió latido nuevo dentro de 180 s. No se abrió la app. Guardián independiente restauró QA123: archivos, ACL, XML, tarea Running, latido de proceso actual y PID QA ausente: PASS. Evidencia en `artifacts/qa230-attempt1/restore-result.json`.

Segundo intento acotado: mismo código, sin reinstalar. Arranque del candidato confirmado en aproximadamente 4,7 s. Esto descarta una demora determinista por añadir la librería; causa exacta del primer arranque: UNKNOWN, no hay trace previo a LAUNCHER_STARTED. Se espera READY real del failsafe antes de abrir.

No se consultó ni modificó producción; sin migraciones, despliegues, llamadas GOAL, FCM ni cambios a ramas protegidas.


### Resultado del segundo ensayo

El candidato arrancó, pero el watchdog no confirmó READY. QADEV_PENDING_CLOSE a las 08:01:56 UTC; restauración iniciada a las 08:01:57. No se abrió FutBeat. Capturas nuevas, latencia, memoria y validación física: NOT VERIFIED. Ninguno de estos intentos se declara PASS.

Tras restaurar los archivos originales no se renovó el latido. Se realizó un único reinicio de la tarea original, sin cambiar archivos ni XML. El guardián sigue independiente y la app permanece sin PID; el estado final se registra debajo tras verificarlo.

La suite 1.405/2 corresponde a 45d5bc4. El cambio final d3ea1ab está cubierto por 48 pruebas de cuenta/notificaciones y analyze; no se repitió toda la suite por este cambio aislado de diagnóstico.


## Cierre 31-10-2026, 08:08 UTC

Restauración final PASS a las 08:07:43 UTC, revalidada después: tarea Running/DISARMED, latido del proceso actual válido, archivos/ACL/XML originales, QA sin PID. Red original restaurada: Wi-Fi=1, datos=0, avión=0. Archivos temporales de autorización, estado, ventana activa y READY eliminados. Guardián terminado. No queda una sesión QA armada.

|Componente|Resultado de esta iteración|
|---|---|
|Correcciones Flutter, pruebas y análisis|PASS local; dos casos golden conocidos pendientes de aprobación|
|APK conectada +34|Compilada/verificada; NO instalada|
|APK offline +34|Instalada/verificada, datos conservados; app cerrada|
|Nueva navegación/capturas físicas|NOT VERIFIED: no READY independiente; ninguna pantalla abierta|
|Ensayo del controlador candidato|FAIL operativo, sin debilitar condiciones de apertura|
|Restauración de QA123|PASS final|
|QA conectada|NO EJECUTADA, contrato pasivo sin activar|

GO para revisión local de código y artefactos. NO-GO para nueva QA física hasta resolver el arranque intermitente del controlador/watchdog; no se prueba su causa con la evidencia actual. QA conectada requiere además aprobar la API pasiva. Referencias visuales siguen pendientes de autorización expresa. No se promete ejecución durante las horas restantes ni se deja un proceso de desarrollo esperando al backend.

## Actualización QA234 — 31-10-2026

### Código y regresión final

- Base comprobada: 2d31938, rama codex/night-mobile-230. Sin cambios Flutter, APK, Supabase ni referencias visuales adicionales.
- 92cfd58: el registro anterior conserva una excepción real File.Move/Access denied. La regresión usa el publicador histórico real y un lector Windows sin FileShare.Delete: falla antes; el publicador corregido pasa. Reintento atómico máximo500ms, solo errores de acceso/compartición, sin borrar el registro anterior, extender autorizaciones o cambiar ACL. El lector/archivo concreto que mantuvo el handle en aquel intento histórico no quedó registrado.
- da8e4c0: tras observar timeouts ADB de1500ms y cierre principal no confirmado, se separó el presupuesto: lecturas individuales3000ms, ronda total5000ms (una lectura en vuelo puede terminar hasta3000ms después), cierre5000ms por comando. STOP, heartbeat, SHA, sesión, nonce, radio y caducidad siguen siendo obligatorios. No se convirtió UNKNOWN en autorización.
- El guardián de restauración ya considera pérdida de protección un launcher DISARMED, otra ventana, otro PID o sesión vencida, aunque la tarea figure Running. Tras10s de pérdida aplica su cierre/restauración existente. No se registraron tareas nuevas.
- 90 regresiones PowerShell PASS: publicación4, presupuesto3, propiedad activa8, política42, READY13, failsafe con ADB falso4, reloj7 y propiedad/restauración9. Sintaxis y diff-check PASS.
- Suite Flutter completa, dos invocaciones disjuntas: **1.412 PASS + 6 visuales generales PASS = 1.418 PASS,0 FAIL**. No se omitió visual_test.dart en el resultado consolidado. Analyze PASS,8,3s. Logs: artifacts/qa234-attempt1/full-mobile.log, visual-general.log, analyze.log y controller-regressions.log.
- La APK offline sigue siendo A383EA04037F1A32B19CA181668584DFCFF101E9EF2FA4CE0F54A6F153DC7DC7, versionCode34, firma debug6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362. Origen d3ea1ab. Se comprobó diff vacío en lib/Android/assets/pubspec respecto a ese origen. No se generó ni reinstaló ninguna APK.

### Evidencia física real

Dispositivo RF8R32GQWGL, SM-A325M. Wi-Fi/datos desactivados y sin red activa antes de abrir; variante con bloqueo HttpOverrides. Watchdog READY real, PID34380 en primer ensayo y30984 en segundo; archivos vinculados a sesión/nonce actuales. Ningún gate productivo utilizado.

|Componente|Resultado|Evidencia|
|---|---|---|
|Feed desde SQLite|PASS|qa234-attempt1/physical/01-feed.png|
|Calendario y selección29octubre|PASS|qa234-attempt1/physical/02-calendar.png y04-oct29-feed.png|
|Everton–Newcastle, marcador3–1 y goleadores|PASS|qa234-attempt2/physical/10-cold-match-route.png|
|Alineaciones, dorsales, eventos, fotos y placeholders offline|PASS en tramos observados|11-lineups-top.png,12-lineups-middle.png,13-lineups-bench.png,14-away-bench.png|
|Panel local de Joelinton, foto, entrada46 y amarilla89|PASS|15-player-panel.png; no se abrió Ver perfil|
|Suplentes con fuente1,3|PASS sin overflow observado|16-bench-font130.png; escala original1,1 restaurada y registrada|
|Estadísticas guardadas|PASS|18-statistics.png: posesión43/57,tiros11/28,a puerta5/9|
|Tabla con posiciones|NOT VERIFIED|19-table.png muestra Sin tabla disponible; no se inventan posiciones|
|Cronología inicial y marcadores1–0/2–0, tarjetas y sustituciones visibles|PASS parcial|20-live-timeline.png; fotos y asistencias visibles|
|Final de cronología, suspensión/reanudación y ciclo completo de reapertura|NOT VERIFIED|Se interrumpió antes de abrir esos casos; no se afirma PASS|
|Videos reales y LIVE actualizado|NOT VERIFIED|Partido finalizado y ausencia de videos verificados; sin conexiones|

Los nombres de capturas de alineaciones/panel/estadísticas/tabla/cronología de la tabla pertenecen a artifacts/qa234-attempt2/physical. No se recorrieron ni contaron las40imágenes individualmente; no se reitera el conteo18/22 como medición nueva.

Métricas observadas: arranque frío feed8228ms; arranque frío directo al encuentro mediante extra Android route6150ms. Feed SQLite170ms y202ms; detalle SQLite1724ms en esa apertura fría, seguido de memoryHit. No equivalen a una mejora comparativa controlada. Se observaron22 clientes HTTP bloqueados en el primer proceso y6 en el segundo; son intentos de crear cliente, NO solicitudes transmitidas. Logs sin httpStart/httpComplete; sin red y excepción anterior al socket. No se afirma una captura de paquetes. No hubo llamadas directas GOAL ni consultas Supabase.

### Fallos operativos conservados, no ocultados

1. Primer ensayo: READY sí obtenido; durante scroll instrumentado ADB agotó1500ms. Watchdog/launcher no confirmaron cierre; el PID seguía activo. Cierre manual confirmado en1035ms. Resultado automático: FAIL. Se conservan evidencia y logs, no se reclasifica como PASS.
2. Segundo: READY sí obtenido y pantallas anteriores verificadas. ADB volvió a agotar3000ms y cierre principal5000ms; los registros declaran CLOSED_NOT_VERIFIED. El guardián detectó pérdida de propiedad a14:22:32 y comenzó restauración14:22:45; a14:22:47 el PID ya estaba ausente sin cierre manual en esa comprobación. El respaldo funcionó, pero no se declara estable el mecanismo principal.
3. Recuperación USB: adb reconnect perdió temporalmente el transporte. Se recuperó el servidor ADB existente tras comprobar ausencia de otros dispositivos; el usuario también reconectó/desbloqueó el A32. La restauración del segundo ensayo se verificó PASS a14:28:38.
4. Tercer intento: no apareció latido nuevo del candidato en el límite de preparación; NO se abrió FutBeat. Restauración iniciada14:32:22. La demora anterior al primer log/heartbeat no tiene causa raíz demostrada; no se atribuye sin prueba a Flutter, al ejecutable PowerShell o a permisos.

**Decisión: NO-GO para dar QA234 por cerrada o autorizar ejecución desatendida.** La candidata+34 y sus pantallas observadas no muestran una regresión Flutter nueva; queda una inestabilidad concreta de ADB/controlador y casos físicos sin observar. No se justifica otra APK. No habrá nuevos intentos en este bloque.

### Estado final QA234,14:34:58 UTC

Restauración **PASS**, confirmada dos veces: tarea original Running/DISARMED, heartbeat de su proceso actual válido, mismos archivos/ACL/XML, sin PID de com.futbeat.futbeat.qa. Guardián finalizó14:34:13. Wifi1/datos0/avión0 y fuente1,1 restaurados. No quedan aprobación, estado de desarrollo, ventana activa ni READY temporales en el directorio operativo. Teléfono en HOME. La app oficial no se modificó.

Quedan imágenes físicas de15pantallas/estados entre qa234-attempt1/physical y qa234-attempt2/physical; el directorio final qa234/physical está vacío porque no hubo apertura en el tercer intento. No se presentan imágenes de pruebas como nuevas capturas del A32.

La función del producto observada queda validada parcialmente. El cierre completo de QA234 sigue **NO-GO** por los casos no observados y el arranque/transporte intermitente; no hay autorización nueva ni ensayo pendiente. Las correcciones del controlador están en la rama local como candidato probado, NO sustituyen permanentemente los scripts originales restaurados. No se generó nueva APK ni se alteró+34.

## MOBILE234 — continuación cerrada,31-10-2026

Esta sección actualiza el NO-GO histórico de QA234 para los tres casos offline pendientes. No habilita QA conectada ni reemplaza permanentemente QA123.

### Corrección nueva: 7224670

El timeout anterior solo limitaba WaitForExit; después esperaba stdout/stderr con GetResult sin plazo. Reproducción con el wrapper generado real y un ejecutable temporal propio: el padre sale, un descendiente mantiene sus pipes abiertos6s; con timeout2000ms el wrapper anterior devolvió éxito tras6179ms. No se afirma que todos los fallos USB históricos tuvieran esa misma causa; sí se demuestra el bloqueo posible en este código y su capacidad de detener el heartbeat.

Ahora Invoke-QaBoundedAdb comparte un único reloj entre inicio, salida y drenaje de ambos canales. Salida parcial nunca autoriza: timeout de proceso o de streams rechaza la consulta. Solo termina el cliente que posee; no mata su árbol y, por tanto, no elimina un servidor ADB compartido iniciado como descendiente. El guardián de restauración usa el mismo runner. El generador comprueba el hash de la función original antes de sustituirla, para no descartar futuros controles ajenos.

96 pruebas locales PASS:6 del wrapper real con ejecutable ficticio (normal,ausencia legítima,exit inválido,pipes heredados,descendiente conservado,proceso lento) más90 regresiones anteriores de READY,heartbeat,reloj,STOP,presupuestos y propiedad. El test heredado conserva timeout2000ms y exige rechazo en menos3000ms. Antes falla; después pasa. Log: artifacts/mobile234/controller-regressions.log. No hubo operaciones de dispositivo en estas pruebas.

Sin cambios en apps/mobile respecto a1f44251; no se repitió innecesariamente la suite Flutter1.418PASS/analyze ya aprobados. No se generó ni instaló otra APK. Sigue+34 offline,A383EA04037F1A32B19CA181668584DFCFF101E9EF2FA4CE0F54A6F153DC7DC7, origen d3ea1ab, datos conservados.

### Sesión física única y resultados

Galaxy A32 RF8R32GQWGL. Ventana local QADEV-QA234-20261031T145513Z-NORMAL, de08:55 a09:00 aproximadamente (Costa Rica); caducidad fija09:15:13,no renovada. Launcher46640,watchdog48676. READY real antes de abrir; misma sesión para todas las pantallas, segundo plano y reapertura. Sin nuevo gate por pantalla. Radio bloqueada y APK cache_only durante todo el recorrido.

|Caso|Resultado|Prueba física|
|---|---|---|
|Detalle desde SQLite tras abrir el proceso|PASS|30-reopened-match.png;3–1 y goleadores|
|Cronología hasta Final|PASS|31 a34:1–0,2–0,3–0,3–1,tarjetas,sustituciones,Inicio/Medio tiempo/Final|
|Suspensión/reanudación|PASS|PID28635 conservado tras8,424s en HOME; retorno HOT136ms,Final sigue visible en35-resumed-final.png|
|Cierre y reapertura fría|PASS|force-stop confirmado,PID ausente y luego28635→30548;36-cold-reopen.png y37-reopened-lineups.png|
|Fotos persistentes en el proceso nuevo|PASS en filas observadas|37-reopened-lineups.png, sin Internet|
|Pérdida real del launcher/heartbeat|PASS|Se terminó solo el candidato identificado; watchdog48676 cerró QA sin ayuda manual en9226ms por PID|

Las capturas30–37 están en artifacts/qa234/physical. Entrada al encuentro mediante la ruta existente de Flutter Activity; no se declara una nueva prueba de navegación desde una tarjeta del feed. Tabla con posiciones y actualizaciones LIVE reales continúan NOT VERIFIED; no formaban parte de estos tres casos pendientes.

Métricas observadas: apertura fría6157ms,reapertura fría5421ms; SQLite1784ms y1429ms, seguidas por memoryHit. Son muestras de este A32, no una comparación controlada ni una mejora atribuida al controlador. No aparecen RenderFlex/OVERFLOW/FATAL en los diagnósticos filtrados de estos procesos. Se registran intentos HTTP bloqueados antes del socket, no conexiones productivas; sin captura de paquetes ni consultas Supabase/GOAL.

### Prueba independiente de cierre

Launcher terminado08:59:52,390 (Costa Rica), appPID30548. Ausencia de PID y ADB=device confirmadas09:00:01,617:9226ms,sin cierre manual. El propio watchdog guardó FORCE_STOP_CONFIRMED a09:00:01,699 con reason heartbeat_stale. El guardián comenzó restauración después,a09:00:02,104. Por tanto, el cierre observado corresponde al watchdog independiente, antes de la restauración de respaldo. Evidencias: heartbeat-fault-start.json,heartbeat-fault-result.json y final-qa227-failsafe-evidence.json en artifacts/qa234.

Restauración final PASS a09:00:08 (Costa Rica), revalidada posteriormente: tarea original Running/DISARMED,heartbeat del proceso actual,XML/hash/ACL originales y QA sin PID. Red original Wifi1/datos0/avión0; fuente1,1. Autorizaciones,estado,ventana y READY temporales ausentes. Guardián terminó. Teléfono en HOME; paquete oficial intacto.

**GO para reutilizar el candidato corregido en QA offline supervisada y acotada.** Los tres casos pendientes quedan observados. No es una garantía de todos los futuros estados del cable/driver ni una autorización de ejecución conectada o desatendida. El parche está local; QA123 original quedó restaurado. Los ensayos históricos fallidos se conservan en qa234-attempt1/2/3 y no se reclasifican como PASS.
