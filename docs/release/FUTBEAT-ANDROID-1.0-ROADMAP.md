# FutBeat Android 1.0 — roadmap único de lanzamiento

Corte MOBILE252: 2026-11-02, America/Costa_Rica (registros técnicos UTC pueden indicar 02-nov). Responsable de release: propietario; Flutter/Android: Codex; backend productivo: Claude. Documento de trabajo, no autorización de conexión, firma, subida o publicación.

## Decisión y medición

**NO-GO Internal Testing de la nueva línea todavía.** No falta otro rediseño: faltan contrato conectado vigente, QA física del SHA candidato y cierre del binario oficial/CI/Console. Continuar localmente donde esas dependencias no sean necesarias.

52 requisitos explícitos: **0 DONE / 52 = 0% de aceptación final acreditada sobre la candidata actual**; 30 IN PROGRESS, 21 BLOCKED, 1 NOT STARTED. Esto NO significa que el código esté0% implementado: casi toda la experiencia tiene código y pruebas previas. Significa que no hay todavía una candidata release congelada y validada extremo a extremo a la que atribuir su aceptación. Una prueba con mocks, una captura antigua o compilar una APK no cierra la aceptación real. No se calcula un porcentaje ficticio de implementación a partir de conteos de tests.

- DONE: aceptación de la fila satisfecha, con evidencia del binario/SHA pertinente. Para comportamiento real exige observación real; mocks no bastan.
- IN PROGRESS: código y/o pruebas locales existentes; falta aceptación final.
- BLOCKED: falta dependencia concreta externa/operativa o decisión del propietario. No implica un defecto Flutter demostrado.
- NOT STARTED: todavía no se ha preparado la candidata oficial de esta línea o su distribución.
- P0 impide liberar si no se resuelve. P1 es alcance funcional; P2 puede aplazarse explícitamente con UI coherente. Cualquier reducción de alcance se registra, no se borra del denominador silenciosamente.

## Línea vigente y avances conservados

Destino MOBILE252: codex/mobile-252-release, F:/FutBeat/FutBeat/.codex-worktrees/mobile-252; base fa4c2141, sin merges/cherry-picks. Fuente Flutter funcional actual d2fa62fb33e2f6189492503ab43c31f21cb60bd0; guardas release6ce42a74/c74012f conservadas. Ascendencia3977bc7 (M244) ->57b9851b (M245) ->e703864a comprobada en la reconciliación inmediatamente anterior. Sin merges, cherry-picks o copia de implementaciones. Archivos rastreados limpios antes de este documento; artifacts/ no rastreados se conservan. No se modifican otros worktrees.

| Corrección integrada | Evidencia local | Commit | Requisito |
|---|---|---|---|
| Reabrir detalle parcial pasivo sin GET duplicado | Dos visitas3->2, tres visitas5->3; ruta ordinaria conserva fallback | bee70aca | M03 |
| No reintentar errores definitivos/calendario cancelado |400/401/403/404/422/429:3->1;503 transitorio mantiene recuperación | ec16b80d | S08/M01 |
| Cancelar precarga de fecha obsoleta | Regresión bidireccional; solo fecha elegida,HTTP0 | abc3b671 | M01/S06 |
| Tabla pasiva no promete hidratación |6->1lecturas; sin spinner ficticio, resume sin demanda, retry manual1lectura; ordinario6 permanece | e703864a | M08 |
| Fotos: enriquecimiento pasivo no promete trabajo remoto |3->1lecturas; tras pausa/resume sigue1; placeholder preservado, ordinario conserva sus relecturas | c903ccc5 | M07/M03 |

### Registro de evidencia

Rutas relativas a este worktree, salvo indicación explícita. Los logs en artifacts/ se conservan localmente; no se publican binarios ni secretos.

- **E1**: artifacts/mobile246/full-suite.log y analyze.log:1573PASS/0FAIL y analyzePASS sobre código dabdeea6 (e5ce50c solo añade informe),197s/21,6s. Validación anterior, no suite completa de e703864a. Fixtures/tiempos fallidos iniciales quedaron registrados y corregidos sin cambiar goldens.
- **E2**: artifacts/mobile246/hourly01-before.log: dos regresiones nuevas fallan6vs1; hourly01-tests.log:30PASS; hourly01-contracts.log:20PASS; analyzePASS21,6s de esa continuación. Contratos ACK/STOP y comportamiento ordinario preservados. Sin CI remoto del HEAD local.
- **E3**: apps/mobile/test/mobile246_calendar_terminal_error_test.dart y mobile244_feed_prefetch_race_test.dart; resultados antes/después en MOBILE246-RESULTS.md y checkpoint local.
- **E4**: artifacts/mobile246/roadmap250-accounts.log: **203PASS/0FAIL** ejecutados en esta revisión sobre e703864a: auth_flows_test, auth_sheet_test, onboarding_test, onboarding_country_relevance_test, personalization_153_test, mobile244_personalization_resilience_test, mobile245_profile_sync_race_test. Es validación local instrumentada; ningún login/cuenta/permiso remoto probado aquí.
- **E5**: apps/mobile/test/mobile244_notification_dedup_test.dart, mobile245_notification_contract_test.dart, notifications_app_test.dart; docs/notifications.md. Pruebas de contrato/UI heredadas; no entrega FCM real ni confirmación del dry_run remoto.
- **E6**: artifacts/mobile246/apk-verification.json, apk38-manifest.json, aapt35/36/38.log, signature35/36/38.log, physical-precheck.json. Paquete/firma/ELF verificados, sin instalación. ADB local sin ACK en precheck1s el01-nov23:14UTC; no diagnóstico USB concluyente ni PID actual confirmado. QA123 observadoDISARMED, hashes originales, sin modificaciones. READY físico no alcanzado.
- **E7**: F:/FutBeat/recovery-03/autonomous-244/API-CONTRACTS.md y BACKEND-HANDOFF.md, fechados31-oct. Candidato feat/passive-read-api-244@2696527f/PR#240; handoff declara NO-GO conectado y sin despliegue. Es evidencia histórica: no afirmar que esa siga siendo hoy la versión productiva. No consultas Supabase en esta revisión.
- **E8**: QA225-C PASS informado por el usuario: fotos18/40,22placeholders, persistencia offline y sin overflow en+32. Evidencia histórica conservada en línea anterior; no sustituye QA física de+38 ni del AAB futuro.
- **E9**: docs/release/OAUTH-PROVIDER-AVAILABILITY.md, android-signing.md, PLAY-130-PREPARATION.md y declaraciones previas del usuario. Documentos históricos, no estado actual de Play. Gradle actual permite release sin anuncios mediante FUTBEAT_ADS_DISABLED=true y sigue exigiendo firma; decisiones externas requieren confirmación, no copiar valores de documentos antiguos.
- **E10**: CI último conocido de#235/run41247542032:1537PASS/11FAIL de goldens heredados; atribución36PNG idénticos a base exacta, no equivale a CI verde. contractsSUCCESS con suites omitidas por ausencia de cambios backend. Intento de refrescar GitHub en ROADMAP250: plugin no disponible; gh no conecta a api.github.com. Estado remoto actualUNKNOWN. Ningún push/PR/run nuevo ejecutado.

