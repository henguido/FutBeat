# MOBILE252 — Android 1.0 release readiness

Fecha: 02-nov-2026, Costa Rica. **GO de consolidación y validación local; NO-GO de distribución Internal Testing todavía.** No hay autorización implícita de conexión, instalación, firma o subida.

## 1. Rama y consolidación

Rama `codex/mobile-252-release`, worktree `F:/FutBeat/FutBeat/.codex-worktrees/mobile-252`, creada desde `fa4c21419c95f5d6b2be157df6a76fa70fa97ad0`. Fuente Flutter probada: `d2fa62fb`; guardas release posteriores conservadas. No merge/cherry-pick, ni modificación de main/ramas ajenas. Los archivos de aplicación son idénticos a la línea vigente; no se copia código antiguo sobre correcciones nuevas.

Se revisaron 88 referencias locales móviles relacionadas (incluidas fuentes no Codex): 48 son ancestros; 40 no lo son. De estas últimas, 19 tienen todos sus commits equivalentes por patch-id en la línea actual. Las otras 21 requieren comparación semántica: un `+` de `git cherry` NO demuestra que falte la funcionalidad. HEAD remotos recientes verificados: mobile243=d9fe6823, autonomous244=3977bc74, mobile245=57b9851b; no hay una línea móvil remota posterior bajo esos prefijos. Inventario completo con SHA, worktree, archivos pendientes y equivalencias: `artifacts/mobile252/branch-inventory.json`.

| Fuente | Decisión y evidencia |
|---|---|
| MOBILE245, MOBILE246, MOBILE251 | Ancestros conservados; no transferencia pendiente |
| beta-backlog-functional; 211 cache/lifecycle/prefetch; 215 offline/prefetch/SQLite; 229 notifications/timeline; night230 LIVE | Equivalentes por patch-id; no duplicar |
| 244 LIVE | Tres commits equivalentes por patch-id |
| 245 cache | Regresiones de identidad de detalle, media y notificaciones idénticas; profile-sync solo difiere en llaves de estilo. providers actual conserva las correcciones y añade STOP/ausencia pasiva/reintentos acotados |
| 245 Match Center | Tests de aliases, encabezado, goles numéricos y fases idénticos; regular-phase solo difiere por sintaxis null-aware. No reinstalar la versión antigua |
| 245 LIVE/feed/stored | Regresiones conservadas; contrato stored solo difiere por sintaxis null-aware. Reanudación y cancelación actuales incluidas en suite |
| 244 feed | La guarda de generación se conserva; la versión actual además reencola la fecha nueva y preserva grupos al seleccionar el mismo día. Personalización contiene el arreglo posterior de país/orden |
| 244 Match Center | Cronología idéntica; test de integridad de tabla solo cambia sintaxis null-aware |
| night230 cache/goldens, 229 stored | Tamaño de decode preservado con helper canónico; privacidad equivalente. La política actual añade publisher atómico y ADB acotado posteriores; no retroceder controlador |
| lineups-ux-v2 | Alternativa histórica del 07-oct, anterior a la línea reciente; no importar sus 33 archivos/goldens sobre Match Center actual |
| Onboarding v1/v2, country UX/relevance/polish; notifications-app; splash | Variantes históricas con adaptaciones; pruebas actuales de onboarding, permisos, cuenta, splash y recuperación siguen presentes y ampliadas. No reemplazar componentes actuales por pantallas anteriores |
| feat/lineup-player-panel y fix/mobile-feed-history-performance | Commits equivalentes por patch-id; panel actual añade contexto/media posteriores |
| android-match-news-92 / android-orchestrator-10h / integration-s244 | Noticias históricas, documentación o integración backend mixta: fuera del delta de esta RC; no importar por nombre de rama |
| NEWS106/107 históricas | No importar ramas antiguas de derechos; no son correcciones pendientes para esta RC |

No se perdió ningún archivo ajeno: los untracked de artifacts/failures de otros worktrees se conservaron. No se editaron. TEST-UTC permanece separado en PR #242, commit `a19080f1`, CI verde: no es una dependencia funcional de Flutter ni prueba de CI de esta RC.

### Commits funcionales conservados

- `bee70aca`: reapertura stored sin lectura de hidratación duplicada.
- `ec16b80d`: no reintentar errores definitivos/cancelación de calendario.
- `abc3b671`: descartar precarga de fecha obsoleta.
- `e703864a`: tabla pasiva 6→1 lecturas automáticas.
- `c903ccc5`: enriquecimiento pasivo de alineaciones 3→1.
- `d2fa62fb`: país invitado→cuenta, orden de favoritos y overflow de Personalizar.
- `6ce42a74`, `c74012f7`, `c280ffdc`: configuración release fail-closed y regresiones nativas.
- MOBILE252 `ebea42b`: CI permite base `codex/mobile-245` y conserva timeout contracts35 de main. Antes no se dispararía ese PR dependiente y quedaría un límite25 inferior a los29m43s observados en TEST-UTC. No cambia comandos de tests, secretos, despliegues ni timeout móvil15. YAML parseado localmente.

