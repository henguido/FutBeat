# LIVE v1: estado medido y propuesta (2026-10-05)

Documento de decisión. No se aplicó ningún cambio de cron, cuota ni política en producción.
Toda la evidencia viene de lecturas read-only de producción (`provider_call_ledger`,
`demand_metrics`, `provider_quota_policy`, `cron.job`).

## 1. Arquitectura actual

| Pieza | Cadencia | Qué hace |
| --- | --- | --- |
| `futbeat-goal-live-cron` (job 15) | cada 5 min (`*/5`); el gobernador permite ≥ 240 s | `/fixtures/live` (máximo 100 por página, hasta `livePageLimit` páginas) → observaciones, eventos y estado en vivo |
| `futbeat-goal-detail-cron` (job 16) | cada minuto | un planner por buckets (live, recovery, recent, recent_hot, results, prematch): una llamada `/fixtures/{id}` por partido |
| `futbeat-goal-results-cron` (job 17) | cada 2 h (la migración 20261005010000 propone 30 min) | `/results/date/{d}`, tope de 500 filas por día |
| `futbeat-prune-stale-live` (job 13) | cada 5 min | cierra los LIVE caducados (sin inventar FINAL) |
| Realtime | push por cambio | `live_match_updates` llega a la app sin hacer polling |
| Push (`futbeat-push-outbox`) | cada minuto | outbox de notificaciones (FCM **no** está live) |

## 2. Cuota real

- La cuota es de **1000 unidades/día** y se reinicia a las 00:00 UTC (`provider_remaining` pasa de 76 a 999).
- Uso por día (2–4 oct):

| Lane | Unidades por día |
| --- | --- |
| match-detail | 154–697 |
| live-goal | ~150 |
| team-squad | ~50 |
| results-date | 6–11 |
| standings | 1–4 |

- **El 60–70 % del día se consume entre las 00:00 y las 03:00 UTC.** En la hora de reinicio corren unas 190 llamadas de detalle por hora; el 5 oct a las 06:10 UTC solo quedaban 360 unidades.
- Floors (`class_floors`):
  - bootstrap: 600;
  - coverage: 300;
  - user: 300;
  - user_high: 150;
  - live y results: 20.

  El background (`coverage`) tiene **el mismo floor que la demanda de usuario**: cuando coverage baja el restante a 300, la demanda normal de usuario queda bloqueada el resto del día. Hoy el impacto es bajo (8 demandas de usuario en 3 días), pero escala mal.
- Utilidad del detalle en 3 días (`md_useful_*` / `md_calls_*`):

| Bucket | Útiles / llamadas | % útil |
| --- | --- | --- |
| recovery | 347/527 | 66 % |
| recent | 150/325 | 46 % |
| live | 146/419 | 35 % |
| results | 65/318 | 20 % |
| recent_hot | 30/183 | 16 % |
| prematch | 2/67 | 3 % |

  En total, alrededor del 40 % de las llamadas aporta algo.

## 3. Qué cubrimos bien / qué no

| Caso | Estado |
| --- | --- |
| Gol, marcador, minuto | OK vía la lista live (≤ 5 min de latencia) y Realtime hacia la app |
| Gol anulado / corrección de marcador | OK: reconciliación de eventos y corrección terminal (`terminal_score_correction`, `event_reconciliation`) |
| Roja | OK como evento y push (`notify_red_cards`). La amarilla se muestra en la línea de tiempo, sin push |
| Sustitución / entra / sale | Eventos OK cuando el detalle se refresca; el push de jugador favorito depende del detalle, no de la lista live |
| Titular / banca | Requiere un detalle prematch: el bucket `prematch` tiene 3 % de utilidad (la alineación suele llegar tarde) |
| Inicio | Lista live, con 5 min de latencia |
| Final | Lista live; fallback: lane de resultados más recovery por detalle |
| Partidos de días grandes (>100 en vivo, >500 resultados) | **No**: la lista live tope 100 y los resultados tope 500 dejan fuera partidos. Solo el detalle por partido (1 unidad cada uno) los recupera |

