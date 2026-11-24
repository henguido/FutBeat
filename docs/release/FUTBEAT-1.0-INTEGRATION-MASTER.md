# FutBeat 1.0 · tablero de integración

## Consolidación final · 24 de noviembre de 2026 · GO técnico para commit local

HEAD `8a37e913abce5a0a1b1df291214e98f8ffaf91df` conservado. Sin staging,
commit, ramas, worktrees, push, merge, despliegues ni APK nueva. Android, sus
pruebas físicas, sesiones y favoritos no se tocaron. Inventario de aplicación
sin drift; se conserva la APK aprobada
`775CDD8853B5C9A8FB085D7F68C76A6192104D18C310257F97DBE84046FBBF93`.

**Sección 5 de Claude integrada:**
- REOPEN-1 `20261124150000_reopen1_stale_missing_from_provider.sql` y su prueba,
  byte-exactos LF con los hashes confirmados. La regresión falló sin el fix;
  ambos casos pasan con él. BE16, BE18b, cuotas y VERIFIED conservados.
- `20261005090000_load_relief.sql` completo, de 52498e0a: lookup timezone,
  cinco consumidores optimizados, bucket inlinable y revocaciones privadas.
- `20261004230000_interest_aggregates_safeupdate.sql` completo, de 1b73c2b9:
  cuerpo productivo de refresh_interest_aggregates, sin regresar al DELETE inseguro.
- Solo tabla/semilla inerte/ACL de detail_planner_schedule y wrapper de un
  argumento de O1; sin ejecución de planes ni operaciones históricas.
- Se conserva la línea anterior: BE11/12/16/14/18/18b, N1/PL1/W2, K2/D1v2,
  G3/RTDN, FCM v9, identidades y cobertura. Sin repetir fusiones ni redirects.

**Validación:** reconstrucción nueva de **171 migraciones** en PostgreSQL 17.6
nativo y en imagen Supabase inmutable
`sha256:6942962433a569e87f228b4d4ab7e11db5deca64e43babb3a038443ad6c4f1bb`.
Firmas, ACL, D1 P0 sin wake directo y repetición en orden consolidada→REOPEN-1 PASS.
Los 11 prefijos nuevos coinciden con Claude; el cuerpo REOPEN-1 da
`83cbc022447cdbdc79f60cdd8258858e`. Verificación real safeupdate PASS: borrado
sin condición rechazado y refresh permitido, todo con rollback local.
Vault, pg_net y pg_cron reales PASS; red Docker none, ningún scheduler de aplicación
activado ni consulta a GOAL. Auth sigue siendo fixture aislado.

**Contracts:** ejecución completa: 1426 casos, 1423 PASS, un fallo de aserción
antigua de O1 y dos TODO existentes. Se corrigió solo el test para comprobar el
wrapper de un argumento y el bloqueo del planificador de dos argumentos; el
archivo completo afectado pasó **14/14**. Cobertura final reconciliada:
**1424 PASS, cero fallos pendientes, dos TODO**. No se presenta esto como una
segunda ejecución completa verde. Regresiones focales recuperación/calendario/
timezone/interés: **27/27 PASS**. Detalle auditable en
`artifacts/consolidation-section5-contracts-summary.json`.

**Equivalencia cerrada según handoff §5:** pub1-a y pub1-b (incluidas FK BE11-A5),
load_relief, safeupdate y O1. Las fuentes de cinco Edge confirmadas se conservan,
JWT explícito; imports cerrados, pin npm documentado y cambios aún no desplegados
de ingesta/News preservados y probados separadamente en `supabase/undeployed/`.
Android, Billing, AdMob/UMP y FCM no cambiaron durante este cierre.

**Límites que no se convierten en PASS productivo:**
- REOPEN-1 es una corrección **local, aún no aplicada en producción**. Producción
  conserva el cuerpo 9a667517; aplicarla requiere autorización operativa separada.
- Los nombres timezone dependen del tzdata del servidor. Se verifica igualdad
  con su propio catálogo, sin inventar igualdad de filas entre servidores.
- Defaults de grants Supabase en public difieren de PostgreSQL nativo; no se
  modificaron grants productivos ni se copiaron configuraciones o secretos.
- Ocho imports global-ingest carecen de readback byte por byte; sí tienen evidencia
  de commit limpio y despliegue/ezbr. Resolución npm histórica de Passive desconocida;
  local fija 1.8.0. ACL productiva de ocho RPC no releída; local fail-closed PASS.
  Dos cuerpos PL1 se preservan con normalización whitespace, sin afirmar byte igualdad.
- Dos TODO preexistentes: muestra real AET sin penales y copia calendario/LIVE
  atravesando medianoche. No se gastó cuota ni se inventó aceptación deportiva N1.

**Conjunto y rollback:** 198 rutas en `artifacts/atomic-consolidation-final-paths.txt`;
hashes en `scripts/release/consolidation1.sources.json`. Las 192 rutas anteriores,
sus respaldos e inventarios quedan preservados; se añaden seis fuentes/fixtures.
Preparación del único commit y rollback en `artifacts/atomic-consolidation-plan.json`;
no se ejecuta staging/commit. Copia exacta nueva y validación de blobs previstas
antes de solicitar autorización. Ningún reset/clean o rollback productivo está incluido.

**GO técnico para autorizar un único commit local** del manifiesto final sellado.
No implica GO de despliegue, pagos, Push global, Play, Internal Testing o Alpha.
N1 deportivo continúa pendiente de aceptación operativa/física con Claude.

## Estado vigente · 23 de noviembre de 2026 (Costa Rica)

Única base Android autorizada: `F:/FutBeat/FutBeat`, main local HEAD `8a37e913`
con cambios sin commit conservados. No crear ramas/worktrees ni commit/push/merge.
Candidata instalada: `artifacts/FutBeat-1.0.0-17-consolidated-final-acceptance-A32.apk`,
SHA256 `775CDD8853B5C9A8FB085D7F68C76A6192104D18C310257F97DBE84046FBBF93`,
instalada en A32 conservando UID, datos y sesión. La base real del propietario al
iniciar esta misión tenía 16 favoritos (6 equipos, 5 jugadores, 5 competiciones);
se conservó exactamente, junto con preferencias, sin restaurar el antiguo listado
de once. Cinco IDs guardados de jugador representan ahora cuatro entidades tras
un redirect oficial PID-1; no se reescribió ni eliminó ninguna fila personal.
Analyze actual limpio9,2s;53focalesBilling y8G2QA/aislamientoPASS.
Suite completa final2222PASS/6skip/0fail,3m35s, goldens sin cambios.
Contratos finales locales:1358PASS/2TODO/0fail,1360casos,31m22s, exit0.
Inventario actual `consolidated-final-acceptance-source.json`,
evidencia previa `consolidated-r4-coherence-manifest.json`; inventario y evidencia
actuales `consolidated-r4-live-frame-source.json` / `...manifest.json`. La nota de contratos en
ejecución del inventario corresponde al instante de compilación; este manifiesto
es el cierre posterior. Las APK 0DD1780D/D474 y sus evidencias permanecen conservadas.
R4 anteriores y evidencias conservadas; este es el binario para evaluación actual.
N1 deportivo pendiente del SM-G781U1 y ventana autorizada de Claude. A32 no es
destinatario piloto y conserva permiso denegado. Sin compras comerciales ni envíos.
GO evaluación personal; NO-GO publicación/Alpha. LIVE físico cerrado; N1 deportivo
y compuertas comerciales conservan su aceptación pendiente. Los registros de fechas
anteriores son históricos: estados y rutas antiguas no reemplazan este resumen ni autorizan acciones.

### Consolidación funcional · 21 noviembre · única base y candidata QA

#### Consolidación atómica preparada · 24 noviembre · sin staging/commit

**FCM v9 confirmado byte a byte por Claude según mensaje del propietario.**
Queda cerrado ese pendiente de fuente, sin nuevo desarrollo ni despliegue FCM.
SHAEAB8A07E del transporte local y kit conservados. APK775CDD88 intacta y sin
cambios runtime Android; OAuth/Billing/AdMob/N1/MatchCenter/Favoritos/SQLite
mantienen sus fuentes aprobadas. No operación en teléfonos en esta preparación.

**Conjunto exacto original:97 entradas =78modificadas+19sin seguimiento.**
Todas tienen contenido distinto de HEAD más allá deCRLF:33runtime/configAndroid,
50pruebasFlutter,7goldens,3contratoBackendFCM y4entradasrelease. La categoría de
contenido no afirma que cada línea sea un cambio funcional (incluye tests/config).
No son97cambiosmás67EOL: de las67entradasEOL,38están modificadas,3son nuevas y
26no cambian contenido de HEAD. El JSON del inventario se reserializaráLF al
recongelar; no se incluye a sí mismo entre sus67inputs. Ninguna normalización
efectuada. Fuente existente `scripts/release/acceptance17.sources.json` intacta.

Plan revisable `artifacts/atomic-consolidation-plan.json`, lista exacta
`atomic-consolidation-paths.txt` y listaEOL `atomic-consolidation-eol-paths.txt`.
Cada fila fija SHAHEAD, SHAactual, SHALF y categoría. Rollback previo de123archivos
(unión de97+26EOL sin cambio de contenido): `atomic-consolidation-before.zip`,
SHA256`5945DC7ABD8C29180CEB87C747FBE5337A6F407299CC2A86337357C5D339A4FD`.
ValidaciónPASS de las123entradas contra el disco y los67hashesLF calculados en
memoria. No se borró/restauró ningún archivo. Rollback futuro solo autorizado y
con guard de hash para no sobrescribir trabajo posterior; nunca reset/clean.

**Fuera del conjunto original, preservado y visible:**10entradasbackend requieren
revisión antes de cerrar el allowlist final. Incluyen la regresión existente de
Letonia en `backend/test/live_terminal_recovery.test.mjs`, tests de calendario/
identidad ySQLmanuales. No se pierden ni se incorporan kits operativos por
inferencia. También se preservan las dos fichasPlay130 históricas, fuera de alcance.
El tablero maestro mantiene la evidencia y no se considera código de la APK.

Backend pendiente de fuente canónica/dependencias de Claude: D1v2,K2,PL1,PO1,
N1,W2,PO2,Q429,BE18b,G3 ylocalizaciónBE14; inventario previo actualizado distingue
FCMresuelto. La ausencia de blob exacto en este repo no prueba ausencia semántica
ni falta de commits en otros clones. No se ejecuta ni se reemplaza código productivo.

**Validación de preparación:**14ContractsbackendPASS,13FlutterPASS, inventario
sin drift, archivo de rollbackPASS, APKoriginalSHAigual. GateGit estricto continúa
rechazando correctamente el árbol pendiente (exit1), sin generarAPK.

**Secuencia mínima, toda escritura Git pendiente de autorización:**
1. Claude confirma las fuentes/dependencias backend pendientes y se decide el
   allowlist final, incluyendo las regresiones aprobadas fuera de los97originales.
2. Autorizar ese conjunto explícito; normalizar solo losEOL propuestos con hash
   previo y guardar provenanceRaw775. Re-fijar inventario canónicoLF sin cambiar
   lógica ni atribuir al binario anterior un hash de fuentes distinto.
3. Una consolidación atómica, preservando los3commits anteriores. Nunca `git add .`;
   no credenciales privadas, dumps, keystores, cachés ni carpetas de operadores.
4. Gate de Git limpio y hashes, focales más Contracts/suite/goldens del commit
   congelado, luego build reproducible autorizado. No otraAPK antes de ese freeze.
5. Si hay regresión local de normalización, recuperar solo bytes del backup con
   guard de hash y autorización; si ya haycommit, un revert separado y autorizado.
   No implica rollback de backend, push, merge ni publicación.

**GO para revisión/autorización de la consolidación. NO-GO para ejecutarla o
declarar release reproducible desde Git** hasta cerrar backend canónico y autorizar
el conjunto. Artefactos: `atomic-consolidation-validation.json`, contratos y logs
`atomic-consolidation-*`. Nada deAPK/servicios/dispositivos modificado.

#### Cierre de fuentes / reproducción · 24 noviembre · sin operaciones remotas

HEADlocalmain `8a37e913abce5a0a1b1df291214e98f8ffaf91df`; consulta GitHub
`ls-remote` confirma main `6e10d3c83eed80c34db28ac14aa21af6bc1f81d1`.
Tres commits locales existentes por delante:e3cfc788,1285566a,8a37e913; main
remota es ancestro. No commit/merge/rebase/push/staging efectuado. SHA de APK775
intacto, **cero diferencias de fuente runtime Android** frente al inventario
físicamente probado; no APK ni nueva prueba física necesarias en esta etapa.

**Corrección local de respaldo FCM:** `backend/notifications/transports.mjs`
se copió byte a byte desde el kit de Claude `live-pro/fcm-n1/new`, preservando
la copia anterior en `artifacts/source-closure-before/`. SHA256
`EAB8A07E4E195DCD00B0BDDD01A55E553B500079759EE241A5ECB1666F870B79`.
`dispatch.mjs` e `index.ts` ya coinciden byte a byte. Runner/log de Claude
registran v8→v9 DONE18nov21:56:13Z con hashes fijados; versión9 vigente reportada
por Claude/propietario. **Confirmación fresca del SHA desplegado pendiente de
Claude**, solicitada mediante propietario; no se reemplaza ni consulta el cuerpo
productivo con permisos inferidos.

**Contrato compartido ejecutado:** fixture JSON único en
`backend/test/fixtures/fcm_n1_v9_payloads.json`; Node comprueba `fcmDataOf` y
Flutter consume los mismos `data`: legacy, penal personal/múltiples follows,
equipo sin atribución personal, titular, filtrado de scope/rol huérfano.
14backendPASS/13FlutterPASS, analyze limpio8,5s. Reglas destinatarios permanecen
backend; matchId y dedupe conservados. No FCM real ni eventos deportivos creados.

**Entradas versionables preparadas y usadas:**
`scripts/release/acceptance17.sources.json` fija432entradas SHA256, más1registrador
Flutter generado separado (no se propone versionarlo). `acceptance17.public.json`
conserva exactamente la configuración pública de la APK; sin claves privadas,
sesiones ni tokens. `verify-acceptance-inputs.mjs` y `Build-Acceptance17.ps1`:
preflight PASS, Flutter/engine, Java y Node24.20.0 fijados, pubspec.lock obligatorio, salida
existente protegida, firma QA exigida, sin deploy/install. Modo build bloqueado
si Git/entradas no están consolidados. No reconstrucción efectuada por instrucción
de no generar otra APK sin cambio funcional; **no se afirma reproducción binaria**.
El script oficial de Play16 permanece intacto; no reutilizarlo con flags antiguos
para declarar validada esta candidata.

Inventario actual:19entradas requeridas sin seguimiento y78modificadas frente
aHEAD;67entradas textuales difieren en EOL respecto aLF. No se normaliza ni
sobrescribe el trabajo. Gate estricto devuelve1 correctamente. Archivo preservado
`source-closure-frozen-inputs.zip` (433entradas+manifiesto,6,18MB sin DB/keystore/
tokens); inventario e instrucciones exactas de paths en
`artifacts/source-closure-integration-paths.txt`. **Nunca `git add .`**: artefactos,
credenciales, instalaciones y trabajos únicos externos quedan fuera.

**Otros kits productivos por conciliar con Claude:** el ledgerDONE identifica
D1v2/K2/PL1/PO1/N1/W2/PO2/Q429/BE18b yG3. Se contrastaron19fuentes candidatas:
18archivos sin blob exacto enHEAD/main ni refs locales examinadas; ruta BE14
requiere localización por Claude. G3 incluye entrypoint y6móduloslib. Esto no
demuestra ausencia semántica de sus funciones en migraciones ni ausencia en otro
clon; falta que Claude fije la fuente canónica, dependencias y baseline real.
Inventario `source-closure-production-gaps.json` con SHA y evidencia ledger,
sin copiar ni modificar kits, claves, permisos o recursos productivos.

**Plan mínimo para autorización posterior:**
1. Claude confirma el SHA v9 y mapea únicamente los kits desplegados/dependencias
   que deben respaldarse; no desplegar backend desde main antigua.
2. Revisar67EOL y fijar fuentes canónicas conservando el archivo original.
   Re-fijar inventario tras esa decisión; no prometer que cambia a mismo SHA APK.
3. Una consolidación local atómica con la lista explícita de entradas Android,
   contrato compartido y transporte v9, preservando los3commits existentes y
   excluyendo trabajos ajenos. Solo con autorización de commit, sin push implícito.
4. Desde ese Git limpio: gate estricto, focales compartidos, suite Flutter/
   contratos/goldens como compuerta única del commit congelado y build controlado;
   comparar binario/manifest/firma y registrar nuevo SHA si no coincide. La
   autorización de push/Play/despliegue se solicita separadamente cuando proceda.

**GO preparación local; NO-GO release reproducible desde Git hoy.** Bloqueos:
respaldo productivo canónico de Claude y consolidación autorizada con EOL/Git
limpios. La aceptación personal sobre APK775 y los16favoritos no se altera.

#### Cierre consolidado · 23 noviembre23:24CostaRica

**Compuertas finales PASS:**2222FlutterPASS/6skip/0fail, goldens sin actualizar,
analyze9,2s limpio;1360contratos locales,1358PASS/2TODO conocidos/0fail,
1882249ms, exit0. No archivos backend modificados durante la ejecución. El código
congelado continúa sin drift después del build/físico/contratos. Manifiesto final
actualizado con resultados, firma y SHA775CDD88. Ninguna otra APK de esta misión.
Sin nuevos P0/P1 demostrados en esta validación; cerrada la ruta comercial local.
**GO para probar los recorridos disponibles de esta candidata**, NO-GO para
aceptación integral y distribución: N1 deportivo y G3 comercial conservan las
dependencias exactas descritas debajo. No se declara Premium deshabilitado como
aceptación definitiva Premium. G2 físico previo y8fixturesQA permanecen válidos.

**APK final775CDD88 instalada en A32**, firma6533, `.qa`/17, SHA instalado exacto,
UID10356 y primera instalación intactos. 16 follows y preferencias idénticos antes/
después. Sesión Google existente preservada sin login/logout; planGratis y banner
de prueba visibles. Permiso de notificaciones sigue denegado. Cero marcadores de
excepción del proceso observado, sin afirmar ausencia global de crashes/ANR.
Fuentes congeladas sin drift; revisión de patrones privados con0coincidencias.
Inventario `consolidated-final-acceptance-source.json`; firma/manifest y evidencia
física `consolidated-final-acceptance-manifest.json`, capturas
`r4-closure-final-acceptance-home.png` / `...profile.png`.
Suite final2222PASS/6skip y analyze limpio. **Contracts cerrados PASS**, exit0.
APK anteriores conservadas, sin AAB.
No nueva prueba física Premium/G2 ni FCM; sus evidencias siguen vigentes y no se
confunden con Premium comercial o entrega deportiva. Único delta de aplicación
frente a CCF9:3archivosBilling/derechos; resto del Android consolidado intacto.

D1v2 **PASS físico y backend**, confirmado por el propietario; queda cerrada la
correlación anteriormente pendiente, sin repetir la apertura. N1 deportivo sigue
pendiente y no se sustituye su dispositivo por el A32. G2 integral, OAuth,
AdMob/UMP, redirects, Buscar y Favoritos conservan su evidencia aprobada.

Delta Android demostrado: configurar productos en una compilación no QA podía
seleccionar el adaptador histórico que concedía derechos desde Play localmente.
En la APK anterior no era activo (productos ausentes), pero no debía quedar como
ruta comercial futura. Producción ahora falla cerrada sin verificador aprobado:
fuente unavailable, compras no ofrecidas, buy directo rechazado y eventos de
compra no acknowledged localmente. El adaptador histórico solo se ejercita con
overrides explícitos en fixtures; no se duplica verificador backend.
G2 mantiene la misma fuente y transporte QA; **53 focales PASS**, más **8 pruebas
con FUTBEAT_PREMIUM_PLAY_QA=true PASS**. Incluye 403/503/aislamiento ya cubiertos;
no se repiten compras físicas. No se modifica G3/intake/RTDN.

Una suite Flutter inicial2221PASS precedió este ajuste. La suite integral de
cierre se ejecuta de nuevo por el cambio comercial relevante, secuencialmente
respecto a los focales para evitar el lock SQLite de Windows. Contracts locales
en ejecución con2 procesos; analyze limpio9,2s. Nada se publica ni despliega.
La configuración final conserva Authproducción, anuncios de prueba, OAuth y
parser N1v9; sin credenciales AuthQA ni compras reales. Premium/G2 permanece en
su variante QA aprobada del mismo código; no se declara Premium comercial PASS.
Dependencias precisas: aceptación deportiva PL1/N1 en dispositivo autorizado;
contrato/activación comercial G3 aprobados antes de integrar el verificador y
habilitar productos en la candidata pública. G3 intake permaneceOFF.

#### D1v2 apertura correlacionable / primer frame · 23 noviembre21:08CostaRica

Seguimiento independiente tras el handoff: ampliada únicamente la regresión
`match_context_first_frame_test.dart`: HTTP POSTPONED posterior se muestra aunque
la pantalla partiera LIVE/VERIFIED; un replay VERIFIED antiguo no lo revierte.
**2 casos ampliados PASS**, log `first-frame-authority-followup.log`. Ningún
defecto nuevo demostrado ni cambio de código de aplicación; único delta frente
al inventario CCF9 es ese archivo de prueba. APKCCF9, evidencia física D1v2 y
datos del A32 conservados. No se opera el teléfono, no otra apertura ni build,
sin repetir suites aprobadas. Correlación backend pendiente de respuesta Claude.

**Cierre Android21:15CostaRica:** única APKactualizada CCF9D9D5 compilada100,6s,
firma6533/paqueteQA/versión17 verificados. SHA de instalación exacto. UID10356,
primera instalación y permiso denegado intactos;16 follows/preferences exactamente
iguales al inicio. Hashes de fuente sin drift. F4A3D0EF y demás APK conservadas.
Secuencia física Alajuelense–Cartaginés03:14:08.912Z: LIVE1–0/minuto47 conservado
en capturas a0,187/0,963/1,758/2,548s, sin «Por confirmar». No es vídeo continuo
ni se alteró SQLite para forzar el defecto; caché SCHEDULED antigua tiene regresión
RED/GREEN determinista. Evidencia `first-frame-physical-sequence.json` y
`r4-closure-first-frame-live-0..3.png`, manifiesto actual. Presentación PASS en
alcance probado; **correlación D1v2 servidor continúa pendiente de Claude**.

**Apertura física online PASS sobre APKF4A3D0EF:**
`2026-11-24T03:08:19.563416Z`, St. Louis City–Los Angeles,
`fb_match_72b1d9f80f3742d59fbced14c02e988c`, LIVE3–1/minuto79 y detalle visible.
Ya había contenido disponible: no se acredita como prueba de adquisición pendiente.
`d1-final-online-evidence.json` y capturas `r4-closure-d1-final-online-*.png`.
Margen de correlación03:08:14.563Z–03:09:49.563Z. Diagnósticos saneados de90s:
3HTTPcalendar,1preview,1detail,5context; no se afirma una sola petición total.
**Claude pendiente solo lectura:** P0/expiry, decisión/atención del planificador,
wake demand sin incremento, ninguna adquisición fuera del presupuesto cron.
No se fuerza una llamada GOAL ni se ejecutan operaciones backend por Codex.
Solicitud de correlación transmitida al propietario; no hay canal Claude directo.

**Por confirmar reproducido y corregido localmente:** el primer contexto de
SQLite se emite `asStale()` y reemplazaba el snapshot LIVE ya mostrado del
calendario. Se conserva el último fixture exacto visible durante replay de caché;
HTTP posterior sigue siendo autoridad, sin reescribir estado/minuto/timestamps.
Regresión RED para LIVE y VERIFIED, luego **28 focales PASS, analyze limpio6,7s**.
Cobertura: caché antigua, corrección HTTP nueva y segundo replay tardío; no se
repite la suite completa2219PASS recién ejecutada por este cambio pequeño.
Una única actualización conjunta en compilación para validación física.

#### Consolidación de coherencia · 23 noviembre · en ejecución local

**Cierre21:05CostaRica:** una candidata conjunta compilada124,2s, firma6533 y
manifest `.qa`/17 verificados, SHA de archivo e instalación F4A3D0EF exacto.
Actualización `install -r` sin borrar datos; UID10356, primera instalación y
permiso de notificaciones denegado conservados. **16 follows y preferencias
exactamente iguales** antes/después. Fuentes congeladas sin drift posterior.
2219PASS/6skip/0fail,58focalesPASS, analyze limpio; goldens no actualizados.
No se crea AAB ni se instala en otros dispositivos. APKFD8D y demás conservadas.

Físico sobre este binario: Alajuelense–Cartaginés
`fb_match_00730aa50ea944088d5992c63c552297`, descanso1–0, gol45+3 y contexto
asentado coinciden con calendario. Levante–Elche VERIFIED1–1, goleadores62/88,
sin pestaña En vivo activa; Eventos y selección sobreviven background/resume.
Evidencias `r4-closure-coherence-*.png`, SQLitecoherence*, manifiesto actual.
Cero marcadores de excepción en log del proceso observado, sin afirmar auditoría
global de crashes/ANR. No se inyectaron respuestas tardías en producción:
su protección es PASS determinista, no PASS físico simulado.

**Pendiente concreto de presentación:** primera apertura LIVE mostró brevemente
un contexto previo «Por confirmar» antes del HTTP correcto; capturas
`coherence-live-open`/`coherence-live-settled` conservan ambas fases. No es fallo
persistente del backend ni se declara corregido; no se genera otra APK inmediata
por este detalle. GO evaluación personal con esta limitación, NO-GO distribución
mientras N1 deportivo y compuertas comerciales sigan pendientes. Sin registros
FCM, N1, producción, commits, push ni merges.

Se conserva el catchup de contexto aprobado38PASS. Segundo defecto reproducido:
`LiveMatchUpdate.applyTo` y la retención SQLite no incluían `FINISHED` entre los
finales, aunque Flutter lo presenta como finalizado. Regresión RED: FINISHED←LIVE
alteraba resultado/estado. Añadido el estado a las protecciones existentes, sin
resolver entidades ni cambiar contratos backend. Prueba ampliada HTTP/SQLite/
reinicio para FINISHED y VERIFIED conserva el resultado frente a LIVE tardío y
acepta la corrección VERIFIED posterior. 58 focales PASS, analyze limpio.
Una sola suite Flutter integral en curso antes de una candidata conjunta.
No se repiten contratos backend sin cambios de backend. A32 mantiene UID10356,
permiso de notificaciones denegado y APKFD8D hasta superar las compuertas.
Piloto N1/dispositivos ajenos no operados. Sin branches/commits/servicios remotos.

#### A32 independiente · 21 noviembre18:12 Costa Rica

Solo A32 conectado. No se sustituye el destinatario N1 ni se opera Ventana C;
ningún cambio de registro FCM, permisos, cuenta o backend. HEAD8a37e913 y WIP
previo preservados, sin commit/branch/worktree/build.

**Corrección local nueva:** reproducida con fixture la carrera donde calendario
ya tiene un cambio y la primera lectura de contexto todavía responde anterior.
La marca `_lastCalendarHead` consumía el cambio antes de verlo; una respuesta
posterior idéntica de calendario no podía recuperarlo. Eliminada esa marca: la
deduplicación compara con el contexto mostrado, mantiene bloqueo de lectura en
curso y se recupera dentro de la cadencia compartida existente. Sin otro poller,
Realtime ni llamadas GOAL. Snapshot idéntico con contexto actualizado no añade
lecturas; VERIFIED sigue protegido.

Reproducción RED registrada; corrección **38 focales PASS** y **analyze limpio**.
Logs `r4-context-catchup-repro.log`, `...tests.log`, `...analyze.log`.
Delta exacto frente a APKFD8D: `match_screen.dart` y su regresión
`d1v2_match_calendar_sync_test.dart`. **No compilada ni aceptada físicamente**:
se acumula para la próxima candidata integral; APK instalada/evidencias previas
intactas. Backups `artifacts/r4-context-catchup-before/`.

