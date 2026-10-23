# FutBeat Release 130 — decisión de lanzamiento

Fecha: 22-10-2026, Costa Rica. **NO-GO para publicación y AAB firmado; GO para cerrar la candidata local.**
No hay P0 móvil reproducido en esta sesión. Esto no equivale a demostrar ausencia de P0: la ejecución Flutter y los contratos productivos siguen bloqueados.

## Cierre técnico local — continuación del 22-10-2026

Este apartado actualiza el estado anterior de `4edbc5f`. **NO-GO técnico para dar la candidata por validada; NO-GO de publicación.** Los controles estáticos y el smoke Dart están verdes. La ejecución de tests Flutter permanece BLOCKED, no FAIL funcional ni PASS. No se esperó a QA126 ni se accedió a sus archivos, procesos o dispositivo en esta continuación.

### Bloqueo: causa comprobada y límites de la solución

Se reprodujo una conexión TCP mínima a `127.0.0.1` usando `System.Net.Sockets.TcpListener` y `TcpClient`, sin Flutter, pub, SQLite ni código de FutBeat. El listener pudo arrancar; la conexión falló con **SocketException 10013 / WSAEACCES**, «Intento de acceso a un socket no permitido por sus permisos de acceso». El ejecutor Flutter falla al conectar su WebSocket de control al host con **errno 10057**, `Connection closed before test suite loaded`.

Conclusión comprobada: este proceso no puede completar una conexión TCP loopback. El fallo es independiente de Flutter y dependencias. Es consistente con restricciones de aislamiento/red del entorno administrado; no se atribuye a una regla concreta de firewall sin evidencia. Cambiar PATH, regenerar código, actualizar paquetes o esperar más no resuelve una denegación de socket reproducida fuera de Flutter. No se modificaron permisos del sistema, firewall ni reglas de aislamiento.

Mitigaciones locales usadas: SDK aislado ya disponible, ejecutable Dart y snapshot Flutter por ruta absoluta; APPDATA/TEMP/TMP en directorios controlados; PUB_CACHE explícito de lectura; `--no-pub` con package_config existente y lockfile sin cambios. Esto permite analizar y compilar el bootstrap de tests, pero **no desbloquea su canal TCP**. No se hizo otra instalación de SDK, descarga ni actualización de dependencias. No se alteró código funcional para ocultar el fallo.

Se añadió `scripts/release/verify-release130-local.ps1` en **`4e2e887`**: prueba loopback, ejecuta analyze, focales, suite, smoke Dart y controles Android, guarda comandos/logs/hash del runner y restaura las variables de entorno del proceso. Solo termina los procesos que él mismo inicia. Con loopback denegado acota cada intento Flutter a 30 segundos; en host operativo permite hasta 1.800 segundos por batería, configurable. Devuelve código no cero si hay BLOCKED/FAIL.

Comando exacto de esta continuación, desde la raíz aislada:

```powershell
& ./scripts/release/verify-release130-local.ps1 -TestDeadlineSeconds 30
```

Para completar la ejecución en una terminal normal del host que permita loopback, sin abrir la app ni contactar producción:

```powershell
Set-Location F:/FutBeat/FutBeat/artifacts/release130-work
pwsh -NoProfile -File ./scripts/release/verify-release130-local.ps1 -FlutterSdkPath C:/dev/flutter
```

No se ejecutó este segundo comando fuera del entorno restringido. No se disparó CI porque push/PR siguen sin autorización. El workflow beta existente compila APK conectada: **no usarlo como sustituto de un job de tests local**.

### Resultados de la continuación

| Control ejecutado | Resultado real | Alcance |
|---|---|---|
| Probe TCP .NET independiente | BLOCKED, código 10013 | Demuestra denegación loopback fuera de Flutter |
| `flutter analyze --no-pub` mediante snapshot 3.47.4 | PASS, sin incidencias | Código móvil actual, no certifica runtime |
| Focales Flutter: 21 archivos críticos | BLOCKED antes de ejecutar tests | Noticias, Auth, cuenta/reset/onboarding, favoritos, navegación, perfiles, Match Center, correcciones, LIVE, offline, anuncios |
| Suite Flutter completa, `--no-pub --concurrency=2 --fail-fast --reporter=expanded` | BLOCKED antes del primer test | Intento acotado; no completada y cero tests acreditados |
| `dart scripts/release/news_linkout_smoke.dart` | PASS | v1/v2 link-only, dedup, no mutación y feeds malformados |
| `node --test backend/test/android_release_hardening.test.mjs` | PASS, 2/2 | Firma fail-closed e iconos, controles de fuente |
| Diferencia Android/pubspec/lockfile frente a RC98 | PASS de comparación, sin diferencias | No prueba resolución Gradle ni manifest fusionado |