- **E11**: continuación02, artifacts/mobile246/hourly02-before.log: dos regresiones fallan3vs1; hourly02-after.log:53PASS/0FAIL (MatchCenter,enriquecimiento ordinario,detalle,contratos/STOP/loopback); hourly02-analyze.log:PASS12,1s. Pausa/reanudación pasiva no repite consulta; se conserva jugador canónico y placeholder. Prueba local, no fotos físicas nuevas ni DONE de producto. Commit c903ccc5; +38 no lo contiene.

- **E12 — MOBILE250**: artifacts/mobile246/mobile250-full-suite.log: **1577PASS/0FAIL**,155s, suite completa incluida visual_test y goldens, sin exclusiones ni referencias nuevas. Flutter sobre fuente412f9ca4; los nuevos cambios son guardas Android de build y preparación release. mobile250-analyze.log:PASS142,5s. mobile250-android-hardening-final.log:2PASS/0FAIL; guardas de firma fail-closed e iconos. No son CI remoto ni prueba A32.

- **E13 — continuación03/R03/R06**: commit c74012f, verificador nativo ampliado: **5/5PASS** (modosQA,HTTPS válido,API vacía,credenciales sintéticas enURL y grafo real release con --dry-run estricto). El grafo rechazó DEMO en whenReady antes de acciones de empaquetado/firma; no se generó APK/AAB. artifacts/mobile250/runtime-config/artifact-observation.json confirma tamaños/mtimes de los APK/AAB existentes sin cambios. Dos casos anteriores conservados en artifacts/mobile246/hourly03-previous-runtime/. No se repitió Flutter/analyze por un cambio solo del verificador, no hay nuevo PASS físico ni release firmada.

- **E14 — MOBILE251**: commit d2fa62fb. Tres regresiones/recorridos en mobile251_onboarding_restart_test.dart: dos pérdidas de preferencias fallan antes (paísES->MX al vincular; ordenmanual->automático al confirmar país) y pasan después. Recorrido completo de bienvenida/configuración/país/equipos/ligas/jugadores/alertas/invitado/resumen/Partidos; cierre real de SQLite en archivo y nuevos DB/service/container/router; Perfil->Personalizar->destinos reales de equipos/ligas/jugadores/alertas. Conservar país frente a otra región y tres favoritos sin filas duplicadas. Al navegar, dropdown de hora desbordaba61px; isExpanded lo corrige. SecureStorage y Auth son dobles explícitos; no prueba Android Keystore/OAuth reales. Logs antes/después y ubicación de overflow conservados en artifacts/mobile246/mobile251-*.log. Suite completa1580PASS/0FAIL,132s; goldens sin cambios; analyzePASS15,6s. Los ensayos iniciales con selectores imprecisos/esperas de limpieza se conservaron como problemas del harness, no bugs de producto; solo se terminaron dos árboles de test propios previamente identificados por comando exacto. Sin producción, teléfono, APK/AAB o credenciales reales.

## Backlog de aceptación

Cada fila permanece abierta hasta reunir su aceptación concreta. Las referencias de tests son evidencias locales, no datos reales. Cambios e703864a y anteriores están integrados solo en esta línea local; no implican main ni Play.

