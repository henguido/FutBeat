# MOBILE260 — progreso funcional local

Checkpoint UTC: 2026-11-03T22:08:44.115249+00:00. Rama codex/mobile-260-integration, código 31ecbb7c6915eb31c65f1f13bd40b593805f7e38.
Tiempo transcurrido medido desde el checkpoint inicial: 44.3 minutos; incluye pruebas y coordinación, no equivale a horas CPU ni a QA física.

## Estado

43 issues iniciales / 20 abiertos; 0 issues cerrados remotamente. Las correcciones siguientes están integradas localmente y conservan pendiente la aceptación física y del contrato desplegado. No se modifica main, producción, teléfono, goldens ni artefactos Android.

- A07/A09: escrituras y ACK de perfil ordenados; reconciliación no pisa cambios locales ni otra sesión; borrado de cuenta y permisos push ligados a la cuenta/intención original.
- A02/A03/A07: progreso onboarding ordenado, errores de país recuperables, carga de ajustes antes de editar nombre y UPSERT SQLite parcial atómico.
- S06/M02: Favoritos y liga conservados; aliases explícitos resueltos para agrupación, deduplicación, orden y precarga exclusivamente local.
- M04/M09: eventos canónicos, penalti, autogol, actividad de jugador y referencias de Tabla preservados sin unir homónimos.
- M07/M10: caché de imágenes detecta corrupción y respeta reparaciones posteriores; límites de tamaño preservados.
- S03/S05/S07: replay antiguo tras DELETE bloqueado, reloj de última página REST, eventos extranjeros rechazados antes de reemplazar IDs y observaciones antiguas no degradan frescura.
- M03: contexto de otro partido rechazado antes de contaminar caché, media o redirects.

## Evidencia

Primer bloque integrado: 1665 PASS. Segundo bloque: 1710 PASS / 3 FAIL; dos fixtures de imagen inválidos y una espera incompleta del bootstrap identificados y corregidos, sin cambiar expectativas funcionales ni PNG golden. Regresiones cruzadas posteriores: 14 PASS. Identidad de contexto: 17 PASS. Suite completa del tercer bloque: **1730/1730 PASS**, 104 segundos, goldens incluidos (código 31ecbb7). Analyze posterior al ajuste exclusivo de llaves en tests: **PASS, 0 avisos**, 6,8 segundos (02651d1).

Parches de agentes comprobados mediante ascendencia, archivos y patch-id: artifacts/mobile260/integration/ledger.json. Regresiones previas fallidas y logs posteriores se conservan en artifacts/mobile260.

## Release

RC NO-GO: falta CI Linux del HEAD nuevo, certificado de subida confirmado, configuración aprobada, QA física y contrato conectado vigente. CI histórico de PR243/07a54b25 no acredita MOBILE260. PR dependiente preparada conceptualmente hacia codex/mobile-252-release; no push ni workflow con secretos ejecutado.

## Próximo bloque

Terminar regresiones de intención push ante respuesta tardía y error de borrado, cerrar analyze y suite integrada; revisar persistencia de intereses. Sin resultados reales de OAuth, FCM o A32 en esta sesión.

## Commits locales acumulados

