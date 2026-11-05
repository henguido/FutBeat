# Contrato: feed de Noticias v2 (#104)

Lectura: `GET /functions/v1/futbeat-api/v1/news?tab=for_you` → RPC `futbeat_read_news_feed`.
El parámetro `tab` es obligatorio para seleccionar v2; sin él se conserva la respuesta v1.
La app **nunca** consulta proveedores de noticias; solo lee este feed central.

## Petición

| Parámetro | Valores | Por defecto |
|---|---|---|
| `tab` | `for_you` · `latest` · `country` · `transfers` | `for_you` |
| `country` | ISO 3166-1 alfa-2 (`CR`). Obligatorio con `tab=country` | — |
| `follows` | `type:id` separados por coma, máx. 50; `type` ∈ team/player/competition | vacío |
| `offset` | 0–200 | 0 |
| `limit` | 1–50 | 20 |

Los `follows` solo **reordenan** `for_you`; nunca filtran. Una petición inválida
responde 400 sin tocar la base de datos.

## Respuesta (`schemaVersion: 2`)

```json
{
  "schemaVersion": 2,
  "tab": "for_you",
  "country": null,
  "updatedAt": "2026-10-19T12:00:00Z",
  "offset": 0,
  "hasMore": false,
  "stories": [
    {
      "clusterId": "currents:r1",
      "title": "Comunicado: Club Uno ficha a Mario Ejemplo Rojas",
      "url": "https://club.example/noticias/mario",
      "sourceName": "Club Uno",
      "sourceDomain": "club.example",
      "sourceRole": "FIRST_PARTY_OFFICIAL",
      "publishedAt": "2026-10-19T09:00:00Z",
      "updatedAt": "2026-10-19T09:00:00Z",
      "snippet": "Solo si proveedor Y fuente lo permiten (≤300)",
      "imageUrl": "Solo si proveedor Y fuente lo permiten",
      "attribution": { "publisher": "Club Uno", "provider": "Currents API" },
      "category": "TRANSFER",
      "storyState": "OFFICIAL",
      "transferStatus": "CONFIRMED",
      "memberCount": 3,
      "entities": [{ "type": "team", "id": "fb_team_x", "name": "Club Uno" }],
      "alsoReportedBy": [
        { "sourceName": "Teletica", "url": "https://...", "sourceRole": "ESTABLISHED_MEDIA", "publishedAt": "..." }
      ]
    }
  ]
}
```

Claves nulas se omiten (`snippet`, `imageUrl`, `transferStatus`, `attribution.provider`).

### Semántica

- **Una tarjeta por historia** (`clusterId`). La tarjeta muestra el miembro más
  confiable: `FIRST_PARTY_OFFICIAL` > `ESTABLISHED_MEDIA` > `AGGREGATOR` > `UNVERIFIED`.
- `storyState`: `OFFICIAL` si algún miembro es oficial; `REPORT` si algún medio
  establecido; si no, `DEVELOPING`.
- `transferStatus` (solo `category=TRANSFER`): `CONFIRMED` únicamente si una
  fuente oficial lo redacta como hecho; la repetición entre agregadores
  **nunca** sube el estado.
- `category`: `TRANSFER`, `INJURY`, `DISCIPLINE`, `COACHING`, `SQUAD`, `MATCH`, `GENERAL`.
- `country` de la solicitud influye en `for_you` y filtra `tab=country` solo
  mediante entidades canónicas etiquetadas (equipo/competición). El país del
  medio o la cobertura del feed **nunca** se infieren como país de la historia.
- `storyCountryNames` contiene los países explícitos de esas entidades;
  `sourceCountryCode` identifica al editor y `language` al artículo. Son
  metadatos independientes. `inSelectedCountry` indica la coincidencia con
  el país solicitado; una historia global sin etiquetas sigue en `for_you`
  y `latest`, pero no se finge nacional.
- La UI debe mostrar siempre la fuente (`sourceName`) y, si existe,
  `attribution.provider` ("vía Currents API"). Toque → abrir `url` (link-out).

## Derechos (gobernanza)

`futbeat_private.news_sources` (por dominio) y `news_provider_config` (por
proveedor). Snippet/imagen exigen permiso de **ambos** y una fecha de revisión
(`rights_reviewed_at` / `terms_reviewed_at`), forzado por CHECK. El almacén
re-deriva derechos y rol en el servidor: un cliente no puede concederlos.
Todos los proveedores y feeds se entregan **deshabilitados**.

### Derechos de lectura v1 (NEWS107)

Cada historia incluye `rights` calculado en la misma lectura acotada que
aplica la política vigente. `snippet` e `image` son independientes y toman
`ALLOWED`, `REVOKED` o `UNVERIFIED`. `ALLOWED` exige permiso explícito de la
fuente y el proveedor, y ambas revisiones presentes. `REVOKED` significa que
hay revisiones pero al menos un permiso está desactivado. Si falta una fuente,
configuración o revisión, el estado es `UNVERIFIED`.

`checkedAt` es la hora de esa lectura; `expiresAt` es 30 segundos después.
El cliente solo puede mostrar el contenido opcional de un campo `ALLOWED`
si `version=1`, ambas fechas son válidas y aún no llegó `expiresAt`.
Al vencer el plazo debe retirarlo de la pantalla y la caché de imágenes,
sin generar una petición automática. Una recarga consulta los permisos de
nuevo. Una respuesta antigua, mal formada o sin `rights` no concede permisos.

El titular permitido, la fuente, fecha y URL original continúan disponibles
como enlace, incluso cuando no hay permiso de extracto o imagen. v1 no emite
este contrato; se trata como enlace sin extracto ni imagen. La API conserva
`Cache-Control: no-store` para Noticias. La señal no se debe emitir desde la
Edge Function como una afirmación genérica: la calcula el RPC filtrante de
NEWS115, sobre el mismo miembro de historia cuya tarjeta se entrega.

NEWS115 añade una migración nueva después de la retención segura de NEWS114;
no reescribe migraciones previas. Su rollback retira la lectura v2 antes de
permitir una respuesta que pueda exponer contenido revocado.
