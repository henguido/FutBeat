# FutBeat — auditoría de estados obsoletos de partidos

Fecha: 2026-10-08
Base local: `66915869b3c91476b3a8ace723c7d43b4b509217`
Producción declarada por el owner: v38 `21c71c2`
Evidencia: código, migraciones, historial y pruebas locales. Sin consultas remotas.

## Resultado ejecutivo

Los tres síntomas no comparten una sola causa:

1. **SCHEDULED antiguo.** Hubo una causa histórica demostrada: las reservas de
   GOAL se contaban entre lanes y el calendar ingest quedaba siempre saltado.
   `20261005070000_goal_ingest_reservation_per_kind.sql` la corrigió. También
   existen días de alta densidad donde `/results/date` y LIVE quedaron truncados;
   las rutas de catch-up/recovery actuales persiguen partidos vistos en juego,
   pero un partido nunca observado y ausente del proveedor permanece sin
   evidencia terminal por diseño. No es seguro finalizarlo solo por antigüedad.
2. **LIVE antiguo.** Puede sobrevivir físicamente en `entities` o
   `live_match_state`, pero el read model expira la presentación LIVE tras 15
   minutos, la proyección realtime no revive un terminal y el cliente rechaza
   overlays LIVE silenciosos. Los casos históricos requieren diagnóstico; no se
   encontró una ruta actual que deba inventar un final por reloj.
3. **VERIFIED futuro.** Defecto activo reproducido: el normalizador de calendario
   GOAL convertía cualquier estado final en `VERIFIED` sin comprobar que
   `receivedAt >= kickoffUtc`. La reconciliación SQL sí contiene ese guard, pero
   el calendario escribe directamente el payload canónico y la bypassaba.
   Corrección local: terminal antes del kickoff UTC queda `SCHEDULED`, sin score.

El guard preventivo no repara filas históricas. Esa reparación queda separada.

## Arquitectura real

```text
GOAL calendar / GOAL live / API-Football
  -> normalización de vocabulario y score
  -> provider_entities (identidad fuerte)
  -> entities.payload (canónico) + calendar_matches
  -> provider_observations / live_match_state / canonical_events
  -> results-date reconciliation + terminal recovery
  -> match_read_model_core (estado efectivo)
  -> calendar/match-context API snapshot
  -> public.live_match_updates (overlay realtime)
  -> Match.fromJson / applyLiveUpdate (stale + terminal guards)
```

La fuente mostrada no es una sola columna. `entities.payload` es la base
canónica; `match_read_model_core` aplica evidencia de observaciones, live,
detalle y FULL_TIME. La app recibe ese resultado y puede superponer
`public.live_match_updates`, sujeto a absorción terminal y frescura.

## Precedencia efectiva

1. `VERIFIED`, `FINISHED_PENDING_VERIFICATION`, `CANCELLED` y `POSTPONED`
   canónicos no se degradan en el read model.
2. Evidencia terminal real posterior al kickoff gana frente a pre-match y LIVE
   expirado. Nunca se infiere final por hora, score o eventos aislados.
3. LIVE/HALFTIME/ET/PENALTIES solo se muestra mientras la evidencia es fresca.
4. Un reingest de calendario pre-match conserva un terminal previo del mismo
   fixture; una reprogramación legítima posterior puede reemplazarlo.
5. El overlay realtime no puede revivir un canónico efectivamente terminal.

## Causas y vigencia

### SCHEDULED antiguo

- **Histórico corregido:** reserva `live` bloqueaba `calendar-ingest`; evidencia
  documentada en `20261005070000`.
- **Histórico/operativo:** resultados y LIVE capados en días de 1.100–1.500
  fixtures; documentado en `20261002110000`.
- **Todavía posible sin bug:** fixture nunca visto en juego, sin terminal del
  proveedor o ambiguo. Tras reintentos queda `missing_from_provider`; cerrarlo
  automáticamente sería fabricar evidencia.
- **Mitigación actual:** results catch-up, reapertura acotada, detail recovery
  para partidos vistos en juego, v39 para calendario grande.

### LIVE antiguo

- Una fila de almacenamiento puede seguir diciendo LIVE después del último
  poll. Eso sirve como evidencia y no equivale al estado mostrado.
- `match_read_model_core` degrada LIVE silencioso a SCHEDULED después de 15 min.
- `match_effectively_terminal`, `record_live_events` y
  `futbeat_publish_live_state` impiden terminal -> LIVE.
- El cliente aplica su propia ventana de frescura y considera terminal
  absorbente. Un LIVE realmente visible y antiguo apuntaría a una lectura que
  bypassa el read model, timestamps ausentes o una versión anterior.

### VERIFIED futuro

- **Activo en el HEAD base:** `backend/providers/goal_api.mjs::statusOf` no
  recibía `receivedAt` y aceptaba final antes del kickoff.
- API-Football y GOAL-live producen `FINISHED_PENDING_VERIFICATION`; sus
  observaciones tempranas quedan excluidas por los guards SQL del kickoff.
- El calendario GOAL producía `VERIFIED` directamente y no pasaba por esos
  guards. La prueba nueva falló `actual VERIFIED / expected SCHEDULED` antes de
  la corrección y pasó después.

## Clasificación fail-closed