```
f3720b66 fix(profile): serialize local preference writes and acknowledgements
16a56ad0 fix(account): scope pending profile saves and retry stale acknowledgements
3e7f30ee fix(feed): complete bounded favorite disk warm batches
c3332dbb fix(match): resolve dismissal minutes by canonical identity
a2bfec6c fix(match): retain canonical penalty goals in summaries
519079b9 fix(live): fence deleted versions against stale replay
1e9dd425 fix(live): preserve freshness across bootstrap pagination
6dfdec2b fix(account): retain edits made during profile reconciliation
6f661a7d fix(account): preserve countries changed during cloud reconciliation
2e092e14 fix(account): bind deletion to its original session generation
f45894df fix(account): prevent push opt-in transfer during account changes
ea9bebc0 fix(push): scope notification grants and tokens to current intent
433c9cea fix(feed): retain followed teams through explicit redirects
d92aacfd fix(feed): deduplicate explicit redirected fixture identities
543c5570 fix(feed): warm canonical followed fixtures from disk
f15ef4c5 fix(feed): preserve redirected competition groups
41de2389 fix(feed): preserve canonical competition pin order
3b7625dd fix(match): retain explicit own-goal attribution
35f8dbe0 fix(profile): preserve canonical player match activity
77a65af3 fix(profile): retain standings through team redirects
ed8df6ce fix(profile): resolve primary competition before table choice
4d247bcd ci: allow dependent Android release candidate checks
42d4d35f fix(images): recover corrupt persistent entity images
5d7e3d7b fix(images): preserve newer repaired cache file versions
bd911849 fix(alerts): finish saves safely after route closes
1b7f0b53 fix(alerts): ignore obsolete preference recovery reads
577bf25c fix(onboarding): order progress persistence and completion
3d7a4f29 fix(onboarding): recover country selection after local errors
b18b101b fix(account): wait for stored settings before name changes
f66feff1 test(mobile260): use valid image fixtures and settled LIVE responses
04a0d0f7 fix(cache): reject foreign match contexts before persistence
0ba2b182 fix(preferences): atomically preserve concurrent preference edits
816498e7 fix(live): filter foreign events before replacing retained IDs
31ecbb7c fix(live): preserve newer identical-version observations
```

## Bloque posterior: país y notificaciones

- e44257e: ACK tardío de país no borra la intención posterior. Reproducción1FAIL antes;102pruebas focales PASS después.
- 6303b0f: registros push HTTP ordenados y error de borrado no restaura una autorización retirada; antes4PASS/2FAIL, después6/6 y144focalesPASS. Son servicios simulados, no FCM real.
- 2cd3b70: guardia de Match Center conserva redirects explícitos de equipos/competiciones con el mismo ID de partido. No se amplió el contrato de redirección de partidos.
- 8ce170d: reinicio de provider conserva dirty; fallo de escritura permite retry y ACK de selected no borra detected.4PASS. No se reprodujo el supuesto fallo de interests y no se cambió ese código.
- Analyze del bloque6303b0f: limpio10,4s. Suite global del bloque8ce170d en ejecución.

Fallo de invocación conservado: push-fifo-initial-after.log incluye96PASS y1error de carga por ruta inexistente push_test.dart. Se corrigió la selección de archivos, no el producto; corrida válida posterior144PASS.

Checkpoint UTC 2026-11-03T22:16:34.568856+00:00; transcurridos 52.1minutos desde START. Ningún cierre remoto, build, publicación ni operación productiva.

### Historial acumulado actualizado

