# NEWS111 — preparación de activación internacional (20-10-2026)

Estado: **solo local**. NEWS109 → NEWS110 → NEWS111; Noticias v2 no está
desplegada. Este documento no autoriza recolección, licencias ni despliegue.

## Fuentes y derechos

"Listado" significa que el editor publica el enlace en su índice; no prueba
que hoy responda correctamente ni concede permiso de uso en FutBeat. Las
pruebas funcionales usan XML sintético. Ningún feed queda autorizado o activo.

| País de cobertura / fuente | Endpoint o índice oficial | Disponibilidad técnica | Uso comercial en FutBeat | Título | Extracto | Imagen |
|---|---|---|---|---|---|---|
| CR / Teletica | [Índice RSS](https://test.teletica.com/rss), `https://www.teletica.com/rss/feed/deportes/futbol` | Registrado en P3; respuesta actual sin verificar | Permiso no localizado | Sin autorización documentada | No | No |
| ES / AS | [Índice](https://as.com/rss-de-ascom-n/), `https://feeds.as.com/mrss-s/pages/as/site/as.com/section/futbol/portada/` | Feed enlazado; XML señalado por comprobación pública, sin prueba del colector | [Aviso legal](https://as.com/aviso-legal/): solicitar licencia | Pendiente de licencia | No | No |
| MX / Marca USA | [Índice](https://us.marca.com/rss.html), `https://e00-us-marca.uecdn.es/rss/soccer/liga-mx.xml` | Listado; respuesta actual sin verificar | [Términos](https://us.marca.com/corporativo/terminos-condiciones-uso.shtml): autorización expresa y escrita, incluida extracción automatizada | Pendiente de licencia | No | No |
| AR / Clarín | [Índice](https://www.clarin.com/filer/RSS/rss.html), `https://www.clarin.com/rss/deportes/futbol/` | Listado; respuesta actual sin verificar | [Términos RSS](https://www.clarin.com/filer/RSS/terminos_condiciones.html): permiso limitado para títulos/enlaces en sitio propio; no demostrado para esta app comercial | No autorizado para esta app | No | No |
| BR / ge Globo | [Índice histórico](https://ge.globo.com/Esportes/0,,GEH946-9645,00.html), `https://ge.globo.com/Esportes/Rss/0,,AS0-9825,00.xml` | Endpoint antiguo; revalidación obligatoria | Licencia específica no localizada | Sin autorización documentada | No | No |
| CO / El Tiempo | [Índice](https://www.eltiempo.com/rss), `https://www.eltiempo.com/rss/deportes_futbol-colombiano.xml` | Listado; respuesta actual sin verificar | [Términos RSS](https://www.eltiempo.com/rss): uso gratuito personal y no comercial solamente | No autorizado para esta app | No | No |
| GB / BBC Sport | [Guía RSS](https://www.bbc.co.uk/sport/articles/cqllxj2n4kyo) | Endpoint HTTPS actual no confirmado; no hay feed registrado | [Términos](https://downloads.bbc.co.uk/usingthebbc/bbc_terms_of_use_31March2022english.pdf): uso empresarial requiere permiso/licencia | Pendiente de licencia | No | No |

Mediotiempo, Olé, TyC, FIFA, UEFA y Concacaf siguen sin combinación verificada
de endpoint HTTPS actual y permiso aplicable. El país del medio, el país de
cobertura y el país inferido de entidades deportivas son campos distintos.
Una fuente `NO` puede cambiar solo tras revisión documentada de sus términos
y acuerdo específico; un RSS accesible nunca basta por sí solo.

## Gates técnicos

La migración NEWS111 agrega `collection_authorized_at` y
`collection_permission_ref` a `news_sources`, ambos nulos por defecto. El
planner RSS exige simultáneamente:

1. proveedor `enabled`, `production_allowed` y `terms_reviewed_at`;
2. feed individual `enabled` y vencido por cadencia;
3. fuente con autorización de recolección y referencia no vacía.

La referencia debe identificar un acuerdo o revisión humana verificable, no
la URL del RSS. Los permisos de extracto e imagen siguen siendo independientes
y denegados por defecto. Desactivar el feed, el proveedor o revocar la
autorización de la fuente corta nuevas selecciones; el contenido almacenado
se sigue filtrando por derechos al leer. No se modifica el cron.

No se usaron feeds reales en tests. PGlite aplicó todas las migraciones en
orden y probó rollback transaccional de NEWS111; **no equivale a probar la
reversión operativa en un servidor PostgreSQL/Supabase**. Deno comprueba los
tipos de las funciones compartidas y del colector. El CI ahora incluye esa
comprobación. Flutter y backend deben pasar sus suites completas antes de
staging.

Resultado local: backend 1.289 PASS, 0 FAIL (1 SKIP, 2 TODO); Flutter 1.277
PASS; `flutter analyze`, `npm run check`, `deno check` y `git diff --check`
correctos. La prueba de migración también aplicó el borrador de rollback de
emergencia en PGlite y verificó que RSS queda deshabilitado.

## Presupuesto y retención

- Cinco feeds nuevos + Teletica: techo teórico de 144 solicitudes/día a una
  por hora, aunque Teletica conserva cadencia de 30 minutos en P3 (techo real
  configurado para los seis: 168/día). Los cinco nuevos son 120/día.
- Presupuesto RSS central: 500/día; mínimo entre consultas: 60 segundos;
  backoff exponencial y GET condicional. Con los feeds apagados: cero llamadas.
- Límite por respuesta: 2 MiB; máximo teórico para 168 respuestas máximas:
  336 MiB/día. Es un límite de seguridad, **no una predicción de tráfico**.
  A 50 KiB hipotéticos por respuesta: ~8,2 MiB/día.
- Una URL canónica por artículo y un cluster por historia; no se duplica por
  país/usuario. Medición NEWS111 con 40 historias sintéticas en PGlite:
  mediana de 4,84 ms en lectura base y 8,46 ms con guard de derechos;
  artículos 122.880 bytes, clusters 49.152 bytes, sin crecimiento por lectura.
  No extrapolar estas latencias a producción.
- Retención v2: 35 días; máximo 100 vencidos por inserción nueva. El feed
  excluye vencidos aunque permanezcan físicamente. Si cesan las inserciones,
  la limpieza física queda pendiente de decisión basada en crecimiento real;
  no se crea cron adicional por anticipación.

## Secuencia propuesta para staging

1. Confirmar historial de migraciones. NEWS110 modificó P3 antes de su
   despliegue conocido; si P3 ya está aplicado en staging, no editar/repetir
   su historial: preparar migración forward equivalente antes de continuar.
2. Ejecutar CI backend, Flutter y Deno. En una base staging aislada, aplicar
   P1–P4/NEWS109, NEWS110 y NEWS111 en orden; verificar RLS, grants y ausencia
   de feeds/proveedores habilitados.
3. Probar con fixtures sintéticos la personalización por país, deduplicación,
   caducidad, revocación, enlaces HTTPS y que un feed habilitado sin permiso
   no se seleccione. Medir consultas, escrituras y tamaño.
4. Obtener revisión jurídica/comercial por fuente y guardar referencia fuera
   del repositorio. Confirmar endpoint, redirects y formato con una lectura
   pública acotada **solo después de aprobarla**. No usar scraping.
5. En una ventana operativa separada, aprobar proveedor y **una** fuente con
   licencia; habilitar únicamente ese feed; observar presupuesto, respuestas,
   atribución y derechos. Suspender ante errores, quejas o consumo anómalo.

Rollback operativo: primero deshabilitar proveedor y feeds, comprobar que el
planner devuelve `null` y que no hay ejecución activa. Revocar derechos y
autorización de fuente para impedir contenido nuevo; verificar que las lecturas
ocultan extractos/imágenes revocados. El borrador
[`NEWS111-LOCAL-ROLLBACK.sql`](NEWS111-LOCAL-ROLLBACK.sql) deja el planner RSS
fail-closed y revierte el esquema; se ensayó solo en PGlite. Si NEWS111 ya figura
aplicada en staging, preferir una migración forward correctiva y no borrar
historial ni hacer `db reset --linked`. Cualquier reversión operativa exige una
copia aislada, backup y revisión adicional; la prueba PGlite no sustituye el
ensayo en PostgreSQL del entorno de destino.

**Veredicto:** preparación local apta para CI. Staging **solo sintético** tras
verificar historial y CI; activación de fuentes reales **NO-GO** hasta obtener
permisos y comprobar endpoints/condiciones por editor.