**Físico nuevo sobre FD8D:** reabrir Parma–Roma recupera FINISHED1–5,
sin pestaña En vivo activa; Eventos muestra goleadores/minutos. Malen→panel→
Ver perfil abre el jugador; volver y background/resume conservan Eventos.
Esto acredita reapertura, no observación continua del instante de finalización.
Capturas `r4-closure-independent-*.png`; SQLite before/after confirma **16 follows
y preferencias exactamente iguales**. No login/logout, compra ni notificación.
No se repiten suites completas ni los recorridos ya cerrados sin cambio relevante.

#### N1 · siguiente ventana · 21 noviembre17:50Z

**Coordinación confirmada18:08Z por mensaje de Claude transmitido por propietario:**
§35 del runbook fija Real Madrid–Celta, `fb_match_91d71f271d4b4819828f472244b4e1b9`,
SCHEDULED20:00Z, GOAL mapeado. Lectura de Claude confirma un registro FCM de la
instalación autorizada, nunca deshabilitado, cero fallos; no se extrae token.
Claude ejecuta PO2/PRE/pilot_on/cron desde19:00Z; confirmación ON esperada19:06Z.
**Codex no sigue nada hasta esa confirmación**, después sigue solo ese match
antes19:30Z. Cierre backend≤20:30Z, sin extensión. Bloqueo PRE de15 transferencias
pendientes requiere PO2 de Claude antes de ON; no se omite esa protección.
Estado actual: WAITING, sin nuevos follows/envíos/operaciones backend por Codex.

- SM-G781U1 RFCNB05YHKM: APK49310277 instalada y hash releído exacto;
  UID10355, primera instalación18nov14:25:17, permiso concedido. Perfil físico
  `alienmagiccr@gmail.com`, Google/correo confirmado. Sin cambio de cuenta,
  preferencias, instalación ni APK. A32 no se operó en esta etapa.
- Evidencia `n1-next-g781-identity.png`, `n1-next-g781-profile.png` (permiso),
  `n1-next-g781-baseline.sqlite`. Token no extraído ni mostrado. **Vigencia FCM
  servidor e installation_id actual requieren lectura de Claude**; la continuidad
  de UID no sustituye esa prueba. PL1 exclusivo pendiente de reconfirmar.
- Candidatos obtenidos solamente del calendario SQLite, sin consultas GOAL:
  `n1-next-fixture-candidates.json`. Ejemplo Sporting CP–UD da Serra,
  `fb_match_007fc36078c148f8bd26fc79cad077de`,12:00CostaRica/18:00Z;
  es solo candidato, cobertura GOAL/KICKOFF **no confirmada**, no seguido.
- Se pidió al propietario transmitir a Claude la coordinación: no hay canal
  Claude identificado en las herramientas disponibles. Claude debe seleccionar
  fixture aún programado, confirmar registro vigente/PL1/health y ventana,
  controlar pilot_on→pilot_off y confirmar follows antes del inicio real.
- Recepción KICKOFF y payload v9 se correlacionarán por notificationId/eventId/
  matchId, sin tokens. Navegación debe abrir ese Match Center online. Primer
  evento con app abierta; background/cerrada se acreditan con otros eventos
  elegibles reales, sin repetir o reenviar el mismo evento para simular cobertura.
  No usar force-stop para representar una app cerrada. Campos personales o penal
  no aplicables a KICKOFF pueden estar ausentes: no se inventan.
- **NOT_RUN deportivo**, sin activación, envíos ni cambios de seguimiento por
  Codex. La ventana anterior está vencida y no se reutiliza. Preparación local
  completada; siguiente compuerta concreta: confirmación operativa de Claude.

#### Delta D1v2 · 21 noviembre, 16:56Z · aceptación de continuidad pendiente

**Cierre Android17:29Z: PASS físico de continuidad del minuto en APKFD8D.**
Parma–Roma `fb_match_83b21acef7684d33a451a9419835c5c5`: cabecera25′→27′,
marcador0–0, sin salir del mismo Match Center ni recargar manualmente. Snapshots
de contexto y calendario coinciden; capturas `r4-closure-d1-http-match-first.png`
y `...match-tick.png`, evidencia `d1v2-http-header-physical.json`. No hubo gol:
no se acredita una transición de marcador física con esta observación. 16 follows
y preferencias permanecen exactos. La candidata FD8D queda instalada en A32;
9EF queda conservada como artefacto anterior. No se cambió el SM-G781U1/493.
La correlación backend de adquisición/cron sigue a cargo de Claude. N1 deportivo
NOT_RUN por ventana vencida; requiere nueva ventana y confirmación PL1, sin
repetir diagnóstico FCM ni atribuir un fallo a Android.

Actualización17:27Z: propietario autorizó ambas operaciones. La respuesta se
procesó17:24Z, **después del cierre17:15Z de Ventana B**; no se activó ni extendió
el piloto. N1 sigue NOT_RUN. A32 actualizado con `install -r` a FD8D7E5A;
SHA instalado exacto, UID10356 y primera instalación intactos, 16 follows y
preferencias idénticos antes/después. Validación de continuidad física en curso.

- La apertura online descrita abajo conserva PASS, pero **la continuidad LIVE de
  Match Center en APK9EF tiene FAIL físico**: Nice–PSG seguía 0–0/minuto4 mientras
  el calendario actualizado mostraba 1–0/minuto19 para el mismo ID canónico.
  Evidencia: `r4-closure-d1v2-live-later.png`,
  `r4-closure-d1v2-return-calendar.png` y SQLite de retorno. No se atribuye el
  defecto a D1v2: faltaba consumir el calendario HTTP compartido cuando Realtime
  está deshabilitado por contrato.
- Corrección local en `providers.dart` y `match_screen.dart`: escuchar el
  calendario compartido, releer contexto persistido solo ante cambios deportivos
  válidos y recuperar al volver al primer plano. Sin nuevo polling, Realtime,
  llamadas GOAL, cambios backend ni regresión de VERIFIED.
- **86 pruebas focales PASS y analyze limpio**; incluye pestaña conservada,
  snapshots repetidos/antiguos, offline, background/resume y VERIFIED. No se
  repitieron las suites completas previas; sus resultados pertenecen al cierre9EF.
- Única actualización justificada por este defecto:
  `FutBeat-1.0.0-17-consolidated-r4-d1-http-A32.apk`, SHA256
  `FD8D7E5A75BC1F94332D121A437BCACE4B33C79D335299315CA3ED7F7C9E8D17`.
  Mismo paquete, firma y versión17 del A32. **NO instalada: autorización de
  actualización solicitada y aceptación física pendientes.** APK9EF y sus datos
  siguen conservados; el piloto493 del otro teléfono no se modifica.
- N1 deportivo sigue NOT_RUN. Ventana B y confirmación servidor UUID/PL1 pendientes;
  no se infiere un PASS deportivo del catálogo de preferencias ni del diagnóstico.

#### Handoff operativo D1v2 / N1 · 21 noviembre, 16:22Z–16:30Z

- **D1v2 aplicado según Claude:** `N1-PILOT-GATES.md` §34: op16:02:32Z,
  `navigation_demands=on`, `openTriggersFetch=0`. Decisión del propietario
  «Keep D1v2»16:16Z. **K2 conserva NO-GO**, no se reclasifica. El fetch por
  prioridad dentro del cupo del cron fue aceptado; no equivale a prometer cero
  adquisiciones posteriores del planificador.
- **PASS físico de apertura online en A32**, APK9EF37A53 intacta: Nice–PSG,
  `fb_match_adc5e6c453894be9ada0944a9f5bfe83`, LIVE0–0/minuto4 recibido.
  La lista LIVE se actualizó antes de la pulsación y el objetivo real quedó
  confirmado por cabecera y snapshot, no por las coordenadas antiguas del listado.
  Datos visibles desde apertura y «Actualizando» resuelto; contexto y detalle
  persistidos. Sin cambios en follows/preferences. Capturas
  `r4-closure-d1v2-match-open.png` / `...match-settled.png`.
- **Para Claude, correlación solo lectura:** apertura iniciada
  `2026-11-21T16:22:53.145449Z`, usar margen de reloj desde16:22:48Z hasta16:24:23Z
  para ese match. `artifacts/d1v2-android-online-evidence.json` conserva diagnósticos
  saneados:1 HTTPcontext,5 HTTPdetail,1 HTTPpreview. Son peticiones FutBeat;
  las relecturas de detalle son acotadas y usan `request=0` en el cliente existente.
  **PENDIENTE Claude:** confirmar wake `demand` sin incremento, demanda/lease y
  atribución de llamadas GOAL solo al cron dentro del cupo. El log Android por sí
  solo no acredita causalidad del proveedor ni cierra ese PASS backend.
- **PASS preparación física N1-v9 en SM-G781U1 RFCNB05YHKM**, actualización
  autorizada expresamente por el propietario y aplicada con `install -r`:
  D222→49310277, mismo `.qa`, versión17, firmaF692F70E. UID10355 y primera
  instalación18nov14:25:17 conservados. Sesión Google
  `alienmagiccr@gmail.com` verificada antes/después; permiso Android concedido.
  Follows/preferences idénticos. Configuración difiere de D222 exclusivamente en
  `FUTBEAT_NOTIFICATION_SCOPES_ENABLED`; Firebasefutbeat-686af y Authproducción
  izlm permanecen iguales. BillingQA deshabilitado; no cambio de cuentas.
- **PASS físico lectura del catálogo N1:** menú jugador/equipo/partido y expansión
  Jugador con titular/suplente confirmados, gol, penal, asistencia y cobertura.
  Ningún interruptor pulsado. `n1-v9-g781-scopes.png`,
  `n1-v9-g781-player-scopes.png`, `n1-v9-g781-profile-after.png`.
  Parser v9 del APK493 coincide por hash con `push_messages.dart` actual.
- **Antes de todo envío, Claude debe reconfirmar:** usuario
  `f572a5bc-f18f-4687-918f-02fae3a696ba` + installation_id histórico
  `77c8be62-2165-447c-bf1f-ae8ee7f1f9eb`, device row histórico
  `8d5cc698-c66d-46c3-8494-b47feb7e957b`, un único destinatario PL1 y protecciones
  contra filas antiguas. La continuidad local no sustituye esa lectura servidor.
  Nunca se extrajo/guardó/mostró el token FCM.
- **Ventana B solicitada, aún no confirmada:**21nov10:45–11:15CostaRica
  (16:45–17:15Z). Activación y cierre son exclusivamente de Claude con preflight
  y autorización propios. Candidato tentativo del calendario: Lugano–Grasshoppers,
  `fb_match_119efbf97ac443b1ba20f8da694107ff`, kickoff17:00Z; sin solapamiento
  con equipos seguidos en este teléfono. **No seguido aún; cobertura GOAL no
  confirmada por Codex.** Claude debe confirmar cobertura y evento KICKOFF posible
  antes de elegirlo. Sin confirmación o al vencer ventana: no activar.
- No pilot_on/off, probes, wake, cron, envíos ni eventos artificiales por Codex.
  A32 sigue con APK9EF y permiso denegado, separado del piloto. APK493 es anterior
  a las mejoras R4: se usa únicamente para este piloto solicitado; no se presenta
  como candidata pública ni sustituye la base consolidada. No nuevas compilaciones,
  suites, cambios de código, commits, push, merge o publicaciones.

Plan actualizado en `artifacts/n1-next-acceptance-plan.json` (original conservado).
KICKOFF/equipo/jugador/dedupe/navegación desde push siguen **NOT_RUN** hasta evento
real y ventana backend confirmada. D1 UI PASS físico no se mezcla con recepción FCM.

La diferencia de fuente frente a la APK0DD1780D es exclusivamente
`features/favorites/favorites_screen.dart` y `test/favorites_hub_v2_test.dart`.
Sin cambios en servicios Android, credenciales, contratos backend ni SQLite.
No se retomaron News, Premium FPD ni ramas históricas. No se cambió HEAD ni se
crearon ramas/worktrees/commits. No operaciones Supabase/GOAL/IAM/Play.

| Componente | Integración real / corrección pendiente cubierta | Evidencia y límite |
| --- | --- | --- |
| Favoritos incompletos | CORREGIDO: respuesta exitosa sin metadatos ya no afirma que no se sigue a nadie. Conserva una fila guardada, cuenta canónica, ruta de perfil y recuperación manual; no fabrica una entidad. | Regresión que fallaba antes del cambio; jugador/equipo/competición y homónimos cubiertos. Caso parcial y503 son deterministas, no se indujeron fallos productivos. |
| Actualización de Favoritos | CORREGIDO: gesto de actualizar en las tres listas, incluso cortas; conserva datos durante fallo y permite recuperar cambios del servidor sin borrar caché. | PASS físico A32: saved_at de la caché pasó1795249412→1795249431. `r4-closure-refresh-evidence.json`, capturas `r4-closure-players-refresh.png` y `...competitions-refreshed.png`. |
| IDs canónicos / PID-1 | CORREGIDO cliente: próximo rival del equipo seguido usa el resolver existente cuando el fixture referencia un alias. Metadatos de club recibidos se muestran aunque falte el objeto de equipo. Sin resolver por nombres. | PASS automático: next-match alias, clubName y perfiles sin reescritura. PASS físico: redirect oficial `fb_player_298d8e7894304a639577f46f218c6229`→`fb_player_0bb3b4c64a8f4aca9b45df7e9dd03509`, perfil y reapertura. Los dos Messi con IDs diferentes se conservan para PID-1. |
| Onboarding, OAuth, invitado, sesiones y eliminación | INTEGRADOS, sin diferencia de fuente respecto a R4 validada. | Suite integral PASS. Evidencia física previa conservada; no se crearon cuentas ni se cambió la sesión invitada del A32. |
| Calendario, LIVE, Match Center, cancha, suplentes, perfiles y SQLite | INTEGRADOS, sin cambios de código en esta misión. No se inventan ratings ni alineaciones; tablas/H2H siguen sujetos a cobertura y fase oficial. | Suite integral y goldens PASS. Evidencia física previa programado/finalizado conservada. Nuevo filtro LIVE físico: no había partidos; no se acredita PASS LIVE ni se fabricó uno. D1v2 y adquisición son de Claude. |
| FCMv9 / N1 | INTEGRADO cliente, campos opcionales y ciclo de vida preservados; piloto existente preparado. | Focales N1 incluidos en54PASS y suite completa. Diagnóstico físico anterior conservado. Entrega deportiva aún requiere dispositivoSM-G781U1 y ventana PL1 autorizada de Claude; ningún envío/activación/registro piloto por esta misión. A32 mantiene permiso denegado. |
| Gratis / AdMob / UMP | INTEGRADOS y sin cambios. Anuncios de prueba, sin nuevas unidades. | PASS físico previo conservado; banner de prueba visible en el binario nuevo, no se pulsó. No se repitió consentimiento ni se borraron preferencias. |
| Billing / G2 / Premium | INTEGRADOS, mismo código aprobado. Sin otro verificador ni mezcla AuthQA/producción. | G2 QA físico previo A3/A5/A7 conservado, sin nuevas compras. G3 comercial permanece sujeto a Claude/intake y autorizaciones; no se acredita Premium productivo desde esta QA. |

PASS físico de actualización-r, navegación Favoritos→perfil de Jeyland y
reapertura. UID10356 y primera instalación20nov00:17:35 sin cambios; SQLite
integrity_check=ok, follows y preferences idénticos al baseline16. No toggles de
favoritos en esta misión. `r4-closure-data-preservation.json` y capturas
`r4-closure-players-reopen-confirmed.png` / `r4-closure-player-profile.png`.
UIAutomator no obtuvo árbol al primer arranque; se usaron capturas ADB directas
con comprobación de paquete en primer plano, sin reutilizar XML viejo ni tocar
la otra aplicación del propietario. No es un crash de FutBeat demostrado.

GO evaluación personal de QA; NO-GO publicación/Alpha: recepción deportiva,
LIVE físico disponible y compuertas comerciales aún no acreditadas. No se generó
AAB. La fuente completa se conserva por hashes; no se afirma que HEAD8a37e913
contenga por sí solo estas correcciones sin commit.

Cierre02:42CST: contracts1358PASS/2TODO/0fail, Flutter2217PASS/6skip/0fail,
analyze limpio4,7s. Firma/manifest/paquete y SHA del APK instalado PASS; configuración
idéntica a0DD1780D. Source guard completo PASS después del físico. SQLite/follows/
preferences PASS; cero marcadores fatales del proceso observado tras reapertura.
`r4-closure-local.patch` conserva únicamente la diferencia de esta misión; backups
anteriores intactos. Fallos iniciales del ejecutor por memoria/archivos bloqueados
se resolvieron retirando procesos propios/huérfanos y acotando concurrencia, sin
debilitar pruebas ni detener la compilación ajena. No se interpreta ese problema
del host ni UIAutomator como fallo Android demostrado.

No se encontró otro P0/P1 Android reproducible en los recorridos afectados tras
las correcciones. Esto no sustituye la aceptación integral N1/comercial ni certifica
datos de proveedor ausentes. Claude conserva PID-1, D1v2/cobertura, N1/PL1 y G3/RTDN.
Handoff focal: la lectura normal `/v1/favorites` ya devuelve el redirect298d8e→0bb3b4;
los dos IDs64a9f8/b8c148 de Messi continúan separados en la respuesta observada.
Se mantienen así hasta que PID-1 entregue evidencia/redirect, sin fusión por nombre.
Escorpiones–San Carlos y separación de Arsenal se conservan como cierres físicos
aceptados por el propietario, sin repetirlos ni reabrir las observaciones antiguas.

### R4 · pestañas canónicas y jugadores repetidos · 20 noviembre, cierre 22:58 CST

| Defecto | Causa y corrección en la única base local | Pruebas y evidencia | Estado / dependencia |
| --- | --- | --- | --- |
| Prepartido mostraba En vivo/Estadísticas | `match_screen.dart` construía siempre seis pestañas. Ahora usa estado canónico: SCHEDULED/NOT_STARTED/POSTPONED/CANCELLED sin Live ni estadísticas del partido; LIVE/HALFTIME conservan ambas; FINISHED/VERIFIED muestran Eventos históricos y estadísticas. La hora no decide LIVE. | A32: Leverkusen–Paderborn programado, cuatro pestañas; Bayern–Köln finalizado, Eventos y estadísticas históricas. `r4-arsenal-tabs-search-scheduled-pass.png`, `...finished-pass.png`, `...finished-statistics.png`. | CORREGIDO; PASS físico programado/finalizado. LIVE físico pendiente: filtro actual informa sin partidos LIVE; no se fabricó un estado. |
| Transición de estado con pestaña seleccionada | Selección por identidad lógica, reemplazo seguro de controlador y pager cuando cambia la estructura; sección retirada vuelve a Hechos/Previa. | `r4_canonical_match_tabs_test.dart`: ocho estados, cambios rápidos y cancelación durante animación. H2H y estadísticas mantienen selección cuando siguen disponibles. | CORREGIDO; PASS automatizado. |
| Mismo ID de jugador repetido o incompleto | Snapshot conservaba duplicados y lookup podía apuntar a otra fila; la combinación de sugerencias retenía primero el registro pobre. Deduplicación exacta por ID, registro completo sin mezclar atributos ni fusionar nombres. | `r4_player_search_identity_test.dart`, regresiones autocomplete/perfiles/favoritos en suite. A32: Carole → perfil `fb_player_582d0253d9424a5296b742823b2e552d` → favorito → reinicio; se retiró únicamente ese favorito temporal. | CORREGIDO en cliente; 16 favoritos y preferencias iniciales idénticos al cierre. |
| Nombres repetidos con IDs diferentes | Respuesta real `/v1/search?q=lionel&country=CR` entrega dos Lionel Messi: `fb_player_64a9f8e1de324cc68248168ddd094b7b` (team `fb_team_8b67fe4af6834ddeb7bfac5881e2628c`) y `fb_player_b8c1482cb4b441dab8acecb2e1f83b70` (sin team). La respuesta no entrega IDs de proveedor, posición ni nacimiento para adjudicarlos. También hay Messi/Messias con IDs distintos. No hay IDs canónicos repetidos en las dos respuestas de 37 jugadores. | `artifacts/r4-search-player-evidence.json`, cuerpos públicos `r4-search-lionel-public.json` / `r4-search-messi-public.json`; favoritos físicos conservan los dos IDs ya elegidos por el propietario. | BLOQUEADO POR DATOS: Claude debe verificar identidad/proveedor y aportar club/posición u otra desambiguación; redirect canónico únicamente con evidencia. No se fusionó por nombre ni se alteró Supabase. |

Las tres referencias visuales de alineaciones solo cambian el título histórico
Eventos y el espaciado correspondiente; se revisaron antes de conservarlas. El
primer intento de ejecutar pruebas focales en paralelo con la suite no pudo
acceder a sqlite3.dll; se repitió secuencialmente tras terminar, con 42PASS. No hubo
fallo del producto por ese bloqueo local. Configuración OAuth/FCM/Billing/AdMob
idéntica a D474; permiso de notificaciones del A32 sigue denegado. Sin operaciones
backend, commit, push, merge, AAB ni publicación. Inventario exacto y resultado
físico en `artifacts/consolidated-r4-tabs-search-manifest.json`.

## Histórico inicial de integración (superado)

Referencia antigua, NO instrucción vigente: se usó `codex/android-commercial-qa` en `artifacts/android-commercial-qa`. El checkout comercial y la RC pertenecían a un repositorio Git superficial independiente del checkout principal. El código de Billing, FPD y sus pruebas locales se conservaba fuera del alcance de aquella salida gratuita. Aquella configuración mantenía compras, anuncios, Facebook, push y FPD apagados. Sus compuertas se conservan como evidencia histórica, no como configuración de R4.

| Componente | Ubicación | Estado | Integrado | Pruebas | Acción |
| --- | --- | --- | --- | --- | --- |
| main remoto y local | Repositorio principal | LISTO | Remoto e3e6e29b; local 4dccfe5c es su padre | git ls-remote y git show | Mantener protegidos |
| PR Android #248 | aa5b5d115f1ebc913bcb5ed70afd3acbf72414d6 | REQUIERE CORRECCIÓN | Abierta; base remota e3e6e29b, 482 commits adelante y 0 detrás según GitHub | Mobile y rc-focal PASS; Contracts FAIL | Evaluar contratos sobre candidata exacta |
| RC deportiva | codex/rc248-local-candidate en rc248-reconcile, 13919679cc49426f9a133db2edc3822dab1a9c7a | LISTO PARA INTEGRAR | Ancestro del worktree comercial, once commits sobre #248 | Antecedentes físicos OAuth, favoritos, Match Center, offline y R05; obligatoria validación del binario final | Usar como referencia y conservar checkout |
| UTC PR #242 | a19080f1 y 3c65b46 | LISTO | Ambos tienen patch-id estable f72c09f7e6f5bd2a73bdba1298383df964be4413 | Comparación local | Incorporado en la RC; omitir duplicado |
| PR #243–245 y #234–235 | Cadenas Android históricas abiertas | POSPONIBLE | Sin equivalencia completa confirmada | Inventario GitHub | Comparar por defecto concreto antes de traer parches |
| PR #246–247 | Preview offline y pasiva | POSPONIBLE | Abiertas | Inventario GitHub | Fuera del recorrido gratuito normal |
| PR #233 y #236–241 | LIVE, tablas, calendario, cuotas y API | POSPONIBLE | Abiertas; no se asumió equivalencia | Inventario GitHub | Comparar solo si aparece defecto sobre RC |
| PR #7, #47, #219 | Backend histórico y limpieza | POSPONIBLE | Abiertas | Inventario GitHub | Preservar |
| Claude BE11 PR #249 | b6a8b13768618b290d37924155d6b52ef883db16 | POSPONIBLE | Abierta; no requerida para compilar | Estado de PR | Claude controla integración y despliegue |
| BE14 SQL / Edge / republicación | F:/FutBeat/recovery-03/be14; worktrees be14-contract y be14-edge | BLOQUEADO | SQL GREEN 24h según handoff; Edge y backfill sujetos a compuertas | Regresiones Android VERIFIED y correcciones tardías | Esperar autorización específica y compatibilidad del binario distribuido antes de republicar |
| UMP / anuncios | Worktree comercial, 6d14521 y cambios locales | POSPONIBLE | UMP probado en QA; configuración Internal actual sin anuncios | Antecedente físico UMP y banner de prueba | Conservar separado del primer artefacto gratuito |
| Billing y FPD | Worktree comercial y worktree premium-fpd de Claude | BLOQUEADO | QA y prototipo local; release sin gateway; FPD apagado | Revocación QA aprobada; staging TLS y PostgreSQL real pendientes | Reservar para versión posterior con autorización |
| Visibilidad Premium | commit 7ef08871f6dcf10004a424540302bf8a7716cbae | LISTO | Perfil y ruta protegidos por gateway y catálogo | analyze limpio; 170 focales | Validar en APK deportiva integrada |
| Firma Play | FUTBEAT-1.0-UPLOAD-ACTIVATION.md | BLOQUEADO | Activación prevista 26 nov 2026, estado actual sin confirmar | AAB de inspección anterior utiliza otra clave | Verificar certificado activo y versionCode disponible en Play |

### Inventario Git y límites

El repositorio principal registra 247 worktrees, 232 asociados a ramas y 15 detached. El repositorio superficial de la RC registra cuatro worktrees adicionales: RC, comercial y dos snapshots detached de aa5b5d1. Se preservan todos. El checkout principal está en fix/calendar-day-subbatches y tiene trabajo sin seguimiento. La RC presenta utilidades y artefactos locales sin seguimiento. El worktree comercial conserva cambios rastreados y prototipos nuevos en Android, Billing, Premium FPD y backend. Solo se versionó la corrección de las dos pantallas. La comparación del remoto con PR #248 se obtuvo de GitHub porque el límite superficial de aa5b5d1 impide resolver merge-base local. No se certificó equivalencia de cada rama archivada ni se incorporaron parches adicionales.

### Dependencias, orden y rollback

1. Validar la candidata gratuita con API deportiva existente, sesión de usuario, OAuth y R05. Confirmar la configuración pública y el aislamiento del paquete QA.
2. Acreditar Flutter, Contracts y recorrido físico sobre el artefacto exacto. Resolver discrepancias antes de firmar.
3. Verificar target 36 o superior en el manifiesto, App Links con certificado de distribución, OAuth release, política de privacidad, eliminación y declaraciones Play.
4. Cotejar huella completa de upload activa y disponibilidad del versionCode. Ejecutar Build-FutBeatOfficial.ps1 desde un snapshot limpio verificable. Someter AAB a inspección de firma, manifiesto y SHA. Solicitar autorización de subida tras entregar el artefacto.
5. Instalar la versión que entregue Internal Testing y verificar recepción de VERIFIED antes de considerar republicación. Promoción requiere aprobación independiente.

Si falla la integración local, revertir únicamente el commit de interfaz en la rama comercial. Conservar la RC, los cambios locales de Billing y los artefactos identificados. Para Play, detener la promoción o rollout y preparar una compilación correctiva con código superior si ya se distribuyó. Las operaciones BE14 tienen rollback independiente bajo Claude.

| Hito | Estado | Evidencia | Bloqueo | Próxima acción |
| --- | --- | --- | --- | --- |
| M1 | En curso | Inventario, ramas clave, PR, CI, comparación y patch-id | Equivalencias históricas pendientes de relevancia concreta | Revisar solo dependencias que condicionen 1.0 |
| M2 | En curso | Corrección Premium versionada y 170 focales PASS | Contracts remoto FAIL, árbol comercial contiene trabajo pendiente | Validar y aislar insumos exactos de la candidata |
| M3 | En curso | A32 autorizado visible vía ADB; antecedentes deportivos | Recorrido completo pendiente sobre APK integrada | Compilar, verificar y probar la variante aislada |
| M4 | Bloqueado | Procedimiento de firma y config pública con SHA registrado | Certificado activo y código 16 por confirmar; falta aceptación exacta | Verificar Play y firmar únicamente al pasar las compuertas |
| M5 | Bloqueado | Paquete com.futbeat.futbeat documentado | AAB oficial y autorización de primera subida | Internal Testing y prueba de binario distribuido |
| M6 | Bloqueado | Health BE14 SQL histórico GREEN | Aceptación Internal Testing y autorización de publicación | Rollout supervisado y métricas |

### Evidencia de aceptación en curso

