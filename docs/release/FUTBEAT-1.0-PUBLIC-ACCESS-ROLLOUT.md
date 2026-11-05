# FutBeat 1.0 — acceso público: despliegue y verificación

Estado: **preparado localmente, nada aplicado ni desplegado.** Cada paso
productivo requiere autorización del propietario.

Contrato app ↔ backend: `packages/contracts/public-api-access-v1.md`.

## Paquetes

| Paquete | Archivos | Efecto al aplicarlo | Rollback |
|---|---|---|---|
| A. Navegación pasiva + límites | `supabase/migrations/20261105100000_public_api_access.sql` | **Inmediato para todos los clientes**: abrir pantallas deja de crear demandas a GOAL (incluida la búsqueda de jugadores). Crea `futbeat_api_admit` (sin uso hasta el paquete C). | `supabase/manual/20261105100000_public_api_access_rollback.sql`, o solo `update futbeat_private.api_access_policy set navigation_demands=true` |
| B. Invitado → cuenta | `supabase/migrations/20261105110000_guest_account_merge.sql` | RPC de tickets; nada cambia hasta que la app los use | `supabase/manual/20261105110000_guest_account_merge_rollback.sql` |
| C. Contrato de la API | `supabase/functions/futbeat-api/index.ts`, `_shared/api_access.ts` | **Ninguno** sin variables de entorno: idéntica a la actual | Quitar las variables (vuelve a `open`) o redeploy anterior |
| (P4) Resúmenes | `20261105090000_match_summary_cache.sql` + ruta `/v1/match-summary` | Independiente | `supabase/manual/20261105090000_match_summary_cache_rollback.sql` |

## Requisitos previos en Supabase (panel, con autorización)

1. **Claves JWT asimétricas.** `futbeat-api` verifica tokens con el JWKS.
   Comprobar que `https://<ref>.supabase.co/auth/v1/.well-known/jwks.json`
   devuelve al menos una clave (ES256/RS256). Si el proyecto solo tiene el
   secreto HS256 heredado, migrar a *JWT signing keys* (rotación con clave
   en espera, sin cerrar sesiones) **antes** de activar `dual`/`user`.
2. **Auth → Providers → Anonymous sign-ins: ON.**
3. **Auth → Rate limits**: límite de inicios de sesión anónimos por IP
   (por defecto 30/h). Mantener o bajar. CAPTCHA (Turnstile/hCaptcha) es
   opcional para pruebas internas; recomendable antes de producción abierta.
4. **Auth → Allow manual linking: ON** (vincular Google al invitado).
5. Limpieza de usuarios anónimos antiguos: no se programa aquí (cron fuera
   de alcance). Al hacerlo, el borrado de usuario elimina sus filas.

## Secretos / variables de `futbeat-api`

| Variable | Valor | Nota |
|---|---|---|
| `FUTBEAT_RATE_SALT` | aleatorio ≥ 32 caracteres | Secreto. Sin él no hay límite por IP |
| `FUTBEAT_API_ADMISSION` | `on` | Activa los límites |
| `FUTBEAT_API_ACCESS_MODE` | `dual` → `user` | `dual` mientras existan APKs con token fijo; `user` para la APK de producción |

La clave privada de Preview y su función (`futbeat-passive-api` /
`futbeat-qa-stored`) **no se tocan**: son funciones separadas y no leen
estas variables.

## Orden sugerido

1. Requisitos 1–4.
2. Paquete A fuera de ventana de partidos en vivo. Verificar (abajo).
3. Paquete B.
4. Deploy de `futbeat-api` (paquete C) **sin variables**: comportamiento igual.
5. `FUTBEAT_RATE_SALT` + `FUTBEAT_API_ADMISSION=on` + `FUTBEAT_API_ACCESS_MODE=dual`.
6. Instalar la APK candidata (sesión anónima) en dos teléfonos; prueba de
   aceptación.
7. `FUTBEAT_API_ACCESS_MODE=user` cuando ya no haya APKs con token fijo.
8. Prueba de carga en **staging**:
   `node scripts/load/public-api-multi-client.mjs --clients 10 --rounds 3 --match <id> --run`
   (rechaza producción salvo confirmación explícita).

## Verificación (solo lectura)

```sql
-- Política vigente
select * from futbeat_private.api_access_policy;
-- Demandas de navegación de la última hora (debe ser 0 tras el paquete A)
select 'match_detail' t,count(*) from futbeat_private.match_detail_requests where user_requested_at>now()-interval '1 hour'
union all select 'player_search',count(*) from futbeat_private.player_search_demands where requested_at>now()-interval '1 hour'
union all select 'calendar_date',count(*) from futbeat_private.calendar_date_requests where last_requested_at>now()-interval '1 hour'
union all select 'standings',count(*) from futbeat_private.standings_demands where requested_at>now()-interval '1 hour'
union all select 'team_squad',count(*) from futbeat_private.team_squad_demands where requested_at>now()-interval '1 hour'
union all select 'team_matches',count(*) from futbeat_private.team_match_demands where requested_at>now()-interval '1 hour'
union all select 'terminal_result',count(*) from futbeat_private.results_date_user_demand where requested_at>now()-interval '1 hour';
-- Llamadas GOAL por origen (solo workers programados)
select trigger_source,call_kind,count(*) from futbeat_private.provider_call_ledger
where reserved_at>now()-interval '1 hour' group by 1,2 order by 3 desc;
-- Tráfico y límites del minuto actual
select split_part(bucket,':',1) kind,count(*) clients,sum(hits) hits
from futbeat_private.api_rate_counters where window_start=date_trunc('minute',now()) group by 1;
```

Columnas verificadas contra el esquema migrado local; los workers también
actualizan algunas de estas tablas (p. ej. `standings_demands.requested_at`
al reintentar): un valor distinto de 0 se investiga antes de concluir.

## Límites propuestos (ajustables sin redeploy)

| Ventana | Invitado | Registrado |
|---|---|---|
| Por minuto | 60 | 120 |
| Por hora | 1 200 | 2 400 |
| Por IP (hash), minuto | 240 | |
| Global, minuto | 6 000 | |

Abrir un partido son ~4–5 lecturas; un humano no se acerca a 60/min. Ajustar
tras la prueba de carga: `update futbeat_private.api_access_policy set …`.

## Aceptación (estado)

| Criterio | Evidencia local | Pendiente |
|---|---|---|
| Misma APK en dos teléfonos sin configuración individual | Contrato: config pública común + sesión anónima por instalación | APK de Codex + 2 teléfonos |
| Ambos consultan partidos reales | Prueba multi-cliente (3 usuarios concurrentes servidos) | Staging/producción autorizados |
| Sesiones y favoritos separados | Pruebas `guest_account_merge` y multi-cliente | Dispositivos |
| Sin llamadas GOAL al navegar | Las 11 entradas de demanda neutralizadas; 0 filas de demanda y 0 ledger al navegar | Medición tras aplicar A |
| Límites globales y por usuario | `futbeat_api_admit` + 429 con `Retry-After`; concurrencia exacta | Prueba de carga en staging |
| Offline tras descargar | Sin cambios en SQLite/caché (Android) | Dispositivos |
| Sin credenciales administrativas en la APK | Contrato: solo publishable | Inspección del APK/AAB |
