# NEWS110 — catálogo candidato internacional (20-10-2026)

Ninguna fila de este catálogo habilita recolección o derechos de republicación.
Todos los feeds nuevos están `enabled=false`; `rss` sigue desactivado. El país
del medio, la cobertura del feed y el país de la historia son datos distintos.
La historia solo recibe país por equipos/competiciones canónicos etiquetados.
El idioma del artículo solo se guarda si RSS/Atom lo declara explícitamente;
`language_code` en el catálogo describe el canal candidato, no cada noticia.

| Cobertura | Medio / sitio oficial | Evidencia de RSS | Estado de derechos |
|---|---|---|---|
| CR, es | [Teletica](https://www.teletica.com/deportes/futbol) | [índice RSS](https://test.teletica.com/rss); feed ya registrado en P3 | Pendiente de permiso comercial; titular/enlace únicamente hasta revisión |
| ES, es | [AS](https://as.com/rss-de-ascom-n/) | [Fútbol](https://feeds.as.com/mrss-s/pages/as/site/as.com/section/futbol/portada/) | Pendiente de permiso comercial; extracto e imagen no autorizados |
| MX, es | [Marca USA](https://us.marca.com/rss.html) | [Liga MX](https://e00-us-marca.uecdn.es/rss/soccer/liga-mx.xml) | Pendiente; la edición del medio es USA, no prueba país de cada historia |
| AR, es | [Clarín](https://www.clarin.com/filer/RSS/rss.html) | [Fútbol](https://www.clarin.com/rss/deportes/futbol/) | Pendiente de permiso comercial; página de RSS no es licencia para FutBeat |
| BR, pt | [ge Globo](https://ge.globo.com/Esportes/0,,GEH946-9645,00.html) | [Futebol](https://ge.globo.com/Esportes/Rss/0,,AS0-9825,00.xml), índice antiguo | Pendiente; volver a verificar endpoint y términos antes de habilitar |
| CO, es | [El Tiempo](https://www.eltiempo.com/rss) | [Fútbol colombiano](https://www.eltiempo.com/rss/deportes_futbol-colombiano.xml) | Pendiente de permiso comercial |
| GB, en | [BBC Sport](https://www.bbc.co.uk/sport/articles/cqllxj2n4kyo) | RSS documentado; endpoint HTTPS actual no verificado | Pendiente; exige atribución y términos, no hay feed configurado |

También se registran como candidatos **sin feed habilitado** Mediotiempo,
Olé, TyC Sports, UEFA y CONMEBOL; para ellos no se verificó un endpoint HTTPS
actual y/o autorización aplicable. FIFA y Concacaf ya estaban en P3 con la
misma restricción. [Mediotiempo documenta históricamente RSS HTTP](https://www.mediotiempo.com/futbol/liga-mx/mediotiempo-te-ofrece-el-servicio-de-noticias-rss),
pero eso no demuestra disponibilidad HTTPS actual. Ninguna fuente se clasifica
todavía como autorizada para extractos o imágenes.

La frecuencia real y límites técnicos de cada editor siguen sin verificar;
`cadence_minutes=60` es un **límite configurado**, no una afirmación sobre su
frecuencia editorial. Cinco feeds nuevos más Teletica implicarían como máximo
144 solicitudes/día a una por hora si se aprobaran y habilitaran todos; el
presupuesto central de `rss` (500/día) y el backoff siguen imponiendo techo.
Con cuerpos RSS hipotéticos de 50 KiB serían ~7 MiB/día de transferencia;
no es una medición real. Los 2 MiB por respuesta son el límite de seguridad,
no el tamaño esperado. El almacenamiento conserva una fila por URL canónica y
un cluster por historia; no se crean copias por país ni usuario.

Antes de staging: revisar términos comerciales y derechos de cada editor,
confirmar endpoints/redirects, aprobar atribución, mantener extractos e
imágenes denegados por defecto, ejecutar CI y PGlite, y habilitar fuentes una
por una con observación de costos, errores, retención y derechos. No crear cron
ni activar proveedores desde esta rama.

La ficha interna de Flutter conserva únicamente titular, fuente, fecha y
entidades verificadas, con acción HTTPS explícita hacia el original. No es
un repositorio de artículos ni contiene texto/imágenes licenciables. El tipo
de contenido original de FutBeat requiere un contrato separado antes de
publicar piezas propias completas; no se etiqueta contenido de terceros como
propio. Faltan QA de feeds reales, términos, CI y staging antes de activar.