- APK universal local: artifacts/FutBeat-1.0-integration-qa.apk, SHA-256 B216DCA0679A3418F683F9353E46E023FB854370D0CDBDF39C180EAFFE4BBAF1. Paquete com.futbeat.futbeat.qa, 1.0.0 (16), target 36, firma debug SHA-256 6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362, callback QA presente. Es diagnóstico del árbol comercial con cambios locales; el diff rastreado sobre HEAD se identificó con d7f2d13c51bd5ed855eb52af998499f15cc05267 y no identifica archivos sin seguimiento. No acredita aún un snapshot release reproducible.
- Flutter analyze limpio, 170 focales y seis goldens PASS. La primera suite completa concurrente se interrumpió tras un crash JIT de Flutter. Reintento serial en curso. Contracts rastreados en ejecución; el primer fallo de caché histórico pasó al repetirlo en aislamiento. Los demás fallos aún requieren clasificación.
- A32: el paquete QA no estaba instalado. Streaming no completó; la transferencia no streaming avanzó de 5,9 a 30,7 MB sin modificar los otros paquetes. Se inició compilación arm64 para reducir la transferencia.
- El AAB de inspección 99A1A5AA2C2A585A9AC18823DA7D8910F12AF4E18470F33A323DB7B1A7C469E4 corresponde a 5663cc6 y una clave anterior. No acredita la línea actual. El APK QA sí cumple el target API 36 exigido por Google Play desde agosto de 2026.
- Checkpoint de esta ejecución: segunda compilación arm64 sin split produjo un APK de tamaño comparable al universal. Se inició un split por ABI para abordar la transferencia. La suite serial superó el punto de caída JIT; Contracts mostró otros fallos aún sin diagnóstico definitivo. Mantener M2 y M3 abiertos hasta que terminen las pruebas y el A32 complete el recorrido.

### Continuación de APK y release

- Snapshot fuente extraído con git archive desde 20c39ec8c982a6e7498362bfb59890bb2489f618, sin cambios locales de Billing o FPD. Configuración pública de Internal previamente aprobada, Flutter pub offline y split arm64 de SDK 36. APK deportiva FutBeat-1.0-20c39ec-qa-arm64.apk SHA-256 6276C506C0FFF87D340CDDA52C1D5677412B140D5D49AC9CBCAE89566CC3C047. Paquete com.futbeat.futbeat.qa, 1.0.0 (2016), firma debug y callback QA comprobados. El código 2016 es el ajuste del split y el AAB oficial base conserva 16. El A32 instaló y devolvió el mismo SHA.
- Android cerró QA con USB incluso usando am start directo. exit-info identifica USER REQUESTED / FORCE STOP y PIDs emisores distintos del proceso FutBeat. wait_for_debugger=0 y debug_app=null. El muestreo no capturó la identidad del emisor. El propietario confirmó que la primera APK de aceptación permanece abierta sin USB. No cambiar aplicación ni controles Android hasta identificar el emisor. Recorrido esencial pendiente sobre el binario exacto.
- Suite serial del árbol de trabajo: 2.105 PASS, 6 SKIP, 0 FAIL. El árbol limpio pasó analyze. Contracts anterior: 1.312 PASS, 8 FAIL, 1 SKIP, 2 TODO. Siete fallos de memoria inicializando PGlite y uno por ID FPD no versionado. Reintento de ocho archivos sobre snapshot limpio en serie: 56 PASS, 0 FAIL. Suite completa del snapshot en curso.
- Publicidad QA: FutBeat-1.0-20c39ec-ads-qa-arm64.apk, com.futbeat.futbeat.commercialqa 1.0.0 (2016), SHA-256 5E8FD8C1731B20866E6A82FED7453ACD739035093F5E3EA81756AC861CA3FF52. App ID existente en manifiesto, UMP y banner de prueba, catálogo Premium ausente. Falta aceptación física del binario. app-ads.txt HTTP 200 y línea esperada. App Links HTTP 200 y entrada de paquete oficial con dos huellas; pendiente cotejo contra Play.
- AAB de inspección del snapshot: FutBeat-1.0-20c39ec-inspection-NOT-FOR-PLAY.aab, SHA-256 6C4B4444B8376C4782587BFC57F634CEB78B0479BED6853F85A685A0E8B3E56A. Validado con bundletool y jarsigner, firma temporal de inspección eliminada, com.futbeat.futbeat 1.0.0 (16), target 36, min 24, OAuth oficial y enlace /auth/reset. Configuración sin anuncios ni Premium. Firma upload activa y disponibilidad de 16 todavía no confirmadas en Play.
- Dependencias de Claude: BE18 dry OK sin cambio a 11:47 CST del 14 nov; BE17 informe local no aplicado. BE14 Edge sigue separado. No usar los pendientes deportivos de backend como defectos Android sin correlación de evidencia.

### Reconciliación de News 131 y Release 130 del 17 de noviembre

Referencia remota actualizada mediante fetch de `https://github.com/henguido/FutBeat`:
`origin/main` = `6e10d3c83eed80c34db28ac14aa21af6bc1f81d1`.
La versión distribuida de referencia es 1.0.0 (16) de Internal Testing.

Los dos worktrees bajo `F:/Bottrading/bot-trading-platform/.worktrees`
comparten el Git common dir `.futbeat-r130-control/.git`. Su remoto
`origin` apunta a `F:/FutBeat/FutBeat/artifacts/release130-work`, una copia
local sin remoto configurado. Comparten con main el ancestro `6a6a34e`.
Por contenido e historia pertenecen a la línea FutBeat, pero esos worktrees
no están vinculados directamente al remoto GitHub consolidado. Ambos estaban
limpios al revisarlos. Se importaron sus objetos para comparar sin crear ramas.

| Commit | Decisión | Diferencias y dependencias |
| --- | --- | --- |
| `517c8cde023ff1ffd43354edb990130990f51156` | NO-GO de integración; conservar aislado | Tres archivos exclusivos sobre su padre: evita duplicar imagen principal, distingue fuente propia/externa y añade copia de enlace YouTube. Depende de `9bb22cb`, que añade helpers, flags y superficies experimentales. La base común es R130, anterior a main. Integrar la rama completa degradaría cambios posteriores de derechos, caché, sesiones y Match Center. Los cuatro flags siguen false por defecto. |
| `955549d3` | GO parcial documental; NO-GO de cherry-pick íntegro | Añade solo una ficha Play de 99 líneas. La descripción, declaraciones y capturas se solapan con los documentos Play ya presentes. Se trasladaron las instrucciones útiles de acceso de revisión y procedencia de capturas a `PLAY-130-STORE-ES.md`. Se corrigió la referencia obsoleta a versionCode 5 en `PLAY-130-PREPARATION.md`. Conservar la descripción actual como borrador sujeto al binario distribuido y a Console. |

El padre CI `cfb862b` ya pertenece a main, junto con la corrección posterior
`5a6551c9`. El workflow `release-130-flutter.yml` ya no está en main:
la candidata antigua lo introduce de nuevo con `workflow_dispatch`, mientras
el documento actual describe el trigger corregido por push de rama. Esa CI
prueba el snapshot R130 antiguo y no acredita el binario distribuido. El push
de esa rama y su arranque manual requieren reevaluar el procedimiento actual
antes de pedir autorización. Esta reconciliación prepara cambios documentales.

Validación focal del contenido de News 131 mediante helpers/adaptador extraídos
del commit exacto, con el mismo validador de URL y un alias local del tipo Json.
Se comprueban flags por defecto apagados, eliminación de medios con flags
apagados y restricciones de URL YouTube. Se reproducen los dos bloqueos
ya documentados: caducidad malformada aceptada y subject match descartado.
El commit `517c8cd` conserva ambos. El arreglo posterior `5997ee1`
registrado en `NEWS-131-PREINTEGRATION-REVIEW.md` no es ancestro de ese
commit y debe reconciliarse antes de integrar News. También siguen pendientes
revocación/expiración de medios y coherencia del subflag YouTube.

Resultado de esta revisión: seis comprobaciones Dart directas PASS, dos de
ellas reproducen los bloqueos para activación. Verificación documental de
versión, acceso de revisión y límite de descripción corta, más
`git diff --check`. Los widgets exclusivos de News quedan pendientes de
ejecución en su candidata reconciliada. La preparación aplicada aquí contiene
solo documentación.

No se autoriza integración de News ni activación de flags. La preparación
Play requiere confirmar datos de soporte, audiencia, países, declaraciones,
capturas y acceso de revisión en Console. Los cambios de este cierre quedan
locales en los documentos existentes.

### LIVE cerrado en producción y Play 16 — 17 de noviembre, CST

Operación `calendar-provider-observation-20261117`, autorizada expresamente
en este chat para los 30 minutos siguientes a la respuesta del propietario.
Aplicado exclusivamente `calendar_provider_observation_apply.sql`.
MD5 del constructor antes `32bf38b60517131a23a4fec6ee2dfea6`, después
`201d1f20cdb9eed211ae4ac8a4d15d45`. El candidato coincidió antes de DDL;
propietario, permisos, RPC y read model conservaron sus firmas. Registro
compartido reservado, sin operación concurrente. Rollback exacto disponible.
Health de entrada y salida con cero clientes incompatibles, leases y cola.
REST 200 en cinco sondas y PGRST002 0/5. Cinco mediciones posteriores de
calendario dieron 200 entre 247 y 521 ms. Las siete observaciones del snapshot
coincidieron con el estado/minuto/marcador registrado del proveedor.
La renovación natural de caché expuso las siete marcas sin intervención sobre
estados deportivos.

Galaxy A32 `RF8R32GQWGL`, paquete `com.futbeat.futbeat`, 1.0.0 (16),
instalador `com.android.vending`: PASS físico. LIVE reciente sin aviso falso;
en desconexión controlada apareció «LIVE sin sincronizar» al superar los
15 minutos. Caché y marcadores se conservaron al salir y reabrir.
Se restauraron Wi-Fi y datos a su estado inicial. La reconexión retiró los
avisos y actualizó Ecuador 60′→69′ y Uruguay 2–0/73′→3–0/85′.
Chile–Colombia pasó de LIVE a Finalizado 0–0 en el teléfono tras observación
GOAL FINISHED de las 19:11:03 CST. El proceso permaneció estable y el muestreo
de logs no mostró excepciones fatales. Evidencia local en
`artifacts/live-a32-active.png`, `live-a32-stale.png`,
`live-a32-reconnected.png` y `live-a32-final-found.png`.
El método exacto de frescura del commit distribuido pasó con siete filas
recientes, las mismas siete envejecidas y supresión en estado VERIFIED.

Granada figura VERIFIED 1–0 y Letonia VERIFIED 0–0 en canónico, proyección y
calendario; ambas recuperaciones están RESOLVED y existe evidencia terminal
persistida. Granada corrigió el 1–1 provisional a 1–0. Los casos de revisión
VERIFIED tardía tienen las regresiones locales ya aprobadas. El parche de
retención de Granada queda como candidato local sin aplicar.

E1 y E2 cerrados para esta corrección de backend. E3 satisfecho con Play 16,
sin actualización Android ni AAB nuevo. HEAD fuente sigue en `6e10d3c8`;
las correcciones Android locales anteriores quedan fuera del despliegue.
Para ampliar distribución quedan la aprobación del propietario del canal y
el cierre efectivo en Play Console de los requisitos de publicación que
correspondan (ficha, acceso de revisión y declaraciones). No se amplió el canal.

### Siguiente canal confirmado en Play Console

Lectura autenticada posterior al cierre LIVE: Internal activo con versión
16 (1.0.0), disponible desde el 15 de noviembre a las 10:21, sin revisión.
Lista interna seleccionada: FutBeat QA Personal (2 usuarios); License Testers
(2 usuarios) sin seleccionar. Main y origin/main, tras fetch, siguen en
`6e10d3c83eed80c34db28ac14aa21af6bc1f81d1`. Las cuatro capturas LIVE
de la operación DONE se conservan con sus archivos originales.

Destino recomendado: **Prueba cerrada — Alpha**, track
`4698645232280397939`. Está inactivo, con cero tareas de configuración
completadas, sin países y con ambas listas de testers existentes sin
seleccionar. El menú de promoción de la versión 16 permite prueba cerrada.
Prueba abierta y producción están deshabilitadas por falta de acceso a
producción. El panel exige al menos 12 testers inscritos durante 14 días
continuos para solicitar acceso; registra 0 inscritos actualmente.

La ficha predeterminada está lista para revisión, con es-419 y en-US,
icono, gráfico destacado y dos capturas de teléfono. Español usa FutBeat;
inglés tiene el error guardado **FtuBeat**, pendiente de corrección autorizada.
Las 11 declaraciones aparecen completadas y listas para enviar: Data Safety,
privacidad, acceso, anuncios/ID, audiencia y clasificación entre ellas.
Privacidad guardada: `https://futbeat.com/privacidad.html`, HTTP 200.
Audiencia declarada 16+; clasificación IARC con ESRB para todos, PEGI 3 y
genérica 3+. Esto acredita los campos guardados, no su aprobación por Google.
El resumen tiene 10 cambios sin enviar y publicación gestionada desactivada.
Tras aprobación de Google los cambios enviados pueden publicarse
automáticamente. No se enviaron cambios en esta tarea.

Android vitals: últimos 28 días sin clústeres de fallos/ANR, tanto con el
filtro de percibidos como sin él. Última actualización indicada hoy a las
02:00. No hay tasas agregadas visibles para acreditar estabilidad a escala.
No apareció una incidencia de políticas; Console indica que el estado se
mostrará cuando revise la app. El ticket P1 #220 sigue abierto: es de la
versión +4, con implementación y regresión local registradas, y aceptación
física específica pendiente en la matriz. No certificar cero P1 abiertos.
La ampliación controlada Alpha puede recoger esa aceptación; producción
requiere resolver la disposición del ticket además de los requisitos Play.

Decisión: **GO técnico para usar el AAB 16 en Alpha; NO-GO de ejecución**
hasta autorización y definición por el propietario de países, lista de
testers y canal de comentarios. La operación propuesta es corregir el
nombre inglés a FutBeat, configurar esos datos aprobados, promover la
versión interna 16 al track Alpha existente, revisar el conjunto exacto de
cambios y enviarlo a Google para revisión/publicación exclusiva en Alpha.
Usar el AAB existente. Se necesita autorización expresa para esa operación,
incluida la publicación en Alpha tras revisión. No abarca producción,
prueba abierta, una nueva compilación ni activación comercial.

### Preparación final Alpha — 17/18 noviembre 2026

Resultado ejecutado: nombre en-US corregido de FtuBeat a FutBeat y guardado
sin envío. Costa Rica, confirmado por el propietario, guardado como único
país Alpha. Creado y guardado borrador release 1 del track
4698645232280397939 con el App Bundle existente 16 (1.0.0), SDK objetivo 36,
API 24+, sin subir ni compilar otro binario. Notas es-419/en-US conservadoras.
Console muestra explícitamente Borrador. Evidencia: artifacts/alpha16-draft.jpg.

#220: solicitud de agrupación de favoritos de la versión +4. No afecta
seguridad, estabilidad ni acceso al recorrido esencial. La prueba focal
`#220: favorites from two leagues remain once in each league` pasó 1/1.
El test y matches_screen.dart coinciden con HEAD aprobado. GO para reutilizar
AAB 16 en Alpha; issue sigue abierto, sin afirmar aceptación física específica.

Revisadas las once declaraciones guardadas. Finanzas y salud: ninguna función;
gobierno: No; operador: Sí heredado de cuenta; audiencia: 16-17 y 18+;
IARC completado (genérica 3+, PEGI 3, ESRB todos); privacidad y acceso para
revisión presentes. Esto no equivale a aprobación Google ni validación de
credenciales de revisión en esta tarea.

NO-GO para enviar todavía: Data Safety deja OAuth sin marcar aunque AAB 16
permite Google OAuth. Declara ubicación aproximada, diagnósticos, actividad
e IDs compartidos y finalidad publicitaria; anuncios está en Sí y AD_ID en
Sí/publicidad, mientras la configuración oficial 16 deshabilita anuncios.
AD_ID está presente en manifiesto y Console exige Sí o retirarlo: conservarlo,
no cambiar el binario. Revisar/corregir OAuth y coherencia de anuncios y
tratamiento efectivo antes del envío; no se alteraron estas declaraciones.
Premium, push y Facebook deshabilitados no deben describirse como activos.

Datos del propietario pendientes: lista/grupo de cuentas Google para Alpha
(ninguna lista seleccionada; dos listas existentes de 2 usuarios cada una),
y correo/URL oficial de comentarios. Costa Rica no confirma el uso de
support@futbeat.com. No se inventaron ni agregaron cuentas o contactos.

Comunicación para testers preparada, no enviada: salir de Internal Testing
https://play.google.com/apps/internaltest/4701158343688912794 con la misma
cuenta Google y luego inscribirse a Alpha mediante
https://play.google.com/apps/testing/com.futbeat.futbeat cuando esté activo.
Propietario debe confirmar distribución de estas instrucciones. El mínimo
mostrado por Console es 12 inscritos durante 14 días continuos; las listas
actuales no acreditan ese mínimo ni que los usuarios conozcan el cambio.

No se envió a revisión, no se activó Alpha y no se tocó producción pública.
Con publicación gestionada desactivada, los cambios que se envíen y Google
apruebe pueden publicarse automáticamente, incluida disponibilidad Alpha
para los testers elegibles y países seleccionados. Revisar el lote completo
pendiente antes de autorizar envío. No cambia acceso a producción pública.

### Integración de notificaciones previa a Alpha — 17 noviembre 2026

Alpha detenido por la nueva decisión de producto: push funcional obligatorio.
No se vuelve a abrir el defecto providerObservedAt ni se cambia Play 16.

Implementado localmente N1 Flutter sobre PushService existente: lectura de
futbeat_read_notification_scopes y merge por futbeat_set_notification_scopes,
matriz player/team/match con cobertura y elección explícita, reset null,
pantalla independiente desde Notificaciones. Cola durable en secure storage
por UID, escrituras serializadas, refresh de sesión y descarte de respuestas
tras cambio de cuenta. Reintento en reconciliación/reconexión, eliminación
de pendientes al borrar cuenta. No escribe notify_* ni crea seguimientos.
FUTBEAT_NOTIFICATION_SCOPES_ENABLED sigue false por defecto. No se alteran
kits de Claude, cuotas, fuentes ni polling del teléfono hacia GOAL.

Reutilizados registro/rotación/revocación FCM, permisos Android/canal,
banner foreground, apertura background/terminated y Match Center existentes.
No afirmar recepción real a partir de estos contratos locales.

Lectura productiva autorizada 2026-11-18T02:40:27Z (17/11 CST): push_settings
mode=dry_run, N1 read/write RPC ausentes, 2 dispositivos FCM, 132 outbox pending,
más antiguo 2026-10-05T01:56:09Z. Ninguna escritura de datos/configuración.
No activar global con esta cola sin revisión operativa del claim y vencimiento.
Inventario de secretos Edge no confirmado: MCP y CLI fallaron por transporte;
no insistir con el mismo método ni inferir ausencia de credenciales remotas.

Firebase existente confirmado por consola autenticada: futbeat-686af,
remitente 438739446086, Android com.futbeat.futbeat registrado, API FCM V1
habilitada, Spark. Configuración pública y credencial de servidor existentes
en Descargas, proyecto coincidente; no copiar la clave privada al repositorio.
Solo se observó registro Android oficial, no com.futbeat.futbeat.qa.
A32 RF8R32GQWGL conectado. Pendiente confirmar copia QA previa a activación
global para preservar el binario Play 16; no se reemplaza ni desinstala.

Dependencias exactas: N1 para preferencias independientes y deduplicación
sin autor; K3 sobre K2 para elevar demanda por jugador/equipo/partido usando
alineaciones oficiales o plantillas vigentes; W2 sobre infraestructura W1 para
despertar dispatcher. K1-A/B y P1 afectan cadencia/paginación, no requieren
servicios móviles paralelos. BE18b/BE17/BE14 conservados, sin desplegarlos.
Activación global exige N1 con firmas/rollback vigentes, credencial FCM válida,
configuración pública del binario y ambas compuertas de modo live (Edge+DB),
precedida por entrega controlada al A32 y revisión de la cola pendiente.
La preferencia del propietario por alcance global no demuestra esas compuertas.

Pruebas realizadas: 58 focales Flutter iniciales PASS; 7 pruebas nuevas N1
(modelo, RPC, offline/reinicio, cuenta tardía, rechazo y UI); kit Claude N1
18/18 PASS sin modificarlo; backend push/transporte 40/40 PASS. Prueba
adicional contra kit N1 para club+selección 1/1 PASS, con un único jugador
canónico y ausencia de goles de compañeros. Artefactos notifications-*.log.
Suite completa detectó 3 expectativas antiguas de frescura: ajustados solo
fixtures a providerObservedAt en provenance + liveChangedAt cuando procede;
sin timestamp opcional no se espera alerta falsa. Sin cambio LIVE funcional.
Suite final/Contracts, APK y aceptación física se registran al concluir.

Cierre de compuertas locales de esta integración: commit local
`e3cfc7888d0509bdba1d3043fb8b93d3e44a888a`, sin push. Flutter analyze limpio;
suite final 2107 PASS, 6 omitidos. Contracts completos: 1356 casos,
1350 PASS, 4 fallos de entorno, 2 TODO. Reejecución elevada de los casos
localhost/PostgreSQL: 7/7 PASS; prueba canary aislada de la vinculación
productiva: 3/3 PASS. La guarda real no se modificó ni se desvinculó Supabase.
Regresiones adicionales de cuenta/token/borrado: 26/26 PASS.

El propietario autorizó explícitamente la copia QA previa al alcance global.
Registrada com.futbeat.futbeat.qa (FutBeat QA A32) en Firebase futbeat-686af,
app ID 1:438739446086:android:8dddc8705e37d0a141dd47. Evidencia
artifacts/firebase-qa-registered.jpg. No se crearon claves privadas nuevas.
APK debug aislada 2017 instalada por adb install -r, verificada v2:
artifacts/FutBeat-1.0.0-2017-push-QA.apk, SHA256
FCC8F6D0191F660517D240A9824CD8B549AC46E644A131A5C69FA6E4556CD3B9.
QA 17 fue rechazada porque existía QA 2016; se usó 2017 sin bajar versión.
Push configurado con opciones públicas reales, scopes flag false hasta N1.
No AAB ni subida. Config/HEAD/diff móvil trazados en
artifacts/notifications-candidate-manifest.json. El binario incluye cambios
móviles previos no commiteados conservados en el patch asociado: no fingir
que HEAD por sí solo reproduce toda la candidata.

QA física NOT VERIFIED: permiso POST_NOTIFICATIONS=false tras instalación,
acceso visual a ventana scrcpy pendiente (la solicitud de control venció).
No se envió FCM ni se cambió modo global. Confirmación adicional importante:
Play 16 estaba presente al primer intento (version16, installer com.android.vending),
pero dejó de aparecer después. Logcat PackageManager registra eliminación
com.futbeat.futbeat.qa 17/11 21:14:15.985 y com.futbeat.futbeat 21:14:22.778,
caller UID10067=com.google.android.packageinstaller. Esto identifica el
componente, no quién inició la operación. Los comandos de esta misión no
incluyeron uninstall, pm clear ni downgrade; no atribuir eliminación sin evidencia.
La última consulta solo muestra QA 2017. Restauración Play y aceptación física
requieren atender esta diferencia con el propietario, no dar PASS ficticio.

NO-GO Alpha/AAB final hasta entrega física y N1 autorizado/desplegado.
La preferencia global del propietario no habilita automáticamente los kits
BE18b/BE17/BE14/LIVE Pro ni el vaciado de las 132 notificaciones pendientes.

Continuación física con A32 desbloqueado: acceso CUA al espejo concedido.
FutBeat QA intentó abrir desde su icono; volvió al launcher. No hay excepción
en crash buffer. ActivityManager registra force-stop externo desde pid31238
21:28:44.592, pid31388 21:29:32.480 y pid31626 21:31:02.727 CST, después
del arranque de los procesos QA. No atribuirlo a Flutter ni a Claude sin
identificar al operador. No detener procesos ajenos ni competir por el A32.
Solicitada al propietario una ventana sin otra prueba/controlador activo.
No se envió FCM ni se concedió permiso de notificaciones por fuera de la UI.

Credencial Firebase existente comprobada con el transporte actual y CA de
confianza Windows (node --use-system-ca): OAuth HTTP200 a
2026-11-18T03:34:16.083Z, prepare=null, ninguna notificación enviada.
Evidencia artifacts/notifications-fcm-credential-check.json. No copiar
clave privada ni access token a resultados. QA no llegó a crear shared_prefs
antes de quedar detenida. Recepción/navegación real siguen pendientes.

Actualización final 17/11/2026, 22:16 CST: por petición del propietario se
compiló e instaló localmente el paquete oficial com.futbeat.futbeat, release
firmada 1.0.0 (17), sin publicar en Play. Se reprodujo y corrigió una carrera
de inicialización Firebase que dejaba sin listeners de recepción/navegación.
Commit local 1285566a4c4ae7caa00b0df7e4d2038f4fc5cd28; regresión nueva falla
antes y pasa después. Flutter analyze limpio; 48 focales PASS; suite final
2109 PASS y 6 omitidos. No se repitieron Contracts sin cambios backend.

Candidata vigente: artifacts/FutBeat-1.0.0-17-release-fixed.apk, SHA256
236F9F6AEEDD6C82B0BAFE19A9434BCEF9D2396F7DA418C5952B317E487C85BF.
Firma upload autorizada verificada; no debug. Incluye el WIP móvil previo
preservado, trazado en artifacts/notifications-mobile-working-tree.patch.

PASS físico dirigido en Galaxy A32: permiso y registro FCM; banner en primer
plano con acción Ver; aviso Android en segundo plano; arranque con proceso
ausente desde aviso Final. Ambos avisos abren Match Center Gales–Portugal
2–3 FINALIZADO. Mensajes explícitamente sintéticos QA, sin modificar eventos
deportivos. Aceptación FCM: 391/343/420 ms (no equivale a latencia total hasta
pantalla). Evidencias notifications-release-foreground.png,
notifications-release-match-center.png y notifications-release-cold.png,
con recibos notifications-release-fcm-*.json. Crash buffer vacío al cierre.
Se eliminó el token temporal. No se alteró dry_run ni se vació la cola.

Esto sustituye los pendientes físicos de transporte/navegación anteriores,
no certifica fanout deportivo ni preferencias N1 en producción: sus RPC
siguen ausentes y el flag móvil permanece false. NO-GO Alpha/global hasta
contrato N1 autorizado y prueba dirigida real de selección/deduplicación,
más aceptación del propietario. No AAB nuevo, push, despliegue ni publicación.

### Integración N1 + Gratis + G1 (continuación local)

Android conserva PushService y los RPC N1 existentes. Añadidas regresiones
para última elección offline (on/off repetido), independencia entre ámbitos
y envío de todas las parejas del catálogo, incluidos titular/suplente.
Los 18 escenarios del kit N1 ya probados cubren atribución, compañeros,
equipo, partido, deduplicación triple, anulación, cambio de preferencia,
unfollow y falta de jugador; no se ha reejecutado ni modificado ese kit.

Reutilizado premium_qa_transport del archivo comercial existente. Corregida
su incompatibilidad con /functions/v1/futbeat-billing; GET entitlement,
POST verify {token}, POST restore {tokens} (máximo 10). Solo G1 concede
Premium y acusa la compra. La ruta QA no usa el acuse local de Play.
Contrato v1 estricto; 503 conserva caché, inactive revoca; derechos y
respuestas tardías siguen aislados por cuenta. Catálogo futbeat_premium con
base plans monthly/yearly y precios reales de Play, sin ofertas inventadas.
Compras ocultas cuando purchasesEnabled=false y compuerta revalidada antes
de abrir Play. Puente opt-in debug, ligado únicamente a Auth QA
wctxcnqcblgewaznxrqh; ninguna sesión productiva se envía allí.

