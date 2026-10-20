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
- `country`: cuenta una entidad etiquetada (equipo/competición) del país; el país
  del medio solo decide si la historia no etiqueta equipos ni competiciones.
- La UI debe mostrar siempre la fuente (`sourceName`) y, si existe,
  `attribution.provider` ("vía Currents API"). Toque → abrir `url` (link-out).

## Derechos (gobernanza)

`futbeat_private.news_sources` (por dominio) y `news_provider_config` (por
proveedor). Snippet/imagen exigen permiso de **ambos** y una fecha de revisión
(`rights_reviewed_at` / `terms_reviewed_at`), forzado por CHECK. El almacén
re-deriva derechos y rol en el servidor: un cliente no puede concederlos.
Todos los proveedores y feeds se entregan **deshabilitados**.

Este paquete valida permisos al almacenar, pero todavía no revalida una
revocación posterior en cada lectura. No debe activarse una fuente real hasta
integrar y probar la capa de revocación de derechos del paquete siguiente.
