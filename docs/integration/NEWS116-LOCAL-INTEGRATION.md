# NEWS116 — integración local de Noticias internacionales

Cadena: NEWS113 (v1) → NEWS114 (v2) → NEWS115 (retención y derechos) → NEWS116 (catálogo, país y autorización de recolección). NEWS110/111 se trasladaron selectivamente; no se incorporaron sus cambios Android, GOAL ni otras migraciones.

## Alcance

- NEWS110 registra cinco feeds candidatos para ES, AR, BR, CO y MX; el feed CR de Teletica ya existía. Todos continúan desactivados. Otros medios internacionales quedan catalogados sin endpoint habilitado. Las URLs candidatas y sus términos deben volver a comprobarse antes de cualquier activación.
- El país de la noticia proviene exclusivamente de equipos o competiciones canónicos etiquetados; país del medio, cobertura del feed e idioma declarado se conservan como campos separados. Historias mundiales y de otros países permanecen en `for_you` y `latest` al cambiar de país.
- NEWS111 exige conjuntamente proveedor habilitado, términos revisados, fuente aprobada y feed individual habilitado. Retirar la aprobación de fuente la excluye del plan inmediatamente. Ningún registro queda autorizado por defecto.
- Flutter filtra localmente los 40 artículos cargados por entidades seguidas, fichajes y búsqueda; no agrega solicitudes. La ficha interna presenta solo metadatos y abre la fuente original mediante un enlace HTTPS seguro. Extractos e imágenes siguen sujetos al contrato de derechos NEWS115 y a su caducidad.

## Validación y orden

Aplicar sobre una base limpia y aislada las migraciones en orden de nombre, en especial P3 v2 → NEWS110 (`20261020063629`) → NEWS111 (`20261020071515`) → NEWS115 (`20261020151117`). Los tests PGlite de NEWS110 y NEWS111 comprueban aplicación, rollback transaccional y reaplicación; NEWS111 dispone de `NEWS111-LOCAL-ROLLBACK.sql` para una emergencia en staging, que deja RSS desactivado. No se probó PostgreSQL nativo en esta máquina porque `psql`, `pg_ctl` y Docker no están disponibles.

CI debe ejecutar `npm test`, `npm run check`, Deno check, `flutter test` y `flutter analyze`. Deno no está instalado localmente; su paso de CI queda pendiente de ejecución real. Antes de staging: revisar el diff y la cadena de migraciones, verificar endpoints HTTPS y términos comerciales por fuente, comprobar derechos de titular/extracto/imagen, ejecutar rollback en PostgreSQL staging independiente y mantener todos los proveedores desactivados. No hay autorización para activar fuentes ni para desplegar migraciones.