| ID | Funcionalidad | Prioridad | Estado | Evidencia | Responsable | Dependencias | Prueba de aceptación | Commit/PR | Entrega |
|---|---|---|---|---|---|---|---|---|---|
| S01 | Calendario con fechas y partidos recuperados | P0 | BLOCKED | E3/E7; calendario local probado, cobertura actual desconocida | Claude + Codex | R10 | Mostrar hoy/ayer/día siguiente con IDs y zona CR del backend autorizado | ec16b80d,abc3b671 | INTERNAL |
| S02 | Marcadores LIVE recientes | P0 | BLOCKED | E1/E7; pruebas LIVE locales, sin observación vigente | Claude + Codex | R10 | Observar timestamp reciente y llegada real en A32 | 57b9851b,dabdeea6 | INTERNAL |
| S03 | Actualización de marcador | P0 | IN PROGRESS | E1; correcciones y revisiones probadas localmente | Codex | S02 | Un cambio real llega sin recarga ni duplicación | 57b9851b | INTERNAL |
| S04 | Final termina LIVE | P0 | IN PROGRESS | E1; estados terminales locales | Codex + Claude | S02 | Final canónico cancela seguimiento y persiste tras reabrir | 57b9851b | INTERNAL |
| S05 | Correcciones de goles | P1 | IN PROGRESS | E1; fixtures de revisiones y marcador | Codex | S02 | Anulación y corrección convergen al estado canónico sin sumar doble | 57b9851b | INTERNAL |
| S06 | Feed sin partidos duplicados | P0 | IN PROGRESS | E258:82 tests feed PASS; usuario confirma Favoritos y liga; dedupe por sección | Codex | S01 | Mismo ID aparece una vez por grupo; favorito también permanece en liga | abc3b671,fe31e1b9 | INTERNAL |
| S07 | Datos antiguos identificados | P0 | IN PROGRESS | E1; avisos frescura y LIVE sin timestamp | Codex | S01/S02 | Offline/stale no se presenta como observación actual | 57b9851b | INTERNAL |
| S08 | Error temporal sin crash | P0 | IN PROGRESS | E1/E2; errores terminales y503, caché preservada | Codex | R08 | Corte y503 mantienen pantalla recuperable y datos guardados | ec16b80d | INTERNAL |
| S09 | Cobertura Costa Rica validada | P0 | BLOCKED | E7 fechado; no es health actual | Claude | R10 | IDs de competiciones/fechas CR y cobertura parcial explicitados | handoff244 | INTERNAL |
| S10 | Cobertura internacional principal | P1 | BLOCKED | E7; sin verificación actual de datos | Claude | R10 | Muestra acordada con fixtures almacenados, sin exigir datos inexistentes | handoff244 | PUBLIC |
| M01 | Feed y navegación por fechas | P0 | IN PROGRESS | E1; carrera de fecha corregida | Codex | S01/R08 | Cambiar ida/vuelta sin respuesta obsoleta ni precarga de fecha anterior | abc3b671 | INTERNAL |
| M02 | Favoritos agrupados y persistentes | P0 | IN PROGRESS | E14:SQLite reabierto, favoritos sin duplicados y orden manual preservado | Codex | A07/R08 | Seleccionar/quitar, reiniciar y conservar un grupo; no perder demás partidos | 57b9851b; pruebas153 existentes | INTERNAL |
| M03 | Match Center cache-first | P0 | IN PROGRESS | E1/E2/E11; reapertura pasiva3->2lecturas en dos visitas, enriquecimiento3->1 | Codex | R08/R10 | Primera lectura, reapertura SQLite y actualización segura en partido real | bee70aca,c903ccc5 | INTERNAL |
| M04 | Cronología completa y compacta | P1 | IN PROGRESS | E1; regresiones locales IDs/eventos | Codex + Claude | M03 | Comparar IDs API/SQLite/UI; explicar eventos filtrados sin inventarlos | 57b9851b | INTERNAL |
| M05 | Previa y estados sin datos | P1 | IN PROGRESS | E1; contratos locales; ruta no pasiva por defecto | Codex + Claude | R10 | Previa disponible o ausencia explícita; no red fuera del alcance | 57b9851b | INTERNAL |
| M06 | Estadísticas | P1 | IN PROGRESS | E1/E2; datos tardíos y recuperación local | Codex | M03/R08 | Valores reales coinciden con payload y permanecen offline cuando guardados | e703864a | INTERNAL |
| M07 | Alineaciones y fotografías | P0 | IN PROGRESS | E8 histórica/E11 local;3->1lecturas pasivas, sin prueba física del nuevo SHA | Codex | R08 | Titulares/banca legibles sin overflow y fotos correctas sin red tras reinicio | 75f60b8 heredado;c903ccc5 | INTERNAL |
| M08 | Tabla de fase/grupo/temporada | P1 | IN PROGRESS | E2; ordinario6lecturas, pasivo6->1; filas conservadas | Codex + Claude | R10 | Apertura/Clausura/grupo exactos; sin datos legítimos no son tabla inventada | e703864a | INTERNAL |
| M09 | Perfil por identidad canónica | P1 | IN PROGRESS | E1; alias/homónimos/identidad local | Codex + Claude | R10 | Plantilla/alineación abren mismo ID; homónimos separados | 57b9851b | PUBLIC |
| M10 | Caché de fotos persistente y acotada | P1 | IN PROGRESS | E8 histórica y E1 regresiones; no prueba actual del dispositivo | Codex | R08 | Descarga autorizada, cierre de proceso, offline, placeholder y evicción | 75f60b8 heredado | INTERNAL |
| A01 | Invitado | P0 | IN PROGRESS | E14:recorrido completo invitado->Partidos y reinicio local, sin permisoPush | Codex | R08 | Entrar sin cuenta y navegar feed/MC sin login forzado | e703864a base probada | INTERNAL |
| A02 | Configuración rápida | P1 | IN PROGRESS | E14:configuración completa y entrada real Perfil->Personalizar tras reinicio | Codex | R08 | Completar u omitir sin bucle y editar desde Perfil | e703864a base probada | INTERNAL |
| A03 | País sugerido y modificable | P1 | IN PROGRESS | E14:país manual persistente; vinculación simulada conserva la elección | Codex | R08 | País manual persiste y no borra favoritos; distinguir zona/país | e703864a base probada | INTERNAL |
| A04 | Seguir equipos | P0 | IN PROGRESS | E14:agregar/quitar/agregar equipo; un único registro tras reabrir | Codex | A07 | Agregar/quitar por ID y conservar al reiniciar | e703864a base probada | INTERNAL |
| A05 | Seguir competiciones | P1 | IN PROGRESS | E14:selección de liga e ID persistente; navegación real desde Perfil | Codex | A07 | Selección persistente y feed coherente | e703864a base probada | INTERNAL |
| A06 | Seguir jugadores existentes | P1 | IN PROGRESS | E14:jugador de catálogo por ID y persistencia; sin datos nuevos inventados | Codex | A07/R10 | Buscar ID canónico existente; ausencias no crean jugadores | e703864a base probada | INTERNAL |
| A07 | Preferencias y guest->cuenta | P0 | IN PROGRESS | E14:país/favoritos conservados en vinculación local; cuenta real pendiente | Codex | A09/R08 | Reinicio offline y login no pierden ni duplican favoritos | 57b9851b | INTERNAL |
| A08 | Google | P1 | BLOCKED | E9; bandera por proveedor, no login release actual | Propietario + Codex | R02/R03 | Validar callback con certificado distribuido o aplazar explícitamente ocultándolo | OAuth availability doc | PUBLIC |
| A09 | Correo, confirmación, reset y salida | P0 | IN PROGRESS | E14/suite:correo,reset,sesión/logout yOAuth con dobles; proveedores reales pendientes | Propietario + Codex + Claude | R10/R08 | Cuenta autorizada: login/confirmación/reset/logout sin exponer contraseña | auth_flows_test.dart | INTERNAL |
| A10 | Facebook si está configurado | P2 | BLOCKED | E9; no configuración real verificada | Propietario | R02 | Mantener flag false y botón ausente; habilitar solo tras QA Meta/callback | OAuth availability doc | POSTERIOR |
| N01 | Notificación de gol | P1 | BLOCKED | E5; contrato local no entrega FCM | Claude + Codex | R10/permiso específico | Entrega controlada real o exclusión explícita sin promesa en UI | 57b9851b | PUBLIC |
| N02 | Notificación de inicio | P1 | BLOCKED | E5; sin entrega real | Claude + Codex | N01 | Evento correcto una sola vez en dispositivo autorizado | 57b9851b | PUBLIC |
| N03 | Notificación de final | P1 | BLOCKED | E5; sin entrega real | Claude + Codex | N01 | Final canónico entregado una sola vez | 57b9851b | PUBLIC |
| N04 | Notificación tarjeta roja | P1 | BLOCKED | E5; sin entrega real | Claude + Codex | N01 | Destinatario y evento correctos sin duplicación | 57b9851b | PUBLIC |
| N05 | Notificación titular | P1 | BLOCKED | E5; sin entrega real | Claude + Codex | N01 | Jugador canónico y preferencia correctos | 57b9851b | PUBLIC |
| N06 | Notificación banca | P1 | BLOCKED | E5; sin entrega real | Claude + Codex | N01 | No confundir suplente con titular ni inventar alineación | 57b9851b | PUBLIC |
| N07 | Correcciones de notificaciones | P1 | IN PROGRESS | E5; contrato/revisiones locales | Claude + Codex | N01 | Corrección no repite gol obsoleto ni altera identidad | 57b9851b | PUBLIC |
| N08 | Preferencias de alertas | P1 | IN PROGRESS | E4/E5; preferencias sin pedir permiso al abrir | Codex | A07 | Cambios persistentes y coherentes con feature desactivada | 57b9851b | PUBLIC |
| N09 | Tap abre partido correcto | P1 | IN PROGRESS | E5; navegación local | Codex | N01 | Tap real cold/warm abre ID del mensaje, sin externo | 57b9851b | PUBLIC |
| N10 | Deduplicación y autorización FCM | P0 | BLOCKED | E5; solo pruebas locales; no estado remoto inferido | Claude + propietario | permiso separado | Mantener dry_run; decisión explícita: FCM apagado en1.0 o prueba aprobada | 57b9851b | INTERNAL |
| R01 | Paquete oficial y versionCode disponible | P0 | BLOCKED | E6/E9; QA38 no es com.futbeat.futbeat release | Propietario + Codex | Console lectura autorizada | Paquete oficial; siguiente código libre en todos los tracks | build.gradle.kts | INTERNAL |
| R02 | Firma upload activa correcta | P0 | BLOCKED | E9 histórica; Console no revisada hoy | Propietario | R01 | Certificado público de upload actual coincide con firma del AAB; sin claves en logs | android-signing.md | INTERNAL |
| R03 | Configuración release congelada | P0 | IN PROGRESS | Guardas nativas8/8PASS(E15), fuente conservada; origen/token/firma oficiales pendientes | Propietario + Codex | R10/A08/N10 | Defines explícitos; no DEMO/loopback/diag QA; OAuth/Ads/Push según decisión verificada | e703864a | INTERNAL |
| R04 | AAB existente o siguiente release trazable | P0 | BLOCKED | +6 histórico preservado, no revalidado ni sustituido; no contiene esta línea | Propietario + Codex | R01/R02/R03/R09 | Fuente/hash/firma/manifest/ELF/16KB aceptados del AAB exacto; build solo autorizado | Internal+6 histórico | INTERNAL |
| R05 | Privacidad, permisos y borrado | P0 | BLOCKED | E9 histórica; no evidencia actual sobre nuevo binario | Propietario + Codex + Claude | R03/R04 | Manifest fusionado y SDKs coinciden con declaraciones; enlaces/borrado verificados | PLAY-130-PREPARATION.md | INTERNAL |
| R06 | Dependencias y secretos release | P0 | IN PROGRESS | E15:c280ffdc rechaza claves privadas/sesión en campos públicos; binario final pendiente | Codex | R04 | Lockfile sin cambio inadvertido; ningún secreto privado; endpoints/diagnóstico correctos | build.gradle.kts | INTERNAL |
| R07 | Compatibilidad Android y nativas | P0 | IN PROGRESS | E6 QA:SDK24/36,4ELF requeridos; no equivale a AAB16KB | Codex | R04 | Inspección binario release y arranque A32 sin crash/R8 | dabdeea6 | INTERNAL |
| R08 | QA física candidata exacta | P0 | BLOCKED | E16:ADB/identidad/PID verificados; modo avión=0; no READY físico | Codex + propietario | ADB/READY/autorización | Instalación/actualización sin pérdida, recorrido observado y cierre PID; QA123 restaurado | physical-precheck.json | INTERNAL |
| R09 | Suite y CI del SHA de release | P0 | BLOCKED | E16:1580PASS/analyze frescos; #234/#235 mobileFAIL; CI dependiente preparado, sin publicar | Codex + propietario | permiso push/CI posterior | Suite/analyze correctos, CI de SHA exacto sin ocultar diferencias | #234/#235 | INTERNAL |
| R10 | Contrato desplegado y salud operativa | P0 | BLOCKED | E7 es handoff fechado, no producción actual | Claude + propietario | aprobación específica | Rutas/ACK/demandas/health/STOP comprobados, cero fallback no autorizado | PR#240 candidato | INTERNAL |
| R11 | Checklist Play, testers y acceso revisor | P0 | BLOCKED | E9 y mensajes históricos; no lectura Console hoy | Propietario | R02/R04/R05 | Conservar testers/ficha; revisar estado real; contraseña solo formulario seguro | PLAY-130 docs históricos | INTERNAL |
| R12 | Internal Testing y smoke desde Play | P0 | NOT STARTED | Ninguna subida de esta candidata autorizada | Propietario + Codex | R01..R11 | Autorización de subida distinta; enlace de participación e instalación de track probados | Sin PR release nuevo | INTERNAL |

