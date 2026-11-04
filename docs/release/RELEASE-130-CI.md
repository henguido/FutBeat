# Release 130 — activación CI corregida

Fecha: 22-10-2026. Rama `codex/release-130-ci-play`, base `cfb862b` (sobre R130 `6a6a34e`).
Solo preparación local: no push, PR, dispatch, build Android ni ejecución remota.

## Corrección

GitHub main verificado: `99da8729660892dac76720a5732885fa039d5709`.
Su árbol contiene seis workflows y no contiene `release-130-flutter.yml`;
la lectura del archivo en ese SHA devuelve 404. Un workflow nuevo con solo
`workflow_dispatch` necesita existir en la rama predeterminada para recibir
ese evento. No se modifica main para resolverlo.

El trigger definitivo es exclusivamente:

```yaml
on:
  push:
    branches:
      - codex/release-130-ci-play
```

El job agrega la misma restricción de evento y ref. Sin filtro de paths:
cualquier futuro commit autorizado en esta rama puede verificar la candidata,
incluyendo la primera subida del workflow. No se activará por tags, otras ramas
ni dispatch. Un push autorizado ya dispara esta ejecución; no se requiere
ni se debe intentar un segundo arranque manual.

Se conserva Ubuntu/Flutter 3.47.4, loopback, lockfile estricto, analyze,
21 focales, suite completa que incluye `visual_test.dart`, comprobación de que
no se modifican/crean goldens y evidencia de 30 días. No hay `--update-goldens`.
Con `--fail-fast`, un fallo puede detener la batería: no se declarará suite
completa PASS si no termina satisfactoriamente. Preparar YAML no acredita ejecución.

Permisos: solo `contents: read`; checkout con `persist-credentials: false`.
No se solicitan secrets de repositorio, OIDC, credenciales de servicios ni
environment de producción. Checkout usa el token automático limitado de Actions.
La única carga es de logs/fallos de tests como artefactos de CI: no AAB, APK,
instalación, despliegue ni publicación. La concurrencia es específica de esta
rama y no cancela otros jobs.

## Workflows que recibirían el futuro push

Se inspeccionaron los siete archivos de la candidata y los triggers de los
seis workflows en main `99da872`. No se encontraron receptores `workflow_run`,
`workflow_call`, `repository_dispatch` ni `pull_request_target`.

| Workflow | Trigger en candidata | Push a esta rama, sin PR |
|---|---|---|
| `release-130-flutter.yml` | Push exacto a `codex/release-130-ci-play` | Sí, único workflow disparado por ese push |
| `ci.yml` | PR hacia main | No; con PR abierto hacia main, un push también emite synchronize y sí puede ejecutarlo |
| `beta-android.yml` | Manual | No; no usarlo para este cierre, compila APK conectada |
| `goal-api-probe.yml` | Manual | No |
| `live-fixtures.yml` | Manual o push a main con cambio de su archivo | No; ni branch ni path coinciden |
| `global-fixtures.yml` | Cron o manual | No por el push; su cron de main continúa independiente |
| `standings.yml` | Cron o manual | No por el push; su cron de main continúa independiente |

En main, `ci.yml` también admite PR con base en tres ramas news117; eso no
lo convierte en receptor de push. No se abrirá PR. Antes de cualquier push,
reconfirmar que no existe PR abierto de esta rama a una base admitida y que
los triggers no han cambiado; no inferirlo del estado del clon local.
Los workflows de cron/producción no se editan, cancelan ni disparan.

## SHA exacto y ejecución posterior autorizada

1. Esperar cierre confirmado de QA126 y autorización explícita de push.
2. Revisar árbol limpio y registrar el SHA completo del HEAD aprobado.
3. No usar el remote origin de la copia anterior de Bottrading: apunta a otro
   repositorio local. La copia activa permitida está en
   `F:/FutBeat/FutBeat/artifacts/release130-ci-play`; su repositorio de control
   `release130-ci-control.git` no tiene remote GitHub configurado.
4. Bajo autorización, configurar/verificar el destino exacto `henguido/FutBeat`
   y publicar solamente `HEAD:refs/heads/codex/release-130-ci-play`, sin force,
   sin tags, sin `--all` y sin publicar NEWS 131. No se ha ejecutado esa acción.
5. El evento push registra `github.sha`. Checkout está fijado a ese SHA;
   el primer paso exige `git rev-parse HEAD == GITHUB_SHA`. El nombre del run
   y del artefacto incluyen el SHA, no solo el nombre mutable de la rama.
6. Comparar SHA aprobado con head_sha del run, source-sha.txt y run-metadata.txt
   del artefacto. Registrar URL, run ID y attempt.
7. Revisar loopback, pub get, hashes de lockfile, analyze, focales, suite y
   goldens. Un job exitoso con pasos omitidos no demuestra PASS de esos pasos.
   Solo aprobar si se ejecutaron y terminaron los controles obligatorios.

La rama original en Bottrading permanece en `cfb862b`; se importó su historia
mediante bundle a una copia escribible, sin rebase/merge ni cambios a R130,
NEWS 131 o sus worktrees originales.

Referencias oficiales consultadas:
- https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow
- https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow

Estado: GO para revisión del ajuste local; NOT RUN para CI; NO-GO para AAB
y publicación hasta completar tests y gates de configuración/QA.
