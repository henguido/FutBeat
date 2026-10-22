# NEWS 131 — riesgos concretos antes de integrar

Revisión local del commit `9bb22cbd24b98f49e59607e862be256756f37b9c`,
sin modificar su rama ni incorporarla a Release 130. Se conserva R130 `6a6a34e`.

El diff contiene solo cuatro archivos de implementación Flutter, dos tests y
documentación. No cambia pubspec/lockfile, Android, backend ni migraciones.
Los imports nuevos apuntan a código Dart local, sin SDKs o paquetes nuevos.

Una ejecución Dart directa, sin Flutter runner, sockets, app ni red, compiló
los helpers/adaptador e imprimió los siguientes resultados con fixtures:

```json
{
  "all_default_flags_off": true,
  "default_adapter_strips_media": true,
  "malformed_expiry_accepted": true,
  "v2_explicit_match_subject_preserved": false
}
```

1. Antes de habilitar rich media: `_explicitlyAllowed` convierte una fecha
   no parseable en null y la acepta como ausencia de caducidad. El fixture
   `{status: ALLOWED, verified: true, expiresAt: invalid}` devuelve true.
   No demuestra procedencia/licencia: corregir el contrato y rechazar fechas
   malformadas antes de activar. Además no hay revalidación por timer de medios
   ya mostrados; revisar expiración durante permanencia y cache en esa fase.
2. Antes de habilitar noticias por partido: el adaptador v2 solo proyecta
   subjects team/player/competition. Un entity explícito de tipo match se
   descarta y `articleReferencesMatch` no lo encuentra. Resolver ambos lados
   del contrato sin inferir relación por nombre o coincidencia de equipo.
3. El subflag YouTube está declarado, pero la conservación de referencias
   depende del parámetro richContentEnabled, no de ese subflag. No existe
   reproducción; completar coherencia de flags antes de exponer esa superficie.

Son bloqueos de la futura activación/integración NEWS 131, no P0/P1 de R130
con flags apagados y ramas separadas. No se corrigieron en esta tarea.
La prueba directa no ejecuta widgets: analyze Flutter y suite de NEWS 131
siguen NOT VERIFIED. No se afirmó que la app completa compile o pase tests.

Decisión: mantener aislada en `9bb22cb`; todos los defines NEWS 131 ausentes/false.
No aprobar integración hasta corregir esos casos y ejecutar su CI específico.