AdMob/UMP reutilizados sin unidades nuevas. Recuperado únicamente el modo
EEE de dispositivo QA ya existente en el archivo comercial: debug + QA +
UMP + anuncios de prueba + dispositivo explícito. Sin reset de UMP ni
consentimiento simulado. Evidencia física anterior M3 sigue conservada en
artifacts/android-commercial-qa/docs/release/FUTBEAT-1.0-INTEGRATION-MASTER.md:
rechazo, aceptación, persistencia y retirada. No es PASS físico del código
nuevo ni de Premium. Retirada no implica necesariamente ausencia de todo
anuncio: la elegibilidad vigente la decide canRequestAds de UMP.

Pruebas: suite completa con integración Billing/N1 2118 PASS, 6 omitidos;
tras recuperar la opción UMP QA, 85 focales PASS y analyze sin incidencias.
Incluye prefijo Edge, cuerpos HTTP, restauración filtrada, servidor como
única autoridad, no acuse Android, indisponibilidad, revocación, cuentas,
catálogo mensual/anual y 16 combinaciones de compuertas UMP. Logs
artifacts/integral-qa-{full,focused-final,analyze-final}.log. La prueba HTTP
usa un servidor local por una costura explícita: no acredita TLS remoto,
Play ni recepción física deportiva. Sin repetición de los PASS FCM previos.

Aceptación física preparada sobre destinatario único, sin fanout global:
1) player-only + gol propio => 1; 2) compañero => 0 personales;
3) lineup oficial titular/suplente => su alerta; 4) team-only => eventos de
sus partidos; 5) match-only => solo ese partido; 6) player+team+match => 1;
7) preferencia desactivada/unfollow antes de claim => cancelada;
8) gol sin autor => 0 atribuciones personales; 9) reintento/anulación =>
sin duplicado y corrección; 10) proceso cerrado => Match Center correcto.
Registrar eventId/outbox/claim/recibo y pantalla por caso. Los negativos
requieren prueba de cancelación del claim, no inferirlos solo por no ver un
banner. No inyectar eventos ficticios en partidos productivos.

Dependencias exactas: N1 sin despliegue autorizado, con flags móviles off.
G1 ledger local: g1-db DONE y g1-secrets-r2 DONE; no hay resultado local de
deploy/token/cron/smoke ni aceptación A1–A6. Esto no se confunde con lectura
actual autenticada remota. Claude conserva esos pasos. Su contrato exige
Auth QA no anónimo, token Publisher temporal y license tester de Play.
N1 usa actualmente Auth productiva; una APK integral no debe reutilizar esa
sesión contra G1 QA. Hace falta acordar servicios y cuenta del mismo entorno
de aceptación, con App ID AdMob del paquete elegido, antes de compilar la
única candidata integral. El App ID comercial ya aprobado pertenece a
com.futbeat.futbeat.commercialqa, no acredita com.futbeat.futbeat.qa.

No se generó una APK parcial adicional ni se cambió versionCode. La APK17
física anterior y su SHA permanecen intactos; no contiene estos cambios.
NO-GO próxima Internal Testing hasta N1/G1 y aceptación física integral.
Sin push, merge, cambios de kits, despliegue, pagos reales o subida a Play.

Gradle real validateReleaseRuntimeConfig: configuración release aprobada
PASS (exit 0); configuración con FUTBEAT_PREMIUM_PLAY_QA/BILLING_BASE
rechazada por ambas guardas (exit 1 esperado). Logs
artifacts/integral-qa-release-guard-{clean,block}.log. No binario generado.
Commit local de esta integración: 8a37e913abce5a0a1b1df291214e98f8ffaf91df.
Solo 11 archivos propios incluidos; tablero y WIP ajeno conservados sin
incorporarlos a ese commit. Sin push.

### Misión maestra: correcciones locales posteriores a 8a37e913

Propietario autoriza edición local en main existente, sin commit/push/merge,
sin ramas/worktrees ni cambios de servicios. HEAD sigue 8a37e913 y conserva
1285566a como antecesor directo. WIP previo intacto; solo archivos Android
sin diferencias previas se editaron para estas correcciones.

Defecto reproducido: si Play completaba una compra y el proceso moría antes
del callback, check() solo leía el derecho G1; no reenviaba el token comprado.
Test temporal falló con lista enviada vacía. Corregido en el adaptador
existente: recuperación por cuenta al arrancar, compartida entre solicitudes
concurrentes; tras éxito, resume lee el servidor sin restaurar cada vez.
Indisponibilidad de Play o G1 no consume la recuperación; reintento posterior
conservado. Sigue sin acuse Android ni concesión local de Premium.

UX completada: Gestionar suscripción abre el centro oficial de Google Play
con sku futbeat_premium y paquete oficial; fallo de apertura muestra la ruta
manual. Confirmación de borrado avisa que borrar FutBeat no cancela la
suscripción cuando Billing está configurado. Cancelar el diálogo no borra
ni modifica la sesión. No se abrió Play ni se borró una cuenta real.

Pruebas de este WIP: 24 focales Billing/G1 PASS;
123 regresiones afectadas de cuenta/auth PASS; analyze final sin incidencias.
Logs artifacts/g1-recovery-ui-focused.log,
artifacts/g1-account-safety-focused.log y artifacts/g1-recovery-final-analyze.log.
No se repitieron suite completa, Goldens ni FCM físico; son compuertas para
la candidata exacta posterior, no PASS de este WIP. git diff --check limpio.

APK física anterior conservada con SHA256
236F9F6AEEDD6C82B0BAFE19A9434BCEF9D2396F7DA418C5952B317E487C85BF;
no contiene este WIP. No APK parcial ni AAB nuevo. No se atribuye aceptación
física a fixtures. Se mantiene NO-GO Internal/Alpha integral.

Bloqueos de aceptación: (1) PO1 -> N1 -> W2 con sus autorizaciones y
destinatarios QA, sin enviar transferencias históricas ni activar modo global;
(2) G1 QA de Claude con Publisher temporal, despliegue/cron/smoke y cuenta
license tester, seguido de A1–A6. Antes de construir la APK integral, fijar
el entorno de identidad compatible de ambos contratos y reutilizar el App
ID AdMob del paquete correspondiente; no crear apps ni unidades nuevas.
Los resultados locales g1-db/g1-secrets-r2 DONE no acreditan esos pasos.

### Diagnóstico integral preparado (continuación, sin commit)

APK entregable: artifacts/FutBeat-1.0.0-17-integral-diagnostic.apk,
SHA256 4B05D2A4E289671925553021A5D3218EEC6AC865D62F86ED37B71E1E033895D4.
Paquete oficial com.futbeat.futbeat, 1.0.0 (17), ARM64, debug, etiqueta
FutBeat Diagnóstico. Firma autorizada F692F70E52DC61E0E79A872309B719C5624833E32DE03AE21755D6859800E0FE,
v2 verificada. No instalada, no publicada y no aceptada físicamente.
No sustituye el AAB16 ni el PASS FCM del APK17 release previo, cuyo hash
236F9F6A…487C85BF se comprobó intacto. HEAD sigue 8a37e913, con WIP conservado;
el APK no es reproducible con ese HEAD solo. Inputs, patch y hashes en
artifacts/integral-diagnostic-manifest.json. Build ejecutable local:
artifacts/build-integral-diagnostic.ps1. Sin contraseña ni token en archivos.

Incluye anuncios Google de prueba + UMP con el App ID existente. G1, N1,
push y OAuth apagados. Sin precios ficticios, compras reales, news o FPD.
G1/N1 no se presentan como aceptados porque el código esté compilado.

Corrección del supuesto anterior sobre AdMob: lectura autenticada muestra
una única app FutBeat con ID ca-app-pub-8924896982382230~6462208745, SIN paquete
ni tienda vinculados (no estaba reservada a commercialqa), dos unidades
activas y estado Debe revisarse/servicio limitado. Evidencia
artifacts/integral-qa-admob-existing.png. Reutilizado ese ID en el manifiesto
oficial debug con banners de muestra; no se crearon apps/unidades ni se
vinculó la tienda. La aprobación comercial sigue pendiente para anuncios
reales. EEE forzada solo en debug y A32 de prueba explícito.

Billing: 403 {status:rejected} y 503 ahora son resultados diferentes. Solo
texto fijo de rechazo, sin datos de la otra cuenta; 503 conserva el derecho
válido y no se interpreta como revocación. Mensajes tanto en compra como en
restauración, sin acuse ni concesión local. 5 casos focales PASS y transporte
v1 probado. Se conservan los tres cambios anteriores de recuperación,
gestión de suscripción y aviso previo al borrado.

Aislamiento QA: las credenciales, el perfil, preferencias y recibos de
PushService se separan por origen G1 QA, con una base SQLite futbeat_g1_qa.
El origen productivo conserva exactamente sus claves y futbeat. No se
migró, borró ni leyó una sesión productiva hacia QA. Test de aislamiento
confirma que QA no restaura el token/email productivos ni modifica el perfil
productivo. Las cuentas y sus derechos siguen segregados por UID.

D1: UI cache-first con Actualizando acotado a 8 s, seguido de estado estable
Detalle en actualización · Según cobertura. Con el modo de cliente D1 no
hay bucles de detalle; lectura por apertura/reanudación. En ESTE diagnóstico,
antes de que D1 backend esté autorizado, se usa la lectura existente
request=0 y no la ruta request-aware; el interés local/normal conserva su
mecanismo existente. No se habilitó openTriggersFetch=0 en producción ni
Realtime. 29 casos Match Center PASS; caso final específico D1 PASS con
partido visible, 1 lectura y 0 demandas request-aware. El resto del modo
normal conserva sus reintentos anteriores hasta activación aprobada.

Pruebas por cambios afectados (solapadas, no sumar como suite): 109 focales
integración, 5 errores Billing, 29 Match Center, 1 D1 stored y 112 finales de
Auth/almacenamiento/ámbitos PASS. Analyze final limpio. No suite completa ni
FCM físico repetidos. Gradle real: diagnóstico rechazado como release;
perfil G1 con Auth/API/Billing QA aislados aceptado; mezcla Auth QA/API
productiva rechazada. Los tres resultados esperados PASS; la configuración
de esa prueba usa una clave sintética, no acredita autenticación remota.

Coordinación autorizada enviada a Claude sin interrumpir ni autorizar ops.
Respuesta contractual leída en
F:/FutBeat/recovery-03/premium/CODEX-HANDOFF-D1-N1.md. Confirma v1, firma D1
invariable y pilotos separados: G1 usa Auth QA; N1 no existe allí y usa Auth
productiva tras PO1 -> N1 -> W2. El A32 sirve secuencialmente, con builds o
perfiles aislados del MISMO paquete. No se simula que ambas identidades son
intercambiables. El build G1 exige API también QA; no puede enviar su sesión
a la API productiva. Su contenido deportivo QA debe estar disponible o
prepararse como fixture autorizado para el recorrido de anuncios completo.

Dependencias externas exactas: operador entrega Publisher temporal en la
ubicación protegida de Claude (no por chat); Claude completa token/deploy/
extensions/vault/cron/smoke, evidencia cron_fail_1h=0 y señal G1 QA DISPONIBLE
en G1-RUNBOOK.md y OPS-READY.md. Propietario autoriza license tester y dos
cuentas Auth QA para A1–A8. Para N1: cuenta productiva de piloto, dispositivo
QA autorizado y PO1/N1/W2 con sus ventanas, sin push global ni transferencias
viejas. D1 remoto depende de K2 y las compuertas LIVE de Claude/BE18b. Ninguna
de estas operaciones se ejecutó en esta misión. NO-GO Internal/Alpha hasta
aceptación física integral y verificador productivo aprobado para pagos reales.

### 2026-11-18 — diagnóstico físico y acceso G1 QA
APK diagnóstica 17 instalada con actualización conservando datos, SHA256
99705E800CAC5D666972DF4A8D6FF7D4DCB7925DC62F2F1696C56FEAB8BA6878.
Se corrigió exclusivamente el identificador UMP del A32 en la configuración
pública debug; reconstrucción necesaria, sin cambios adicionales de código.
AdMob banner de prueba PASS. UMP rechazo 0/11, aceptación 11/11, persistencia
tras cierre/reapertura 11/11, retirada 0/11 y persistencia final 0/11 PASS.
Calendario y Match Center desde caché tras cierre/reapertura offline PASS;
se observó spinner transitorio de arranque, sin medición de latencia.
Reconexión recuperó jornada/árbitro persistido del API; red restaurada
(avión 0, WiFi 1, datos 1). Búfer crash sin líneas FATAL/FutBeat al cierre.
Evidencias: artifacts/diagnostic-{test-banner,ump-form,offline-cache-loaded,
offline-match-center,reconnected-detail}.png y consent-*.json.
No acredita Premium, OAuth ni N1: permanecen deshabilitados.

Acceso Cloud del operador completado con CLI existente y validación TLS.
Propietario autorizó expresamente Android Publisher + userinfo.email.
Token temporal QA emitido, identidad exacta verificada, guardado fuera de
Git con ACL protegida y vencimiento 2026-11-18T15:32:16Z. Valor no registrado.
Claude recibió ubicación privada y vencimiento; su secuencia G1 QA conserva
sus propias compuertas/autorizaciones. No ejecuté kits ni despliegues.
NO-GO Internal/Alpha: faltan G1 real y piloto N1 físico con sus dependencias.

### 2026-11-18 14:54Z — G1 aceptación física iniciada
G1 QA DISPONIBLE 14:36Z confirmado en OPS-READY y por propietario.
Token vigente hasta15:32:16Z; sin renovación necesaria al inicio.
Play Console: alienmagiccr@gmail.com y henguido@gmail.com presentes en
lista activa FutBeat License Testers. No se modificó la configuración.
Firma Play D307B7E2F9D399FA3C6CC314B6DEB00139B3F609A96B87EBFB764812D10DCDE4;
la APK sideload usa la firma de carga autorizada F692F70E…E0FE.
No es un binario firmado/distribuido por Play; Billing admite sideload
para license testers, pendiente comprobar tarjeta de prueba en diálogo.
APK G1 debug17: artifacts/FutBeat-1.0.0-17-g1-physical.apk,
SHA256 585C0D4502BB0536EBF59729ED9D37E16710274E808FC688CC7C0660251B813F.
Instalación -r PASS sin borrado/desinstalación. Datos productivos conservados,
Auth y SQLite QA aislados. G1 activo, push/N1/OAuth desactivados.
Configuración demo heredada bloqueaba Auth; corregida únicamente a false.
No cambios de código ni repetición de suites. Build PASS77.7s; firma válida.
Ruta G1 cliente sin sesión401 (486ms). Calendario QA no disponible;
no acreditar supresión/reaparición de anuncios solo por un feed vacío.
Ambas cuentas faltan en Auth QA (Claude lectura14:47Z). Registro de primera
cuenta abierto para que propietario cree contraseña y confirme correo;
no se solicita ni registra contraseña. A1–A8 aún NOT_RUN, ningún cobro.

### 2026-11-18 — aceptación G1 QA real A32
A1 mensual PASS en APK585C0D45: compra persistida alienmagiccr, estado active,
ACK servidor<=30s, ack_pending0, cron_fail_1h0/net_5xx0 (lectura Claude).
A2 reinicio conservó Premium; A7 avión conservó derecho vigente. No inferir
HTTP503 físico: ese escenario tiene cobertura local previa.
A3 restore real confirmado por backend a15:00:32Z y anual15:15:32.75Z;
no instalación limpia ni borrado de datos. Primer restore15:01:55Z no llegó
al backend: no acreditarlo como verificación remota.
A4 encontró fallo real: filtrado por accountTag generaba restore vacíoHTTP400;
UI mostraba error genérico. Corrección local: tokens adquiridos del producto
se envían deduplicados a G1 (máximo10), servidor decide titularidad; inventario
vacío consulta entitlement. Restore200 inactive+rejected>0 se comunica con
mensaje fijo sin información de la otra cuenta, aplicando inactive autoritativo.
EntitlementCheck.answered permite failure sin confundir indisponibilidad.
29 pruebas focales PASS; analyze limpio9.8s. No kits backend modificados.
APK corregida17 SHA8BE2510902979B64F2DD1178805551F7D97176DBA19AC076BF402C500C3A62A5.
A4 físico PASS: henguido permaneceGratis y muestra rechazo seguro.
Compra anual nueva en henguido15:14:51.67Z, ACK<=32s, persistida; no cambio
mensual→anual activo. A5 parcial para ese criterio específico del runbook.
Mensual cancelada y reembolsada con Quitar acceso15:13:25Z; anual test
reembolsada con Quitar acceso15:21:40Z desde PlayConsole autorizado.
Ningún pedido real tocado; no tokens de compra copiados/expuestos.
A6 pendiente de recheck y regreso físicoGratis al momento de esta entrada.

Para anuncios, fixture local demo se rechazó por guard existente y se retiró.
No se debilitó guard ni se modificó el binario. Se restauró backup SQLite QA
y se copió SOLO fila calendario deportivo público18nov ya cacheada en teléfono,
con timestampsoriginales, sin perfiles, Auth, tokens ni compras. Base productiva
intacta. Backup artifacts/g1-qa-sports-before-fixture.sqlite.
Feed real cacheado visible y sin banner durante Premium; snapshot almacenado
no valida cobertura deportiva remotaQA. Reapertura/avión repetidos en SHA8BE25109.
A8 opcional omitida para conservar ambas cuentas. Sin commit/push/merge/AAB.

Cierre físico G1: anual revocada Play15:21:40Z, recheck backend15:30Z la
marcó terminal/inactive (revision11), comprobaciónClaude15:30:16Z. A32 mostró
Gratis y bannerGoogleDEPRUEBAvisible15:30Z: A6PASS dentro10min. Comparación
visual mismo feedcacheado: Premium sinbanner / Gratisconbanner. No se midió
contador interno banner_request ni p95HTTP; no inventar métricas.
Regresión adicional inactive+rechazo elimina caché por autoridad servidor:
1PASS; sumada a29focales, sin cambios deAPK desde8BE25109.
Estado final ambos derechos terminales, 0comprasactivas, cron_fail_1h0/net_5xx0
según evidenciaClaude. Red0/1/1restaurada, crashbufferrelevante0 al15:25Z.
Aviso cierre enviado aClaude para g1-cleanup autorizado; enejecución al registro.
A8opcional omitida, cuentasconservadas. A3cleaninstall, A5reemplazoplanactivo,
503físico noacreditados. NO-GO aceptaciónintegral/Play/Alpha: cubrirestoscasos
y cerrar gaprenovaciónG1 queClaudedocumentó; no desplegarbajopresenteoperación.
Evidencias: artifacts/g1-a4-rejection-fixed.png, g1-premium-no-banner-real-cache.png,
g1-final-a7-premium-profile.png, g1-yearly-revoked.png,
g1-a6-final-state.png y g1-a6-free-test-banner.png.

Cleanup confirmado por Claude DONE15:30:50Z: secretoPublisherQAretirado y ambosarchivostemporaleseliminados; cuentas/comprasterminalesconservadas. G1 quedaQA sincredencial, no listo paraotrascomprashastanuevopilotoautorizado.

### 2026-11-18 — cierre de cobertura pendiente A3/A5/A7 (preparación local)
La APK aprobada 8BE2510902979B64F2DD1178805551F7D97176DBA19AC076BF402C500C3A62A5
permanece intacta. No se repitieron A1/A2/A4/A6 físicos; no se desinstaló,
instaló ni borró dato del A32 en esta continuación. Ninguna operación externa.

Defecto A5 confirmado en cliente: Premium activo ocultaba compra/cambio y el
adaptador no enviaba la suscripción anterior a Play. Corrección local QA:
- Cambiar plan visible solo en Billing QA con compras autorizadas por G1.
- Leer plan mensual/anual de respuesta v1 existente; ofrecer solo el alternativo.
- Seleccionar exactamente una compra adquirida y acusada del mismo producto,
  usuario, token y handle Play. Rechazar ambigüedad, compra ajena, falta de
  compra anterior, plan desconocido/igual y cambio de cuenta durante lookup.
- GooglePlayPurchaseParam incluye ChangeSubscriptionParam con compra anterior,
  offerToken del nuevo plan y chargeFullPrice. Play muestra precios y aceptación;
  no se conceden derechos ni acuses locales. G1 verifica el nuevo token.
- Release/QA apagado conserva compuerta; no habilitar pagos productivos.
Referencia primaria: developer.android.com/google/play/billing/subscriptions
(sección cambio de plan y modos de reemplazo). Mismo producto existente,
sin nuevos productos ni cambios Play Console.

Pruebas: 37 regresiones Billing/transporte PASS; adaptador Android QA PASS,
compuerta adaptador apagada PASS, interfaz QA PASS, interfaz apagada PASS.
Las pruebas de UI requirieron corregir el reloj simulado y cancelar su timer
sintético; no implicaron un defecto nuevo del runtime Android.
Build QA separado PASS82.6s, firma de carga verificada F692F70E…E0FE:
artifacts/FutBeat-1.0.0-17-g1-coverage.apk,
SHA256 E093C7025AFE6853D1B2D7A4B518E112EE1F373FC4155AEFB1AAADCE1108FA38.
Misma17, debug, Auth/API/Billing exclusivamente wctxcnqcblgewaznxrqh;
N1/push/OAuth apagados, anuncios de prueba. NO instalada, NO aceptación física.

Procedimiento A3 (pendiente de autorización si toca datos):
1. Con G1 renovable operativo y compra QA activa, conservar hashes/evidencias y
   respaldo de datos públicos necesarios; no dar por restaurable el almacén
   cifrado tras desinstalar: las claves Android pueden perderse.
2. Preferir otro Android autorizado o perfil Android realmente limpio si existe.
   No crear perfil ni desinstalar/vaciar el perfil actual sin autorización expresa.
3. Instalar paquete oficial QA firmado en ese destino, misma cuenta Google
   license tester y misma cuenta Auth QA no anónima/confirmada. Sin copiar sesión,
   derecho Premium ni configuración productiva al destino limpio.
4. Restaurar: backend POST restore200/restored1/active, compra ligada al propietario
   y acuse servidor; confirmar Premium y ausencia de anuncios. Conservar fuente
   HTTP/DB y SHA físico. No acreditar solo lectura de caché ni reinstalación -r.
5. Volver al dispositivo/perfil previo sin borrar sus datos; conservar ambos
   artefactos y cuentas. La compra usada es testPurchase, nunca tarjeta real.

Procedimiento A5 (no repetir auditoría A1):
1. Una compra QA activa/acuse confirmado es precondición para reemplazarla;
   las dos del piloto anterior están terminales y no sirven como compra anterior.
2. Misma cuenta Google tester y mismo Auth QA; elegir Cambiar plan y período
   alternativo. Confirmar diálogo Play de prueba sin cargo y su aceptación.
3. Verificar que Play recibe token anterior + nueva oferta; G1 confirma nuevo plan,
   linkedPurchaseToken y terminalidad del anterior; un solo derecho activo, sin
   concesión/acuse Android. Si se cancela, conservar el derecho previo vigente.
4. No sustituir este caso por cancelar/expirar y comprar otra suscripción nueva.

Procedimiento A7 (solo ventana QA explícita, operada por Claude):
1. Reutilizar el derecho QA activo de A5 con vencimiento suficiente; confirmar
   propietario y Premium persistido antes de la perturbación.
2. Claude prepara en el G1 existente un fallo controlado de autenticación Publisher
   QA que produzca HTTP503 en restore con token conocido. No bloquear TLS, no
   cambiar origen Auth, no usar servicio paralelo ni inyectar respuesta en Android.
   Debe confirmar cómo forzar ese503 con proveedor renovable/cacheado antes de
   autorizar la operación; retirar un secreto podría no bastar si existe caché.
3. Disparar restore desde A32: capturar HTTP503 real (solo metadatos), mensaje
   temporal seguro, Premium vigente y anuncios suprimidos. No confundir modo
   avión/timeout/401/403 con503 ni extender un derecho expirado.
4. Claude restaura autenticación QA; repetir misma compra/restore ->200 active,
   sin nueva compra ni pago. Correlacionar DB/HTTP, sin tokens en evidencias.
5. Terminar perturbación y cleanup de credenciales temporales con su compuerta;
   no modificar IAM/producción ni desplegar bajo la autorización de Android.

Coordinación enviada a Claude. Su autenticación renovable y corrección de
renovación están en desarrollo local, sin despliegue ni ventana autorizada
confirmada. A3/A5/A7 permanecen PENDIENTES físicos estrictos. NO-GO integral.

Comprobación final de esta continuación: analyze limpio7.2s y git diff --check sin errores en archivos afectados. APKaprobada8BE25109 conserva SHAexacto. No instalación/compra nueva ni pruebas físicas repetidas.

### 2026-11-18 — espera G2 y trabajo Android independiente autorizado
Restricciones del propietario conservadas: no compras, no token manual, no
instalación/desinstalación ni borrado de datos del A32, no ramas/commits/push.
Ambas APK conservadas con SHA exacto: 8BE25109… (físico) y E093C702… (coverage).

Defecto N1 reproducido localmente: una lectura iniciada por A esperaba vaciar
la cola; al cambiar a B, la continuación consultaba con la sesión B. La pantalla
ya descartaba el resultado por propietario, pero el servicio hacía una consulta
no necesaria para la cuenta nueva. Nuevo caso falló antes de corregirlo.
Corrección en notification_scopes_access.dart: capturar propietario/generación
antes del flush y rechazar el cambio antes del RPC de lectura. Pruebas N1
11/11 PASS, incluidos offline, borrado confirmado y aislamiento. N1 sigue
apagado. No cambios backend ni repetición del diagnóstico LIVE cerrado.

Contrato A7 aclarado por Claude en CODEX-HANDOFF-D1-N1.md:
restore mantiene HTTP200 con estado guardado cuando Publisher no está disponible;
verify es la ruta que devuelve HTTP503. Queda SUPERADO el procedimiento anterior
que proponía acreditar503 pulsando solamente Restaurar compras.
Se prepara acción «Verificar compra QA», exclusivamente debug Billing QA:
- No compra ni restaura otra suscripción: toma exactamente una compra existente,
  adquirida/acusada y de la cuenta actual, y usa el verify v1 de G1 existente.
- Requiere Premium vigente previamente verificado, no permite iniciar derechos
  desde Gratis. 503 devuelve mensaje temporal y conserva la caché vigente;
  una respuesta disponible actualiza el derecho por autoridad del servidor.
- Cambios de usuario y respuestas tardías se rechazan; sin concesiones o acuses
  locales, sin tokens impresos y sin otro verificador.
Pruebas: 3 casos A7 QA PASS (fallo/recuperación, compra ajena, respuesta tardía),
compuerta QA apagada PASS y UI QA PASS. Analyze limpio6.8s. No PASS físico nuevo.

Bloqueo técnico operativo confirmado leyendo G2-RUNBOOK y OPS-READY:
G2 (WIF + renovación + corrección del hueco de renovación de Premium) está probado
LOCALMENTE, SIN APLICAR. No hay ventana autorizada. Faltan compuertas G-0..G-3
operador y g2-key/secrets/deploy/smoke de Claude en wctxcnqcblgewaznxrqh.
Esperar «G2 QA DISPONIBLE» con cron mode=wif, lastError=null, expiresInS>600.
No ejecutar esas operaciones ni emitir token manual bajo esta continuación.

A7 físico posterior: después de G2 disponible y autorización propia de Claude,
usar compra existente y derecho vigente; g2-a7-off retira clave WIF SOLO QA,
comprobar isolates sin credencial; pulsar Verificar compra QA -> HTTP503 real
(metadatos solamente), derecho/anuncios sin falsa revocación. g2-a7-on restaura
clave y cron wif/refreshes>=1; repetir verify ->200 active, misma compra.
Duración<15min desde último recheck válido QA. No simular503 en Android.
A3 necesita Android/perfil limpio separado AUTORIZADO, sin borrar el A32.
A3/A5/A7 se harán con una única APK congelada y mismo SHA, sin mezclar evidencia
histórica. No se repiten A1/A2/A4/A6. Actualizar solo esta fuente documental.

APK única preparada para A3/A5/A7: artifacts/FutBeat-1.0.0-17-g1-a3-a5-a7.apk, SHA256 B75617695CC8203CC62D0874F359D633231337EE22C9027B636D6924DEB58658. Build69.8s y firmaQA autorizada verificada. NO instalada ni probada físicamente. 8BE25109 y E093C702 preservadas sin sobrescritura. Manifest g1-a3-a5-a7-manifest.json. No nuevas compras, tokens, AAB, commits ni operaciones externas.