Evidencia local completa: `.local-data/release130-checks/{summary.json,loopback.json,analyze.log,focused.log,full.log,news-smoke.log,android-source.log}`. `summary.json` contiene comando por comando, SHA fuente, hash del runner, hash del lockfile, códigos de salida y timeout. Los intentos bloqueados conservan el error original; un timeout aquí no se reporta como regresión. La lista exacta de los 21 archivos está versionada en el runner. No hay evidencia para comparar fallos funcionales nuevos con preexistentes porque el runner no llegó a ejecutar tests.

### Preparación Android verificada en fuente

La comparación con RC98 conserva únicamente el adaptador/test de Noticias ya aprobado localmente, smoke Dart, runner de verificación y documentación. `apps/mobile/android`, `pubspec.yaml` y `pubspec.lock` no cambiaron. Ninguna migración ni contrato backend fue incorporado. En esta continuación no se modificó ningún archivo funcional de la app.

| Área | Evidencia local | Pendiente externo / artefacto |
|---|---|---|
| Toolchain | Flutter 3.47.4, Dart 3.13.3; AGP 9.1.0; Gradle 9.3.1; Kotlin plugin 2.4.0; JVM target 17; Flutter compile/target 36, min 24 | Resolución transitiva Gradle, manifest fusionado y bibliotecas nativas/16 KB no ejecutados |
| Paquete/versión | `com.futbeat.futbeat`, `1.0.0+5`; sufijo `.qa` solo en build debug opt-in | Confirmar códigos ocupados en todos los tracks; no presumir que 5 esté libre |
| Firma | Config release exige cuatro propiedades y no recurre a debug; regla R8 Room conservada | `android/key.properties` ausente aquí; comparar certificado de carga con Console, no reemplazar clave. App Signing y upload son certificados distintos |
| Permisos | Fuente declara INTERNET y POST_NOTIFICATIONS; callbacks exportados con filtros explícitos | Manifest fusionado/SDKs puede agregar permisos; revisar en build autorizado |
| App Links/Auth | autoVerify a futbeat.com/auth/reset; fallback password-reset; OAuth callback oficial; cola de cold start y PKCE existentes | assetlinks con certificado Play, redirects/backend OAuth, email real y pruebas bajo firma Play |
| Ads | Gradle bloquea IDs ausentes/de prueba y publisher distinto; Dart tiene guard de release y UMP fail-closed | `.env.android-release.local` ausente; no se validaron entradas reales ni configuración AdMob. No afirmar que un AAB futuro carece de IDs de prueba antes de inspeccionarlo |
| Legal/eliminación | Rutas públicas declaradas, UI de borrado y llamada autenticada `futbeat-delete-account`; la UI de soporte copia enlaces | Verificar contenido y accesibilidad web, soporte operativo, eliminación backend y solicitud desde web. No se accedió a Bluehost ni sitios externos |

Dependencias bloqueadas por lockfile, sin actualización: app_links 7.2.1; dio 5.11.1; drift 2.35.0 / drift_flutter 0.3.1 / sqlite3 3.5.2; flutter_secure_storage 11.2.0; flutter_web_auth_2 5.1.0; go_router 18.0.1; firebase_core 4.15.0 / firebase_messaging 16.7.0; google_mobile_ads 9.1.0; in_app_purchase 3.3.1; url_launcher 6.3.3. Este inventario acredita versiones Dart, no dependencias Maven resueltas ni compatibilidad de un bundle inexistente.

Borrador de evidencia para Data Safety, **no formulario completado**:

| Dato/capacidad | Lo que hace el código | Cierre requerido antes de declarar |
|---|---|---|
| Email/cuenta e identificador de usuario | Auth por email/OAuth; sesión en almacenamiento seguro | Confirmar campos efectivos devueltos y retenidos por servicios habilitados |
| Favoritos y preferencias/país | Drift local; sincronización asociada a cuenta | Claude confirma retención, borrado y aislamiento de usuario; país de SIM/red no implica GPS |
| Publicidad y consentimiento | SDK Google Mobile Ads y UMP; anuncios detrás de elegibilidad/consentimiento | Revisar datos de la versión/config SDK y clasificación de compartición; no inferir ausencia de recopilación por no mostrar un banner |
| Push y compras | SDKs incluidos, funciones desactivadas según flags propuestos | Verificar flags efectivos y comportamiento SDK; no afirmar que un SDK ausente de UI esté fuera del binario |
| Diagnósticos | No se encontró integración Crashlytics/Sentry en código móvil | No equivale a cero diagnósticos: revisar SDKs publicitarios y servicios externos |

