# Contrato: resumen de partido v1 (`futbeat.match-summary`)

Generador: `supabase/functions/_shared/match_summary.ts` (`SUMMARY_GENERATOR_VERSION`).
Lectura: `GET /functions/v1/futbeat-api/v1/match-summary?id=fb_match_…`.
Caché compartida: `futbeat_private.match_summaries` (una fila por partido).

## Garantías

1. **Determinista**: misma entrada + misma `generatorVersion` ⇒ mismos bytes.
   Sin reloj, sin aleatoriedad, sin LLM.
2. **Solo hechos verificables**:
   - Fase según el estado efectivo: `FINAL` solo con `VERIFIED`;
     `FINISHED_PENDING_VERIFICATION` ⇒ `FINAL_PROVISIONAL` ("Resultado provisional").
   - Un gol se atribuye solo desde un evento rico (nunca un gol sintético
     "Marcador actualizado", nunca un evento retractado) y **solo si** los
     eventos de gol de cada lado suman exactamente su marcador. Si no cuadran,
     no se nombra a ningún autor (`omissions: scorers_unverified`).
   - Autogol y penal solo si el evento lo indica explícitamente.
   - Asistencias solo en `FINAL` (verificado); en provisional/en vivo se
     omiten (`assists_pending_verification`).
   - Estadísticas: no se resumen en v1 (`statistics_not_summarized`).
3. **Trazable**: cada párrafo lista los `facts` que lo sustentan.
4. **Versionado**: `contractVersion` (forma) y `generatorVersion` (redacción/reglas).
   Un generador más antiguo nunca sobrescribe uno más nuevo en caché.

## Forma

```json
{
  "contract": "futbeat.match-summary",
  "contractVersion": 1,
  "generatorVersion": "1.0.0",
  "locale": "es",
  "matchId": "fb_match_x",
  "phase": "FINAL",
  "headline": "Club Uno 2-1 Club Dos",
  "paragraphs": [
    { "kind": "result", "text": "Club Uno venció 2-1 a Club Dos. Primera Ejemplo.", "facts": ["score"] },
    { "kind": "goals", "text": "Goles de Club Uno: Ana Delantera (12′, asistencia de Bruno Medio) y Ana Delantera (90+3′, penal).", "facts": ["goal-1", "goal-3"] },
    { "kind": "goals", "text": "Goles de Club Dos: Carlos Defensa en propia puerta (40′).", "facts": ["goal-2"] }
  ],
  "facts": [
    { "id": "score", "kind": "score", "home": 2, "away": 1, "provisional": false },
    { "id": "goal-1", "kind": "goal", "side": "home", "minute": 12, "extraMinute": null,
      "playerId": "fb_player_a", "playerName": "Ana Delantera", "ownGoal": false, "penalty": false,
      "assistPlayerId": "fb_player_b", "assistName": "Bruno Medio" }
  ],
  "omissions": [{ "code": "statistics_not_summarized" }],
  "fingerprint": { "significant": "16 hex", "input": "16 hex" }
}
```

`phase` ∈ `PRE_MATCH`, `LIVE`, `FINAL`, `FINAL_PROVISIONAL`, `CALLED_OFF`, `UNKNOWN`.
`paragraphs[].kind` ∈ `result`, `goals`, `red_cards`, `shootout`, `context`.

## Regeneración

`fingerprint.significant` = hash de (versión del generador, fase, titular,
hechos, textos). Cambia con: gol, corrección de marcador, cambio de fase,
expulsión, nombre de un goleador. **No** cambia con: amarillas, cambios,
estadísticas, datos de jugadores ajenos al resumen. La API reescribe la fila
de caché solo cuando cambia esta huella o la versión del generador.

## Uso futuro con texto generado

Un redactor (p. ej. un LLM) puede reescribir el texto **solo** a partir de
`facts` y debe conservar `omissions`; su salida se cachearía con la misma
huella significativa, así se regenera únicamente ante cambios relevantes.