### 2026-11-18 — preparación A3 sin afectar la instalación principal
APK A3/A5/A7 B7561769… y APK física 8BE25109… verificadas y conservadas.
Sin compilaciones, compras, tokens, instalaciones, borrados ni pruebas Billing repetidas.
Solo conectado RF8R32GQWGL (SM-A325M, Android 13). Usuario propietario único;
max-users=1, pero la capacidad de perfil administrado está presente y habilitada.
No se ha creado perfil. El aislamiento de datos de un perfil no aísla el código
instalado del mismo paquete: instalar B756 en un perfil actualizaría también el
binario compartido con el propietario, actualmente 8BE. Por ello A3 requiere
un segundo Android autorizado para cumplir la preservación estricta del A32.
Se solicitó al propietario ese dispositivo; no hay autorización inferida.

Lectura de OPS-READY: G2 QA tiene ventana preparada y GO técnico, pero todavía
espera autorización G-0..G-3 + g2-*; no consta «G2 QA DISPONIBLE».
A3/A5/A7 siguen NOT_RUN. Además, tras cleanup ambas compras anteriores son
terminales: A3 necesita una compra de prueba restaurable y A5 una suscripción
activa y autorización expresa del cambio de plan. La prohibición actual de
nuevas compras se conserva. A7 requiere derecho vigente y perturbación QA
controlada autorizada por separado; nunca acreditar 503 a partir de restore200.
N1 mantiene su corrección local ya probada y los flags apagados; LIVE conserva
el contrato D1 y la corrección de frescura aprobada. Sin evidencia nueva no se
modifica código ni se repiten pruebas previamente aprobadas. NO-GO integral.

### 2026-11-18 — segundo Android autorizado: A3 preparado
Propietario confirmó y conectó R3GYB07KKJP, Samsung SM-S938U1, Android 17.
Lecturas previas: paquete oficial ausente globalmente (dumpsys); existente
com.futbeat.futbeat.r05test conservado. Secure Folder no se modificó ni accedió.
Instalación nueva en usuario 0 de APK congelada B75617695CC8203CC62D0874F359D633231337EE22C9027B636D6924DEB58658: Success.
Comprobación posterior: ambos paquetes presentes; oficial 1.0.0 (17),
notLaunched=true. No restauración ni compra ejecutada; no PASS A3 físico.
A32 no conectado ni modificado. Sin APK nueva, borrados o cambios backend.
Pendientes: G2 QA DISPONIBLE, derecho restaurable y autorización de las
operaciones de compra/cambio de plan y perturbación QA requeridas. A3/A5/A7
siguen pendientes; solo se acredita preparación e instalación nueva aislada.

### 2026-11-18 — G2 Google G-0 PASS, G-1/G-2/G-3 sin ejecutar
Proyecto futbeat ACTIVE, PROJECT_NUMBER=751942598962, sin parent de organización
en projects.describe. Operador activo henguido@gmail.com: roles/owner directo.
Política efectiva constraints/iam.workloadIdentityPoolProviders: allValues ALLOW.
APIs sts.googleapis.com e iamcredentials.googleapis.com no aparecen habilitadas.
Pools existentes: []. IAM SA QA conserva user:henguido@gmail.com con
roles/iam.serviceAccountTokenCreator; ningún workloadIdentityUser existente.
JWKS público: kid futbeat-billing-qa-20261118, EC P-256 ES256, sin componente d.
No se leyó ni cargó la privada. Emisor y sujeto del runbook restringidos a QA.
Audiencia por defecto Google: recurso canónico de edge-qa con o sin prefijo HTTPS;
JWT del backend usa https://iam.googleapis.com/projects/751942598962/locations/global/workloadIdentityPools/futbeat-billing/providers/edge-qa.
Incidencia local: SSLKEYLOGFILE apuntaba a driver AVG inaccesible; se retiró solo
del proceso. TLS de Python no confiaba en la cadena local; resuelto usando el
bundle existente artifacts/gcloud-windows-trust.pem solo en el proceso, sin
desactivar TLS ni cambiar configuración global. G-0 posterior completado.
Pendiente autorización expresa del propietario para habilitar ambas APIs, crear
pool futbeat-billing/proveedor edge-qa con JWKS del runbook y añadir únicamente
roles/iam.workloadIdentityUser al principal subject/futbeat-billing:qa en la SA QA.
No cambios Google/Supabase, ni tokens nuevos, claves JSON, compras o APK.

### 2026-11-18T17:22:59Z — G2 Google G-1/G-2/G-3 PASS
Autorización expresa del propietario ejecutada exclusivamente en futbeat,
PROJECT_NUMBER 751942598962. APIs sts.googleapis.com e iamcredentials.googleapis.com
habilitadas y verificadas. Pool futbeat-billing/proveedor edge-qa creado.
Describe: state ACTIVE (habilitado), issuer https://futbeat.com/billing-wif/qa,
condition assertion.sub == 'futbeat-billing:qa' && assertion.iss == 'https://futbeat.com/billing-wif/qa',
mapping google.subject=assertion.sub. allowedAudiences ausente: restricción
Google al recurso canónico de este proveedor, con o sin prefijo HTTPS.
JWKS subido comprobado contra todos los campos públicos locales, kid
futbeat-billing-qa-20261118; privada no leída ni transmitida.
Binding añadido exclusivamente en futbeat-billing-qa@futbeat.iam.gserviceaccount.com:
roles/iam.workloadIdentityUser al principal://iam.googleapis.com/projects/751942598962/locations/global/workloadIdentityPools/futbeat-billing/subject/futbeat-billing:qa.
Comparación IAM antes/después confirma solo ese delta, sin pérdida o alteración
de bindings previos. Evidencia no secreta: artifacts/g2-google-iam-before.json,
g2-google-iam-after.json y g2-google-provider-final.json.
Resultados comunicados a Claude en su sesión FutBeat GOAL API Pro optimización;
mensaje enviado y ejecución de respuesta visible. Se delimitó explícitamente
que el aviso NO autoriza operaciones Supabase. No tokens manuales, claves JSON,
compras, cambios APK/Play/producción ni operaciones de repositorio.
Siguiente dependencia: operaciones G2 QA de Claude bajo su propia autorización;
aún no se acredita G2 QA DISPONIBLE ni aceptación física A3/A5/A7.

### 2026-11-18T18:29Z — mensual G2 QA: compra y activación PASS
Propietario autorizó expresamente una mensual de prueba. APK instalada en
RFCNB05YHKM (SM-G781U1) con SHA B75617695CC8203CC62D0874F359D633231337EE22C9027B636D6924DEB58658 comprobado en base.apk.
Auth QA alienmagiccr@gmail.com, correo verificado, visto en Perfil. Play confirmó
Tarjeta de prueba siempre aprobada, sin importe real, renovación5min. Al recibir
autorización ya aparecía compra exitosa; Codex no disparó una segunda compra.
Propietario cerró preferencia de autenticación de Play; después se observó
FutBeat Premium activo y acción Verificar compra QA. Evidencia:
artifacts/g2-monthly-test-confirmation.png y g2-monthly-premium-active.png.
Claude confirmó lectura QA: hash corto f3923e67 monthly active, verify18:28:58Z,
evento purchase único18:28:58.58Z; acuse cron18:29:00Z (aprox2s), ackPending=false,
1 intento; WIF ready3597s, failures0, sin error. Cron y5xx sin fallos.
No se acredita A7/A5/A3. A7 debe sincronizarse tras recheck y completarse antes
de paidEnd+grace2min (aprox5min operativos), no asumir15min Premium garantizado.
Claude aún no ejecuta off/on; requiere autorización separada. Sin nueva compra,
plan anual, compilación, cambios Play/producción o repositorio.

### 2026-11-18 — A7 PASS físico estricto, G2 QA recuperado
Autorización separada del propietario: «Autorizo A7 QA y su recuperación».
Misma APK B75617695CC8203CC62D0874F359D633231337EE22C9027B636D6924DEB58658,
Samsung SM-G781U1 RFCNB05YHKM, Auth QA alienmagiccr@gmail.com.
Claude ejecutó solo g2-a7-off/on QA: off18:35:17Z tras recheck18:35:01Z;
on18:36:38Z antes de fin del derecho18:40:44Z. Watcher de seguridad no actuó.
Android: Verificar compra QA mostró fallo temporal y conservó Premium activo;
Restaurar compras mantuvo Premium; verify tras recuperación mantuvo Premium.
Log Android filtrado exclusivamente hora/status, sin secretos:
12:35:50.341 CRC verify503;12:35:58.539 restore200;12:37:17.692 verify200.
Claude confirmó metadatos Edge independientes UTC: verify50318:35:50.307,
restore20018:35:58.608, verify20018:37:17.726. Recuperación: evento recheck
SUBSCRIPTION_STATE_ACTIVE->active18:37:17.69Z, revisión16, nunca terminal.
Credencial WIF recuperada. No concesión local ni compra adicional.
Evidencias: artifacts/g2-a7-http-status-only.log, g2-a7-off-premium-preserved.png,
g2-a7-off-restore-premium.png, g2-a7-on-verified.png; backend Claude
F:/FutBeat/recovery-03/premium/prod/g2/a7_edge_http_evidence.txt.
El aviso temporal se observó en captura de herramienta; el PNG off guardado
muestra Premium después de desaparecer el aviso. No confundirlo con un PNG
que contenga el texto del aviso. Restore active corroborado por DB y UI;
los logs solo acreditan status/ruta/hora, no cuerpos de respuesta.
A5 y A3 siguen pendientes, cada una con autorización propia. No nuevas APK,
commits, cambios Play/producción o repetición de A1/A2/A4/A6.

### 2026-11-18T18:51Z — A5 PASS físico y backend
Propietario autorizó A5 anual y confirmó pulsar Suscribirse en diálogo Play.
Misma APK B75617695CC8203CC62D0874F359D633231337EE22C9027B636D6924DEB58658
sobre RFCNB05YHKM, Auth QA alienmagiccr@gmail.com. Cambiar plan solo ofrecía
Anual; Play tarjeta de prueba siempre aprobada, sin importe real,30min.
Confirmación única; Android permaneció Premium y solo ofrece Mensual como
alternativa posterior. Sin nueva compilación, repetición de A1/A2/A4/A6 o Playops.
Claude leyó QA: verify20018:50:31.181Z, evento replacement18:50:31.145Z único.
Mensual f3923e67 terminal y anual acef324f yearlyactive, mismoowner y revisión20
en transacción replace_purchase. Acuse cron18:51:01Z, ackPendingfalse,1intento.
Sin duplicados, cuentas ajenas o falloscron. Fin derecho19:26:25Z.
Evidencia Android: g2-a5-yearly-replacement-dialog.png,
g2-a5-after-replacement.png, g2-a5-yearly-current-monthly-alternative.png,
g2-a5-http-status-only.log, todos en artifacts/. Backend G2-RUNBOOK de Claude.
Observación no bloqueante: dos GET entitlement paralelos; no cambio de código
ni recompilación durante candidata congelada. Pendiente únicamente A3 limpio
con autorización propia y otroperfil/dispositivo realmente limpio. El Samsung
RFCNB05YHKM ahora ya tiene sesión/compra: no se acredita A3 desde esta misma
instalación. SM-S938U1 R3GYB07KKJP tenía B756 instalada y sin abrir anteriormente;
comprobar estado actual y cuentaGoogle antes de usar, sin borrar datos ni A32.

### 2026-11-18T19:00Z — A3 PASS físico estricto; A3/A5/A7 cerrados
Autorización propia A3 y reinstalación expresa después de que el propietario
confirmara haber eliminado la app. Mismo APK B75617695CC8203CC62D0874F359D633231337EE22C9027B636D6924DEB58658
verificado en archivo y base.apk de R3GYB07KKJP SM-S938U1 Android17.
Antes de abrir: notLaunched=true; primera pantalla sin sesión capturada.
Propietario inició AuthQA alienmagiccr@gmail.com; Perfil confirmó cuenta/correo.
No datos/sesiones/derechos copiados, no compras ni modificación del A32.
Restauración automática al login18:59:42.09Z: POSTrestore200 y recheckactive
anual acef324f18:59:42.04Z. Restauración explícita19:00:07.84Z: POSTrestore200,
recheckactive19:00:07.80Z revisión22, mismoowner. Claude corroboró DB+Edge:
inventario real, no GET entitlement confundido conrestore y ningúncron enesa
ventana (siguiente19:00:30Z). Nueva ventana peticiones18:59:41.6Z.
AndroidHTTPstatus12:59:42.158200,12:59:59.155200(GET),13:00:07.861200;
artifacts/g2-a3-http-status-only.log. Capturas g2-a3-clean-first-launch.png,
g2-a3-clean-profile-premium.png y g2-a3-restored-premium.png.
Resultado A3 PASS; A5 y A7 PASS preservados en mismaAPK. Claude confirmó cierre
G2QA en G2-RUNBOOK.md y OPS-READY.md. No se acredita producción Premium ni GO
InternalTesting/Alpha integral: N1/push real sigue dependencia separada.
Limitación conocidaQA: calendario404 porque QA no tiene APIdeportiva; no se
atribuye aBilling. Anual de prueba sigue activa, sin cargo; no se cancela ni
revoca automáticamente sin autorización del propietario. No tokensmanuales,
compilaciones, commits, push, Playops o producción.

### 2026-11-18 — N1 Android: preparación de piloto, sin APK nueva
Trabajo local preservado, incluido Billing/UMP/FCM/favoritos/D1 y B756 con SHA
exacto verificado. No código modificado sin defecto nuevo; no repetición de
Billing ni de las11pruebasN1 ya aprobadas. Configuración preparada y validada:
artifacts/n1-pilot-public.pending.json, paqueteQA existente com.futbeat.futbeat.qa,
FirebaseAppQA existente 1:438739446086:android:8dddc8705e37d0a141dd47,
Auth/API producción izlmruqawgagwdcsjhte; G2/BillingQA/OAuthoff, N1flagoff.
Esto preserva la instalación oficial B756 y no mezcla AuthQA wctx conN1.
Sin generar APK ni instalar/activar esta configuración.
artifacts/n1-pilot-acceptance.pending.json contiene12casos NOT_RUN:
jugadorpropio/compañero/sinid, equipo, partido, deduplicacióncanónica+retry,
preferenciasoffline+confirmación, unfollowconfirmado, cambioCuenta, tapMatchCenter,
permiso y rotación/logouttoken. Destinatarios decidebackend; Android no fabrica
alertas personales. Evento/controlcanónico aún debeautorizarse conClaude.
Se solicitó propietario confirmar cuenta producción alienmagiccr y SM-S938U1;
no inferir permiso porser cuentasBillingQAprevias. Pendiente respuesta.
Claude confirmó durante coordinación un bloqueo concreto: transporte test
simula; push_settings.mode live habilita todoslosFCM y NO existe allowlist de
un único dispositivo. No piloto físico hasta filtroservidor y corte verificables.
PO1->N1->W2 conservan autorizaciones separadas; DRYN1/W2 reportadoGREEN pero
no aplicación autorizada porCodex. Coordinación entregada/en cola en Claude.
Resultado: preparaciónAndroidvalidada, físicoN1 NOT_RUN; NO-GO para envíos y
para distribuciónintegral. No nuevas APIs, credenciales, producción, compras,
commits, ramas/worktrees o Play. Única fuente documental: este tablero.

Propietario confirmó destinatario N1: alienmagiccr@gmail.com en producción y SM-S938U1 (R3GYB07KKJP), único dispositivo de prueba. Selección autorizada, sin autorización de envíos ni PO1/N1/W2. Manifest actualizado; N1 sigue apagado y aceptación física NOT_RUN.

### 2026-11-18 — OAuth N1 aislado preparado; físico pendiente USB
Reutilizado flujo existente BrowserPKCE + cliente OAuthWEB de Supabase; no usa
SDKGoogleSignIn/clienteAndroid nativo. Paquete com.futbeat.futbeat.qa y callback
com.futbeat.futbeat.qa://login-callback coincidentes Dart/Manifest.
Claude leyó producción sin cambios: allowlist incluye exactamente callbackQA,
Google habilitado, clienteWEB 751942598962-8ql7hveci4cspu83jum3nqe5cckfa1kj.apps.googleusercontent.com,
callbackGoogle https://izlmruqawgagwdcsjhte.supabase.co/auth/v1/callback.
No crear clienteAndroid ni modificarFirebase para este flujo. SHA1firma comprobada
DF9C09BD9EDCA03C19FFEDCC4035F575E0FCC28A, SHA256firmanteF692F70E…0E0FE.
5pruebasPKCE focales PASS con configuraciónexacta nueva; sin suites generales.
Única APK necesaria accesoOAuth preparada: FutBeat-1.0.0-17-n1-oauth-only.apk,
SHA25688580CBCF40CE103BCCA8891A2FD988CC13CFB81168A19DC15101DDB04EB1B8C,
build93.2s, debug paqueteQA verificado, OAuthon/PUSHoff/N1off/G2off. Configuración
n1-oauth-only-public.json y manifest n1-oauth-only-manifest.json en artifacts.
FCM no se inicializa ni registra en esta configuración. B756Billing preservada.
SM-S938U1 se desconectó antesdeinstalar; propietario avisado para reconectar.
APK NO instalada, OAuth físico NOT_RUN, installation_id/FCMdeviceID NO registrado.
No inventarPASS ni identificador. Tras reconectar: comprobar paqueteQApreexistente
sinborrar, instalar compatible, Googlecuentaexistente, retornoproducción y perfil.
RegistroFCM exclusivamente despuésdeClaudeconfirmarPL1operativo y autorización.
Sincontraseñas/nuevasidentidades, cambiosAuth/Firebase/Play/producción o commits.

### 2026-11-18T19:39Z — Google OAuth piloto N1 PASS físico y backend
SM-S938U1 R3GYB07KKJP conectado; paqueteQA ausente antesdeinstalar. Instalación
com.futbeat.futbeat.qa junto aBillingoficial, sinborrados. SHA realbase.apk
88580CBCF40CE103BCCA8891A2FD988CC13CFB81168A19DC15101DDB04EB1B8C.
Continuar conGoogle ->accounts.google.com paraSupabaseproducción ->selección
alienmagiccr@gmail.com ->retorno automáticoFutBeatQA. Perfil: Google, PlanGratis,
CorreoVerificado,2equipos1ligaexistentes. Imagen n1-google-oauth-profile-pass.png.
Claude confirmó lectura backend: user f572a5bc-f18f-4687-918f-02fae3a696ba existente,
únicoemail, noanónimo, Googleidentidadactualizada19:38:59Z, login19:39:00Z,
1sesiónnueva y0identidadesGoogleduplicadas. 0dispositivosFCMdelacuenta y0nuevos
globalesdesde19:30; dry_run. Porrestricción propietario no registrarhastaPL1.
No existe deviceIDFCM que entregar; serialhardware anterior NO es installation_id.
Sesiónguestautomática previa creó1usuarioanónimo19:37:51Z, sinemail/dispositivo/
seguimientos; separado de la cuenta y sinpush. No contraseña/identidadalternativa
paraalienmagiccr. Backend evidencia N1-PILOT-GATES.md§11. G2Billing permanece
separado. Sin cambiosFirebase/Auth/Play/backend, pushN1off y sin nuevostokensFCM.
Compilación yfirma de esteOAuth ya registradas; no nuevaAPK enestacontinuación.
Siguientegate: ClaudeconfirmarPL1operativo y autorización de registro/envíos;
no acreditar N1 físico por haber pasado OAuth. Manifest actualizado.

Registro N1 autorizado sin envíos. Propietario cambió dispositivo a SM-G781U1 RFCNB05YHKM: 'usa este otro celular por favor'; comunicado a Claude. APK OAuth8858 tiene FCM apagado compilado, requiere única actualización mínima D2228E7A5692027BCED877FAA39C04C0EFECF9B7E13AD02D629FAB34AF2751A2, mismaQA/firma, build91.5s, SHA instalado verificado. Firebase futbeat-686af/appQA existente; N1/G2false, Billing oficial conservado. Al iniciar Google aparece Chrome primera ejecución con condiciones: propietario debe completar. Sin sesión producción confirmada aún, permiso/registroFCM NO ejecutados, token no mostrado/guardado. Sin envíos, pilot_on, cron, probes ni cambios backend. Manifest n1-fcm-registration-manifest.json.

### 2026-11-18T20:32Z — registro FCM piloto PASS, sin envíos
Dispositivo cambiado expresamente por propietario a SM-G781U1 RFCNB05YHKM.
Solo se instaló/registró este teléfono; SM-S938U1 y A32 excluidos. GoogleOAuth
confirmó alienmagiccr@gmail.com, correo verificado, cuenta existente producción
f572a5bc-f18f-4687-918f-02fae3a696ba. BillingQA conserva paquete oficial separado.
Única actualización necesaria porque OAuth8858 tenía PUSHfalse: paqueteQA misma
firma, D2228E7A5692027BCED877FAA39C04C0EFECF9B7E13AD02D629FAB34AF2751A2,
build91.5s, instaladoSHAexacto, Firebase futbeat-686af y appQA existente; N1/G2off.
Sin cambios fuente ni backend ni repetición Billing. PermisoPOST_NOTIFICATIONS
concedido porAndroid y register mediante futbeat_register_push existente.
Token no leído/impreso/guardado/compartido. Imagen n1-fcm-registration-device-enabled.png.
Claude confirmó lectura20:32:52Z: única nueva fila desde20:25 en todaslascuentas,
android/fcm/enabled, registro20:32:07.354Z, preferencias intactasdesde11-14.
installation_id=77c8be62-2165-447c-bf1f-ae8ee7f1f9eb;
device_id=8d5cc698-c66d-46c3-8494-b47feb7e957b.
PL1activo, allowlistvacía0, dry_run, croninactivo, 0deliverables, sent_ever0,
outboxpiloto0. PREidentity/dispositivo/gate/otros/backlog/pushglobaloffPASS;
allowlistexacta false por estarvacía antesdeON. No pilotoON/cron/probes/envíos.
Registro completado y comunicado aClaude; claim-dry/Firebasecheck/pilotON son
operaciones posteriores con autorizaciónpropia. Manifestregistro actualizado.

### 2026-11-18T21:08Z — piloto real, identidad verificada, esperando evento
Autorización propietario cierre físico y pilot_off final. Sustitución previa
SM-S938U1->SM-G781U1 explícita y vigente; adbRFCNB05YHKM/modelSM-G781U1,
APKbaseD2228E7A5692027BCED877FAA39C04C0EFECF9B7E13AD02D629FAB34AF2751A2,
perfilGooglealienmagiccr/correoverificado confirmados nuevamente.
Prueba no secreta deinstallationlocal: UIdeviceoff21:05:36.183Z/on21:05:45.932Z
(RPC200 ambos segúnClaude). Upsertmismafila8d5cc698 yinstallation77c8be62 sin
ningúnnuevoID desde21:04; espruebasuficiente sinextraerSecureStorage niFCMtoken.
Claude preflight21:04/21:06: GREEN,pilot,parejaexacta,0terceros,0envíos,0cola;
staletrigger8h yregla10min intactos. Probe0filas corregido porClaude localrunner:
[]=>NO-PASS,1fila=>PASS,invalido=>NO-PASS; ledgerprobeantiguocorregidoNO-PASS,
sinreenvío ni deportesmodificados.
CalendarioUI ChelseaW–PSGW46min0-0 seguidoestrella21:08:10Z persistidoenpush_follows,
matchfb_match_565af1a1dd484ae8912cd3f9604a21cf. Capturan1-real-follow-chelsea-psg.png.
Appbackground paraavisoOSpersistente. NoGOALdirecto niMCabierto. D1noaplicado:
parasatisfacerceroGOALportap, trasrecibir se probaráavión->tapMC->salir->reconectar;
Claudeverificará0request_match_detailgateway. Sinprobes/eventossintéticos.
VentanaacordadaconClaude hasta21:25Z oprimeraentrega/fallo; anteausenciadeevento
NO-PASSfísico ypilot_off autorizado,sinextensiónautomática. Recibo/tap pendientes.

### 2026-11-18T21:26Z — cierre físico piloto N1 NO-PASS por falta de evento
Ventana21:08:10..21:25:37Z ChelseaW–PSGW: 0eventoscanónicos posterioresal
seguimiento; sigueLIVE67min0-0,providerobserved21:25:01Z. KICKOFF20:05 yHALFTIME
20:50anterioresno reutilizados. 0filasdelpiloto,0envíos,0eventoelegiblesinoutbox;
no defectofanoutdemostrado. Android no recibió, tapMC NOT_RUN. Gateway0llamadas
request_match_detail; noGOALporacción. Sinprobes viejos,eventossintéticos oAPK nueva.
Compuertaprobe0filas=>NO-PASS corregidalocalmente yprobada porClaude; histórico
pilot-probe corregidoNO-PASS, sinreintento. Identidad/PL1exclusiva verificadas.
Claudeejecutópilot_off UNAvez,ledgerDONE21:26:06Z; verificación21:26:27Z:
pushdry_run,croninactivo/textooriginalrestauradomd57e74f43d…,allowlistvacía,
FUTBEAT_PUSH_MODEretirado,0deliverables,0envíosfueraPL1y0totales,0duplicados
porevento. Contadorgeneraldups1eraagrupación117transferenciasconevent_idNULL,
contenido distinto de tercero; no duplicacióndeeventosdelpiloto.
Dispositivo77c8…sigregistradoenabled,perosinentregablesporcorte. No modificar
automáticamenteelseguimientoqueseautorizó; pilot_OFFimpideenvíos.
EvidenciabackendN1-PILOT-GATES.md§20,OPS-READY; evidenciadispositivo
artifacts/n1-real-follow-chelsea-psg.png yD222SHAinstalado/modelo/Googleconfirmados.
Resultadoestricto: identidad/aislamiento/protecciones/cortePASS; recepción/tap
NO-PASS/NORUNporfaltaevento, NO-GOdeaceptaciónfísicaN1. Siguientepruebapreparada
coneventosfuturos,KICKOFF/GOALofinalycompuertasiguales; requiereventanaautorizada,
no reactivada. D1siguependienteparataponline; rutaseguraaviónparasiguienteprueba.

### 2026-11-18 — próxima aceptación N1 preparada, sin otra ventana
Se conserva resultado previo: falta de evento, no fallo Android/FCM demostrado.
SHA de APKregistroD222, OAuth8858 y BillingB756 comprobados intactos. Registro
77c8be62… SM-G781U1 RFCNB05YHKM/alienmagiccrprod conservado, no reinstalación,
compras, compilación ni operaciones remotas. No suites aprobadas repetidas.
Recorrido ejecutable de evidencias preparado en artifacts/n1-next-acceptance-plan.json:
A) diagnóstico genérico de transporte FCM, 1 destinatario, sin canonical_events
ni mensaje deportivo viejo. Claude prepara operación reutilizada; NO ejecutada.
Aceptación exige reciboFCM Y recepción física, no solo inserción niHTTP200.
B) seguir partido programado ANTES del inicio, confirmar persistencia antesde
KICKOFFoficial, exigir eventocanónico posterior,1outbox/fanout/despacho/recepción.
C) equipo: evento general confirmado de partido propio; aislar solapamientos.
D) solojugador: participacióncanónica y evento individual atribuible; compañero/
sinjugadoridentificado negativos verificables. Sinpositivo observado noPASS.
E) seguimientomúltiple:1evento/usuario/aviso; F) preferencias: elegirunámbito,
confirmarRPCantesdeenvío, offlinependiente/reconexiónmismoowner, unfollowantes
despacho. Registrarvaloresiniciales yrestaurarsoloajustespilotoacordados.
TapONLINE depende obligatoriamente deD1aplicado/openTriggersFetch0 y evidencia
backend de que apertura solo registra interés/lee persistido, sinworkerGOALporUI.
LaAPK D222 conserva N1preferencesflagfalse; configfinal local preparada en
artifacts/n1-acceptance-public.pending.json con N1true yG2false, mismo paqueteQA/
Firebase/authproducción. NO compilada/instalada; únicaactualización posterior
necesaria para aceptación depreferencias, solo cuando servicios/recorrido listos.
Compuertas anterioresintactas: parejaPL1exacta,0terceros,protecciónstale8h/10min,
0filas=>NO-PASS, deadline explícito ypilot_offverificado. Sin nuevosGOALporusuario.
Cadafase guarda SHA,identidad,UTC,event_iddeportivo(si procede),outbox/destinatario,
receiptFCMsinsecretos,capturafísica,matchdestino,0fueraPL1,0dup(eventnoNULL),corte.
Coordinación enviada aClaude; pendientescontratoexactodiagnóstico yD1/K2 con
sus autorizaciones. No se solicitaotra ventana hasta completar esascompuertas.
NingúnPASSfísiconuevo ni reactivaciónautorizada por esta preparación.