### Inventario reutilizable para NEWS 131 — sin implementación nueva

| Capacidad | Existe en R130 | Límite de reutilización |
|---|---|---|
| Feed personalizado | `newsFeedProvider` + `ApiRepository.loadNewsFeed`; follows/subjects y país, una consulta `/v1/news` | Personalización semántica/orden del servidor no verificados en producción |
| Últimas | `NewsSection.latest` ordena por publishedAt | Ordena solo artículos ya recibidos; no es paginación global de noticias |
| Fichajes | Filtro TRANSFER y lista `transfers` de cambios de plantilla | No confundir cambios de roster con noticia editorial o fichaje confirmado |
| Ligas | Filtro `NewsSection.competitions` y pestaña de noticias en perfil de competición | Requiere etiquetas canónicas del feed; no catálogo editorial por liga nuevo |
| Relacionadas con partidos | Se puede reutilizar `NewsArticleCard` y subjects canónicos | Match Center no tiene consulta/sección de noticias por matchId. Una coincidencia de equipo no demuestra relación con un partido |
| Originales futbeat.com | Enlace HTTPS público puede abrirse con la tarjeta actual | No existe CMS, publicación ni ingestión de originales en esta candidata; sitio no consultado |
| Fuentes externas | `safeNewsUri`, tarjeta con navegador externo, atribución y error recuperable | El adaptador R130 conserva titulares/enlaces, elimina medios/fragmentos. Los perfiles también usan la tarjeta común y reciben `data.news` directamente: no asumir que el adaptador del feed sanitiza esas otras respuestas; validar procedencia antes de habilitar contenido enriquecido |
| YouTube oficial | `MatchDetail.videos`, `PostMatchVideos`, título/canal/fuente y copiar URL; esquema local de canales verificados | No hay reproductor embebido ni apertura desde esa tarjeta. La verificación de canal depende del servidor; `videos` en Dart no filtra verificationStatus. No se activó servicio ni se descargó video |

### Pendientes mínimos y decisión

No se añadió ningún P0/P1 funcional nuevo ni se corrigieron tests para cambiar expectativas. El commit `4e2e887` agrega exclusivamente herramienta local. La corrección de derechos `3e6880f` permanece intacta y NEWS 131 no se incorporó.

1. **P1 local de verificación:** ejecutar las dos baterías en host con loopback permitido y conservar resultados del mismo código; resolver solo regresiones reproducibles. No hace falta otra auditoría.
2. **P1 de configuración:** verificar código de versión libre, firma/certificados, entradas AdMob/UMP y OAuth; después autorizar build e inspección del AAB.
3. **P1 físico/productivo, separado:** evidencia de Claude sobre disponibilidad y contratos; QA existente revisada por su controlador; smoke del bundle Play de cuenta/favoritos/reset/borrado y funciones críticas en ventana autorizada.
4. **P1 de publicación:** propietario cierra Console, elegibilidad/testing requerido, ficha, acceso de revisión, Data Safety y URLs legales/borrado. No se modificó ninguna cuenta.

**GO local parcial** para revisión de fuente y preparación; **NO-GO técnico** para certificar runtime/tests; **NO-GO publicación/AAB productivo**. El siguiente paso concreto es ejecutar el runner desde terminal normal autorizada con loopback, no ampliar Noticias ni esperar pasivamente a QA126.

## Candidata y trazabilidad

- GitHub `main` verificado mediante conector: `99da8729660892dac76720a5732885fa039d5709`.
- El checkout compartido está en `fix/calendar-day-subbatches` @ `66915869`; su referencia local `main` es `b1c8dea` y está atrasada. No se movieron esas referencias.
- RC98 local: `codex/android-1.0.0-plus-5-rc98` @ `4f34b9cf547a3ce89aeccadc138d34cc55fc9ce4`.
- Candidata: rama `codex/release-130`, repositorio independiente en `F:/FutBeat/FutBeat/artifacts/release130-work`, descendiente directo de RC98. Corrección: `3e6880f`.
- El worktree solicitado fue bloqueado por permisos de escritura sobre `.git`. Se importó la historia local mediante bundle a un repositorio aislado; no es un worktree registrado en el original. No tiene remote de escritura a GitHub.
- Paquete fuente: `com.futbeat.futbeat`; versión fuente: `1.0.0+5`. El código 5 es provisional: consultar todos los tracks de Play antes del build. No se consultó Play en esta sesión. `1.0.0+4` en Internal es información aportada por el propietario, no verificación actual.
- No se compiló APK/AAB ni se copiaron claves de firma. No se tocó la APK de QA126.

