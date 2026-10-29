# LIVE 161 — resultado local

Base: `codex/integral-qa-160` (`58e188d`). Sin llamadas a Supabase o a proveedores. Las cifras siguientes son de código o simulación, no observaciones de producción.

## Arquitectura reutilizada

`futbeat-goal-live-sync` realiza una lectura global paginada de `/fixtures/live` y registra unidades reales de solicitud. `canonical_events` deduplica los hechos y `notification_outbox` conserva idempotencia por evento, usuario y dispositivo. El claim verifica preferencias y vigencia antes de entregar; el dispatcher acota lotes a 50, concurrencia a 10 y tiempo a 45 s. FCM funciona en `dry_run` salvo habilitación explícita de configuración y base. Flutter ya registra y desregistra dispositivos para usuarios autenticados, y mantiene preferencias. No se añadió otro pipeline.

En esta rama se reutilizó el endurecimiento local PUSH68/69: caducidad de contenido en el claim, `expiresAt` desde la hora del evento, cancelación antes de FCM si venció, TTL Android y expiración APNs. Los archivos SQL son **propuesta local**; Claude debe revisar historial de migraciones y estado remoto antes de cualquier aplicación. Los rollbacks están en `supabase/manual` y tampoco se ejecutaron.

## Proveedores y catálogo

| Evento | GOAL documenta | API-Football documenta | Push actual de FutBeat | Evidencia faltante |
| --- | --- | --- | --- | --- |
| Marcador, inicio, final | fixtures LIVE, cambios de estado | fixtures LIVE y estados | inicio/final para partido o equipo seguido | demora y cobertura por competición |
| Gol, minuto, autogol, penal | eventos de partido | eventos de partido | gol; anulación confirmada después de uno enviado | correcciones reales y cuota por detalle |
| Roja, amarilla | eventos de partido | eventos de partido | roja; amarilla no | cobertura de tarjetas |
| Descanso, segundo tiempo | estado de partido | estados de partido | no | estabilidad de transiciones |
| FT, AET, PEN | estado y marcadores | estados y marcadores | final canónico; no alerta específica de tanda | exactitud de marcadores por torneo |
| Titulares, suplentes | alineaciones | alineaciones | ambas alertas de jugador, incluidas gratis | antelación y cobertura oficial |
| Sustituciones, asistencia | eventos de partido | eventos de partido | sustitución y asistencia de jugador confirmado | identidad canónica y cobertura |
| Resultado final corregido | comparación de snapshots | comparación de snapshots | no alerta genérica | regla de retractación fiable |

La documentación de ambos proveedores describe posibilidades de sus endpoints, no cobertura completa de Costa Rica, ligas internacionales, selecciones ni competiciones secundarias. No hay muestra actual autorizada para estimar porcentajes o latencia de cada una. El fallback a API-Football exige reconciliación canónica y presupuesto independiente; no se habilitó.

Fuentes oficiales: [GOAL API](https://goal-api.com/documentation), [cobertura GOAL](https://goal-api.com/coverage), [API-Football](https://api-sports.io/documentation/football/v3), [planes API-Sports](https://api-sports.io/sports/football).

## Presupuesto de lectura LIVE

Política **local** de GOAL: `live-goal` máximo 400 unidades/día, mínimo 240 s y reserva de 20; hasta 10 páginas por barrido. El límite contratado actual, la reserva compartida real, páginas reales, horario LIVE y llamadas de calendario/detalle/alineaciones no se verificaron. El siguiente cálculo supone 6 horas de actividad y asigna 1/2/5/10 páginas a 10/50/100/300 partidos solo como escenarios, **no** como medición de tamaño de página. Cada celda indica unidades en 15/30/60/120/300 s.

| Partidos / páginas supuestas | 15 s | 30 s | 60 s | 120 s | 300 s |
| --- | ---: | ---: | ---: | ---: | ---: |
| 10 / 1 | 1440 | 720 | 360 | 180 | 72 |
| 50 / 2 | 2880 | 1440 | 720 | 360 | 144 |
| 100 / 5 | 7200 | 3600 | 1800 | 900 | 360 |
| 300 / 10 | 14400 | 7200 | 3600 | 1800 | 720 |

Incluso el valor de 240 s puede gastar 90/180/450/900 unidades en esos cuatro escenarios. La frecuencia sostenible depende de páginas, reserva y horas activas; 15–60 s no es una promesa viable bajo la política local. El simulador puro `backend/notifications/live_budget.mjs` permite repetir el cálculo sin red. Seguidores no multiplican llamadas al proveedor, pero sí mensajes FCM y filas de outbox: 100.000 seguidores requieren capacidad de fanout, limpieza y límites por usuario que aún deben medirse.

## Latencia y activación

Modelo: retraso proveedor + espera de barrido (0 a intervalo) + procesamiento/cola + FCM + entrega Android. Solo la espera de barrido puede calcularse; las demás etapas requieren trazas reales con marcas de tiempo y permiso operativo. El objetivo inicial debe ser alertar únicamente eventos verificados y frescos dentro de su TTL, nunca prometer instantaneidad. `*FtScore` y terminales AET/PEN tienen reconciliación local y pruebas existentes; no se validó su comportamiento en producción en esta tarea.

Antes de LIVE real: confirmar cuota contratada y páginas por barrido con Claude; inventario de migraciones remotas; aprobar y aplicar SQL en ventana separada; habilitar credenciales FCM y modo live por separado; validar RLS, permisos Android, token revocado, tasa por usuario y observabilidad en staging; medir latencia/cobertura por país y torneo. El modo invitado guarda preferencias locales, pero sin usuario autenticado no registra token para push dirigido. Los topics de FCM para equipos públicos abaratarían fanout, pero dificultan revocación y preferencias finas; se conserva el envío dirigido por token.
