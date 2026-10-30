# FUTBEAT 200 — necesidades móviles para el contrato de Claude

Estado local: el archivo `FUTBEAT-200-API-CONTRACT.md` todavía no está presente en esta base. Estas necesidades no modifican contratos ni autorizan llamadas directas a proveedores.

| Área | Necesidad móvil | Estado actual |
| --- | --- | --- |
| Calendario | `GET /v1/calendar` por fecha y zona horaria, con `updatedAt` comparable para descartar respuestas atrasadas. | El cliente conserva la respuesta más reciente en memoria y SQLite. |
| Detalle | `GET /v1/match-detail?id=<ID canónico>` debe incluir cobertura y frescura de alineaciones, estadísticas, eventos y videos. | El feed precarga como máximo dos detalles relevantes por tanda y ocho por sesión activa; falta medir tráfico físico. |
| Contexto | `GET /v1/match-context?id=<ID canónico>` debe identificar temporada, fase y grupo exactos de la tabla. | La UI no inventa posiciones cuando faltan filas. |
| LIVE | Cambios por ID canónico, revisión y tiempo de cambio; reconexión con lectura incremental para recuperar eventos perdidos. | Canal filtrado se cierra en segundo plano y se reconcilia al volver. |
| Imágenes | URL, identidad canónica, verificación y revocación explícitas; ausencia significa placeholder. | La app no debe inferir fotografías por nombre. |
| Videos | ID de partido, fuente, URL HTTPS, titular de derechos y permisos separados para enlace, miniatura y reproducción. | Solo se exponen enlaces verificados; no se infieren derechos de miniatura o reproducción. |

Para la QA conectada: Claude debe confirmar horizonte de calendario, política de frescura por estado de partido, límites de demanda de detalle y condiciones STOP. La app no realiza llamadas directas a GOAL ni API-Football.