## Alcance de salida MOBILE250

Clasificación técnica para detener iteraciones abiertas: **39 requisitos INTERNAL**, **12 PUBLIC**, **1 POSTERIOR**. INTERNAL es imprescindible para la primera prueba interna; PUBLIC debe cerrarse antes de distribución pública; POSTERIOR puede aplazarse. La clasificación no activa servicios ni aprueba automáticamente la configuración de release.

- INTERNAL: lectura deportiva básica sincrónica/cache, estados sin datos, onboarding/invitado/correo, favoritos, navegación crítica y controles de build/seguridad/QA/Play. LIVE real exige evidencia vigente; el propietario informa recuperación L237, pero no se convierte en health actual ni en prueba móvil.
- PUBLIC: cobertura internacional amplia, perfil enriquecido, Google y entrega real de alertas. Para Internal pueden permanecer apagados/limitados SOLO si la UI lo representa y la configuración se aprueba explícitamente. Correo e invitado no se posponen.
- POSTERIOR: Facebook hasta configuración y aceptación real verificadas. No mostrar un botón operativo si la integración está deshabilitada.
- La entrega FCM real no es condición de un Internal que lo mantiene apagado/dry_run; sí lo son deduplicación/preferencias locales y no prometer entregas inexistentes. Ningún test local prueba entrega FCM.

