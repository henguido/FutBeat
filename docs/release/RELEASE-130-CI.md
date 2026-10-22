# Release 130 — CI Flutter preparada

Base local: `6a6a34e2dc152ac254999572b3100587d794417f`.
Workflow: `.github/workflows/release-130-flutter.yml`.

El workflow es exclusivamente manual (`workflow_dispatch`) y no recibe
secretos. Usa Ubuntu, Flutter 3.47.4, permisos `contents: read` y checkout sin
credenciales persistentes. Comprueba loopback antes de Flutter, resuelve con
`pubspec.lock` estricto, conserva SHA y hashes, ejecuta analyze, 21 pruebas
focales y la suite completa. La suite incluye explícitamente la existencia de
`visual_test.dart`; no usa `--update-goldens` y falla si cambia o aparece un
golden. Logs, metadatos y fallos visuales se conservan 30 días como artefacto
nombrado con el SHA exacto.

No se ejecutó localmente Flutter ni se activó CI remoto durante esta
preparación, debido a la protección de QA126 y al bloqueo loopback ya
documentado en Windows.

## Efecto de un futuro push de esta rama

| Workflow existente | Disparador | ¿Se activa solo por push a esta rama? |
|---|---|---|
| `release-130-flutter.yml` | `workflow_dispatch` | No |
| `beta-android.yml` | `workflow_dispatch` | No |
| `ci.yml` | PR hacia `main` | No; un push sin PR no lo ejecuta. Con PR abierto sí ejecutaría contracts/mobile |
| `goal-api-probe.yml` | `workflow_dispatch` | No |
| `live-fixtures.yml` | Manual o push a `main` cuando cambia su propio archivo | No |
| `global-fixtures.yml` | Schedule o manual | No por este push; sus ejecuciones programadas son independientes |
| `standings.yml` | Schedule o manual | No por este push; sus ejecuciones programadas son independientes |

Un push futuro no basta para ejecutar la verificación nueva: después de subir
la rama se necesita una autorización separada para lanzar manualmente
`Release 130 Flutter verification`. Abrir o actualizar un PR hacia `main`
también activaría el CI general existente y debe considerarse una acción
remota distinta.