## Alcance congelado de 1.0

Incluye Partidos del día con paginación, estados y marcadores, favoritos y orden de competiciones, Match Center, eventos, perfiles, tablas/alineaciones/estadísticas disponibles, estados vacíos y recuperación de errores; país y favoritos persistentes; cuenta por correo y Google cuando su configuración esté validada; recuperación y eliminación de cuenta.

Noticias queda como titulares/fuente/enlace externo. No depende del despliegue v2. Facebook permanece oculto mientras no haya aprobación/configuración y prueba real. Si se decide anunciar Facebook como parte del lanzamiento, debe pasar el mismo gate de OAuth que Google.

1.1: Noticias enriquecidas e internacionales, imágenes y fragmentos con derechos y caducidad; videos; resúmenes; Push productivo; Premium/compras; iOS. No activar estos extras para cerrar 1.0.

## Comparación de código y corrección realizada

RC98 contiene mejoras móviles que no están en GitHub main. Reconstruir desde main descartaría endurecimiento Android/auth/LIVE y UI ya existente. Se conserva RC98 como base; no se integró main completo.

Los cambios móviles posteriores presentes en la línea de identidad son `0c44a91`, `c3d7509`, `76912be`, `2c46996`. Los tres primeros corresponden a Noticias y no son una dependencia del MVP. El último agrega membresías de club/selección: RC98 ya implementa esa conducta con `playerProfileMatches`, `teamIds`, `nationalTeamId`, eventos propios y resolución de alias. No se copió su implementación anterior ni su migración.

La equivalencia no se asumió por el mensaje del commit: el patch-id móvil de `e4e0fe4` es `319b6e7b41e5c2e597e5b2f1ad24f90a55aacb75`, y el de `2c46996` es `88d7a097eb020170abad4a872b88c220231405ba`; son parches diferentes, con conducta solapada revisada en código. RC98 ya incluye por ascendencia `e4e0fe4`. No hubo cherry-pick, merge ni rebase.

**Corrección local P1, `3e6880f`:** el adaptador RC98 copiaba fragmentos e imágenes de v2 sin consultar `rights`, y aceptaba esos campos de v1. Se redujo el alcance a enlaces: se eliminan `description`, `snippet` e `imageUrl` del feed v1 y no se proyectan desde v2. Conserva titulares, enlaces, fuente, filtros y deduplicación; no muta la respuesta original. No se añade un protocolo nuevo ni persistencia nueva. Las respuestas v1 con `news` malformado fallan de forma explícita. Es una reducción deliberada de alcance, incluso si llegan derechos ALLOWED; el cliente enriquecido se difiere a 1.1.

## P0/P1 y acciones mínimas

| Prioridad | Problema o gate | Estado | Acción / responsable |
|---|---|---|---|
| P0 | Crash bloqueante, fuga de datos, calendario vacío por fallo general | NOT VERIFIED; ninguno reproducido aquí | QA126 y smoke Play; tratar cualquier caso confirmado como STOP |
| P1 | Noticias conserva medios sin comprobar derechos | Corregido localmente | Validar tests Flutter de la candidata antes de integrar |
| P1 | Suite Flutter y pruebas focales sin ejecución válida | BLOCKED por sockets del entorno | Ejecutar comandos inferiores en host/CI que permita loopback |
| P1 | Disponibilidad, calendario y LIVE reales | BLOCKED por backend/ventana | Claude entrega evidencia con fecha, versión y salud |
| P1 | Auth real, persistencia y reset bajo firma Play | NOT VERIFIED | Ventana explícitamente autorizada, instalación desde Internal |
| P1 | Configuración final de firma, AdMob, OAuth y versión | BLOCKED por configuración | Verificar entradas seguras y flags; después solicitar autorización específica de build |
| P1 | Data Safety, eliminación y elegibilidad de producción | NOT VERIFIED | Propietario revisa Console y flujos; no afirmar completado por tener código |

P2: pulido visual adicional, métricas de perfiles incompletas cuando no hay datos del proveedor, crash SDK dedicado. No inventar datos ni añadir Crashlytics para desbloquear 1.0: usar Android vitals y reportes de testers inicialmente.

## Matriz de aceptación

PASS significa evidencia de esta candidata y del ámbito descrito; no convierte un control estático en QA real.