### 2026-11-18 — payload FCM N1 aditivo: implementación local PASS
push_messages.dart conserva mapa data completo, título/cuerpo, ruta matchId
prioritaria y autoridad de destinatarios backend. Añadida lectura opcional:
scopes JSONarray player/team/match; scopeKinds JSONobject scope->kind;
penalty booleano explícito/stringtruefalse, ausencia/malformado null;
playerRole primary/assist/starter/bench opcional. personalPlayerId solo con
scopeplayer explícito e ID válido. Sin inferir penal por texto ni playerScope
por presencia playerId; sin modificación del mensaje del servidor.
Deduplicación notificationId prioritaria; fallback eventId+type conserva
GOAL frenteGOAL_ANNULLED, finalmente FCMmessageId. Correcciones distintas del
mismoevento/tipo requieren notificationIddistinto; informado aClaude.
Nuevo test/n1_push_payload_test.dart8casos y mobile244dedup3casos:11PASS.
Flutteranalyze limpio8.4s, diffchecksin errores. No suiteBilling/generalrepetida.
APK D222/8858/B756 comprobadas SHAintactos. Sin nuevaAPK/instalación/commit,
push/merge/backend/envíos. Nuevalógica solo fuente local, SINPASS físico nuevo.
Contrato/formato comunicado aClaude antesdeintegración: JSONenstrings, booleanos
explícitos yrolespermitidos, todosopcionales. Dispatcherdesplegado sin estos
campos nohabilitaatribuciónpersonal encliente; legacy sigueenrutandocorrecto.
El piloto personal integrado requiere transporteampliado autorizado + posterior
candidata única justificada; no se solicitó ventana ni se desplegópor estecambio.

### 2026-11-18 — candidata única Android N1-ON compatible con dispatcher v9
Contrato v9 cotejado con PushMessage local: scopes yscopeKindsJSONstrings,
penaltytrueopcional, playerRoleprimary/assist/starter/bench; camposausentes
siguen válidos. Parser acepta false explícito por compatibilidad, pero nunca
infierenegación/penal/atribuciónporausenciaotexto. notificationId siempre
prioritario; correcciones separadas, ruta matchId. No cambiodecódigo posterior
a11focalesPASS+analyzelimpio8.4s ya registrados; pruebasno repetidas.
Build único90.3s, debug/firmaverificados: artifacts/FutBeat-1.0.0-17-n1-v9-acceptance.apk
SHA25649310277688D3138F5589FB68E0BC77CA5982C26AFDDB939BEC6F51A44EC158A,
paquetecom.futbeat.futbeat.qa version17, firmanteF692F70E…0E0FE.
Config artifacts/n1-v9-acceptance-public.json: N1ON/FCMON/GoogleOAuthON,
Authizlmproducción/Firebasefutbeat-686afappQAexistente, G2OFF. No cambios a
Billing/AdMob/UMP. Fuente main8a37e913 conWIPpreservado, sincommit; hashesparser/
test/configyestado en n1-v9-acceptance-manifest.json. Guardbuildimpidesobrescribir
candidata. D222,8858,B756 verificadosintactos. NOinstalada, NOFCMenvíos.
Plan actualizado artifacts/n1-next-acceptance-plan.json: diagnóstico no deportivo
connotificationId/typeDIAGNOSTIC,sinmatchId/eventId; nocreditaMCy no dependeBE18b,
K2oD1. KICKOFFrealposterioralfollow conmatchId/eventId/scopesmatch/scopeKinds
kickoff; navegaciónONLINE exige K2/D1aplicados/openTriggersFetch0. Lecturav9
backendconfirmadeployDONE21:56Z; K2/D1soloDRYsegúnevidenciadisponible, no inferir
aplicación. Noactivarentornopiloto/envíos por crearAPK.
Candidata única lista para instalaciónprueba cuando exista ventanaautorizada,
registro77c8…SM-G781U1 conservado. NoGO físico v9 sinrecepción/procesamiento.
Coordinación deClaude contenía borrador del propietario: sepreservó sineditar
ni enviar en sunombre. Resultados preparados eneste tablero compartido.

### 2026-11-18 — instalación N1-v9 preparada, NO ejecutada
Propietario exige autorizaciónexpresa antesdeinstalar. SM-G781U1 RFCNB05YHKM
conectado,actualcom.futbeat.futbeat.qa D222 confirmado enbase.apk,version17,
UID10355,dataDir/data/user/0/com.futbeat.futbeat.qa. Candidata49310277688D3138F5589FB68E0BC77CA5982C26AFDDB939BEC6F51A44EC158A
exacta, mismo paquete/version/firmaF692F70E…0E0FE. CompatibilidadpreflightPASS.
Delta configuraciónúnico N1false->true; sin cambio de origenAuthizlm/FirebaseQA,
namespaceSecureStorage,clavefutbeat.push.installationniSQLite. Actualización
prevista install-r usuario0, sinuninstall/clear/grantall: retienecontenedor y
Keystore. Postinstalaciónautorizada confirmarOAuthsinrelogin,userf572…,
installation77c8…,mismafiladevice8d5…,ningúnIDnuevo; no prometerpostPASSantes.
APKanteriorespreservadas. N1soloONenconfigdeaceptación; noCambiosPlay/binary16.
FCMyaestabacompiladoONenD222; noacciónmanualenable ni cambioBackend/Pilot/cron.
Preparaciónconcreta artifacts/n1-v9-install-preflight.json. NoAPK nueva.
Claude informado decompatibilidad y deguardarGOALencoladocomoevidencia,no
reenviarvencido. EsperarPREcorregidoyventanaAautorizada. Diagnóstico separado
sinMatchCenter; payload a capturar solo mediante lista permitida de campos
notificationId/type y ausenciasesperadas,sinlogscrudos ni tokens. Mecanismode
capturapendientedeconfirmarconClaudeantesdeejecución; nofabricarevidencia.

### 2026-11-18 — Ventana A: diagnóstico FCM PASS físico y cierre seguro
APK D222 conservada en SM-G781U1 (RFCNB05YHKM); no instalación N1-ON,
compilación ni cambio de cuenta, registro o preferencias. Notificación visible
«FutBeat · prueba técnica», origen FutBeat QA, cuerpo «Diagnóstico de
notificaciones. No es un evento deportivo.». ADB filtrado confirmó paquete QA,
tag diag:pilot:20261118T231138 y recepción 23:12:02.972Z (17:12:02.972 CST).
Evidencia: artifacts/n1-window-a-android-notification-metadata.txt. Al tocarla
abrió la lista Partidos, sin Match Center; captura n1-window-a-after-tap.png.
No se guardaron dumps crudos, tokens ni notificaciones ajenas. El data FCM no
fue capturado directamente en Android: correlación por tag con fila backend
d7bc1817-5f7c-4e99-bed7-cdd0d9f72ca5; Claude reconstruyó notificationId/type
DIAGNOSTIC desde v9 y fila persistida, sin matchId/eventId/scopes.
Claude confirmó sent/FCM futbeat-686af y dispatcher HTTP 200 a 23:12:02.9Z,
1 envío diagnóstico, 0 fuera de PL1, 0 duplicados y 0 request_match_detail.
Dos filas deportivas antiguas expiraron y fueron canceladas sin envío.
pilot-off-2 DONE 23:12:48Z; cierre verificado por Claude 23:13:09Z: dry_run,
cron inactivo con texto original, allowlist vacía, secreto retirado, 0 dispositivos
habilitados y health GREEN. Recepción física comunicada a Claude para su registro.
PASS exclusivo del diagnóstico; no acredita filtros deportivos ni navegación
online de Match Center. APK N1-v9 49310277…EC158A preservada sin instalar.

### 2026-11-18 — acuerdo definitivo Claude / Codex y siguiente delta
Acuerdo del propietario vigente: Claude es responsable exclusivo del backend,
contratos, observación y rollback; Codex de Android, pruebas físicas y release.
Este tablero consolida dependencias; los runbooks backend siguen bajo Claude.
Se conservan PASS físicos Premium G2 QA, AdMob/UMP QA, OAuth piloto y diagnóstico
FCM Ventana A. No repetir sin defecto nuevo. N1 tiene fan-out real comprobado,
pero entrega deportiva y filtros siguen pendientes de aceptación física.
BE18b aplicado según confirmación del propietario: observación 24 h pendiente,
no redesplegar. K2/D1 pendientes de aplicación por Claude tras su GO operativo.
Próximo delta Android: con D1 confirmado, apertura online con datos existentes,
estado Actualizando si falta detalle, sin bloqueo y sin adquisición GOAL directa;
correlacionar con evidencia backend de Claude. Después, piloto deportivo PL1:
KICKOFF seguido antes del inicio, equipo, jugador atribuido, deduplicación,
preferencias/offline y navegación al Match Center correcto. Recorrido existente
en artifacts/n1-next-acceptance-plan.json; diagnóstico actualizado a PASS, resto
NOT_RUN. No nueva auditoría, suite completa, build ni instalación en esta etapa.
Se conserva D222 instalada y candidata N1-v9 SHA256 49310277…EC158A preparada;
su instalación sigue requiriendo autorización expresa. No cambios de código.
G3 productivo es dependencia independiente de Claude: G2 QA PASS no acredita
Premium productivo. Push global deshabilitado; Internal Testing ampliado y Alpha
NO-GO hasta aceptación integral y candidata única trazable. Sin nueva autorización
solicitada ahora; no se ejecutaron operaciones externas bajo este acuerdo.

### 2026-11-19 — G3 Google P-0 solo lectura
Handoff CODEX-HANDOFF-D1-N1.md, sección G3, y G3-DESIGN.md consultados.
Proyecto futbeat ACTIVE, número 751942598962. Operador activo henguido@gmail.com.
APIs habilitadas: androidpublisher.googleapis.com, sts.googleapis.com,
iamcredentials.googleapis.com. Pool futbeat-billing existente ACTIVE.
SA futbeat-billing@futbeat.iam.gserviceaccount.com y proveedor edge-prod:
describe devuelve NOT_FOUND; no se crearon. IAM de proyecto: único binding
roles/owner para user:henguido@gmail.com (etag BwZc_HL60RU=); no binding de la SA
productiva. testIamPermissions efectivo confirma serviceAccounts.create,
serviceAccounts.getIamPolicy/setIamPolicy, workloadIdentityPools.create,
workloadIdentityPoolProviders.create/get y serviceusage.services.list.
La lista estática del rol owner no enumeraba permisos de proveedor; el test
EFECTIVO sí los confirma, por lo que no se infiere necesidad de roles nuevos.
Org Policy API deshabilitada: lectura adicional de políticas efectivas no
obtenida; no se habilitó ni se reintentó por otra vía. No afirmar ausencia de
restricciones organizativas a partir de este resultado.
JWKS público preparado por Claude: wif_prod_public_jwks.json, 1 clave EC P-256
ES256/use sig, kid futbeat-billing-prod-20261119, sin d, coordenadas x/y de 43
caracteres. SHA256 35AB1670B7F14AD8114299DBA22B77EA1E405AC9D44DF8F769789E5A509CC92B.
Privada no accedida. Play Console: 2 usuarios actuales (propietario henguido y
SA QA), sin SA productiva; propietario con todos los permisos. Ningún cambio.
Pendientes de autorización: P-1 crear SA productiva sin rol de proyecto ni claves;
P-2 acceso solo com.futbeat.futbeat con Ver información financiera, pedidos y
respuestas de encuesta de cancelación + Gestionar pedidos y suscripciones;
P-3a edge-prod en pool existente con JWKS público, issuer
https://futbeat.com/billing-wif/production, subject futbeat-billing:production,
audiencia canónica del proveedor según handoff; P-3b únicamente
roles/iam.workloadIdentityUser sobre esa SA al principal exacto
principal://iam.googleapis.com/projects/751942598962/locations/global/workloadIdentityPools/futbeat-billing/subject/futbeat-billing:production.
Mínimos de Play corroborados en documentación oficial Android Publisher Getting
Started. Sin permisos de publicación, ficha, cuenta o acceso a otras apps.
P-0 completado con limitación de Org Policy indicada; P-1/P-2/P-3a/P-3b NO ejecutados.

### 2026-11-19 — G3 Google autorización P-1/P-2/P-3a/P-3b: STOP en P-1
Propietario autorizó los cuatro cambios de identidad, sin Supabase ni activación
comercial. Claude confirmó ledger sin operaciones abiertas y reservó SA/proveedor/
sujeto/Play. Preflight exacto: futbeat 751942598962, henguido, pool ACTIVE,
JWKS SHA256 35AB1670B7F14AD8114299DBA22B77EA1E405AC9D44DF8F769789E5A509CC92B.
P-1 create devolvió Created service account [futbeat-billing] y email autorizado.
El describe inmediato devolvió NOT_FOUND para esa misma SA. Se detuvo toda
mutación según compuerta del propietario; no se repitió create. Posible demora
de propagación NO confirmada. No declarar PASS de cuenta, IAM o claves.
P-2/P-3a/P-3b NO EJECUTADOS; formulario Play vacío, sin invitación enviada.
Permisos añadidos por Codex: ninguno; ninguna clave JSON generada; QA intacto.
Baseline de IAM preservado en artifacts/g3-google-identity-evidence.json con
resultado parcial y rollback preparado (disable de SA), no ejecutado. No aplicar
rollback ni recrear ante lectura fallida sin verificar estado exacto. Claude
informado de STOP; sin autorización de backend, intake, RTDN o pagos reales.
Siguiente delta: resolver mediante lectura puntual la verificación de SA y
confirmar causa antes de retomar las operaciones detenidas. Resultado global
FAIL de verificación, no fallo demostrado de creación ni PASS de identidad G3.

### 2026-11-19 — G3 P-1 recuperado; P-3a/P-3b PASS; P-2 bloqueado
Lecturas autorizadas de la SA existente: email exacto, uniqueId
103829545940993254300, habilitada (disabled omitido por API = false), 0 claves
administradas por usuario, IAM inicial vacío. Create NO repetido.
Reserva de Claude vigente: sin operaciones incompatibles; backend no ejecutado.
P-3a creado y describe PASS: edge-prod ACTIVE en pool futbeat-billing,
issuer https://futbeat.com/billing-wif/production, mapping google.subject=assertion.sub,
condición exacta subject futbeat-billing:production + issuer exacto. Audiencia
explícita única https://iam.googleapis.com/projects/751942598962/locations/global/workloadIdentityPools/futbeat-billing/providers/edge-prod.
JWKS de hash autorizado subido, 7 campos públicos coinciden; una clave sin d.
P-3b único binding en SA: roles/iam.workloadIdentityUser al principal exacto
principal://iam.googleapis.com/projects/751942598962/locations/global/workloadIdentityPools/futbeat-billing/subject/futbeat-billing:production.
IAM de proyecto idéntico al baseline; sin roles de proyecto añadidos ni claves.
P-2 NO enviado: Play exige un permiso base de acceso app para aplicar los dos
permisos económicos. Se retiró lectura app preseleccionada; con solo Ver datos
financieros y Gestionar pedidos/suscripciones, Aplicar queda deshabilitado.
No permisos efectivos concedidos en Play. Propietario consultado para ampliar
solo lectura base de com.futbeat.futbeat; ninguna ampliación implícita.
Claude informado de resultados no sensibles. Evidencia y rollback preparado,
no ejecutado, en artifacts/g3-google-identity-evidence.json; captura del bloqueo
g3-play-p2-minimum-access-blocker.png. Supabase, G3 deploy, intake y RTDN intactos.

### 2026-11-19 — G3 P-2 PASS: cierre Google Cloud / Play
Propietario autorizó lectura base solo FutBeat (con calidad) y confirmó enviar
la invitación limitada y su confirmación final. Envío único completado; cuenta
futbeat-billing@futbeat.iam.gserviceaccount.com aparece ACTIVA. Reabierta la
configuración guardada: únicamente com.futbeat.futbeat, 4 permisos efectivos:
Ver información aplicación (lectura), Ver calidad (lectura incluida por Play),
Ver datos financieros y Gestionar pedidos/suscripciones. Cero permisos de cuenta,
administración, publicación/versión, testers, ficha, políticas u otra edición;
sin otras aplicaciones. Guardar cambios deshabilitado en la lectura posterior.
P-1/P-2/P-3a/P-3b PASS. Evidencia consolidada y rollback no ejecutado en
artifacts/g3-google-identity-evidence.json; capturas/textos P-2 en artifacts.
Claude recibió handoff no sensible completo. Sin tokens productivos emitidos,
claves JSON, acceso a privada, cambios Supabase, deploy G3, intake, RTDN o pagos.
Siguiente dependencia exclusiva de Claude: operaciones backend G3 con sus propias
autorizaciones. Esta identidad configurada no acredita disponibilidad de G3 ni
habilita compras reales o distribución Android. QA preservado.

### 2026-11-19 — P-9.0 RTDN: seis lecturas PASS
Evidencia artifacts/g3-p9-0-gcp-readonly.txt, UTC 13:28:51.620Z–13:29:02.947Z.
Pub/Sub no listado entre APIs habilitadas. Proyecto creado 2026-10-04T04:46:29.842Z,
número 751942598962. iam.allowedPolicyMemberDomains efectiva allValues ALLOW.
Topics y subscriptions: vacíos, exit 0 (no se fabricó error de API deshabilitada).
SA list: solo Billing QA y Billing producción; futbeat-rtdn-push ausente.
Sin recursos conflictivos observados, ninguna mutación ni API habilitada.
Claude informado. Siguiente P-9a bajo autorización propia; después P-9b requiere
habilitar Pub/Sub y crear cuenta push sin roles ni claves. Por fecha del proyecto,
no corresponde el binding condicional de TokenCreator para proyectos anteriores
a 2021-04-08. P-9a..P-9e NO ejecutados por esta misión. No repetir estas lecturas.

### 2026-11-19 — P-9b PASS: API Pub/Sub y cuenta RTDN push
Autorización expresa del propietario en este chat: «Autorizo exclusivamente P-9b».
Ocho pasos y códigos de salida en artifacts/g3-p9b-gcp.txt, cierre
2026-11-19T23:39:43.691Z (17:39:43 CST). Proyecto futbeat / 751942598962 y
operador henguido verificados antes de escribir. Pub/Sub habilitada y confirmada;
tópicos y suscripciones vacíos tras enable. Cuenta creada UNA vez:
futbeat-rtdn-push@futbeat.iam.gserviceaccount.com, uniqueId108798014204499368294,
habilitada (disabled omitido por API, valor predeterminado false), 0 claves de
usuario; IAM de cuenta solo etag ACAB, sin bindings. No roles ni TokenCreator.
Describe inmediato NOT_FOUND a 23:38:09Z; relectura autorizada tras propagación
23:39:39Z PASS, sin repetir create. Evidencia conserva fallo inicial y recuperación.
No topics, suscripciones, Play, Supabase, G3, intake ni RTDN comercial modificados.
P-9c/d/e NO ejecutados. Handoff no sensible para Claude: P-9b PASS; siguiente
P-9c con autorización propia (topic y publisher de Play solo en topic).
Canal Claude contiene borrador «º»: preservado sin sobrescribir ni enviar;
resultados entregados en este tablero compartido, pendiente acuse de Claude.
Rollback del runbook preparado, NO ejecutado; no acciones preventivas.

### 2026-11-19 — P-9c PASS: tópico RTDN y publicador de Play
Autorización expresa registrada por Claude en handoff P-9c. Exactamente siete
comandos en orden, todos exit0, UTC 2026-11-20T00:37:32.542Z–00:37:47.424Z
(19 nov 18:37 CST). Evidencia artifacts/g3-p9c-gcp.txt. Lista previa vacía;
creado únicamente projects/futbeat/topics/play-rtdn. Política del tópico:
exactamente un binding roles/pubsub.publisher para
serviceAccount:google-play-developer-notifications@system.gserviceaccount.com,
etag BwZgqnObcFk=. Describe del tópico exacto; suscripciones vacías;
consulta IAM de proyecto para ese principal vacía. Ningún permiso general
concedido. Sin errores/reintentos, cuentas, claves, Play, Supabase ni compras.
Claude recibió PASS y evidencia. P-9d/e NO ejecutados: siguiente autorización
P-9d para suscripción. Tópico inerte sin suscripciones. Rollback del handoff
conservado, no solicitado ni ejecutado; kits de Claude intactos.

### 2026-11-19 — P-9d PASS: suscripción RTDN autenticada
Autorización explícita registrada en handoff de Claude. Exactamente seis comandos,
todos exit0, UTC2026-11-20T02:35:09.103Z–02:35:23.108Z (19nov20:35 CST).
Evidencia artifacts/g3-p9d-gcp.txt. Lista previa vacía; creada solo
projects/futbeat/subscriptions/play-rtdn-prod-push ACTIVE en play-rtdn.
Endpoint y audiencia OIDC exactos:
https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-billing/billing/v1/rtdn
SA futbeat-rtdn-push@futbeat.iam.gserviceaccount.com. Ack30s, retry10–600s,
retención604800s, expirationPolicy{} (sin expiración); sin noWrapper/filter/
deadLetterPolicy. Lista final confirma única suscripción; claves usuario0,
roles proyecto para cuenta push0. Ningún permiso adicional ni reintento.
Claude recibió PASS y evidencia para observe de solo lectura. No Play Console,
Supabase, cuentas ni pagos modificados. P-9e no ejecutado y requiere autorización
propia. Rollback del handoff conservado, no solicitado ni ejecutado.

### 2026-11-19 — P-9e pasos 1–5 UI PASS; recepción backend pendiente
Inicio UTC2026-11-20T03:32:12.0824986Z (19nov21:32 CST), notificado a Claude.
Play Console FutBeat app4974767403919343676 (com.futbeat.futbeat): RTDN activado,
topic projects/futbeat/topics/play-rtdn, Solo compras anuladas y suscripciones;
NO todos productos únicos. Enviar prueba pulsado EXACTAMENTE una vez; sin error
visible. Guardar cambios confirmó Se han guardado los cambios y botón quedó
deshabilitado. Evidencias artifacts/g3-p9e-play.txt y g3-p9e-play.png sin datos
privados. Sin GCP/IAM/Supabase/productos/precios/versiones/tracks modificados.
Claude recibió START_UTC y resultado para observe inmediato de solo lectura;
su ejecución quedó en solicitud de permiso visible al operador. Codex no aprobó
el permiso en nombre del propietario ni ejecutó backend. Recepción autenticada
NO acreditada hasta edge200>=1/401=0/5xx=0, purchases0/rtdn_events0 y salud intacta
por Claude. No repetir prueba. P-9f/P-10 no ejecutados; intake/pagos intactos.

### 2026-11-19 — consolidación Android: fuente real y matriz de aceptación (en curso)
Fuente oficial remota verificada por git ls-remote: main6e10d3c83eed80c34db28ac14aa21af6bc1f81d1.
HEAD local main8a37e913abce5a0a1b1df291214e98f8ffaf91df contiene e3cfc788,
1285566a y 8a37e913, además de WIP preservado. No commit/fetch/merge/push.
Las APK anteriores no son equivalentes a HEAD: B756 es Billing Auth QA; D222
es OAuth/FCM con N1 preferencias off; 49310277 N1-v9 tiene N1 on pero anuncios
apagados y Billing QA off; 99705E80 diagnóstico tiene anuncios de prueba, pero
OAuth/FCM/N1/Billing off. Los manifests antiguos identifican HEAD dirty y algunos
hashes, NO prueban todos los archivos de su fuente. No atribuir WIP posterior a
Play16 ni a esas APK. Nueva candidata única consolidated-acceptance en preparación,
con inventario por archivo y hashes, paquete .qa, sin productos de compra.