## 2. P0 y evidencia funcional

El roadmap tiene **29 P0**. **0/29 = 0% de aceptación final sobre una RC oficial exacta**: todavía no existe ese AAB firmado y probado extremo a extremo. No se transforma una simulación en DONE ni se rebaja el criterio del roadmap.

Separadamente, **13/16 P0 funcionales (81,25%) tienen aceptación local con pruebas verdes**: S03/S04/S06/S07/S08, M01/M02/M03/M07 y A01/A04/A07/A09. Esto acredita lógica/UI/SQLite con datos controlados, no proveedor, OAuth real o dispositivo. Los otros tres funcionales, S01/S02/S09, dependen de calendario, frescura LIVE y cobertura CR reales de Claude. Los 13 P0 restantes son gates de release/notificaciones y no se declaran completos por tener código.

| Bloque | Resultado local | Falta para cierre final |
|---|---|---|
| Onboarding completo, país, equipos/ligas/jugadores, invitado, Perfil→Personalizar | PASS, incluidos reinicio real de archivo SQLite y preferencias sin pérdida; IDs canónicos | Recorrido observado en binario congelado |
| Favoritos | PASS: grupo único y también liga, altas/bajas, orden/pins, persistencia y vinculación con Auth simulada | Cuenta real y dispositivo |
| Previa, cronología, estadísticas, alineaciones, Tabla y panel jugador | PASS: contratos, identidad, fases, estados sin datos, no overflow en goldens locales | Comparación con datos reales autorizados y A32 |
| Fotografías | PASS local: disco, evicción/fallback/identidad; no asignación por nombre | Reinicio offline observado sobre candidata exacta; QA225-C es histórica |
| LIVE | PASS local: correcciones, duplicados, stale, reconexión y suspensión/reanudación | Timestamp/actualización real con contrato y health vigentes |
| Google/correo/Facebook/reset/sesión/logout | PASS de pruebas locales/dobles; cada proveedor opt-in fail-closed | Proveedores, certificados/callback y cuenta reales NOT VERIFIED en esta línea |
| Notificaciones | Contratos/deduplicación/preferencias probados localmente; sin activación de FCM | Entrega real NOT VERIFIED; no se cambió dry_run ni configuración remota |

## 3. Pruebas realmente ejecutadas

Fuente aplicación idéntica a `fa4c2141`, en el worktree nuevo:

- `flutter analyze --no-pub`: **PASS**, 13,7s.
- Suite Flutter completa, **sin excluir visual_test ni goldens**: **1.580 PASS, 0 FAIL**, aproximadamente120s. Incluye contratos HTTP/ACK/STOP, SQLite, Auth simulada, onboarding/favoritos, imágenes, LIVE y lifecycle. No referencias visuales modificadas.
- Guardas Android de fuente: **2 PASS, 0 FAIL**.
- Comparador de goldens: **8 PASS**. Primer intento falló por permisos de carpetas temporales; se conservó y repitió con acceso local, sin cambiar expectativas.
- Workflow: YAML parseado; cuatro bases únicas, contracts35/mobile15, solo jobs existentes y permisos contents:read.
- Ocho pruebas Gradle release de la continuación04 se conservan como evidencia histórica del mismo código nativo, no ejecutadas otra vez aquí ni contadas como build release nuevo.

Logs: `artifacts/mobile252/analyze.log`, `full-suite.log`, `android-hardening.log`, `golden-comparison-permitted.log`, `ci-validation.log`. Salidas analyze/full-suite=0. El workflow fue el único cambio de ejecución posterior; no altera fuentes Flutter.

## 4. CI actual

Consulta de GitHub de solo lectura el02-nov:

- PR #234 `3977bc74`: mobile FAILURE, contracts SUCCESS con trabajo backend omitido.
- PR #235 `57b9851b`: mobile FAILURE, contracts SUCCESS con trabajo backend omitido. Run41247542032. Los11goldens heredados y36PNG equivalentes son evidencia anterior, no un CI verde ni prueba Linux nueva de252.
- PR #242 TEST-UTC: contracts/mobile SUCCESS, backend1.316PASS y Deno. **Mobile omitió Flutter**, por lo que no cierra R09 Android.
- No existe CI remoto del SHA MOBILE252. No push, PR ni reejecución de jobs en este bloque. La automatización245 terminó sus12invocaciones y no se recreó.

