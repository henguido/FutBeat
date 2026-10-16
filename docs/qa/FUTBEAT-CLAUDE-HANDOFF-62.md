# FutBeat: handoff Flutter → backend (orchestrator 62)

Alcance: evidencia local y sintética de la candidata Android 1.0.0+5. No se consultó ni modificó Supabase, GOAL, cron o proveedores. Los puntos siguientes son preguntas para Claude, no defectos de producción confirmados.

## Identidad de jugadores y plantillas

- Flutter resuelve redirecciones canónicas explícitas para actividad reciente y transferencias de un jugador. No fusiona personas por nombre. Una prueba sintética mantiene los eventos del mismo `playerId` en club y selección, y excluye a un homónimo con otro ID.
- Confirmar con snapshots reales si las plantillas de club y selección envían un mismo ID canónico de persona (o un redirect explícito), conservando por separado la pertenencia a cada equipo y temporada. Si faltan mappings, resolverlos en la capa de identidad con evidencia de proveedor, no mediante coincidencia de nombres.
- Revisar si transferencias o eventos llegan sin `playerId`: Flutter ahora excluye transferencias de ID ausente del perfil para evitar mostrarlas en todos los jugadores. Si existe una fuente autoritativa alternativa, documentar su contrato antes de ampliar el filtro.

## Match Center y competiciones

- Standings por fase/grupo, alineaciones, suplentes, formaciones y entrenadores tienen defensas Flutter existentes. No se demostró un fallo local adicional con fixtures sintéticos. Si un caso real carece de tabla o alineación, conservar el payload anonimizado y distinguir ausencia del proveedor de pérdida en ingestión/snapshot.
- Para #221 y antecedentes #98/#147/#217, necesitamos ejemplos reales mínimos, sin tokens ni datos personales: `match_id`, competición/fase/grupo, IDs canónicos de equipo/jugador y presencia/ausencia de secciones. No inferir grupos o entrenadores que el proveedor no entrega.

## Feed y LIVE

- La regla de producto #220 es mostrar una sola sección superior Favoritos y repetir cada partido seguido en su competición. Flutter 1.0.0+5 aplica esa regla localmente; una repetición entre secciones es esperada. Solo se considera duplicado si aparece dos veces dentro de la misma sección con el mismo ID canónico.
- La carrera REST/Realtime investigada en Flutter ya estaba cubierta por el commit `374a411` en la base `9002abd`; no se cambió el contrato backend.
- Sigue sin verificarse sobre datos reales el caso en que dos filas del mismo ID canónico llegan con distinta frescura o evidencia deportiva. Si Claude encuentra un ejemplo, compartir el par de filas anonimizado y el orden de llegada para una prueba de reconciliación local. No asumir que dos IDs de proveedor se deben fusionar.

No ejecutar cambios backend a partir de este handoff sin investigación independiente y coordinación de la ventana de producción.
