# FutBeat — validación v39 calendar sub-batches

Fecha: 2026-10-08
Entorno: worktree local aislado
Base: `fix/calendar-day-subbatches`
HEAD de referencia: `66915869b3c91476b3a8ace723c7d43b4b509217`
Estado: worktree detached y aislado; cambios locales sin commit.

## Resultado ejecutivo

v39 conserva la ruta v38 para fechas de hasta 300 fixtures y divide fechas
grandes por buckets contiguos de kickoff de cinco minutos. Cada sub-batch guarda
con coverage vacío; la fecha solo se finaliza después de que todos los stores
respondan correctamente. Un fallo parcial conserva los upserts, no borra
fixtures, no marca coverage y el reintento es idempotente.

Se encontraron y corrigieron tres defectos:

1. Un bucket de kickoff mayor al máximo podía crear un sub-batch de más de 300.
   Ahora falla antes de cualquier store.
2. El finalizador verificaba solo que el match entity existiera. Ahora cada ID
   debe estar indexado en `calendar_matches`, con source `GOAL API` y dentro de
   la fecha UTC exacta.
3. La estrategia balanceada creaba 6 sub-batches para 1.477 fixtures aunque
   cabían en 5. Ahora empaqueta hasta 300 y corta al terminar un bucket.

## Flujo reconstruido

### Fecha pequeña (`<= 300`)

Un read dirigido, una normalización y un store con coverage. No llama al
finalizador. Es la ruta v38 sin cambios semánticos.

### Fecha grande (`> 300`)

1. Ordena por bucket UTC de cinco minutos; kickoff ausente va primero.
2. Conserva orden dentro del bucket y nunca lo corta.
3. Ningún sub-batch supera 300; un bucket imposible falla cerrado.
4. Por sub-batch: resolve → read dirigido → normalize → store sin coverage.
5. Acumula canonical match IDs.
6. Tras el último store llama una vez al finalizador.
7. El finalizador valida source/fecha, elimina solo filas GOAL ausentes y crea
   una coverage row.

Para 1.477 fixtures: 5 reads, 5 stores de máximo 300 y 1 finalize.

### Fallos y retry

- Fallo de sub-batch: no continúa, no finaliza y no cubre.
- Fallo de finalize: conserva upserts, sin delete ni coverage.
- Retry: mappings/entities/calendar son upserts y finalize es idempotente.
- Con una fecha grande, las restantes se devuelven en `deferredDates`; el
  workflow v39 usa `batchSize=1`.

## Archivos modificados

- `supabase/functions/futbeat-global-ingest/index.ts`
- `supabase/migrations/20261008010000_calendar_date_finalize.sql`
- `backend/test/global_ingest_calendar_subbatches.test.mjs`
- este informe

No se modificaron workflow, rollback, Ads, UI, identidad ni archivos de Claude.

## Tests

Suite v39, ejecutada en procesos separados para evitar acumulación PGlite:

- fecha pequeña, 700, cutoff, bucket imposible, escala 1.477;
- no borrado cruzado, idempotencia, fallo parcial/retry, fallo finalize;
- guard SQL/permisos, deferred y multi-date pequeño.

Resultado: **12/12 PASS**. El caso de 1.477 terminó en **13,88 s local**.

Suites vecinas:

- calendar materialization: **13/13 PASS**;
- ingest/context/cache: **25/26 PASS**.

El único fallo vecino es previo: el test `global_ingest_context_single_pass`
cuenta dos apariciones de una función bajo CRLF porque su regex no elimina el
`\r` de una línea comentada. El HEAD original ya contiene comentario e
invocación; ningún archivo v39 modificado participa.

La primera ejecución no probó producto porque el worktree no tenía PGlite. Se
ejecutó `npm ci --ignore-scripts` con lockfile y se repitieron las suites.

## Disk IO

v38 intentaba procesar 1.477 fixtures en una statement y produjo `57014` a
8,6–11 s. v39 limita cada read/store a 300, reduciendo working set, locks y
riesgo de timeout.

Costes: cinco reads + cinco stores + finalize; 1.477 match upserts; entidades
compartidas pueden repetirse entre sub-batches. Finalize usa búsquedas por PK y
delete acotado por fecha, sin reescribir snapshots completos. La corrección 6→5
reduce 16,7 % las rondas respecto al v39 original.

PGlite no mide IO Supabase. Antes de producción hacen falta query plans y
métricas de buffers, WAL, locks, duración e IO Budget durante un canario.

## Seguridad y compatibilidad

- Funciones revocan `PUBLIC`, `anon` y `authenticated`; solo `service_role`.
- `search_path=''` está fijado.
- v38 no llama la nueva función: migración antes de Edge v39.
- Edge v39 antes del workflow `batchSize=1`.
- El changelog Supabase del 2026-10-08 no muestra un breaking aplicable.

## Riesgos abiertos

1. Falta medición real de Disk IO/query plan.
2. Bucket real >300 falla cerrado y deja la fecha sin coverage.
3. La llamada real de 1.477 debe quedar bajo el timeout de 90 s.
4. Tras fallo parcial quedan upserts visibles, pero coverage sigue partial.
5. El test CRLF ajeno debe corregirse aparte para una suite global verde.

## Rollout recomendado — no ejecutado

1. Confirmar backup/PITR y Disk IO Budget.
2. Preflight staging y grants RPC.
3. Aplicar `20261008010000`.
4. Desplegar Edge v39; smoke 403/400.
5. Canario pequeño y luego fecha grande, vigilando ledger, coverage, conteos,
   57014, locks, WAL e IO.
6. Activar workflow `batchSize=1` y observar un retry completo.

## Rollback recomendado — no ejecutado

1. Edge v39 → v38 (`21c71c2`).
2. Smoke v38.
3. Retirar funciones con rollback manual y reparar migration history.
4. Revertir workflow solo si llegó a main.

Sin finalize no hubo deletes ni coverage; los upserts parciales se reconcilian
en retry y no requieren borrado.

## Confirmación

No hubo deploy, migración remota, escritura en producción, llamada a proveedor,
commit, push, PR, merge ni rebase. Todo fue local y aislado.