## 4. Propuesta v1 (requiere autorización: política de cuota y crons)

1. **Separar el floor del background:** coverage 300 → 500. La demanda de usuario conserva 300–500 todo el día y coverage deja de vaciar la cuota en la hora de reinicio.
2. **Pacing del detalle background:**
   - tope de unidades por hora para coverage, por ejemplo 60/h;
   - recortar `prematch` (3 % útil) a partidos con equipos o jugadores seguidos;
   - recortar `recent_hot` (16 %) a 1 llamada por partido y hora.

   Ahorro estimado: unas 200 unidades/día.
3. **LIVE adaptativo con lo ahorrado:**
   - 4 min por defecto (mínimo actual 240 s);
   - 2 min mientras exista un partido en vivo de un equipo o competición seguida por algún usuario (`push_follows`).

   Coste aproximado: +15 polls/h durante unas 6 h de partidos seguidos/día ≈ +90 unidades.
4. **Detalle en vivo por favoritos:**
   - el bucket `live` prioriza partidos con seguidores (alertas de jugador titular/sale/entra);
   - el resto, solo con la lista live.
5. **Resultados:** aplicar `20261005010000` (chunks en el link, catch-up de 30 min, hoy vencido como candidato). Para los días con más de 500 resultados, el worker ya lee las finales faltantes de `/fixtures/date` (pagina bien; `18a9869`), con un máximo de 15 páginas y sin bajar de 150 unidades.
6. **Sin proveedor nuevo de pago en v1.** Fallback de datos:
   - recovery por detalle (66 % útil) para partidos vencidos con seguidores o abiertos por usuarios;
   - el resto queda "Por confirmar" (nunca un FINAL inventado).

Presupuesto objetivo diario (1000):

| Concepto | Unidades |
| --- | --- |
| live | 240 |
| detail live/favoritos | 200 |
| recovery | 200 |
| user | 150 |
| results | 40 |
| squads/standings/fixtures | 120 |
| margen | 50 |

## 5. Decisiones pendientes del dueño

- [ ] Aprobar floors: coverage 500 (hoy 300).
- [ ] Aprobar pacing de coverage (60/h) y recorte de prematch/recent_hot.
- [ ] Aprobar LIVE a 2 min solo con partidos seguidos en vivo.
- [ ] Evaluar plan GOAL de mayor cuota si v1 crece (1000/día no cubre detalle de días grandes).

## 6. Hallazgo crítico: el ingest de calendario lleva semanas descartado

- El workflow de GitHub "FutBeat global fixtures" (cada 3 h) pagina bien `/fixtures/date/{d}` (2.102 fixtures, ~22 requests) y envía los datos a `futbeat-global-ingest`.
- La reserva legacy `futbeat_reserve_provider_call` cuenta **todas** las llamadas GOAL del día (~700 de detalle) contra un límite de 24 (hot) / 64 (calendar). Resultado:
  - siempre responde `skipped: daily_limit`;
  - el log del workflow muestra `accepted=` vacío;
  - el ledger tiene 0 filas `global-ingest` desde el 27-sep;
  - `calendar_coverage` no se escribe desde el 19-sep.
- Consecuencias:
  - los FINISHED/marcadores de ayer y hoy que el workflow ya pagó nunca llegan a la base de datos;
  - es la causa principal de los miles de SCHEDULED vencidos;
  - el workflow sigue gastando requests GOAL para nada.
- Fix preparado: migración `20261005070000` (para goal_api, el límite cuenta solo el mismo `call_kind`), con tests.
- Además, el workflow solo hace fetch si quedan ≥ 350 unidades; con el consumo de madrugada eso pasa 1–2 veces al día. Subir el floor de coverage (punto 4.1) también devuelve frecuencia al calendario.
- Al aplicarlo, el ingest vuelve a escribir unos 2.100 fixtures por corrida hot, como antes del 19-sep. Hay que vigilar la carga de PostgREST/DB.
