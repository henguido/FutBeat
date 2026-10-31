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
