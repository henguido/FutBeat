# Trazabilidad de los incrementos

## Bloque LIVE — eventos y push

| Historia | Avance verificable | Archivos | Evidencia |
|---|---|---|---|
| FB-US-005/006/008 | Marcador, minuto, estado y seis tipos de evento canónico actualizados por Realtime, con snapshot HTTP de respaldo | `backend/providers/live_observation.mjs`, `lib/core/live_realtime.dart`, `lib/features/matches/match_screen.dart` | Pruebas de evento, merge y reconexión |
| FB-US-013 | Polling acotado, detección durable, primera observación silenciosa y publicación por revisión | `futbeat-live-sync`, migraciones LIVE | Pruebas de primera observación, duplicado y segundo gol |
| FB-US-036/037/038/039 | Cuenta opcional, dispositivo propio y sincronización de equipos/partidos seguidos para push | `lib/core/push.dart`, `lib/features/profile/profile_screen.dart` | Prueba de propiedad autenticada y dos dispositivos |
| FB-US-071 | Eventos públicos sanitizados con IDs `fb_*`; observaciones raw y outbox permanecen privadas | `canonical_events`, `notification_outbox`, RPCs privadas | Asesores Supabase y pruebas de roles |

[Diseño, operación y activación de proveedores](LIVE-PUSH.md).

## Bloque 0.2 — datos reales y almacenamiento local

### Ampliación 0.3 — Supabase

FB-US-004/043/071: mismas identidades, equivalencias y lote original trasladados
a PostgreSQL remoto. `supabase/migrations/`, `supabase/functions/futbeat-api/` y
`lib/core/providers.dart` habilitan lectura móvil HTTPS. Pruebas:
`backend/test/cloud.test.mjs`, verificación SQL de permisos y prueba Dio contra
Supabase. FB-US-001 sigue parcial: lectura real, pero automatización pendiente.
[Evidencias y límites](CLOUD.md).

| Historia | Avance verificable (parcial) | Archivos | Evidencia |
|---|---|---|---|
| FB-US-001/002 | Partidos reales en fechas disponibles, hora local y aviso de cobertura parcial | `backend/providers/thesportsdb.mjs`, `lib/features/matches/matches_screen.dart` | Importación real; prueba de navegación a fecha disponible |
| FB-US-004/043 | Equivalencias persistentes y IDs internos estables | `backend/storage/database.mjs`, `supabase/migrations/` | Reinicio, actualización y deduplicación de job |
| FB-US-012/014/072 | Estados reconocidos, FT pendiente de verificar, rechazo de estados desconocidos | `backend/providers/thesportsdb.mjs` | Normalización y rollback; reconciliación pendiente |
| FB-US-071 | Respuesta original, fuente y fecha de recepción persistentes; fecha por partido en pantalla | `backend/storage/database.mjs`, `lib/features/matches/match_screen.dart` | PostgreSQL local + respuesta HTTP |
| FB-US-073 | Rechazo de observaciones contradictorias dentro del lote | `backend/providers/thesportsdb.mjs` | Implementación parcial; comparación entre proveedores pendiente |

Pruebas principales: `backend/test/provider.test.mjs`, `apps/mobile/test/flow_test.dart` y `api_repository_test.dart`. [Operación y límites](DATA-BLOCK.md). Estas mejoras no cierran historias de automatización, cobertura completa ni verificación multi-fuente.

## Bloque 0.1 — base demo

**Implementado en demo** significa que funciona con el fixture; no cierra los criterios de ingestión o actualización automática de la historia. **Base parcial** no equivale a historia aceptada.

| Historia original | Cambio y estado | Archivos principales | Verificación |
|---|---|---|---|
| FB-US-001/002 | Partidos agrupados, hora local, fechas y filtros. Demo; actualización automática pendiente. | `lib/features/matches/matches_screen.dart`, `lib/core/models.dart` | `domain_test.dart`, `flow_test.dart` |
| FB-US-004 | Enlaces canónicos y IDs independientes; implementado para el grafo demo. | `lib/main.dart`, `lib/features/entities/`, `packages/contracts/` | Flujo partido → equipo → competición; referencias de eventos |
| FB-US-005/006/008 | Marcador, estado, minuto, eventos cronológicos y estadísticas disponibles. Demo; LIVE real pendiente. | `lib/features/matches/match_screen.dart` | Pruebas de flujo y capturas |
| FB-US-012/013 | Estados y política de frecuencia. Base parcial; no hay scheduler activo. | `lib/core/models.dart`, `backend/automation/sync.mjs` | `backend/test/core.test.mjs` |
| FB-US-015 | Tabla de ejemplo y enlaces a equipos; implementado en demo. | `lib/features/entities/standings.dart` | Revisión visual; cálculo LIVE no incluido |
| FB-US-019/020/021/022/026 | Perfiles, calendario, último resultado y jugadores de ejemplo. Parcial: sin forma, estadísticas personales ni plantilla completa. | `lib/features/entities/entity_screen.dart` | Flujo y referencias canónicas |
| FB-US-031/032/033 | Competición, temporada, partidos, equipos y tabla demo. | `lib/features/entities/` | Flujo y capturas |
| FB-US-036/037/038/039 | Guardar/quitar seguimiento local. Parcial: sin personalización, cuenta ni avisos. | `lib/core/database.dart`, `lib/shared/widgets.dart`, `lib/features/favorites/` | `database_test.dart`: cerrar/reabrir SQLite; `flow_test.dart`: seguir desde perfil y abrir Favoritos |
| FB-US-041/042 | Búsqueda local por nombre, país, abreviatura y alias. | `lib/core/models.dart`, `lib/features/explore/` | LDA/Sapri, búsqueda → equipo |
| FB-US-055/056/057 | Fallback y capacidad de renderizar imagen verificada. Solo FB-US-057 cubierto; adquisición de imágenes pendiente. | `lib/shared/widgets.dart` | Rechazo de imagen no verificada y capturas |
| FB-US-071 | Procedencia en contrato y pantalla. Base parcial: sin auditoría persistente. | `backend/providers/core/snapshot.mjs`, contrato, Match Center | Rechazo de lote sin procedencia |
| FB-US-023/024/044–050 | Puntos de entrada de noticias y transferencias con estados vacíos. Pendiente, no contabilizado como historia implementada. | Navegación y perfil de entidad | Revisión visual |

Rutas de `lib/` y `test/` relativas a `apps/mobile/`. La referencia completa y las prioridades originales siguen gobernando futuros incrementos.

## Próximos bloques

1. Activar credenciales Firebase/APNs y validar entrega real en dispositivos Android/iOS; la outbox y el modo seguro ya están desplegados.
2. Completar reconciliación de resultados (FB-US-014/018) y reglas por temporada (017); luego tabla LIVE (009/016), con todos los partidos simultáneos.
3. Escudos/fotos con procedencia y derechos (055–061), noticias y sus relaciones (044–047), estados de fichajes (048–050).
4. Preferencias detalladas de notificación y descubrimiento de highlights.
