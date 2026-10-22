# FutBeat Release 130 — decisión de lanzamiento

Fecha: 22-10-2026, Costa Rica. **NO-GO para publicación y AAB firmado; GO para cerrar la candidata local.**
No hay P0 móvil reproducido en esta sesión. Esto no equivale a demostrar ausencia de P0: la ejecución Flutter y los contratos productivos siguen bloqueados.

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