Próxima publicación revisable: PR dependiente sobre `codex/mobile-245`, con el delta246/251 y la preparación252, no una PR gigante contra main ni un merge de todas las ramas históricas. Requiere autorización de publicación y revisión del alcance; el trigger faltante ya está preparado localmente.

## 5. APK +36 y dispositivo

APK conservada: `F:/FutBeat/FutBeat/.codex-worktrees/autonomous-mobile-244/artifacts/244/futbeat-qa-1.0.0+36-local-cache-546615f2.apk`.

- Fuente `546615f201f41c1d8552366c2e3e345219b5b434`.
- SHA-256 fresco **81B1C4EF5B09C1C39570B0837E18D73F14BAFA6A0B747FC650B140897CA9A5E4**;111.117.388bytes.
- aapt: `com.futbeat.futbeat.qa`,1.0.0/code36. Cuatro ELF arm64 presentes.
- apksigner PASS, certificado **Android Debug**, SHA-256 `6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362`.
- Es offline QA, no oficial release; tiene31archivos móviles distintos frente a la fuente252 y no contiene todas las correcciones posteriores. No sustituirlo/reinstalarlo ni llamarlo RC actual. +37/+38 y AAB+6 preservados.

Precheck físico fresco,16:00UTC: ADB existente respondió, RF8R32GQWGL/SM-A325M/SDK33 correctos, PID QA ausente. **Modo avión=0**: el precheck offline se detuvo. No demuestra Internet activo; demuestra que falta la condición offline requerida. No se abrió/instaló app, no se cambió red, no se reinició ADB ni se tocó QA123. Watchdog READY y restauración no alcanzados; estado actual del controlador no se presume.

## 6. Release Candidate e Internal Testing

**Candidata de código consolidada, no binario oficial listo.** `applicationId` fuente es `com.futbeat.futbeat`, firma release fail-closed, Java17, minSDK24/target36 en QA previa. El manifest fuente declara INTERNET/POST_NOTIFICATIONS y callbacks; manifest fusionado, SDKs, permisos reales y alineación16KB deben revisarse sobre el AAB final, no deducirse de una APK debug.

Bloqueos concretos:

1. **RC/firma/configuración:** `apps/mobile/android/key.properties` ausente en este worktree; no se buscan/copían contraseñas ni se usa firma debug como release. Falta certificado upload activo y versionCode libre confirmado en Play. `pubspec`1.0.0+16 NO es una elección aprobada de versión de distribución; los números QA son overrides. La plantilla pública tiene origen vacío y no es una configuración productiva aprobada. Congelar API/origen, flags OAuth/Ads/Push, privacidad y permisos antes de empaquetar.
2. **CI y dispositivo de SHA final:** CI móvil nuevo y ensayo offline observado pendientes. A32 accesible, pero aislamiento de red y watchdog READY no están acreditados. No instalar automáticamente candidata conectada.
3. **Contrato operativo:** handoff local244 sigue declarando NO-GO conectado; es documentación histórica, no consulta de salud actual. Claude debe confirmar versión desplegada/rutas y ACK, ausencia de demandas/hidrataciones inesperadas, calendario/CR, LIVE reciente, standings y condiciones STOP. No se consultó Supabase ni GOAL.

No generar otra APK/AAB por numeración. Agrupar la siguiente compilación tras congelar código/configuración/firma, conservar hashes y efectuar una única aceptación física. AAB+6 no contiene esta línea y no se reemplazó. No se verificó Console ni se subió/publicó nada.

## 7. Bugs y siguiente acción de mayor impacto

**Ningún P0/P1 Flutter nuevo reproducido** en las1.580pruebas. No inventar correcciones cosméticas para fabricar progreso. Bloqueo R09 demostrado y corregido localmente en el workflow: trigger dependiente ausente y timeout heredado menor al runtime observado. CI nuevo todavía pendiente.

Mayor impacto: **autorizar la publicación del paquete móvil dependiente para obtener CI Linux del SHA congelado**, usando la base existente y el trigger preparado; resolver solo fallos reproducibles, sin regenerar goldens para ocultarlos. En paralelo, preparar A32 offline mediante el procedimiento autorizado y exigir READY real antes de abrir. Tras aprobación de flags/firma/versionCode, producir una única RC oficial y validar desde Internal Testing con autorización de subida separada.

No se ejecutaron operaciones productivas, migraciones, despliegues, ingestas, nuevos servicios ni llamadas de proveedor. No se modificaron main, RC98, Release130, NEWS131, APK existentes ni worktrees ajenos.