Porcentajes de aceptación final: INTERNAL0/39, PUBLIC0/12, POSTERIOR0/1. La validación local consolidada se registra separada; no se añade una nueva funcionalidad ni se baja silenciosamente un P0.

## Cinco bloqueos P0 para liberar

1. **R10/S01/S02/S09**: Claude debe aportar contrato realmente desplegado, rutas/ACK, evidencia vigente de salud y condiciones STOP. No tratar request=0 como pasivo. Las rutas normales pueden registrar demanda diferida. No se requiere nueva auditoría global: solo diferencias y comprobaciones pendientes del handoff.
2. **R08**: A32 ya responde (E16); falta aislamiento offline y obtener READY verificable, sin reiniciar ADB compartido ni alterar QA123. Prueba física de SHA exacto sigue pendiente; no reutilizar gates antiguos ni la autorización de QA225.
3. **R09**: CI nuevo del candidato requiere autorización de publicación. Resolver/disponer explícitamente los11goldens Linux con evidencia reproducible; no ocultarlos con referencias nuevas o exclusiones. Suite local y atribución de render son evidencias distintas.
4. **R01–R07/R11**: verificar upload key activa y versionCodes/Console, configuración oficial/Ads/OAuth/permisos y AAB exacto. +6 firmado histórico no contiene los avances actuales; preservarlo y decidir su uso con el propietario, sin regenerarlo o sustituirlo automáticamente.
5. **N10/A08/R03**: congelar alcance externo. Propuesta para primer Internal: Push/FCM y Facebook desactivados; Google solo si validado con firma Play, correo/invitado obligatorios. Esta es propuesta pendiente de aprobación, no decisión ya aplicada. No activar FCM ni cambiar dry_run para demostrar entrega. Si se exige Push en1.0, su QA controlada se vuelve bloqueo real separado.

## APK/AAB y configuración

