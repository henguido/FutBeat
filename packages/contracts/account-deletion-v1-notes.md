# Notas para Codex: eliminación de cuenta v1 (BE11-A5, 2026-11-07)

El contrato `account-deletion-v1.md` **no cambia**: mismos endpoints, cabecera, códigos y estados. Estas notas recogen lo comprobado al revisar la app (solo lectura) y un ajuste interno de la función.

## Estado de la app (lectura de `codex/android-1-release-candidate` @0d93f83f con cambios locales, y `codex/mobile-266-r05` @a40645d1)
- La app llama a `POST futbeat-delete-account` **sin** `X-FutBeat-Deletion-Id` y no consulta nunca `futbeat_account_deletion_status`. El servidor sigue el camino heredado, que es compatible, pero **sin recibo**: si se pierde el 200, un 401 posterior no prueba nada.
- El POST usa `authHeaders` con el `access_token` guardado tal cual, sin renovarlo antes. Con un token caducado, el gateway responde 401 y el borrado no llega a la función.

## Qué hace falta en la app
1. **Antes del POST:** si el token caduca pronto, renovar la sesión (`refreshSession`). Después generar y guardar `{uid, deletionId, startedAt}` en el almacenamiento seguro.
2. **Enviar** `X-FutBeat-Deletion-Id: <deletionId>`, en minúsculas o mayúsculas (el servidor normaliza).
3. **Tratar** 400, 409 y 503 según el contrato.
   - 503 `RECEIPT_UNAVAILABLE` o sin código: **reintentar con el mismo id**.
4. **Al reabrir con un `deletionId` guardado:** `POST /rest/v1/rpc/futbeat_account_deletion_status`.
   - Solo con `apikey` publishable y **sin `Authorization`**.
   - **Usar POST, no GET:** la consulta puede completar un recibo pendiente, y PostgREST ejecuta los GET en solo lectura.
5. **`deleted`** cuenta igual que un 200: escribir `accountDeletionConfirmedFor` y hacer el cierre local.

## Ajuste interno de la función (sin cambio de contrato)
- El recibo que contiene un `uid` vivo ahora se escribe **después** de que Auth (`/auth/v1/user`) acepte el token, ya no a partir del payload sin verificar.
  - Un token que Auth rechaza da 401 y no escribe ningún recibo.
- Reintento con id cuando la cuenta ya no existe (por ejemplo, se borró antes sin cabecera): 200 `alreadyDeleted` y el id pasa a `deleted`.
  - Si ese id pertenece a otro usuario, la respuesta es 409, igual que antes.
- Las respuestas y los códigos son los mismos para la app.

## Residuos tras borrar una cuenta (migración `20261107120000_account_deletion_residue.sql`, pendiente de autorización)
- Al borrar una cuenta, su uid quedaba sin límite de tiempo en `guest_merge_tickets` y `guest_account_merges`.
  - Con la migración, esas filas se eliminan (o `redeemed_by` se vacía) junto con la cuenta.
- **No resuelto en el backend:** tras fusionar un invitado con una cuenta existente, el usuario anónimo del invitado (con sus favoritos) sigue existiendo.
  - Si la cuenta se elimina después, ese invitado no se borra.
  - Opciones para decidir: borrar el invitado después del canje o purgar periódicamente los anónimos inactivos.