| Flujo / control | Resultado | Evidencia / cierre |
|---|---|---|
| Ascendencia RC98, package, versión y regla R8 de Room | PASS verificado, fuente | Git y archivos Gradle/Proguard |
| Firma fail-closed e iconos Android | PASS verificado, controles de fuente | Node: 2/2 |
| Noticias link-out v1/v2, no mutación, dedup, rechazo de feeds inválidos | PASS verificado, Dart directo | `scripts/release/news_linkout_smoke.dart` |
| Flutter analyze | PASS verificado | Log final de esta sesión |
| Favoritos, país, onboarding, logout, guest→cuenta | BLOCKED, tests; NOT VERIFIED real | Tests focales no llegaron a cargar por socket 10057 |
| Registro/login separados, identities vacías, confirmación, recuperación | BLOCKED, tests; NOT VERIFIED real | Mismo bloqueo; casos existentes en auth/account/reset tests |
| Google | NOT VERIFIED real | Opt-in de build y settings; probar con firma Play |
| Facebook | BLOCKED por configuración | Desactivado en el baseline documentado; no exponer CTA sin cierre |
| Todos los partidos, LIVE, FINAL y correcciones de goles | NOT VERIFIED real | Claude + QA126; no inferir de tests de fixtures |
| Match Center, tablas, alineación, estadísticas, perfiles | NOT VERIFIED real | QA126 por fixture con/sin datos; revisar errores de red y reentrada |
| Suite Flutter completa | BLOCKED | Invocada con fail-fast; error de socket antes de cargar; detenida al persistir el bloqueo. No completada |
| App Links y páginas legales públicas | NOT VERIFIED | Web verifier no pudo acceder; no prueba indisponibilidad |
| AAB, firmante, manifest fusionado, símbolos, 16 KB | NOT VERIFIED | Aún no existe artefacto autorizado de R130 |
| Supabase, cuotas, espacio y migraciones desplegadas | BLOCKED por responsabilidad backend | No se realizó ninguna consulta productiva |
| Secretos comunes en código Android versionado | PASS de búsqueda limitada | Sin coincidencias de claves privadas, sb_secret_, sk-proj_ y patrón service_role; no certifica un binario inexistente |

## Pruebas y reproducción

Se usó Flutter 3.47.4/Dart 3.13.3 instalado, con copia aislada de SDK, directorios temporales y telemetría para evitar escribir en herramientas compartidas. Resolución offline produjo package_config; `pub get` terminó con error por `active_roots` en cache de solo lectura. No se cambiaron dependencias ni lockfile. SQLite nativo se reutilizó del cache local; su hook verifica SHA-256. No se modificó su configuración de producción.

- `flutter analyze --no-pub`: ejecutar sobre `apps/mobile`; log final del árbol modificado.
- `node --test backend/test/android_release_hardening.test.mjs`: 2/2 PASS.
- `dart scripts/release/news_linkout_smoke.dart`: PASS, sin Flutter runner ni red.
- `git diff --check`: PASS.
- Focales intentadas: `flutter test --no-pub --concurrency=2 --reporter expanded test/news_feed_v2_adapter_test.dart test/news_screen_test.dart test/news_link_test.dart test/auth_flows_test.dart test/auth_sheet_test.dart test/account_link_test.dart test/account_lifecycle_test.dart test/onboarding_test.dart test/password_reset_cold_start_test.dart test/favorites_hub_v2_test.dart test/player_profile_test.dart`. Once archivos no cargaron por conexión loopback denegada, cero tests validados por esa ejecución.
- Suite intentada: `flutter test --no-pub --concurrency=1 --fail-fast --reporter expanded`. Bloqueada antes del primer test; no afirmar una cifra de tests aprobados.

Los logs de sesión están en el directorio padre `artifacts`: `release130-analyze-final.log`, `release130-focused.log`, `release130-full.log`. Reejecutar focales y suite una vez en host/CI operativo; conservar salida y SHA. No basta con resultados históricos de RC98 para aprobar `3e6880f`.

## Cierre Android y Play