| Clase | Evidencia mínima |
|---|---|
| `LEGITIMATE_SCHEDULED` | Estado pre-match y kickoff futuro/actual; sin terminal coherente. |
| `STALE_SCHEDULED` | Kickoff >6 h atrás, sigue pre-match, coverage/resultados revisados o `missing_from_provider`, sin terminal. No implica resultado. |
| `LEGITIMATE_LIVE` | Estado in-play y observación fresca posterior al kickoff. |
| `STALE_LIVE` | Evidencia in-play silenciosa >15 min, sin terminal posterior. Se oculta como LIVE, no se finaliza. |
| `VALID_VERIFIED` | Final canónico/observado con evidencia temporal `>= kickoff`. |
| `IMPOSSIBLE_FUTURE_VERIFIED` | Estado efectivo VERIFIED y kickoff futuro. |
| `POSTPONED_OR_RESCHEDULED` | Estado aplazado/cancelado/suspendido/abandonado o reconciliación `rescheduled`; nunca clasificar solo por edad. |
| `PROVIDER_CONFLICT` | Final anterior al kickoff o proveedores con estados incompatibles para la misma identidad. |
| `MANUAL_REVIEW` | Evidencia incompleta, ambigua, sin coverage o fuera de las reglas anteriores. |

El SQL diagnóstico implementa estas clases sobre un rango UTC máximo de 31
días y 500 candidatos por defecto. Si trunca, exige estrechar fechas.

## UTC y proveedores

- SQL usa rangos `date::timestamp at time zone 'UTC'`; planners evitan
  `start_time::date` para conservar índices y no depender de la zona de sesión.
- JavaScript compara instantes con `Date.parse` y serializa ISO.
- `receivedAt` es el instante de observación del ingest autorizado, generado
  por la Edge Function antes de normalizar y almacenar el lote. Si falta o no
  es parseable se rechaza el snapshot completo deliberadamente: degradar filas
  terminales ocultaría una pérdida de procedencia y no permitiría ordenar
  evidencia de forma segura.
- La igualdad exacta `receivedAt == kickoffUtc` se admite, igual que en los
  guards SQL existentes (`>= kickoff`). Es el límite inclusivo mínimo y evita
  introducir una tolerancia arbitraria que rompería `AWARDED`, correcciones de
  kickoff e importaciones históricas. No pretende demostrar duración jugada;
  solo impide que un terminal preceda al kickoff vigente.
- GOAL calendario puede emitir `VERIFIED`; GOAL-live y API-Football emiten
  `FINISHED_PENDING_VERIFICATION` para terminales observacionales.
- GOAL es la fuente de calendario/resultados. API-Football es secundaria LIVE;
  un conflicto no autoriza a elegir por antigüedad o nombre.

## Cambios locales

- `backend/providers/goal_api.mjs`: guard UTC para terminal antes de kickoff.
- `backend/test/goal_api_provider.test.mjs`: regresión futura y equivalencia de
  instantes con offset `-06:00`/UTC.
- `backend/diagnostics/stale_match_states_read_only.sql`: inventario acotado,
  coverage, reconciliación, evidencia y clasificación; solo lectura.
- Este informe.

No se modificaron migraciones ni rutas UI/notificaciones.

## Reparación histórica separada (no implementada)

1. Ejecutar el diagnóstico READ ONLY en ventanas pequeñas y exportar IDs,
   evidencia, coverage, mapping y clasificación.
2. Resolver primero `PROVIDER_CONFLICT`, reprogramaciones y duplicados de
   identidad; no incluirlos en una reparación masiva.
3. `IMPOSSIBLE_FUTURE_VERIFIED`: volver a SCHEDULED únicamente con evidencia
   contemporánea pre-match del mismo provider ID y sin evento/score terminal
   posterior al kickoff; de otro modo `MANUAL_REVIEW`.
4. `STALE_LIVE`: retirar solo la proyección realtime visible. Conservar la
   observación y disparar recuperación normal; no escribir un final.
5. `STALE_SCHEDULED`: reabrir results/detail dentro de cuotas. Solo una
   respuesta terminal del proveedor puede cerrar el partido.
6. Ejecutar por IDs explícitos, con dry-run, transacción, before/after JSON,
   límite pequeño, idempotencia y rollback por payload exacto.
7. Recalcular snapshots afectados y verificar outbox; nunca reenviar pushes
   históricos.

Cualquier DML, consulta remota o provider call requiere autorización separada.

## Riesgos de producto

- **Notificaciones:** una reparación tardía puede crear KICKOFF/FULL_TIME o
  goles “nuevos”; el guard de pushes antiguos debe permanecer activo.
- **Eventos:** no borrar canonical_events; finales corregidos pueden cambiar la
  coherencia score/eventos y deben pasar la reconciliación existente.
- **Standings:** no derivar tabla desde una clasificación diagnóstica; solo
  resultados verificados del provider.
- **Match Center:** un stale LIVE debe perder badge/minuto, pero conservar score
  y timeline reales; un VERIFIED futuro debe volver a presentación pre-match
  sin eliminar datos hasta revisión.
- **Aplazados:** una reanudación legítima puede tener kickoff histórico y LIVE
  fresco; por eso antigüedad sola nunca determina `STALE_LIVE`.

## Próximo paso recomendado

Revisar el diff local, integrar primero el guard preventivo con sus tests y,
por separado, autorizar una auditoría read-only acotada en producción para
cuantificar cada clase. Solo después diseñar un dry-run de reparación por IDs.
