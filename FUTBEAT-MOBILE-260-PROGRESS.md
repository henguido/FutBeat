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