1. Confirmar en Console paquete, códigos usados en todos los tracks, App Signing y certificado de carga. Los certificados documentados en `ANDROID-1.0.0-4-GATES.md` son evidencia histórica; comparar nuevamente al firmar. No imprimir contraseñas ni abrir keystore en reportes.
2. Fuente usa SDK de Flutter: compile/target 36, min 24 en el SDK local. Confirmarlos en manifest del artefacto final. Revisar bibliotecas nativas y compatibilidad de páginas de 16 KB en el bundle/Play; una versión de Flutter no lo demuestra sola.
3. Revisar manifest fusionado, permisos y ausencia de `debuggable`; conservar R8 Room. No añadir permisos nuevos. POST_NOTIFICATIONS está declarado; no pedirlo ni configurar FCM mientras Push esté desactivado.
4. Entorno seguro: `FUTBEAT_ADMOB_APP_ID` real y unidad `FUTBEAT_ADMOB_MATCHES_FEED_ID` real del mismo publisher; `FUTBEAT_ADMOB_TEST_ADS` ausente/false. Gradle ya bloquea IDs de test o ausentes. Verificar UMP en configuración AdMob y comportamiento del formulario en Internal.
5. Google opt-in `FUTBEAT_OAUTH_GOOGLE_ENABLED=true` solo con configuración confirmada y smoke autorizado. Facebook y `FUTBEAT_PUSH_ENABLED=false`; omitir IDs Premium/Firebase. `FUTBEAT_QA_ISOLATED_PACKAGE` ausente para el build oficial. Las URLs/keys publishable del cliente no son secretos; nunca usar service_role.
6. Validar `https://futbeat.com/privacy`, `/terms`, `/data-deletion`, `/auth/reset` y `/.well-known/assetlinks.json`. Incluir huella App Signing de Play para paquete oficial; probar clic desde correo con app cerrada/abierta y fallback. No registrar tokens de recuperación.
7. Cuenta: `futbeat-delete-account` debe eliminar datos del usuario autenticado. Existe UI y llamada, no evidencia de despliegue. La web debe permitir iniciar solicitud de eliminación sin reinstalar la app. Probar con una cuenta QA autorizada.
8. Data Safety: preparar respuestas según el binario/config final: email y datos de cuenta, favoritos/preferencias sincronizadas, OAuth y SDK publicitario/identificadores/diagnósticos que realmente recolecte. Confirmar con documentación de cada SDK. No marcar “no recopilamos datos” ni “no compartimos” por defecto. Completar anuncios, audiencia, clasificación de contenido, acceso de revisores, ficha/capturas y correo de soporte operativo. No se envió ningún formulario.
9. Confirmar elegibilidad: si cuenta personal creada después del 13-11-2023, cerrado con al menos 12 testers inscritos durante 14 días continuos y solicitud de acceso productivo. Internal por sí solo no cubre ese requisito; comprobar lo que exige esta cuenta en Console.
10. Cuando tests, backend y configuración estén cerrados, solicitar autorización específica para AAB firmado. Registrar SHA del código, lockfile, configuración pública redaccionada, versión, certificado público, SHA-256 del AAB y símbolos/debug info en ubicación segura. Verificar archivo antes de pedir autorización separada para subirlo.

Referencias oficiales consultadas el 22-10-2026:
- https://developer.android.com/google/play/requirements/target-sdk
- https://developer.android.com/guide/practices/page-sizes
- https://support.google.com/googleplay/android-developer/answer/14151465
- https://support.google.com/googleplay/android-developer/answer/13327111
- https://support.google.com/googleplay/android-developer/answer/9859348
- https://support.google.com/googleplay/android-developer/answer/6346149
- https://support.google.com/googleplay/android-developer/answer/16285429

## Checklist corto para Claude — sin ejecutarlo desde Codex

Entregar evidencia fechada y versión desplegada; no mezclar los lotes Identity 122, C2+C3 y Noticias. Para cada lote indicar aplicado/no aplicado, dependencia móvil, validación y rollback propio. GitHub no acredita despliegue.

Antes de lanzar:
- Salud API/Auth/PostgREST, latencia y errores recientes, PGRST002 y saturación. Identificar STOP y quién lo opera.
- GOAL y Quota36: consumo, límites, reserva y comportamiento al agotarse; calendario y LIVE deben seguir funcionando sin bucles de demanda.
- Día actual: paginación completa, cobertura por país, fechas/límites, jobs/leases sin atasco; LIVE y FINAL frescos con correcciones.
- Contrato `live_match_updates`: columnas, cursor/paginación, grants/lectura anon y RLS; snapshots, perfiles y tablas compatibles con RC98.
- Usuarios: Auth, redirects de Google/reset, envío de correo y borrado; aislamiento de favoritos/preferencias entre cuentas.
- PostgreSQL: tamaño usado/capacidad, tasa de crecimiento, tablas/índices dominantes, cron realmente necesario, retención activa y margen esperado durante testing/lanzamiento. No hacer counts masivos ni maintenance pesado para este cierre.
- Coste operativo: estimación para cohorte inicial usando mediciones de requests/egress/cuota; alertas y límite de ampliación. Falta de margen medido es un gate; migrar de plataforma o contratar Pro no es una condición automática.