| Artefacto | Fuente | SHA-256 | Estado |
|---|---|---|---|
| QA+36 offline |546615f201f41c1d8552366c2e3e345219b5b434|81B1C4EF5B09C1C39570B0837E18D73F14BAFA6A0B747FC650B140897CA9A5E4|Verificada y conservada; no contiene correcciones245/246 |
| QA+37 offline |ca59ffefd8c27ab8bd9feea2b4f82645b8d29912|0F2051A076245074C7D4CFC499B0D8E02480D3B6454412096D411E91B6CF664C|Conservada, no reinstalada |
| QA+38 offline |dabdeea67a71b2bf8cd40993ef1c6e37272eb4c4|62464130F20D461C79D1DAFB7833262785B884EBEE2AA85EEFB4B133D1EDA155|Verificada, no instalada; no incluye e703864a posterior |
| AAB oficial+6 histórico |Fuente/certificado actuales no revalidados aquí|No copiar un hash no verificado|Preservado; sin nueva generación, subida ni publicación |

+38: com.futbeat.futbeat.qa,1.0.0/code38,SDK24/36,debugQA SHA certificado6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362, cuatro ELF arm64 requeridos. DEMO=false,local-cache-only=true,API127.0.0.1:9,token vacío,OAuth/Push/Ads apagados,diagnósticoQA activado. No es binario distribuible de com.futbeat.futbeat. No prometer datos precargados en una instalación vacía: sin red ni SQLite existente habrá ausencia legítima.

La próxima compilación se agrupa tras cierre de requisitos/correcciones y congelación del SHA; no generar una por cada commit. El versionCode oficial se elige tras lectura de Console, no se deduce del número QA. Inspeccionar manifest fusionado, firma upload, bibliotecas/16KB, flags y secretos sobre el artefacto real. Una huella pública no prueba posesión de upload key activa.

## Plan de una sesión QA conectada supervisada

Preparación local disponible; **no autorizada ni ejecutada**. Una sola sesión de15min,30consultas,8/min y2simultáneas como máximo, sin gate por pantalla. El contrato pasivo sigue opt-in: no instalado automáticamente ni whitelist ampliada. Realtime e imágenes no quedan automáticamente incluidos en el contadorHTTP del adaptador; registrar su alcance y presupuesto aparte antes del GO. No hacer que límites desconocidos parezcan medidos.

1. Claude confirma health/contrato/partido canónico almacenado/coberturaCR y alcance; propietario autoriza sesión y, si hace falta, instalación específica. Confirmar ausencia de despliegue incompatible.
2. Verificar A32/APK/firma/SHA y datos; guardar estado reversibleQA123; exigir watchdogREADY y cierre ante STOP/expiración/heartbeat perdido. No suspender protección sin restauración preparada.
3. Recorrido compacto: invitado,feed/fechaCR,favoritos,unMatchCenter,cronología,alineación/estadísticas,tabla si disponible. Máximo autorizado aplicable; perfil/previews solo si rutas explícitamente aprobadas. Sin login/modificar favoritos salvo autorización de aceptación específica.
4. Capturar ID/eventos/timestamps y FB_QA_DIAG:HTTP por ruta,SQLite/hit/miss/dedup/latencia. Cerrar/reabrir offline el encuentro guardado y fotos; distinguir persistenciaJSON de imágenes. No inferir cuotaGOAL a partir de contadoresHTTP.
5. STOP ante salud no verificable/degradada,ACK ausente,ruta fuera de contrato,ADB perdido,presupuesto vencido,datos/pantalla inesperados. Cierre,PID confirmado,red original yQA123 restaurados; Claude aporta health final. Lo no observado es NOT VERIFIED.

Esta sesión reduce bloqueos M/S; auth/login/borrado y notificaciones reales necesitan su aceptación específica. Las continuaciones automáticas nunca pueden ejecutar este plan físico.

## Cierre funcional local MOBILE250

**Consolidado localmente:** Feed/calendario/Favoritos, MatchCenter/Previa/cronología/panel de jugador, estadísticas/alineaciones/tablas, imágenes/SQLite, cambios de estado LIVE/correcciones/reconexión, onboarding/país/equipos/competiciones/jugadores/alertas y persistencia. La suite completa1580PASS de MOBILE251 incluye las regresiones de Auth/reset/cierre de sesión, ciclo de vida, identidad y contratos; el detalle por caso queda en E14. Son aceptaciones locales con datos controlados: login Google/correo real, FCM real, coberturaCR y frescura LIVE productiva siguen abiertos hasta observación autorizada.

**Integración:** e703864a y c903ccc5 son ancestros del HEAD412f9ca4; no hay que copiarlos ni fusionarlos. Desde57b9851 solo cambiaron tres fuentes Flutter y sus regresiones, antes de preparar estas guardas Android. No se tocaron worktrees ajenos, backend o datos del dispositivo.

**Preparación de candidata oficial:** scripts/release/android-1.0-candidate.public.example.json contiene únicamente decisiones públicas conservadoras y campos vacíos. Es una plantilla, **NO una configuración aprobada ni utilizable todavía**: API vacía debe rechazarse, token público y origen deben venir de la configuración aprobada. Ads/Google/Facebook/Push apagados son propuesta para reducir alcance Internal, no activación/cambio de servicios. Mantener FCM dry_run es instrucción del propietario; su estado remoto no se consultó.

Falta apps/mobile/android/key.properties en este worktree: no se leen/buscan contraseñas ni se fabrica una firma alternativa. Firmar exige la upload key existente, coincidencia con certificado activo dePlay, versión libre y autorización. La APK+38 no se convierte en release ni contiene cambios posteriores. Conservar+36/+37/+38 y AAB+6; no generar otra numeración para esta preparación.

