# Snapshot v1

Fixture canónico compartido para la primera integración. Todos los datos deportivos son ficticios y se identifican con `demo: true`; los nombres de clubes no convierten los marcadores en resultados reales.

- IDs internos `fb_*`, independientes de proveedores.
- `startTime`, `updatedAt`, `provenance.receivedAt`: ISO 8601 con zona.
- Marcador próximo: `score: null`; no convertir ausencia en cero.
- `FINISHED_PENDING_VERIFICATION` y `VERIFIED` separan final pendiente de verificación.
- Eventos llevan ID único por partido, minuto, tipo, equipo y jugador opcional.
- `provenance` registra fuente y estado. La demo no constituye verificación entre fuentes.
- `media: null` usa fallback. Una imagen necesita `verificationStatus: VERIFIED` para mostrarse; la autorización se implementará en el backend de media.
- Noticias y transferencias están vacías y todavía no tienen un contrato implementado de producción.

Validador: `backend/providers/core/snapshot.mjs`. Consumidor Dart: `apps/mobile/lib/core/models.dart`.

Después de editar este fixture, ejecutar `node scripts/sync-fixture.mjs` para actualizar el asset móvil. `node --test backend/test/*.test.mjs` comprueba que ambas copias coincidan.
