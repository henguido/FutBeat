# MOBILE229 — cronología e identidades

Trabajo local sin consultas al backend ni al dispositivo.

## 26 frente a 22

El handoff local de Claude `F:\FutBeat\recovery-03\QA216-CODEX.md`, línea 13, distingue expresamente **26 entity events / 25 canonical events**. La captura real de SQLite QA225-C versionada en `apps/mobile/test/fixtures/everton_newcastle_qa225_timeline.json` contiene:

- Contexto: 25 eventos canónicos.
- Detalle: 22 incidentes, con 22 providerEventId únicos.
- Presentación fusionada: 25 elementos; conserva los 22 providerEventId.
- Tipos deportivos: 4 goles, 8 amarillas, 10 sustituciones, tanto en detalle como en presentación.
- Los otros 3 elementos son KICKOFF (`fb_event_f94ff6a627a551019ab2f0003638ad7a`), HALFTIME (`fb_event_7b15af0d4b79d077ca2b429cc2627fb2`) y FULL_TIME (`fb_event_1d3dc40efd57bfdb4472b73756fadf40`). No son incidencias deportivas perdidas.

No hay evidencia de cuatro incidencias perdidas en Flutter. Falta un export local de las 26 filas de entidad para identificar por ID la diferencia de proyección 26→25; no se afirma que sea un duplicado concreto ni se inventa su causa.

## Defectos demostrados y corregidos

1. El ensamblado de cronología eliminaba `outPlayerId`/`inPlayerId` de las diez sustituciones del fixture real. Ahora conserva ambos campos tal como llegan.
2. Al emparejar detalle y evento canónico solo se conservaba la identidad canónica principal. Se perdía la del asistente/jugador entrante, impidiendo reutilizar su nombre y navegar al perfil desde cronología. Se conserva `canonicalAssistPlayerId` y la vista lo consume, sin emparejar nombres.
3. Tres sustituciones del visitante en el minuto 46 tienen la misma combinación tipo/lado/minuto. Su orden no prueba qué fila del proveedor corresponde a qué identidad canónica. Se mantiene el emparejamiento de presentación para no duplicar incidencias, pero no se adjuntan identidades canónicas por posición. Una clave upstream coincidente o una correspondencia única y recíproca sí permite el puente. Los contadores de unicidad usan los conjuntos originales: la última fila de un grupo ambiguo no se vuelve identificable al consumir las otras.

La regresión conserva recuentos, IDs de ocurrencia, minutos y orden. No cambia persistencia SQLite ni demanda más datos.

## Validación

- Nuevos tests de navegación de sustituto y asistente fallan contra los dos archivos originales de 72c5856: 2 FAIL esperados; vuelven a pasar con la corrección.
- La regresión sobre el fixture real detecta pérdida de outPlayerId/inPlayerId contra el código original.
- 29 tests focales PASS: qa225_real_timeline, match_timeline_v2 y timeline_regression, incluyendo seis goldens existentes sin modificar referencias.
- flutter analyze --no-pub: PASS, sin incidencias.

Sin nueva validación física en este worktree; no se declara PASS de la nueva navegación en A32. Una futura QA offline puede comprobar flechas/nombres de sustituciones identificadas y navegación del asistente sin modificar favoritos ni consultar producción.