# Contrato: eliminación de cuenta con recibo durable (R05, FutBeat 1.0)

Backend: rama `claude/backend-10-close`.
- Migración `supabase/migrations/20261106120000_account_deletion_receipts.sql`.
- Función `supabase/functions/futbeat-delete-account/index.ts` (JWT verificado en el gateway, igual que hoy).

## Problema que resuelve
Hoy la app hace `POST futbeat-delete-account` y solo después escribe su confirmación local. Si la respuesta se pierde y el token caduca, al reabrir solo recibe 401. **Un 401 nunca prueba un borrado.** Con este contrato, el servidor guarda un recibo que la app puede consultar **sin sesión**.

## Flujo de la app
1. **Antes de llamar:** generar `deletionId` (UUID v4 aleatorio, `Random.secure`) y guardarlo de forma durable en el almacenamiento seguro, junto al `uid`, por ejemplo `{uid, deletionId, startedAt}`. Si la escritura falla, no se llama.
2. **Llamada** con la sesión del usuario que se elimina:
   ```
   POST {SUPABASE_URL}/functions/v1/futbeat-delete-account
   apikey: <publishable>
   Authorization: Bearer <access_token del usuario>
   X-FutBeat-Deletion-Id: <deletionId>
   ```
3. **Respuestas:**

   | HTTP | Cuerpo | Significado | Acción |
   |---|---|---|---|
   | 200 | `{deleted:true, deletionId}` (puede traer `alreadyDeleted:true`) | Cuenta eliminada | Confirmación local, como hoy (`accountDeletionConfirmedFor`) |
   | 400 | `code: INVALID_DELETION_ID` | Id mal formado | Error de programación; no reintentar con ese id |
   | 401 | — | Sin sesión válida | **No inferir borrado.** Consultar el estado (paso 4) |
   | 403 | — | El token no es de este usuario | No reintentar |
   | 409 | `code: DELETION_ID_CONFLICT` | El id pertenece a otro usuario | Generar un id nuevo **solo** si el estado del id viejo es `unknown` |
   | 503 | `code: RECEIPT_UNAVAILABLE` o sin código | **No se borró nada** (o el borrado falló antes de completarse) | Reintentar más tarde con el **mismo** id |

4. **Al reabrir con un `deletionId` pendiente**, o tras perder la respuesta, consultar el estado sin `Authorization`, solo con la clave publishable:
   ```
   POST {SUPABASE_URL}/rest/v1/rpc/futbeat_account_deletion_status
   apikey: <publishable>
   Content-Type: application/json
   { "p_deletion_id": "<deletionId>" }
   ```
   Respuesta: `{"status":"deleted","completedAt":"…"}`, `{"status":"pending"}` o `{"status":"unknown"}`.
   - **`deleted`:** prueba durable del borrado. Completar el cierre local, igual que con un 200.
   - **`pending`:** el recibo existe, pero **la cuenta sigue existiendo**, porque el borrado no llegó a hacerse. Si la sesión se renueva, repetir el POST con el **mismo** id. Si no, mostrar "No pudimos confirmar la eliminación" y ofrecer reintentar.
   - **`unknown`:** el servidor nunca registró ese id, así que no se borró nada. Se puede reintentar con sesión válida (mismo id o uno nuevo).
   - **No enviar `Authorization`** en esta consulta: un token caducado haría que PostgREST respondiera 401.
5. **Al terminar** (`deleted`): borrar el `deletionId` guardado junto con el resto de datos de la cuenta.

## Garantías del servidor
- **El recibo se escribe antes de borrar.** Si no se puede escribir, la cuenta no se borra (503).
- **Idempotencia:** el mismo id con el mismo usuario nunca borra dos veces. Con la cuenta ya borrada responde 200 `alreadyDeleted`. Las peticiones concurrentes con el mismo id terminan en un solo recibo y las dos responden 200.
- **Un id está ligado a un usuario:** usarlo con otro usuario da 409 y no borra nada.
- **Respuesta perdida:** si el borrado se completó pero no llegó la respuesta (o falló el cierre del recibo), la consulta de estado comprueba que la cuenta ya no existe y responde `deleted`.
- **Privacidad:**
  - se guarda solo el SHA-256 del id;
  - el `uid` se conserva únicamente mientras el recibo está `pending` (la cuenta aún existe) y se borra al completarse; después queda solo el SHA-256 del `uid`;
  - no se guardan correo, IP ni dispositivo;
  - los recibos se purgan a los 30 días;
  - la consulta de estado no revela ningún dato de usuario.
- **Compatibilidad:** sin la cabecera `X-FutBeat-Deletion-Id`, el comportamiento es exactamente el actual (APK instaladas).
- **Permisos:** `futbeat_account_deletion_status` lo pueden ejecutar `anon`, `authenticated` y `service_role`; `begin` y `finish` solo `service_role`. La tabla queda con RLS y sin acceso para clientes.

## Pruebas (backend)
`backend/test/account_deletion_receipts.test.mjs`: SQL real en PGlite más la función real. Cubre:
- flujo completo;
- ACK perdido;
- recibo no disponible (no borra);
- reintentos idempotentes;
- concurrencia;
- conflicto entre usuarios;
- borrado fallido y reintento;
- sin cabecera (comportamiento heredado);
- ids inválidos;
- purga y permisos.

## Despliegue (requiere autorización)
1. Migración (op `b10-r05-sql`).
2. Función (op `b10-r05-fn`).

**Rollback:**
- volver a desplegar la función anterior (prod v3, idéntica a `27c526f2`);
- después, `supabase/manual/20261106120000_account_deletion_receipts_rollback.sql`.