**GuardasR03/R06:** validar modos de ejecución antes de producir release: DEMO,modoQAoffline y diagnósticosQA deben estar apagados; si se proporciona API explícita debe serHTTPS,no loopback, sin credenciales/query/fragment. Commit6ce42a74: se añadieron validación Gradle y regresión offline reproducible en scripts/release/verify-runtime-config-local.py. Resultado nativo verificado:2/2casosPASS; flagsQA+HTTP local rechazados (exit1 esperado), casoHTTPS válido aceptado (exit0),38,27s/24,61s. Logs en artifacts/mobile250/runtime-config/. La primera compilación del script Kotlin falló por referencia a URI; se corrigió import explícito y se conservaron logs iniciales. Ningún fallo de compilación se contabilizó como rechazo correcto. Firma/anuncios conservan sus controles previos.

## Cierre MOBILE251 — aceptación local y Release Candidate

| Bloque | Estado local | Límite pendiente |
|---|---|---|
| A01–A07: onboarding completo | PASS:recorrido entero, SQLite cerrada/reabierta, nueva región, invitado y Perfil->Personalizar | QA física del binario exacto; SecureStorage se probó mediante doble de plugin |
| M02: equipos/ligas/jugadores favoritos | PASS:IDs conservados, agregar/quitar,3filas únicas; ordenmanual/pins no se sobrescriben al cambiar país | Feed físico y sincronización de cuenta real |
| A03/A07: país invitado->cuenta | PASS con auth/RPC simulados; la elección local gana conforme al contrato existente | No login real ni cambios de cuenta productiva |
| A08/A09/A10: Google/correo/Facebook/reset/sesión/logout | Suite localPASS, incluye doblesPKCE/Auth y persistencia local de sesión | OAuth/correo/recovery con proveedor y certificado reales siguenNOT VERIFIED; no cambiar flags automáticamente |
| R03/R06: configuración release | Guardas nativas8/8PASS(E15); plantilla pública aún no activada | Origen/token aprobados e inspección de binario pendientes; rechazo sintético PASS |
| R01/R02/R04/R07: paquete/firma/versión/APK/AAB | Fuente definecom.futbeat.futbeat; guardas fail-closed conservadas | Falta key.properties en este worktree, certificadoupload/versionCode dePlay y build firmado autorizado; ninguna APK nueva |
| R05: permisos/dependencias/secretos | Sin cambio a manifest/pubspec/lockfile; sin claves reales añadidas | Revisar manifest fusionado/SDKs/declaraciones sobre el AAB final |
| R08/R10: físico/conectado | No ejecutado; QA123 y A32 intactos | Contrato/health/GO, dispositivoREADY y autorización específica |

Estos cierres son de recorrido **local real de Flutter y SQLite**, no DONE de aceptación física/productiva. Se conservan los52requisitos y el NO-GO de publicación hasta sus gates. No sumar pruebas simuladas como entrega FCM o acceso OAuth real. Se mantiene la automatización existente y su límite; esta sesión manual no consume una continuación.

## Hitos y próxima tarea

- **H0 — alcanzado como preparación local**: línea246 conservada, cinco correcciones funcionales integradas, cuentas/preferencias203tests localesPASS, cuatro continuaciones programadas completadas. No confundir hito local con DONE de producto.
- **H1 — siguiente hito de lanzamiento**: contrato conectado vigente aprobado + A32READY + evidencia física del recorrido crítico sobre SHA congelado. En paralelo resolver CI conocido y alcance Google/Push/Facebook, sin esperar inactivo.
- **H2**: un único AAB oficial trazable tras permisos de firma/configuración, revisión de Console y autorización separada de subida. Después smoke desde Internal y enlace real de testers. No publicar enProducción.

Próximo bloque de lanzamiento: **R08/R09/R10**, evidencia física autorizada, CI del SHA final y contrato conectado vigente. Estas continuaciones no tienen permiso para teléfono, publicación/CI remoto o producción. Si no aparece un defecto P0/P1 local reproducible o nueva evidencia autorizada, registrar bloqueo externo sin inventar trabajo ni repetir suites. R06 conserva pendiente la inspección del artefacto final y aprobación de configuración/firma.

## Continuaciones MOBILE245

Automatización futbeat-mobile245-12-continuaciones-locales finalizada y eliminada al alcanzar12invocaciones:4completadas,8bloqueadas. No quedan continuaciones autorizadas y no se creó otra. Esta revisión manual no consume una programada. Instrucciones actualizadas mediante herramienta de la app; creación/horario/límite conservados. No se creó otro proceso/tarea/controlador.

Usar active-target.json y el bloqueo atómico existente antes de editar. Si existe otro dueño, registrar BLOCKED_BUSY y no tocar archivos compartidos. Cada ejecución escoge ID de esta tabla, reproduce/corrige/prueba/commit local, actualiza evidencia/estado y checkpoint, registra ledger y libera solo su bloqueo. No marcar DONE por mocks ni fabricar horas efectivas. No resetear el contador al cambiar instrucciones. Si no hay tarea segura, registrar bloqueo sin falsa implementación.