Puede esperar: rediseño de almacenamiento histórico, optimización a escala de años, Noticias v2, videos y migraciones que solo sirven extras apagados. Si un cambio Identity es necesario para evitar resultados incorrectos del MVP, Claude debe demostrar y cerrar ese caso concreto por separado.

## QA126 y salida mínima

Se leyó únicamente la autorización local: `QA126-20261022-2200`, expiración 22:15 UTC. Ventana aportada: 22:00–22:15 UTC = **16:00–16:15 Costa Rica**. No se ejecutó controlador, adb, app, tarea ni consulta de producción. No se encontraron resultados finales en la carpeta revisada durante esta sesión; no se afirma que QA126 haya pasado.

Reutilizar resultados de QA126 por SHA de APK/RC98 y escenario. Cubren solo lo observado y no prueban firma Play ni la corrección de Noticias R130. No repetir esa batería si ya pasó: validar después solo delta de Noticias y smoke del AAB oficial desde Play, en ventana autorizada.

Salida: cero P0/P1 confirmados abiertos; analyze y suite completas verdes del SHA final; Claude confirma contratos/salud/margen; QA126 revisada; smoke Play de cold start/R8, día/LIVE/eventos/Match Center, login y guest→cuenta, país/favoritos tras reinicio/logout, reset, borrado, anuncios/consentimiento; configuración/legales/Console cerrados. La falta legítima de estadísticas o tabla debe mostrar estado vacío y no impide lanzamiento.

## Publicación y rollback

Tras autorizaciones separadas de build y upload: Internal → smoke del bundle distribuido → cerrado si lo exige la cuenta → acceso a producción/revisión → primer lanzamiento en Costa Rica u otros países expresamente aprobados. **La primera publicación no admite rollout por porcentaje**: alcanza a los usuarios elegibles de los países elegidos. No prometer un 5% inicial.

Para actualizaciones posteriores: propuesta 5% → 20% → 50% → 100%, con revisión de al menos un ciclo real de partidos entre ampliaciones y sin ampliar ante crash bloqueante, error de cuenta, marcadores incorrectos o degradación backend. Observar Android vitals, feedback y métricas agregadas de Claude.

Rollback: detener distribución ante P0/P1. Detener un rollout no desinstala la versión ya entregada. Si Console permite halt de versión completa, usarlo tras autorización; la primera publicación no tiene versión productiva previa que restaurar. Conservar el bundle anterior y su código, pero no intentar subir un versionCode inferior: para usuarios afectados preparar hotfix de la última fuente estable con código mayor, misma firma y prueba de actualización que conserve datos locales. No revertir migraciones desde Android; Claude decide backend por separado. Nunca pedir desinstalar como rollback ordinario porque perdería datos locales.

Próximo paso mínimo: ejecutar tests en entorno con loopback y recibir evidencia QA126/Claude. Solo después cerrar flags/Console y solicitar build. No se necesita abrir nuevas líneas de producto para llegar a producción.
# Cierre del fallo CI — 23 octubre 2026

