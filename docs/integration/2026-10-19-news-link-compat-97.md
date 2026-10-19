# Noticias v1/v2 — cierre local de enlaces (97)

Base: `codex/backend-content-compat-96` @ `e4e0fe4`. Esta rama conserva
el adaptador de historias v2 y la respuesta v1 sin nuevas peticiones.

## Navegación

- La tarjeta abre el `url` original solo tras el toque del usuario, mediante
  `url_launcher` en el navegador externo. No hay apertura automática.
- Solo se admiten URLs HTTPS absolutas con host público, sin credenciales,
  espacios ni barras invertidas. Una URL inválida no ofrece acción de abrir
  ni de copiar.
- «Copiar enlace» es una acción secundaria explícita; tocar la tarjeta no
  modifica el portapapeles. Un fallo del navegador muestra un aviso sin
  exponer la URL en pantalla ni copiarla.
- El medio y la fecha permanecen visibles; autor y proveedor solo aparecen
  cuando el feed los entrega. No se infieren.

## Derechos y contratos

- En v2, el servidor omite `snippet` e `imageUrl` si proveedor y fuente no
  tienen derechos revisados. Flutter no fabrica esos campos ni usa una imagen
  alternativa. Un `imageUrl` presente además debe pasar la validación HTTPS.
- En v1 se conserva el comportamiento existente para metadatos que el feed
  ya publicaba; esta app no puede deducir derechos editoriales ausentes.
- Búsqueda y filtros operan únicamente sobre los artículos ya cargados (40
  como máximo) y no generan peticiones adicionales. La petición v1/v2 sigue
  siendo una por carga/refresco.
- No se llama a `/v1/match-summary`, ni se habilitan resúmenes o videos.

## Pendiente antes de distribución

1. Revisar la implementación y validar físicamente la apertura/cierre del
   navegador en una APK QA aislada, sin confundirla con la versión Play.
2. Verificar Noticias v2 con datos reales únicamente tras el despliegue
   autorizado del backend y la revisión de fuentes/derechos de Claude.
3. La UI no implementa paginación `hasMore` ni pestañas remotas de país/global;
   sigue mostrando los artículos cargados y filtros locales. No representar
   esa búsqueda como global.