Límites automáticos intactos: solo código/pruebas/commits locales; sin teléfono/ADB,producción,Supabase,GOAL,servicios,instalación de dependencias,buildAPK/AAB,push/PR/merge,rebase/cherry-pick o cambios deQA123/ramas ajenas. Las automatizaciones no garantizan trabajo con equipo apagado/app cerrada; ver [documentación oficial](https://learn.chatgpt.com/docs/automations?surface=app).

## E15 — continuación programada 04, R06

Commit c280ffdc: la guarda aceptaba valores sintéticos sb_secret y JWT service_role/authenticated en los dos campos públicos. Dos reproducciones fallaron antes; no se usaron claves reales. La corrección conserva claves publishable y JWT legacy anon, rechaza formatos privados/sesión/malformados y omite sus valores del error. Es una protección contra inclusión accidental, no autenticación de JWT ni validación de firma/proyecto.

Ocho casos Gradle nativos PASS/0FAIL, incluido bundleRelease --dry-run estricto;2 pruebas de hardening Android PASS. Evidencia artifacts/mobile246/hourly04-before-runtime/ y artifacts/mobile250/runtime-config/. Metadatos tamaño/mtime de APK existentes sin cambios; no empaquetado, firma, APK/AAB nuevos, teléfono o producción. La suite Flutter1580PASS y analyzePASS de E14 son históricos, no repetidos: este cambio no altera fuentes Flutter. R06 sigue IN PROGRESS hasta revisión de configuración y binario finales.

## E16 — MOBILE252, cierre de consolidación local

Ver [informe de release](../../FUTBEAT-MOBILE-252-RELEASE-READINESS.md). Rama aislada desdefa4c2141:88referencias locales móviles revisadas;48ancestros,19alternativas equivalentes por patch-id y21requieren comparación/adaptaciones ya presentes o exclusión histórica. Ninguna copia masiva ni retroceso. Reconciliación y regresiones por fuente en el informe; artifacts/mobile252/branch-inventory.json conserva SHA/worktrees/estado.

Validación fresca: Flutter1580PASS/0FAIL, goldens incluidos sin cambios,120s; analyzePASS13,7s; hardeningAndroid2PASS; comparadorgoldens8PASS tras corregir únicamente permisos temporales del entorno. Commit ebea42b prepara R09: triggerbase codex/mobile-245 y timeoutcontracts35 alineado conmain. YAML parseado; comandos/tests/permisos/jobs de despliegue sin ampliar. No CI nuevo ni push de esta rama.

P0:29totales,0/29de aceptación final sobreRCexacta. Separar13/16funcionales con aceptación local de las3dependencias de datos reales(S01,S02,S09); no son DONE productivos. R09 sigueBLOCKED: #234/#235 mobileFAIL verificados enGitHub; #242UTCverde no ejecutóFlutter. No confundirlos conCIde252.

APK+36: SHA,paquete/code36,firmaDEBUG ycuatroELF verificados nuevamente; conservada sin instalar, fuente546615f2 anterior a31archivos móviles actuales. AAB+6 preservado; no build nuevo. Firma/configuración/versionCode oficiales no aprobados ni disponibles en esteworktree.

PrecheckA32 02-nov16:00UTC: ACKADB,SM-A325M/RF8R32GQWGL/SDK33,PIDQAausente; modoavión=0. STOPantes de red/READY/apertura. No cambia conectividad, controladores ni apps. La red activa no se presume: falta acreditar aislamientooffline. Supabase/GOAL no consultados.

Siguiente acción: autorización de publicación dePRdependiente conCIpreparado y aceptaciónoffline bajoaislamiento+READY. Después congelarconfiguración/firma/SHA y generaruna únicaRC. La automatización agotada no se reinicia; esta sesión es manual.


## MOBILE258 — evidencia local consolidada (03-nov-2026)

Rama aislada `codex/mobile-258-integration`, base exacta `07a54b2566d90d978c80c985a3708868a551127d`. PR243/base conserva su CI Linux; no es CI del nuevo HEAD. Integraciones mediante parches revisados, ascendencia y patch-id equivalentes, sin merge/cherry-pick. Ledger: `artifacts/mobile258/integration/ledger.json`.

- **S06 / #220**: el propietario confirmó Favoritos **y también su liga**. `fe31e1b9` conserva todos los partidos en liga, un grupo Favoritos y una aparición canónica por sección. Regresión nueva falla antes de la corrección; después 82/82 tests del feed PASS. Sin nuevas solicitudes de precarga y sin cambiar referencias golden.
- **A09**: respuestas de autenticación/recuperación/restauración obsoletas descartadas; formularios no duplican envío; escrituras y borrados del token mantienen orden. 253 pruebas focales del agente PASS con almacenamiento/control de red simulado; OAuth/correo real NOT VERIFIED.
- **A03/A07/M02**: guardar orden de competiciones solo escribe los campos editados; no revierte país/modo recientes. Favoritos vacíos liberan su scope LIVE, preservando scopes de otras pantallas.
- **S02/M03**: dispose y cierre de un watch LIVE liberan sus recursos sin quitar las funciones de pausa/refresh de otros watches. 63 pruebas relacionadas PASS. No observación de Realtime productivo.
- **M03/M08**: cambio del ID de Match Center reinicia recuperación local; Tabla completa conserva temporada/fase/snapshot sin GET adicional; intereses pendientes no usan WidgetRef desmontado.

Esto es evidencia de código y pruebas locales, **no aceptación física ni DONE** de los requisitos. No se usó teléfono, Supabase, proveedores ni credenciales de producción. RC sigue NO-GO por certificado upload/configuración y aceptación del artefacto exacto pendientes. El versionCode5 continúa como propuesta sin aplicar.

Validación final MOBILE258: **1625/1625PASS**, suite completa con goldens103s; analyze limpio12,8s. Evidencia: `artifacts/mobile258/flutter-full-final.log`, `analyze-final.log` y `FUTBEAT-MOBILE-258-FINAL.md`. CI remoto del nuevo HEAD y aceptación física siguen pendientes.