Evidencia real: [run 39968494840](https://github.com/henguido/FutBeat/actions/runs/39968494840),
job 120464579898, fuente `a115e47cdd3ea3d6c52fa971f0adbfeaa47caca3`.
Logs completos recuperados mediante GitHub y conservados localmente en
`.local-data/39968494840-job.log` (no se incorporan logs de runner a Git).

| Etapa original | Resultado observado |
|---|---|
| Checkout/SHA, loopback Ubuntu, Flutter 3.47.4 | PASS |
| Dependencias, lockfile, analyze | PASS |
| Focales | FAIL: 24 aprobadas, 1 fallida; fail-fast, no completa los 21 archivos |
| Suite | FAIL: 101 aprobadas, 1 fallida; fail-fast, no acredita ejecución completa de visual_test.dart |
| Goldens sin modificaciones y subida de evidencia | PASS |

Causa demostrada: `news_screen_test.dart:497` esperaba `news-image` para
`_article('i1', image: 'https://img.test/x.jpg')`, sin autorización explícita.
La carga atraviesa ApiRepository/adaptNewsFeed, que desde `3e6880f` elimina
intencionadamente imagen y fragmento. Es una expectativa anterior a la política
link-only, no un error Linux, de red de imágenes ni de Match Center.

Corrección: el test de pantalla exige ambos titulares y ausencia de medios.
La cobertura de imagen se prueba separadamente en NewsArticleCard: una
autorización explícita y vigente permite crear Image.network; se verifica su
URL, construcción de frame y fallback sin espacio ante el HTTP 400 del runner.
Esto no acredita una descarga real ni decodificación exitosa de imagen remota.
Además se cierra la ruta directa de perfiles: imagen y fragmento requieren
`rights.image`/`rights.snippet` con `status: ALLOWED`, `verified: true` y
`expiresAt` UTC canónico `YYYY-MM-DDTHH:mm:ssZ`, estrictamente futuro.
Fechas ausentes, ambiguas, malformadas, normalizadas o caducadas se rechazan.
No se presume que el backend entregue este permiso: sin evidencia, no hay medios.
El feed sigue sin medios incluso con permiso; NEWS 131 permanece separada.

Validación local: Dart analyze de helper, widget, dos archivos de tests y smoke;
smoke directo con 12 casos de permisos más v1/v2 link-only, deduplicación,
inmutabilidad y feeds malformados; formato, diff y parser del workflow.
No se repitieron Flutter tests Windows. Los nuevos tests Flutter están
NOT VERIFIED hasta ejecutar Ubuntu. No se regeneraron goldens ni se cambiaron
workflows/lockfile. El acceso Git de lectura sigue BLOCKED por DNS; no se hizo
push ni existe un nuevo run atribuible a esta corrección.

**NO-GO técnico** hasta focales y suite completa verdes en el SHA corregido.
La autorización existente permite push normal exclusivamente de la rama CI.
El procedimiento local `.local-data/Submit-Release130CI.ps1` verificará el SHA
corregido, remoto esperado a115e47 (o el mismo SHA ya enviado), rama, limpieza,
workflow, main revisada y ausencia de PR antes de enviar. Cualquier divergencia
remota detiene el proceso. No genera AAB ni usa secretos productivos.

## Gates mínimos hasta Internal Testing

| Gate | Responsable / estado |
|---|---|
| CI Ubuntu completo del commit corregido | Ingeniería; BLOCKED por envío desde este sandbox |
| Console: versionCode libre, upload/App Signing | Propietario; BLOCKED, no acceso externo realizado |
| Upload key existente y AdMob productivo/UMP | Propietario + ingeniería; BLOCKED, no se solicitan contraseñas en chat |
| OAuth, reset, App Links, privacidad, términos, eliminación y Data Safety | Propietario/servicios; NOT VERIFIED, ver PLAY-130-PREPARATION.md |
| AAB firmado e inspección manifest, firma, R8 y nativas/16 KB | Ingeniería; requiere CI verde, configuración y autorización específica |
| Carga Internal y lista/enlace de testers | Propietario; autorización separada |

Paquete declarado `com.futbeat.futbeat`, pubspec `1.0.0+5`; Console debe
confirmar disponibilidad del código. Se mantiene firma fail-closed sin fallback
debug y validación AdMob; no se creó APK/AAB ni se utilizaron certificados.

## Aceptación corta de la candidata instalada desde Play

Todos los casos siguientes están **NOT VERIFIED** físicamente. QA126 se
canceló y no es evidencia. Usar cuentas y datos QA en ventana autorizada.

| Flujo | Aceptación |
|---|---|
| Apertura y onboarding | Sin crash; país/favoritos persisten tras reinicio y actualización |
| Registro/login/logout y recuperación | Guest a cuenta conserva preferencias; errores recuperables y reset funcional |
| Jornada, LIVE y finalizados | Cobertura contrastada, fecha/zona correctas, marcador/estado y cambios coherentes |
| Match Center | Eventos, alineaciones y estadísticas disponibles; ausencia de datos explícita |
| Tablas, perfiles e historial | Navegación accesible, datos coherentes o estado vacío; sin crash |
| Noticias y navegación | Enlaces seguros; sin medios no autorizados; volver conserva estado |
| Red y rendimiento | Error/reintento, red lenta/offline sin bloqueo; registrar tiempos reales de arranque y cargas |
| Distribución | Instalación/actualización Play, firma, enlaces, UMP/anuncios y borrado QA comprobados |

Antes de distribuir: CI verde, firma/identidad/versionado correctos, configuración
real y ausencia de crash de arranque o pérdida de preferencias conocida. Durante
Internal se recogen los resultados funcionales anteriores: cualquier pérdida de
datos, cuenta inaccesible, crash bloqueante o marcador erróneo reproducible
bloquea expansión/promoción. Detalles visuales menores pueden corregirse durante
Internal. No activar extras para compensar estos gates.

Pasos restantes: enviar commit con el script autorizado; recoger logs/counts del
nuevo run; cerrar las entradas externas; autorizar y generar AAB siguiendo
PLAY-130-PREPARATION.md; inspeccionarlo; autorizar carga Internal; instalar desde
Play con testers y completar la matriz antes de promover.
