# MOBILE 201 — resultado del contrato API 200

Referencia de solo lectura: `F:\FutBeat\FutBeat-int200\docs\integration\FUTBEAT-200-API-CONTRACT.md` (idéntico por SHA-256 a la copia `FutBeat-be200doc`). Este documento separa código local de comportamiento desplegado; no supone que la rama backend 200 esté en producción.

| ID | Clasificación | Resultado móvil / necesidad de Claude |
| --- | --- | --- |
| I-1 | Error real + dato no disponible | `media` explícitamente `REVIEW_REQUIRED` / `DEVELOPMENT_ONLY` puede llegar a vistas que solo exigen `VERIFIED`. El detalle de alineación no trae derechos. Claude debe definir permisos por campo en API antes de declarar aptas esas fotos para distribución; no inferir autorización de `verificationStatus`. |
| I-2 | Diferencia documental con efecto backend | `request=0` puede pedir hidratación de fotos. Corregidos los comentarios del cliente y la precarga del feed: ahora solo lee SQLite y produce 0 HTTP. Claude debe cuantificar el costo de las relecturas del Match Center. |
| I-3 | Dato no disponible | Incidencias de match-detail usan IDs externos; eventos de match-context, canónicos. Se necesita ID canónico explícito o mapeo verificable para cada incidencia. No fusionar jugadores por nombre. |
| I-4 | Diferencia documental / funcionalidad pendiente backend | `/v1/snapshot` no alimenta pantallas móviles; su 503 no bloquea el feed. Claude puede retirar o optimizarlo por separado. |
| I-5 | Error real backend + diferencia cliente corregida | La producción v43 devuelve 404 en `/v1/news`; requiere despliegue autorizado de la ruta. El cliente deja de enviar `subjects` duplicado; conserva `follows`, `tab=for_you` y límite 40. |
| I-6 | Error real cliente corregido localmente | LIVE, temporizador de calendario, precarga de fechas y reintentos propios de Match Center se pausan al salir de primer plano; al volver se revalida el alcance. Pruebas locales; falta medición física. |
| I-7 | Diferencia documental | El cliente tolera `detailLevel=partial`; el servidor actual no lo emite. Mantener compatibilidad; no requiere cambio. |
| I-8 | Dato no disponible | La API descarta `coverage.retryAt`; el cliente mantiene reintentos finitos. Si Claude lo expone, coordinar semántica y prueba antes de usarlo. |
| I-9 | Funcionalidad pendiente | Decidir con Claude si `SUSPENDED` es absorbente o reanudable antes de cambiar el overlay LIVE. |
| I-10 | Diferencia documental | `X-Retry-Count` y `Authorization` no son consumidos por la función. No se cambió autenticación sin confirmar requisitos del gateway. |
| I-11 | Error real cliente corregido localmente | Un día histórico completo con `revalidating=true` ya no usa TTL de recuperación de 20 s; conserva el TTL histórico. Días parciales o realmente stale mantienen recuperación corta. |
| I-12 | Error real backend | `team-context` no valida `demo`; corresponde a Claude. Sin cambio móvil. |
| I-13 | Dato no disponible | Estadísticas llegan con etiquetas del proveedor sin clave estable. Claude debe definir clave canónica opcional para mapearlas sin depender del texto. |

## Mediciones locales

- Precarga de un favorito con detalle guardado: prueba instrumentada de SQLite; 0 solicitudes HTTP. El tiempo se imprime al ejecutar `match_prefetch_local_only_test.dart` y no representa latencia del A32.
- Calendario en segundo plano: 0 solicitudes durante la suspensión en prueba sintética; la reanudación hace una lectura cuando la fecha fue invalidada.
- Límite de precarga: 2 lecturas locales por tanda, 8 por sesión de feed. No se genera demanda de `match-detail` desde el feed.

Para QA real siguen siendo necesarios GO vigente, alcance y STOP de Claude. Esta rama no llama directamente a GOAL ni modifica Supabase.