| Defecto / función | Referencia | Código / commit | Pantalla | Prueba disponible | Estado en fuente candidata | Físico / pendiente |
|---|---|---|---|---|---|---|
| OAuth y regreso correcto | #103; 30c70421 / 1285566a | Flujo existente + startup Firebase | Inicio / perfil | auth_flows, auth_sheet, account_lifecycle | CORREGIDO; incluido | PASS anterior D222, binario nuevo pendiente |
| Invitado, país, continuidad y preferencias | #103; 30c70421 | onboarding_screen + persistencia | Onboarding / perfil | mobile251_onboarding_restart, mobile260_onboarding_progress_order, mobile261_onboarding_account02 | CORREGIDO; incluido | Recorrido nuevo pendiente |
| Grupo único Favoritos conserva partidos en liga | #220/#162; a76564ad | matches_screen y feed_v2 | Calendario | feed_v2_test (#220), match_prefetch_local_only | CORREGIDO; ya en base16 | No afirmar PASS físico específico |
| Aislamiento favoritos/sesiones y cola offline | #103; e3cfc788/8a37e913 + WIP | database/providers/user_session_access | Favoritos / perfil | account_lifecycle, notification_scopes, qa_auth_isolation | CORREGIDO; incluido | Cambio cuenta en binario nuevo pendiente |
| LIVE fresco/desactualizado, VERIFIED y caché | Caso Granada/Letonia; d15c3c7d + WIP | models y providers | Feed / Match Center | calendar_live_observation, live_events, mobile239_resilience | CORREGIDO; incluido | Frescura backend PASS previo; no repetir como nueva prueba |
| Tabla de fase/grupo y falta de alineación | #221/#147; 25621af2 | tabla contextual, mensajes de cobertura | Tabla / alineaciones | mobile245_standings_phase_contract, match_center_completeness | PARCIAL: UI corregida, caso real BLOQUEADO POR DATOS | Claude: fixture/temporada/fase/grupo/lineup oficiales |
| Perfil club y selección del goleador | #222/#217; 4b667583 + cb147a85 | IDs canónicos y eventos, sin fusionar por nombre | Perfil jugador | player_club_national_matches, mobile261_profile_match_revision | CORREGIDO en selección Flutter; identidad real BLOQUEADA POR DATOS si falta vínculo | Caso físico Acuña pendiente |
| Posibles fixtures duplicados y autogol | #222; 25621af2 | IDs canónicos / contexto de marcador | Equipo / cabecera | mobile245_match_header_integrity, corrected_timeline_score | PARCIAL: presentación cubierta; duplicados de identidades NO se fusionan | Claude: verificar IDs de Cartaginés/Puntarenas |
| Cancha demasiado alta en formaciones de cuatro líneas | Reporte propietario; WIP actual | altura simétrica por máximo real de líneas | Alineaciones | night230_pitch_density: 4-3-3/5-4-1 a escalas1/1.3 | CORREGIDO nuevo; pruebas focales PASS | Render sintético revisado; físico nuevo pendiente |
| Fotos/entrenadores faltantes | #160/#221/#99; d15c3c7d | entity_media + CoachTile, sin datos inventados | Cancha / banca | lineup_enrichment, lineup_player_navigation | CORREGIDO renderer; BLOQUEADO POR DATOS cuando no hay URL/canonicalId/coach | No prometer fotos no entregadas |
| Panel contextual jugador / perfil | #99 y aceptación R2 | WIP R3: ID y metadatos canónicos conocidos, reintento recuperable | Modal / perfil | player_navigation; r3_match_center_regressions (503 y recuperación) | CORREGIDO E INTEGRADO, sin commit | PASS R3 1674688B: alineación → Thiago Mendes → Ver perfil |
| Estadísticas detalladas omitidas y texto inválido como número | Solicitud propietario; WIP actual | añade finalThirdPasses, accurateCrosses, accurateLongPasses, turnovers, groundDuelsWon, aerialDuelsWon, foulsWon/foulsCommitted; valida números/fracciones | Modal jugador | 2 casos nuevos en player_sheet; 42 focales PASS | CORREGIDO renderer; datos BLOQUEADOS POR DATOS si stats ausente | Claude: solo métricas oficiales por jugador, no completar ceros |
| Desplazamiento de pestañas sin indicador D1 | Golden detectado en esta misión; WIP | centra pestañas cuando no hay actualización; conserva Actualizando | Match Center | goldens originales + completeness | CORREGIDO nuevo; validación en curso | No actualizar baselines para ocultarlo |
| Apertura inmediata / Actualizando sin consulta GOAL móvil | D1; WIP previo | datos persistidos, SQLite, lectura por apertura | Match Center | completeness, first_paint, on_demand_contract | CORREGIDO cliente; BLOQUEADO POR BACKEND para aceptación online D1 | Claude GO K2/D1; no despliegue Codex |
| FCMv9 y preferencias jugador/equipo/partido | #106/#110; e3cfc788/1285566a/8a37e913 + WIP | push_messages / scopes | Alertas / notificación | n1_push_payload, notification_scopes, mobile244_notification_dedup | CORREGIDO cliente; entrega deportiva PENDIENTE | Diagnóstico PASS D222; piloto PL1 real necesario |
| Gratis AdMob/UMP junto a N1/OAuth | #105; 8a37e913 + WIP actual guard Gradle | permite .qa debug/profile de aceptación, anuncios test y cero productos | Calendario / privacidad | suite ads/UMP; build gate | CORREGIDO configuración nueva | AdMob/UMP PASS9970; nueva combinación pendiente |
| Billing403/503, reemplazo, restore, revocación | #105; 8a37e913 + WIP previo | Billing único, autoridad servidor | Premium / perfil | billing*, premium_qa_transport, billing_android_plan_change | CORREGIDO código; misma implementación, QA auth separado | G2 PASS B756; G3 intake off, no nuevas compras |
| Eliminación de cuenta y recibos por origen | #103; 8a37e913 + WIP | account_deletion_receipts, account_security_screen | Perfil / privacidad | account_lifecycle, account_deletion_receipt, qa_auth_isolation | CORREGIDO cliente | No borrar cuentas en aceptación sin autorización |
| Buscar vacío / perfiles bloqueados | Aceptación R2 P0 | WIP R3: sesión normal30/min y120/15min; Preview conserva8/30; auth/rutas/concurrencia intactas | Buscar / perfiles | public_access_transport, search_autocomplete, first_paint | CORREGIDO E INTEGRADO | PASS 1674688B: Saprissa y Serie A desde Buscar |
| Seguir desde Buscar no aparece o se pierde al reiniciar | Aceptación R2 P0 | WIP R3: metadatos públicos seleccionados SQLite; combina respuesta parcial; selección actual manda | Favoritos | favorites_offline_restart: proceso nuevo, parcial, usuario/offline | CORREGIDO E INTEGRADO | PASS seguir/mostrar/reinicio/dejar de seguir; once originales restituidos |
| Foto del jugador desaparece en arranque limpio | Hallazgo físico R3 | WIP R3: resolver existente absorbe detalle SQLite verificado; matchId y canonicalId exactos | Favoritos | nueva regresión sin HTTP ni IDs de proveedor | CORREGIDO E INTEGRADO | PASS 1674688B: foto Thiago sin abrir partido |
| Navegación entre días lenta | Aceptación R2 P1 | WIP R3: fecha cacheada con invalidación; guarda estable reutiliza snapshot; QA profile hereda identidad final de debug | Calendario | calendar_prefetch, retry_navigation, R3 modelos; CPU A32 | CORREGIDO E INTEGRADO en recorridos medidos |31–131ms, mediana66,5ms; datos26–124ms; cero HTTP de calendario durante seis cambios |
| Rating, probable/confirmada, estadísticas preinicio, Current | Aceptación R2 P1/P2 | WIP R3: rating finito0<r<=10, títulos explícitos, sin ceros preinicio; fase original intacta | Match Center | R3, standings_phase, goldens | CORREGIDO renderer; BLOQUEADO POR DATOS si faltan | Preinicio PASS físico diagnóstico; rating/probable PASS automático sin dato físico inventado |
| H2H pendiente parece carga infinita | Aceptación R2 P1 | WIP R3: estado pendiente asentado + Actualizar manual; conserva extensión acotada | Cara a cara | match_h2h_v2, h2h_full_history; sin reintento automático | CORREGIDO E INTEGRADO | PASS 1674688B Molde–Bodø/Glimt; dato sigue PENDING |
| Arsenal mezcla homónimos y atributos | R3; id-guard/id-split/id-attrs de Claude | Tres IDs separados; nombres/países/escudos 141/997/1348 renovados normalmente | Perfil equipo | r4-arsenal-*-curated.png; r4-arsenal-curated.sqlite; R4-curated-belarus.png | CORREGIDO BACKEND / PASS físico de actualización sin borrar datos | Ningún nombre/escudo fijado en Flutter |
| Tabla e historial ausentes en Molde–Bodø/Glimt | Caso R3 de aceptación R2 | match fb_match_71c81a5780a44be19f4f2580f70ad53d temporada2026: standings missing0filas, H2H PENDING0meetings | Tabla / H2H | r3-molde-public-contract.json; r3-h2h-safe-runtime.jsonl | BLOQUEADO POR DATOS | Claude: disponibilidad exacta; no sustituir fase/temporada |
| Ruta inexistente de sugerencias de jugadores | Confirmación Claude posterior a R3 | R4 elimina método HTTP y consumidores Explorar/onboarding; solo catálogo/Búsqueda existentes; compatibilidad antigua devuelve vacío sin dependencias | Explorar / onboarding | player_suggestions; pruebas R4 con contadores de lecturas cero | CORREGIDO EN APK R4 A44D39FA | Once favoritos conservados; ninguna llamada a la ruta retirada |
| H2H verificado desaparece al caducar caché y fallar red/503 | Reproducción R4 | R4 conserva historial público de SQLite con aviso STALE; sin renovar savedAt ni ocultar401/403/ID incorrecto | Previa / H2H | r4_coverage_contract:503, recuperación, actualización, datos privados/ajenos | CORREGIDO EN APK R4 A44D39FA | HTTP503 PASS determinista; H2H AVAILABLE PASS físico, no se simula interrupción productiva |
| Partidos conocidos desaparecen ante página PENDING/STALE vacía | Reproducción R4, tres casos fallaban antes del arreglo | Conservar filas conocidas hasta cobertura completa; filas de página ganan por ID; Actualizar manual, sin polling nuevo; NO_DATA sigue autoritativo | Perfil equipo / Partidos | r4_team_matches_pending:6PASS; profile_context y retarget | CORREGIDO EN APK R4 A44D39FA | Fallo/recuperación/ausencia de polling probados localmente; Partidos y Ver todo PASS físico |
| Pestaña cambia al aparecer/desaparecer una tabla | Reproducción R4 fallaba en equipo y competición | Controlador conserva sección por nombre; retirada de sección activa vuelve a Resumen; Ver todo usa ese controlador | Perfiles | r4_profile_navigation:2PASS; perfiles afectados46PASS | CORREGIDO EN APK R4 A44D39FA | Cambio dinámico PASS widget; navegación estable y Ver todo PASS físico |
| Duplicado GOAL/TSDB aún en página team-matches | Nuevo hallazgo físico R4, NO en calendario/Resumen ya corregidos | Respuesta HTTP vigente upcoming incluye dos IDs distintos para mismo encuentro; coverage AVAILABLE/windowComplete true | Perfil equipo / Partidos | r4-team-matches-discrepancy.json; r4-arsenal-r4-view-all.png | BLOQUEADO POR BACKEND | Claude: /v1/team-matches id=fb_team_0c679cdda8a44bc184f2fc088c969c1f bucket=upcoming; no deduplicar por nombres en Android |
| Preferencias N1 retienen cuenta anterior o completan su carga con una operación vieja | Reproducción R4: lectura/respuesta/error/guardado entre A/B | Escucha accountChanges; limpia solo al cambiar propietario; epoch protege resultado/error/finally; expansión identificada por cuenta | Alertas por seguimiento | r4_notification_scope_lifecycle:5PASS; grupo N1/v9/dedup27PASS | CORREGIDO EN R4 D474503D | PASS físico lectura/expansión/volver; cambio de cuenta y fallos son deterministas, no se alteraron cuentas del A32 |
| Actualizar con cobertura pendiente borra encuentros obtenidos por paginación | Dos reproducciones R4, ausentes del snapshot inicial | Retiene filas de páginas sin reutilizar cursor antiguo; nueva fila manda por ID; respuesta AVAILABLE/NO_DATA autoritativa elimina o corrige; filtro/equipo limpia retención | Perfil / Partidos | r4_team_matches_pending:8PASS, perfiles/retarget23PASS | CORREGIDO EN R4 D474503D | Escenario de respuesta parcial PASS determinista, no se fabricó un fallo backend para QA |
| Sesión ausente deja Reintentar que nunca puede leer preferencias | Reproducción R4 de cierre de sesión | Acción Iniciar sesión abre la ruta existente /profile/account; no crea identidad ni cambia autenticación automáticamente | Alertas por seguimiento | caso lost-session de r4_notification_scope_lifecycle | CORREGIDO EN R4 D474503D | Navegación PASS widget; no se cerró sesión real para forzar el caso físico |

Nueva candidata máxima segura: Auth/API producción, OAuth, N1v9/FCM y anuncios
TEST con UMP; sin productos Billing configurados ni credenciales Auth QA. La
variante G2 separada comparte código, conserva APK y evidencia aprobada. No se
presenta Premium productivo inactivo como PASS de aceptación integral. News,
FPD y funciones experimentales no se activan. A32 conectado, pero captura CUA
falla GPU; solicitada autorización específica para QA visual mediante ADB.

### Candidata consolidada congelada — 1.0.0 (17), sin publicar
Artefacto único nuevo: artifacts/FutBeat-1.0.0-17-consolidated-acceptance.apk,
SHA2564361E514B735A0FE66569D13415AA2E3FC09332153D869132DBA18F22FA16C26,
paquete com.futbeat.futbeat.qa, version17, target36/min24, debug firmado con
certificado autorizado F692F70E…0E0FE. Config/build/inventario reproducibles:
artifacts/consolidated-acceptance-public.json,
artifacts/build-consolidated-acceptance.ps1,
artifacts/consolidated-acceptance-source.json y manifest consolidado.
Incluye TODO el código Android local hasta el hash por archivo, no solo HEAD.
Sin fuente alterada tras build según comparación de inventario. Configuración
con Auth/API producción y Firebase QA correcto; N1/OAuth/FCM on; solo anuncios
Google TEST+UMP, sin geografía forzada, sin productos Play y G2 QA desactivado.
No secretos privados ni campos de credenciales privilegiadas en config. No se
construyó AAB, no nueva numeración por arreglo, no se sobrescribieron D222/4931/
B756/8BE/9970. Premium G2 sigue acreditado en variante aislada, no en este APK.
Mejoras nuevas integradas: cancha evita línea vacía, stats opcionales completos
según cobertura y formato numérico seguro, guard de build permite convivencia
QA N1/OAuth+UMP sin Billing QA, tabs no se desplazan sin Actualizando.
42 pruebas focales PASS; 49 regresiones (incluidos goldens originales) PASS;
analyze final limpio. Primera suite encontró dos goldens afectados por tabs y
una aserción de calendario que exigía agotar intentos aun al vencer deadline.
Se corrigieron causa visual y aserción para verificar límites reales; no se
cambiaron baselines visuales. Suite final y contratos en ejecución al registrar.
NO instalada: A32 tiene paquete oficial y .qa, ambos conservados. Captura CUA
falló dos veces con GPU 0x887A0005; permiso específico ADB visual solicitado y
pendiente. Antes de instalar, comprobar sesión .qa para no registrar FCM de un
segundo teléfono por accidente. SM-G781U1 no está conectado. No PASS físico
nuevo ni GO oficial. Claude recibió compatibilidad/dependencias en su cola.

### Compuerta final Flutter de la candidata 4361E514 — PASS
Fuente exacta congelada: analyze final sin incidencias; suite completa final
2154 PASS / 6 omitidas / 0 fallos, 10m16s, incluidos goldens originales sin
actualizar referencias. Logs: consolidation-analyze-final.log y
consolidation-full-final.log. Focales42 + regresiones49 anteriores conservados.
Marcadores comprobados DENTRO del kernel del APK: pitchRowCount, Pases en último
tercio, Duelos terrestres ganados, accurateLongPasses, scopeKinds, playerRole.
Evidencia consolidated-acceptance-binary-markers.json. Esto prueba inclusión, NO ejecución
física. Toolchain Flutter3.47.4 rev9584c671 en consolidation-flutter-toolchain.json.
Contratos backend siguen ejecutándose sin fallo registrado; aceptación física
pendiente de permiso ADB visual/lectura de sesión antes de instalar. No nueva APK.

### Cierre local de consolidación — candidata lista para aceptación, NO-GO oficial
Candidata y SHA sin cambios: 4361E514B735A0FE66569D13415AA2E3FC09332153D869132DBA18F22FA16C26.
Flutter completo final2154 PASS/6omitidas/0fallos; analyze limpio; goldens
originales PASS. Contratos npm completos:1360total,1358PASS,2TODO,0fallos,
0cancelados. Log artifacts/consolidation-contracts.log, exit0. Diff check limpio.
Manifest final artifacts/consolidated-acceptance-manifest.json contiene fuente,
configuración, firma, evidencias y separación QA/producción. NO nueva APK ni AAB.
Candidato APTO PARA PRUEBA DEL PROPIETARIO, no aceptado físicamente: no se pudo
capturar el A32 por GPU y autorización ADB visual sigue sin respuesta. No se
instaló sobre .qa ni se registró otro token; ambas instalaciones A32 intactas.
Pendientes de prioridad alta: aceptación física de este SHA (incluyendo sesión,
favoritos/onboarding, cancha/estadísticas y reconexión); entrega deportiva N1 y
navegación online en piloto PL1 tras GO K2/D1. Premium productivo aún bloqueado
por intake OFF y autorización comercial: no se concede localmente ni se mezclan
Auth QA/producción. Los PASS G2/UMP/OAuth/FCM previos se conservan con sus APK,
no se trasladan al binario nuevo. Issues #221/#222 necesitan evidencia de datos
reales para cerrar los casos específicos; pruebas Android descritas en matriz.
No nuevo P0 demostrado en pruebas; NO certificar ausencia de P1 hasta ese QA.
Sin commits, push, merge, ramas/worktrees nuevos ni cambios de servicios externos.

### 2026-11-20 — ADB visual autorizado; bloqueo real de compatibilidad A32
A32 RF8R32GQWGL conectado y captura ADB funcional. Solo lecturas y copia de
APK existente; no abrir app, instalar, bajar versión, borrar datos ni cambiar
cuenta/permiso. QA instalada com.futbeat.futbeat.qa versionCode2017, UID10354,
certSHA2566533B820F58EE837E6BBEDB29F09B26A8384760EE3DE13C5CB6185AD114C0362.
Candidata4361 usa version17 y firma F692…: actualización normal incompatible.
APK existente preservada artifacts/A32-existing-qa-2017-preserved.apk, SHA256
FCC8F6D0191F660517D240A9824CD8B549AC46E644A131A5C69FA6E4556CD3B9.
Notificaciones del paquete QA denegadas; no registro push, piloto ni sesión
modificados. Captura inicial solo demuestra ADB, NO aceptación FutBeat.
Propietario consultado: conectar SM-G781U1 compatible D222/F692/version17 o
preparar firma QA compatible para A32 verificando keystore, sin desinstalar.
No nuevo APK/recompilación/repetición de pruebas en esta continuación.

### 2026-11-20 — copia A32 compatible preparada e instalada; aceptación bloqueada
Propietario autorizó firma QA compatible y actualización debug sin desinstalar.
Keystore debug EXISTENTE coincide con cert6533B820…14C0362. Refirmada sin recompilar
copia artifacts/FutBeat-1.0.0-17-consolidated-A32-compatible.apk, SHA256
7909C1B4FD1D929BEE389BCB4600288E98E3E3600401AAF3BDEB948383CCE86E.
Original4361 intacta. Comparadas632 entradas ZIP no firmantes: todos los hashes
idénticos; pruebas2154Flutter/1358contratos conservadas para ese contenido.
Instalación adb install -r -d: Success, version17. UID10354->10356 y primera
instalación nueva: propietario confirmó que ELIMINÓ manualmente QA durante la
preparación. Codex no ejecutó uninstall/clear; NO acreditar preservación de los
datos que borró esa eliminación. QA notificaciones sigue denegado, sin login,
cambio de cuentas, envíos o registro piloto desde Codex. Oficial no modificada.
Aperturas am/launcher muestran splash y vuelven al launcher. Android exit-info:
reason10 USER_REQUESTED/subreason21 FORCE_STOP/status0, no crash demostrado.
Origen del cierre aún desconocido. La coincidencia local android-smoke PID15672
NO quedó confirmada: podía ser el propio comando de búsqueda; se corrigió el
aviso al propietario. Autorización para detener esa tarea recibida, pero NINGÚN
proceso detenido por falta de identidad confirmada. No atribuir bloqueo a otra
sesión sin evidencia. Monitor PC y shell breve no identificó caller.
Evidencia segura artifacts/A32-consolidated-exit-evidence.txt. Manifest
consolidated-A32-compatible-manifest.json refleja instalación y NO-PASS físico.
Siguiente discriminante solicitado al propietario: desconectar USB y abrir
manualmente QA30s, sin cuentas ni permisos. No otra APK ni pruebas repetidas.

### 2026-11-20 — causa USB confirmada, retirada autorizada, QA físico básico PASS
Emisor real capturado: adb29944 -> pwsh12204 -> svchost(TaskScheduler). Script
C:/Users/hen_g/.codex/visualizations/2026/10/08/01a11d81-14eb-7170-966a-ead982b2856f/qa123/qa123-launcher.ps1.
Tarea FutBeat-QA123-Launcher activa desde17nov, poll5s, cierra .qa como huérfana
si no existe su ledger activo. Esa regla explica los FORCE_STOP USER_REQUESTED;
no era un crash demostrado ni la firma de la APK. Identificación anterior
android-smoke no confirmada se corrigió antes de detener procesos.
Propietario autorizó expresamente retirar ESTA tarea antigua. Disabled y detenida;
launcher12204 residual finalizado tras validar identidad; definición XML, scripts
e historial conservados. Evidencia artifacts/A32-QA123-retirement.json y XML.
Rollback exacto Enable-ScheduledTask + Start-ScheduledTask para ese único nombre.
No ADBglobal, Androidpermisos, PL1, kitsClaude o servicios externos modificados.
MISMA APK7909, sin recompilar: estable varios minutos con USB, PID32111. PASS
físico LIMITADO: bienvenida, Continuar como invitado, calendario con fecha local,
Favoritos vacío, Perfil invitado, navegación y banner Google «Anuncio de prueba».
Permiso POST_NOTIFICATIONS sigue DENEGADO. Sin login/cambio de cuenta ni piloto
FCM del A32. No PASS de preservación de datos tras eliminación manual del dueño.
Capturas: A32-USB-QA123-retired.png, A32-consolidated-calendar-stable.png,
A32-consolidated-favorites.png, A32-consolidated-guest-profile.png. Manifest
consolidated-A32-compatible-manifest.json actualizado con alcance estricto.
No MC ONLINE (D1 pendiente), N1deportivo ni Premium en esta variante.
Hallazgo nuevo de datos:20nov Primera División CR, dos filas20:00 vsSanCarlos:
Escorpiones de Belén(sinlogo) / Escorpiones Belén(conlogo). No afirmar mismo
canónico ni deduplicar por nombre. Claude recibió captura/referencia para
comparar IDs solo con lecturas existentes. Handoff visible en su cola, sin
activar operaciones. Aceptación integral/candidata oficial sigue NO-GO hasta
casos deportivos y MatchCenter/D1, además de resolver datos del caso observado.

### 2026-11-20 07:14Z — aceptación física incremental A32 / BE15 y Match Center

Binario realmente instalado y comprobado mediante SHA-256 de base.apk:
`7909C1B4FD1D929BEE389BCB4600288E98E3E3600401AAF3BDEB948383CCE86E`,
com.futbeat.futbeat.qa 1.0.0(17), A32 RF8R32GQWGL. Misma copia compatible
con las 632 entradas de aplicación idénticas a la candidata4361. Sin recompilar,
sin cambios nuevos de producto y sin repetir suites automáticas ya aprobadas.
Se mantienen los resultados previamente vinculados al código congelado:
analyze limpio; Flutter2154PASS/6skip; contracts1358PASS/2TODO/0fail.

| Recorrido / defecto | Resultado físico estricto | Evidencia / dependencia |
| --- | --- | --- |
| Calendario BE15,20nov,Escorpiones Belén–San Carlos | PASS: un canónico GOAL, ambos escudos,20:00 CR; navegación al encuentro correcto; no reaparición del ID TSDB tras refresh, cierre/reapertura, offline y reconexión | A32-BE15-calendar-refreshed.png, A32-BE15-match-navigation.png, A32-offline-cold-calendar-settled.png |
| Perfil equipo y competición | PENDIENTE de datos: siguen mostrando dos IDs para20nov20:00 CR, también después de reentrada online | A32-team-profile-revalidated.png, A32-competition-profile.png, A32-BE15-profile-ids.json; handoff enviado a Claude |
| MC programado Escorpiones | PASS limitado: cabecera, fecha/jornada, previa y forma reciente, entrenadores Andres Arias/Walter Centeno. Titulares y estadísticas explican ausencia, sin carga infinita | A32-BE15-match-navigation.png, A32-BE15-lineup.png, A32-BE15-statistics.png |
| MC finalizado Vasco–Internacional | PASS limitado:2–1,Thiago Mendes26,Colidio63,Jose Juninho52,estadísticas comparativas,tabla provisional con aviso de guardada,formaciones4-3-2-1/3-4-2-1,titulares,suplentes,fotos disponibles y entradas/salidas | A32-vasco-summary.png, A32-vasco-statistics-correct.png, A32-vasco-table.png, A32-vasco-lineup-lower.png, A32-vasco-lineup-bench.png, A32-vasco-lineup-bottom.png |
| Panel jugador | PASS limitado: Thiago Mendes foto,87min,1gol,gol26/salida87 y acceso Ver perfil visible. No ratings/estadísticas individuales inventadas | A32-vasco-player-sheet.png y A32-player-route-profile.png: Ver perfil PASS físico posterior07:16Z, abre Thiago Mendes/Vasco con contexto87min,1gol y eventos correctos |
| MC offline | PASS del detalle ya persistido: cabecera,goleadores y estadísticas visibles sin redes; no equivale a PASS de política D1v2 online | A32-vasco-offline-open.png |
| Favoritos invitado | PASS: seguir equipo,jugador,competición y2partidos; estrellas/listas; persistencia tras cold start offline; dejar de seguir jugador offline, equipo y competición online | A32-team-followed.png, A32-player-followed-confirmed.png, A32-competition-followed.png, A32-offline-favorites-persisted.png, A32-offline-player-persisted.png, A32-offline-player-unfollow.png, A32-favorites-team-unfollowed.png; matches persistidos en SQLite y estrella verde19nov |
| OAuth,cambio usuario,aislamiento y alertasN1 | NO REPETIDOS / no nuevo PASS sobre este binario: A32 se conserva invitado, POST_NOTIFICATIONSdenegado. N1deportivo depende del pilotoClaudePL1 | Mantener evidencia histórica por APK/entorno; sin registrar A32, sin eventos artificiales |

Aclaración #220: al seguir equipo/competición, la sección FAVORITOS del calendario
y su sección de liga conservan el mismo encuentro (comportamiento explícito del
test feed_v2_test.dart). Eso NO es un segundo ID canónico. El caso pendiente de
perfil sí contiene DOS IDs distintos, no se deduplicó por nombre en Android.

Handoff puntual entregado a Claude sin autorizar operaciones:
- Equipo `fb_team_0c679cdda8a44bc184f2fc088c969c1f`.
- TSDB `fb_match_36e66d65ff5a46a5bbddfcbf360d4bdf`,externalId2557493.
- GOAL `fb_match_f5ea5705815c41e7a9cf0721a754a4f1`,externalId785713.
- Mismos home/away y comienzo2026-11-21T02:00Z. Respuesta de perfil revalidada
  conserva updatedAt2026-11-20T02:00:06.354Z y freshness.stale=false; pendiente
  distinguir caché/proyección del backend. No afirmar que sean nuevos registros.
- MC `fb_match_7cdfad25a3a54e64b56024c09bce823b`: detail disponible,22titulares;
  seis titulares image=null, rating=null en todos, sin stats individuales;
  estadio=null,coaches=null; referee sí recibido. Fotos que sí tienen URL cargan.
  Evidence `A32-match-data-coverage.json` y copia deportiva localSQLite. No afirmar
  ausencia GOAL: solo ausencia en el contrato recibido. Estadísticas ataque/defensa/
  duelos individuales y ratings siguen BLOQUEADOS POR DATOS para aceptación física.

Redes Wi-Fi/datos restauradas a1/1. Sin excepciones AndroidRuntime/flutter:E en
el log filtrado del proceso actual9849 al07:13Z; alcance limitado a ese proceso,
no certificación global de estabilidad. Permiso notificaciones sigue denegado.
Los cambios de follows son locales del invitado; no hubo login ni cambios PL1.
D1v2 NO aplicado según último estado del propietario: no PASS definitivo de
apertura online ni de ausencia de adquisición backend. No se llamó GOAL API desde
Android ni se añadió adquisición. No Supabase/Play/IAM/producción modificados.

Decisión: GO para evaluación personal de los recorridos documentados en la MISMA
APK instalada; NO-GO de aceptación integral/candidata oficial: resta resolver el
perfil duplicado y cerrar D1v2/N1deportivo mediante sus compuertas y piloto.
No P0/P1 Android nuevo demostrado en este muestreo; no equivale a inexistencia
absoluta. Sin nuevo APK por ausencia de corrección de producto justificada.

### 2026-11-20 13:28Z — BE15-TSDB-TWINS, cierre físico PASS (sustituye pendiente anterior)

Corrección backend confirmada por el propietario: be15-tsdb-twins aplicado por
Claude,19duplicados TSDB retirados globalmente,5exclusivos conservados. Codex no
repitió ni modificó esa operación. MISMA APK7909 instalada en A32, sin recompilar.

PASS físico: perfil Escorpiones Belén y Primera División CR muestran una sola
fila Escorpiones–San Carlos20nov20:00CR. Confirmado después de cerrar/reabrir
QA mediante force-stop/start sin desinstalar, borrar datos o cambiar sesión.
GOAL conserva `fb_match_f5ea5705815c41e7a9cf0721a754a4f1`,externalId785713,
comienzo2026-11-21T02:00Z. TSDB36e66d65 ya no está en el perfil renovado.
Comparación SQLite antes/después:25->20partidos en perfil de equipo; los20IDs
restantes se conservan íntegros; los5retirados tenían procedencia TheSportsDB.
Herediano27nov y resultados Cartaginés/Alajuelense/InterSanCarlos siguen visibles.
Follows idénticos antes/después (comparación de filas ordenadas), sin cambios
manuales de favoritos, cuenta o permisos.

Primera apertura mostró caché antigua guardada07:09:32Z y un fallo transitorio
«No se pudo cambiar · Reintentar». NO se atribuyó ese duplicado al backend.
Al completar la lectura normal, caché de equipo reemplazada13:26:54Z y UI quedó
única. Reapertura posterior confirmó equipo/competición correctos. Sin limpieza
SQLite: watchPublicEntity emite disco/memoria asStale, luego loadEntity renueva
la respuesta; revalidateEntitySnapshot permite reentrada tras30s o respuesta
stale/error y evita vuelos concurrentes. No defecto persistente de invalidación
reproducido; no corrección Android necesaria. updatedAt del payload sigue02:00Z,
por lo que la evidencia se apoya en savedAt local e IDs/contenido, no solo en ese
campo. No nuevo PASS D1v2/N1/Premium ni suites repetidas.

Evidencia:
- artifacts/A32-BE15-twins-team-settled.png (equipo único, otros partidos).
- artifacts/A32-BE15-twins-competition-final.png (competición tras reapertura).
- artifacts/A32-BE15-twins-result.json (IDGOAL,20retenidos,followsUnchanged=true).
- artifacts/A32-BE15-twins-cache-report.json (caché ANTERIOR, no estado backend actual).
- Copias locales deportivas before/after preservadas. Sin credenciales extraídas.