```
f3720b66 fix(profile): serialize local preference writes and acknowledgements
16a56ad0 fix(account): scope pending profile saves and retry stale acknowledgements
3e7f30ee fix(feed): complete bounded favorite disk warm batches
c3332dbb fix(match): resolve dismissal minutes by canonical identity
a2bfec6c fix(match): retain canonical penalty goals in summaries
519079b9 fix(live): fence deleted versions against stale replay
1e9dd425 fix(live): preserve freshness across bootstrap pagination
6dfdec2b fix(account): retain edits made during profile reconciliation
6f661a7d fix(account): preserve countries changed during cloud reconciliation
2e092e14 fix(account): bind deletion to its original session generation
f45894df fix(account): prevent push opt-in transfer during account changes
ea9bebc0 fix(push): scope notification grants and tokens to current intent
433c9cea fix(feed): retain followed teams through explicit redirects
d92aacfd fix(feed): deduplicate explicit redirected fixture identities
543c5570 fix(feed): warm canonical followed fixtures from disk
f15ef4c5 fix(feed): preserve redirected competition groups
41de2389 fix(feed): preserve canonical competition pin order
3b7625dd fix(match): retain explicit own-goal attribution
35f8dbe0 fix(profile): preserve canonical player match activity
77a65af3 fix(profile): retain standings through team redirects
ed8df6ce fix(profile): resolve primary competition before table choice
4d247bcd ci: allow dependent Android release candidate checks
42d4d35f fix(images): recover corrupt persistent entity images
5d7e3d7b fix(images): preserve newer repaired cache file versions
bd911849 fix(alerts): finish saves safely after route closes
1b7f0b53 fix(alerts): ignore obsolete preference recovery reads
577bf25c fix(onboarding): order progress persistence and completion
3d7a4f29 fix(onboarding): recover country selection after local errors
b18b101b fix(account): wait for stored settings before name changes
f66feff1 test(mobile260): use valid image fixtures and settled LIVE responses
04a0d0f7 fix(cache): reject foreign match contexts before persistence
0ba2b182 fix(preferences): atomically preserve concurrent preference edits
816498e7 fix(live): filter foreign events before replacing retained IDs
31ecbb7c fix(live): preserve newer identical-version observations
02651d13 test(profile): keep concurrency regressions lint clean
035fd49e docs(mobile260): checkpoint integrated fixes and 1730 passing tests
e44257e6 fix(preferences): preserve dirty country intent after delayed ACK
2cd3b701 test(cache): retain legitimate entity redirects in match contexts
6303b0f5 fix(push): serialize remote registration and retain latest disable
8ce170d0 test(preferences): cover restart, failed writes and independent country ACKs
```

## Validación conjunta posterior

Código8ce170d: **1737/1737 PASS**,113s, goldens incluidos, sin referencias PNG modificadas. Esto suma94tests frente a1643delbaseline; no equivale a94bugs. Analyze final del mismo código: **PASS, 0 avisos**,7,7s. Sin cambios backend, Supabase, AndroidManifest, Gradle, keystores o APK/AAB.

Play Console solo lectura: release interna4(1.0.0) visible. Se alcanzó Firma de aplicaciones→Clave de subida. El botón de copia indicó éxito pero clipboard no devolvió texto; descarga de certificado no produjo archivo observable en10s. Huella upload sigue NOT VERIFIED; no se solicitó cambio ni se ejecutó workflow con secretos. AppSigningSHA visibleD3:07:B7:E2:F9:D3:99:FA:3C:6C:C3:14:B6:DE:B0:01:39:B3:F6:09:A9:6B:87:EB:FB:76:48:12:D1:0D:CD:E4, que no sustituye al certificado upload.

Checkpoint UTC2026-11-03T22:18:37.310685+00:00; 54.2min transcurridos medidos desdeSTART. No se prometen8–12h ni continuidad tras cerrar el chat.

## Pendientes de mayor prioridad

Los20issues abiertos conservan su clasificación:2P0 (#108/#109, release),10P1 y8P2/alcance. No se cerraron issues remotos. Los34bloques funcionales corregidos localmente (24parches de agentes y10correcciones raíz; se excluyen CI, harness, estilo y pruebas positivas) no se cuentan como34issues cerrados.

P0externos: certificado upload confirmado, configuración aprobada y CI Linux del HEAD candidato. P1de aceptación: A32/contrato desplegado para feed, perfiles, tablas e identidad; OAuth/FCM requieren servicios/autorización. No hay un siguiente fallo P0/P1 local reproducido pendiente en este corte; los candidatos negativos investigados sin fallo se conservan como pruebas positivas y no generaron cambios ficticios. Continuar cuando exista nueva evidencia concreta o autorización de CI/aceptación, sin ampliar a funcionalidades P2.

Siguiente acción de entrega: publicar la rama aislada y PR Draft dependiente hacia codex/mobile-252-release para CI Linux, mediante autorización específica. No se ejecutó push ni se creó PR en este bloque.
