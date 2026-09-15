# Trazabilidad del incremento 0.1

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

1. Proveedor autorizado para Costa Rica, equivalencias `provider_entities`, observaciones y PostgreSQL/RLS; fixture → ingesta → persistencia → BFF → móvil. Pruebas de duplicados, errores y cuotas.
2. Máquina de estados durable, scheduler, reconciliación de resultados (FB-US-014/018) y reglas por temporada (017); luego tabla LIVE (009/016), con todos los partidos simultáneos.
3. Escudos/fotos con procedencia y derechos (055–061), noticias y sus relaciones (044–047), estados de fichajes (048–050).
4. Cuenta/sincronización, notificaciones y descubrimiento de highlights, después de verificar el flujo de datos real.