CERRADO el bloqueo de duplicados en perfiles del reporte07:14Z. Resultado de
esta petición PASS; ningún defecto Android concreto pendiente por este caso.
D1v2 y aceptación deportivaN1 permanecen fuera del alcance de esta comprobación.

### 2026-11-20 — candidata consolidada R2: correcciones UI y aceptación física limitada PASS

Cambios incrementales sobre TODO el trabajo local previo, HEAD8a37e913 sin commit:
- Defecto reproducido: suplente de nombre largo con cinco eventos provoca RenderFlex
  overflow4px a escala1.0. Log compact-lineup-reproduce-new.log. Solución: Wrap de
  dos columnas con altura natural; mantiene eventos y texto, sin Grid de celdas fijas.
- Cancha: base84px frente100, crece por texto/eventos medidos; mide también jugadores
  sin eventos. Mitades simétricas; geometría legacy individual conserva100px para
  no introducir un recorte en esa ruta. Formación/posiciones/identidad sin cambios.
- Encabezado de cancha: entrenador conserva avatar disponible por el resolver
  existente y nombre de hasta2líneas; antes solo mostraba nombre aun con foto válida.
  Sin resolver nuevo, sin consultas de proveedor ni fotografías inventadas.

Pruebas: analyze limpio9.8s; suite Flutter COMPLETA una vez tras cambios finales,
2154PASS/6skip/0fail,4m36s (compact-flutter-full.log). Incluye regresiones N1v9,
Billing403/503/reemplazo, aislamiento, onboarding/favoritos y goldens. Se revisaron
renders y actualizaron solo6baselines de alineaciones; originales en
artifacts/compact-goldens-before. Contracts backend previamente1358PASS/2TODO,
sin cambios de contrato/backend en esta misión: NO repetidos ni nuevo PASS remoto.

UNA nueva candidata de la misma línea/version17, no AAB ni nuevo canal:
`artifacts/FutBeat-1.0.0-17-consolidated-r2-A32.apk`
SHA256 `A8FD2C8B65D9544350AC74C1F43AD7932AAA4347988CBAA9B138D1DE379294C9`.
Firma A32compatible6533B820..., paquete.qa, debug17; manifiesto y firma verificados.
Fuente exacta congelada consolidated-r2-source.json;0drift después del build y QA.
Diff de ESTA misión separado de WIP anterior compact-match-center-incremental.patch.
APK7909 anterior y demás artefactos preservados; no reescritos ni desinstalados.

Actualización A32 mediante install-r: Success, UID10356 y primera instalación
00:17:35 conservados. Comparación SQLite de follows y preferences antes/después:
ambos idénticos. Permiso notificaciones sigue denegado; sin registro piloto A32.
Hash de base.apk realmente instalado coincide con A8FD. Evidencia en manifest y
consolidated-r2-data-preservation.json, device-before/after.

PASS físico LIMITADO de A8FD: cancha compacta de Vasco–Internacional, etiquetas y
minutos legibles; suplentes con nombres largos y eventos reales sin recorte;
fotos disponibles; tocar Marino Hinestroza abre su panel correcto (entró72,
amarilla89, foto y dorsal18). Capturas A32-r2-lineup-top.png, A32-r2-bench.png y
A32-r2-bench-player-sheet.png. El caso de5eventos es prueba automatizada, NO evento
físico artificial. Foto de entrenador solo PASS automatizado: coaches=null en este
partido; no se declara PASS físico de un dato no entregado.

Conservados clienteOAuth/FCMv9/N1,AdMobtestUMP,BillingG2 y protección cuentas;
MISMA configuración pública aislada de la candidata anterior, sin mezclar AuthQA
Billing con sesión producción N1. Billingproductivo y compras reales deshabilitados
por configuración/intake vigente; no se presenta esta APK como aceptación Premium
productiva. PremiumG2,OAuth,UMP y FCMdiagnóstico anteriores mantienen evidencia de
SUS APK y entornos, sin repetir ni trasladar indebidamente el PASS a este binario.

No P0/P1 Android nuevo demostrado en recorridos modificados; no auditoría global.
GO para evaluación personal del nuevo UI instalado; NO-GO de aceptación integral/
release mientras D1v2 y piloto deportivoN1 no estén acreditados y G3 comercial no
supere su activación autorizada. Estadísticas individuales/ratings/fotos ausentes
siguen dependencia de campos del contrato registrado en la matriz; no inventados.
No operaciones de Claude,producción,Play,IAM,commits,push,merge o ramas nuevas.


### 2026-11-20 — R3 aceptación: correcciones ejecutadas y físico de recorridos PASS

Reabre y cierra solo los defectos R2 aquí comprobados; no es aceptación integral.
HEAD main8a37e913, WIP previo preservado, sin commits/ramas/push/merge ni backend.
Candidata ÚNICA entregada para reevaluación, instalada en A32:
`artifacts/FutBeat-1.0.0-17-consolidated-r3-acceptance-A32.apk`
SHA256 `1674688B1784AFF9A92B872FF32AA8A1EC6D753608B86A7E5BEF315506854EF4`.
QA profile/AOT, paquete.qa, firma6533B820… y version17 conservados; no es release.
El tipo profile copia la identidad final de debug SOLO con bandera QA existente;
release y otras variantes no cambian. Misma configuración segura: Auth/API de
producción, N1/FCMv9, anuncios TEST/UMP, sin productos Billing ni AuthQA mezclados.
No activa Premium comercial, push global ni fases operativas de Claude.

Causas P0 confirmadas: la sesión normal usaba presupuesto Preview8/min; R2 bloqueó
localmente /v1/search (r3-r2-api-errors-safe.txt). El seguimiento se guardaba, pero
Buscar no persistía sus metadatos y Favoritos esperaba HTTP de la selección nueva.
Ahora mantiene esos metadatos públicos, filtrados por follows actuales, aunque la
respuesta nueva sea parcial o falle. Perfil de jugador conserva el ID y contexto
conocidos durante un503; reintento recupera el perfil completo sin inventar club
actual ni admitir identidades contradictorias. No se alteran timestamps deportivos.

CPU A32 detectó1376/5150 muestras inclusivas en DateTime.parse antes del ajuste;
cachear el valor con invalidación y no reconstruir guardas estables elimina ese
coste repetido. Coste residual debug dominado por framework. QA optimizada:
seis cambios65/68/131/31/102/31ms, mediana66,5ms; datos63/66/124/30/83/26ms.
Cero HTTP de calendario durante los seis cambios; renovaciones anteriores de
fondo independientes. Datos medidos con memoria/SQLite; no se promete dato que
no exista localmente. Evidencia r3-acceptance-calendar-metrics.json y log asociado.

Pruebas:2166PASS/6skip/0fail, suite completa4m45s (r3-final-full-flutter.log),
incluye contratos cliente/goldens. Último ajuste pequeño H2H posterior:46focales
PASS (r3-final-h2h-regressions.log), analyze limpio. No otra suite completa por
ese ajuste de estado/acción. Solo baseline Explorar por texto revisado.
Contracts backend previos1358PASS/2TODO no repetidos: backend sin cambios.
Compilación profile real + verificación firma/manifest prueban el ajuste Gradle.
Inventario exacto consolidated-r3-acceptance-source.json, manifest.json y script
build-consolidated-r3-acceptance.ps1. Cero drift de fuente después del build/QA.
R2 A8FD y diagnósticos DAAE/7AAF quedan conservados, no se entregan como candidata.

Físico1674688B: Buscar Saprissa → seguir → perfil → Favoritos; Serie A desde Buscar;
alineación Vasco–Internacional → Thiago Mendes → Ver perfil; foto Favoritos en
arranque limpio sin abrir partido; H2H pendiente con Actualizar manual; reapertura
offline y recuperación Favorites862ms. LIVE real Molde0–0 al5′ observado durante
el recorrido, sin falso aviso; sin eventos artificiales. Capturas A32-r3-acceptance-*.
Rating/probable/confirmada: PASS automático, no inventar una muestra física ausente.

UID10356 y primera instalación00:17:35 intactos. Once follows originales y
preferences idénticos al cierre; cuatro selecciones de prueba retiradas solo por
UI. Sin borrado/desinstalación/cambio de cuenta. Redes restauradas; notificaciones
siguen denegadas, A32 no registrado al piloto. Cero marcadores de excepción no
controlada en sesión final. Evidencia consolidated-r3-owner-final.json y manifest.

Handoff de datos a Claude, sin autorización de escritura implícita:
1. /v1/entity?type=team&id=fb_team_9d44c27f7a1444fd8286929bd857592d: Arsenal inglés
   llega con escudo ajeno y partidos Prim B Metro/Premier League. La mezcla ya
   está en payload público persistido, no es una identidad fusionada por Android.
   r3-arsenal-public-contract.json contiene ID, matches, escudo y redirects.
   Esperado: escudo y encuentros de la misma identidad canónica verificada.
2. /v1/match-context?id=fb_match_71c81a5780a44be19f4f2580f70ad53d, temporada2026:
   standings=missing, standingsPending=false,0filas. /v1/match-preview del mismo
   ID devuelve H2H availability=PENDING,state=none,meetings0,matchIds0, comprobado
   en objeto recibido (r3-h2h-safe-runtime.jsonl). Esperado: tabla exacta de fase/
   temporada e historial verificado cuando disponibles, o disponibilidad terminal
   explícita cuando no haya cobertura. No completar con otra temporada ni adquirir
   proveedor desde el móvil. UI pendiente corregida; dato deportivo no fabricado.

GO para reevaluación personal de R3 instalada. NO-GO de aceptación integral/release
por la mezcla canónica y cobertura pendiente confirmadas. N1 deportivo, D1v2 y G3
comercial conservan sus dependencias y evidencias anteriores; no se activaron ni
se certificaron otra vez. Rollback QA disponible: R2 A8FD mediante install-r,
misma firma/version y sin migración de esquema/borrado. No rollback ejecutado.


### 2026-11-20 — R4 local: cobertura real, ruta retirada y continuidad H2H

El propietario confirma PASS físico R3 de Buscar/perfiles/favoritos. Se conserva
APK1674688B y evidencias. No ADB, cambios de cuentas/favoritos, nueva APK, commit,
push/merge, rama/worktree, backend, IAM o Play en esta etapa. Once favoritos no
intervenidos. HEAD8a37e913 y trabajo anterior preservados. Cambios acumulados para
una sola R4 posterior; no se presentan todavía como corrección instalada.

Ejecutado localmente:
- Retirada /v1/player-suggestions: cero referencias de ruta en lib; ningún consumidor
  UI del proveedor deshabilitado. Explorar y onboarding usan únicamente jugadores
  que ya entrega catálogo/Buscar. La sección se omite si no hay jugadores reales;
  buscar y seleccionar jugadores sigue disponible. Sin llamadas auxiliares nuevas.
- Respuesta asentada sin alineación: «Alineaciones aún no publicadas» si programado,
  o no disponibles para el partido si iniciado/finalizado. Solo una petición real
  en curso mantiene estado de carga exterior; no se fabrica XI desde perfiles o
  formaciones. Probable/confirmada requieren señal explícita; once nombres o datos
  históricos no la establecen. Claude confirma que hoy GOAL no aporta esa señal.
- Tabla missing/pending: estado discreto de actualización pendiente y Actualizar;
  unavailable: clasificación no disponible. Preservadas fase/temporada exactas,
  lecturas acotadas y aparición en pantalla cuando llega AVAILABLE. Sin adquirir GOAL.
- Rating de cancha/modal/rankings usa el mismo validador de fila del partido,
  finito0<r<=10. No consulta stats.rating/seasonRating del perfil. Se corrigió que
  rankings aceptaban Infinity/11 mientras cancha/modal los rechazaban. La ausencia
  actual en GOAL sigue oculta; no se sustituye por la valoración de temporada.
- H2H: se reprodujo pérdida de historia SQLite pública tras30s + HTTP503. Ahora se
  conserva como STALE, en Previa y Cara a cara con aviso, usando el mismo repositorio.
  No se renueva savedAt al leer. Mantiene TTL30s normal y retención pública existente,
  una petición compartida, cero reintentos nuevos, rechazo de caché privada/ID ajeno,
 401/403 y respuesta con otra identidad. Recuperación200 acepta la historia corregida.
- Arsenal aislado en widget: dos clubes homónimos con IDs distintos conservan sus
  escudos y partidos respectivos. No fusión por nombre ni nueva regla resolver en
  Android; no se modifica la protección de resultados VERIFIED de R3.

Validación focal: grupo Explorar/rankings27PASS; H2H+cobertura37PASS; regresiones
históricas/estados/actualizaciones65PASS; homónimos1PASS; últimas guardas R4 y
onboarding8PASS. Casos de onboarding ya ejecutados en r4-affected-flows.log sin
fallos propios; expectativas antiguas de cobertura se actualizaron y sus grupos
se cerraron en r4-coverage-ui-regressions.log. Nuevos contratos prueban PENDING→
AVAILABLE por /v1/match-preview, tabla nueva de2026 y rechazo de2025, rating de
 temporada excluido y protección de identidades/autorización. Analyze limpio4,1s
(r4-final-analyze.log). No suite completa repetida, sin cambios de goldens aprobados.
No nuevo PASS físico: el binario del teléfono sigue siendo R3.

Trazabilidad: artifacts/r4-local-changes.patch, r4-local-source.json, r4-before y
r4-*.log. Fuentes R3 congeladas y APK anteriores intactos; no se descarta WIP.

Dependencias mínimas Claude, conforme CODEX-HANDOFF-R2-DATA.md ya leído:
1. Adquisición central programada de tablas e H2H. El cliente está probado para
   consumir las mismas rutas y estados; no necesita otro endpoint ni polling GOAL.
   Se conserva caso Molde fb_match_71c81a5780a44be19f4f2580f70ad53d de R3.
2. Verificar asociaciones canónicas de Arsenal fb_team_9d44c27f7a1444fd8286929bd857592d,
   escudo/encuentros por proveedor e identidades explícitas de su reparación. No se
   infieren bajas/fusiones por ausencia de filas ni se borran cachés del propietario.
Probables y ratings por partido no tienen fuente actual: permanecen sin valores,
no se solicita ni se simula un servicio paralelo. N1/G3 y otras operaciones de
Claude conservan sus compuertas. R3 sigue disponible para uso; aceptación integral
mantiene NO-GO hasta cerrar datos/dependencias y evaluar la única R4 cuando proceda.

### 2026-11-20 21:00Z — Arsenal tras id-guard/id-split: prueba física focal

A32 RF8R32GQWGL, com.futbeat.futbeat.qa 1.0.0(17). SHA del base.apk instalado
comprobado por ADB: 1674688b1784aff9a92b872ff32aa8a1ec6d753608b86a7e5bef315506854ef4
(R3 aceptada; R4 sigue local, sin recompilar/instalar).

PASS físico parcial: Buscar y abrir cada club, Resumen y Plantilla. Inglaterra:
Premier League/Champions, Newcastle/Dortmund/Manchester City, 15 jugadores.
Argentina: Prim B Metro, Comunicaciones/Deportivo Merlo, 56 jugadores.
Bielorrusia: Premier League bielorrusa, Neman/Vitebsk/Gomel/BATE, 50 jugadores.
Las cantidades corresponden al contrato almacenado; no acreditan que todas las
inscripciones/transferencias estén al día. Los dos últimos mantienen la advertencia
de plantilla pendiente de actualización.

Caché PASS: entrada inglesa anterior savedAt1795195685 reemplazada por1795208054;
las dos identidades nuevas se guardaron normalmente. Comparación automática de
los tres perfiles SQLite con GET /v1/entity?type=team&id=<ID>, 20:56–20:59Z:
61/36/32 partidos, cero IDs extra o ausentes; plantillas coinciden exactamente
por ID con API. Cierre/reapertura sin borrar datos conserva los perfiles.
Follows=11 e idénticos fila a fila al inicio; preferences idénticas. Sin acciones
de autenticación, sin registrar FCM ni cambiar cuentas. No se afirma igualdad
binaria del almacenamiento seguro, que puede cambiar al renovar una sesión.

FAIL media/datos confirmado; no es un duplicado SQLite:
- fb_team_9d44c27f7a1444fd8286929bd857592d, Inglaterra: API renovada aún devuelve
  media.url=https://media.goal-api.com/badges/1348_arsenal-fc.jpg, visible como
  escudo de Dzerzhinsk en england-before.png y england-reopened.png.
- fb_team_e77e864d58d7ce8ba22d44629ce41aab: sin media en API; UI muestra iniciales
  AD (belarus.png). No se reutiliza el escudo inglés por nombre.
- fb_team_dcf19b92176c91074d448800a50eb1e9: escudo Sarandí correcto visible
  (997_arsenal-fc.jpg), pero entidad pública sigue name=Arsenal FC,country=''.
  Inglaterra también country='' en entity; Buscar sí distingue ambos por país.
  Dependencia mínima Claude: media/nombre/país de esas filas del contrato existente.

Evidencia: artifacts/r4-arsenal-api-summary.json, r4-arsenal-public-<ID>.json,
r4-arsenal-preservation.json y capturas XML/PNG de perfil/plantilla/reapertura.
Prueba focal r4-arsenal-compare.py: PASS, assertions de los once favoritos,
preferencias y correspondencia exacta de partidos/plantillas persistidos.
Sin repetir suites Flutter aprobadas: no hubo cambio de código Android.
Correcciones R4 conservadas; ningún rating o XI inventado.

El handoff consultado no registra cov-1 aplicado: esperar confirmación de Claude
para aceptar tablas/H2H nuevos, sin provocar adquisición ni polling.
Sin compilación, commit, push, merge o cambios backend. R4 única sigue acumulada.
NO-GO de aceptación completa de Arsenal hasta resolver media y verificar respuesta.

### 2026-11-20 22:18Z — R4 única compilada, instalada y comprobada

Artefacto: artifacts/FutBeat-1.0.0-17-consolidated-r4-acceptance-A32.apk.
SHA256 archivo e instalación ADB idénticos:
A44D39FA6B66E3864CE6E9FF2401FE7BC5E8AA5142A9A36C0572BCFA452E786F.
HEAD8a37e913 + cambios locales, SIN commit. Inventario congelado364fuentes en
consolidated-r4-acceptance-source.json; todos sus hashes siguen coincidiendo
después de build y prueba física. Firma QA compatible6533b820…; profile/AOT,
com.futbeat.futbeat.qa 1.0.0(17), configuración idéntica a R3, entorno Auth/API
producción con anuncios TEST; ningún producto Billing/credencial Auth QA añadido.
Premium G2 y APK previas conservan su evidencia separada; no se acreditan compras
productivas/N1 deportivo en esta candidata. No APK intermedias ni nuevo AAB.

Cambios nuevos de esta continuación: página de Partidos PENDING/STALE no elimina
los encuentros ya conocidos; un vacío NO_DATA confirmado sí es autoritativo.
Actualización manual empieza en primera página, conserva contenido durante fallo,
permite reintentar y mantiene Ver más; sin temporizador o petición GOAL nueva.
Se eliminan «Cargando partidos/historial» de respuestas ya asentadas. Segundo
defecto: una tabla que llega durante la consulta desplazaba Plantilla/Noticias;
ahora equipos y competiciones conservan la sección por nombre y la retirada de
la sección activa vuelve a Resumen. Ver todo navega con el controlador correcto.
Conservadas todas las correcciones previas R4, sin inventar rating/XI probable.

Pruebas: analyze limpio (r4-final-analyze-integrated.log). Nuevas guardas8PASS;
perfiles afectados46PASS. Suite completa una vez:2182PASS/6skip/9fallos de
expectativas antiguas de texto. Se alinearon únicamente esas expectativas y el
estado asentado (sin tocar código funcional ni baselines gráficos), y se cerraron
los siete archivos afectados:102PASS. Los otros2182 casos, incluidos goldens y
contratos cliente, permanecen con código funcional idéntico. No se repite toda
la suite por textos de test. Compuerta auditable r4-final-test-gate.json verifica
los9fallos exactos, cierre102PASS y cero cambios de aplicación posteriores al
congelado completo. El log original conserva exit1, sin ocultarlo ni sustituirlo.

Físico R4 A32 RF8R32GQWGL PASS de recorridos comprobados: calendario inicial;
Buscar→Escorpiones→perfil; tabla Bundesliga de cov-1 (18filas API, posiciones
visibles Bayern/Dortmund/Freiburg); Match Center Escorpiones–San Carlos, tabla
Apertura con advertencia de frescura conservada; H2H AVAILABLE con final oficial
San Carlos0–3Escorpiones del26jul2026 y próxima cita claramente sin resultado;
alineaciones parciales muestran entrenadores y «Titulares no disponibles», sin
XI ni rating artificial; volver a perfil/Buscar y Ver todo→Partidos; Favoritos.
Cambio de pestaña durante llegada de datos y503 son pruebas deterministas, no
inyecciones físicas ni PASS productivo inventado. Cero marcadores de excepción
en el log Flutter de ese proceso durante los recorridos (no auditoría de ANR).

Preservación PASS: adb install-r Success; UID10356 y primera instalación
2026-11-20 00:17:35 intactos. Once follows y preferences exactamente iguales a
SQLite previo a instalación y al cierre. No login/logout ni cambio de cuenta;
permiso POST_NOTIFICATIONS permanece DENIED; no registro/envío piloto en A32.
R3 1674688B y demás artefactos anteriores intactos. R4 queda abierta en Favoritos.

Arsenal: runbook Claude confirma id-attrs aplicado22:00Z. Antes de actualizar APK,
reentrada normal en R3 mostró los tres nombres/países/escudos correctos y SQLite
los guardó: Inglaterra141, Sarandi997, Dzerzhinsk1348. Capturas *-curated.png.
R4 conserva Dzerzhinsk corregido al navegar desde Buscar (r4-curated-belarus).
No cambio de atributos en Flutter, ninguna limpieza/invalidez manual de datos.

Dependencia nueva concreta Claude, 22:15:08Z: GET /v1/team-matches?id=
fb_team_0c679cdda8a44bc184f2fc088c969c1f&bucket=upcoming&limit=20 devuelve
coverage.teamMatches AVAILABLE, windowComplete=true, pero incluye simultáneamente
fb_match_36e66d65ff5a46a5bbddfcbf360d4bdf (TheSportsDB2557493) y
fb_match_f5ea5705815c41e7a9cf0721a754a4f1 (GOAL785713), ambos mismos IDs de equipos
y kickoff2026-11-21T02:00Z. GET /v1/entity del mismo equipo devuelve solo GOAL
para ese encuentro. UI Partidos reproduce dos filas; Resumen/calendario conservan
una. Es respuesta vigente, no SQLite antiguo ni el fallback PENDING de R4.
No se revive como fallo del índice ya corregido por be15; diferencia de ruta/read
model demostrada. No fusionar desde Android por nombres/fecha. Evidencias completas
en r4-team-matches-discrepancy.json y r4-escorpiones-*-public.json.

Manifest y evidencias: consolidated-r4-acceptance-manifest.json,
r4-physical-http-safe.log (solo rutas/tiempos, sin tokens), capturas r4-arsenal-r4-*,
r4-local-changes.patch acumulado (parche inicial también conservado).
Sin operaciones backend, commits, merges, push o publicación. cov-1 y st-groups
son trabajo de Claude; Android solo consume rutas FutBeat existentes.
GO para evaluación personal R4 con el defecto backend expuesto; NO-GO para
declarar producto completo o ampliar distribución (N1 deportivo/comercial y
correcciones backend conservan sus compuertas propias).

### 2026-11-21T03:06Z / 20nov21:06 Costa Rica — R4 integrada, sin operaciones externas

Continuación sobre la misma base, sin ramas/worktrees/commits. Diferencia de
aplicación frente a A44D39FA: únicamente team_matches_tab.dart y
notification_scopes_screen.dart. OAuth, parser FCM-N1v9, AdMob/UMP, Billing,
SQLite, Buscar y Favoritos mantienen hashes de fuente de esa R4. D1v2 no se
reimplementa. No se investiga K2/P-9f/Arsenal ni se emite un nuevo veredicto backend.

Corregidos dos fallos demostrados y la acción de acceso asociada: preferencias
de N1 se renuevan al cambiar la cuenta; ninguna operación antigua puede poner
su matriz/error o quitar el indicador de la nueva lectura. Reintentar conserva
la matriz confirmada y la sección abierta para la misma cuenta, sin optimismo
sobre guardados fallidos. Sin sesión se ofrece Iniciar sesión funcional en vez
de un reintento imposible. En perfiles, Actualizar parcial conserva encuentros
que llegaron en páginas anteriores, no solo los del snapshot inicial; se separan
del cursor nuevo. Una respuesta confirmada vacía o corregida sigue siendo
autoridad. Reset de equipo/filtro limpia la retención; sin peticiones adicionales.

Focales: N1/v9/deduplicación27PASS, perfiles/contexto/retarget23PASS. Analyze
final limpio6,1s. Suite integral final2198PASS/6omitidas/0fallos,8m05s, incluidos
goldens originales y contratos cliente; ningún baseline actualizado. Logs
r4-integral-final-flutter.log y r4-integrated-final-analyze.log. Backend de Claude
no se modifica ni se repiten sus auditorías/observaciones.

Única compilación posterior al conjunto: FutBeat-1.0.0-17-consolidated-r4-integrated-A32.apk,
SHA256 D474503DC186A61A70050F107583196DF566527CE8DAB5120CFE492639FA1D72,
archivo e instalación coinciden. Profile QA, versión17, misma firma A32 y misma
configuración pública de R4 anterior; cero credenciales Billing QA añadidas.
Inventario366fuentes consolidated-r4-integrated-source.json, hashes verificados
después de build y físico. Se conservaron APK A44D39FA y anteriores. Cambios
incrementales de aplicación en r4-integrated-followup.patch y backups r4-followup-before.

Físico A32 RF8R32GQWGL: actualización-r Success; UID10356, primera instalación
2026-11-20 00:17:35, once follows y preferences exactamente intactos. UI sesión
Invitado sin login/logout. Permiso Android sigue denegado. PASS apertura de
Notificaciones→Alertas por seguimiento, matriz jugador/equipo/partido y expansión
Jugador con sus categorías y cobertura; volver atrás y Favoritos. No se pulsa
interruptor ni Activar notificaciones, no registro FCM o envío iniciado por esta
tarea. Cero marcadores de excepción en el proceso Flutter observado. Capturas
r4-arsenal-integrated-*.png/XML y manifest consolidated-r4-integrated-manifest.json.
No se acredita como físico el cambio de cuenta, pérdida de sesión, fallo offline
o respuesta de paginación parcial: tienen fixtures deterministas, sin alterar
cuentas ni forzar fallos productivos. R4 queda abierta en Favoritos para el propietario.

Piloto N1 preparado en el plan existente n1-next-acceptance-plan.json (original
conservado): alienmagiccr, SM-G781U1 RFCNB05YHKM, installation_id
77c8be62-2165-447c-bf1f-ae8ee7f1f9eb. Dispositivo no conectado; solo A32 presente.
APK49310277 v9 intacta, parser sin cambios; esa APK anterior NO incluye estas
correcciones de ciclo de vida. Su firma F692F70E difiere de la firma A32: no
instalar la copia A32 en G781 ni desinstalarlo. Revalidar instalación/firma/usuario
y PL1 en la ventana autorizada; la aceptación completa del nuevo código requiere
la firma compatible de ese teléfono, derivada de la misma fuente, sin otra
implementación. No se instala/activa/envía nada para el piloto en esta continuación.

No P0/P1 Android nuevo observado en recorridos modificados tras correcciones;
no equivale a certificar ausencia global ni entrega deportiva real. El duplicado
team-matches conserva su última evidencia22:15Z del20nov: no se reconsulta ni se
afirma que siga presente después de trabajos de Claude. GO evaluación personal
de esta R4, NO-GO distribución oficial mientras faltan aceptación N1 y compuertas
backend/comerciales correspondientes. Sin nuevas APK intermedias, AAB, cambios
Play/IAM/Supabase/GOAL, compras, commits, merges o push.
