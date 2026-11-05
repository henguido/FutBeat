# Contrato: acceso público FutBeat 1.0 (app ↔ backend)

Para la variante Android de producción (Codex, desde `f255404d` / PR #248).
Backend: rama `claude/futbeat-backend-local-d2nnav`, migraciones
`20261105100000`, `20261105110000`, `futbeat-api` + `_shared/api_access.ts`.

## Principios

- **Una sola APK** para todos los teléfonos. Su configuración es pública y
  común: URL del proyecto, clave **publishable** y URL de `futbeat-api`.
  Ningún secreto: ni `service_role`, ni `sb_secret_`, ni la clave Preview, ni
  `FUTBEAT_API_PUBLIC_TOKEN` de usuario fijo.
- **Cada instalación es un usuario de Supabase.** Sin registro, es un
  usuario **anónimo** (invitado), creado automáticamente al primer arranque.
- **Navegar nunca provoca llamadas a GOAL.** El servidor solo sirve lo que ya
  está almacenado; no hay demandas por navegación (interruptor central en la
  base, apagado).
- **Límites en el servidor** por usuario, por IP (hash) y globales.

## Configuración de la APK (dart-define, pública)

| Clave | Valor |
|---|---|
| `FUTBEAT_SUPABASE_URL` | `https://<ref>.supabase.co` |
| `FUTBEAT_SUPABASE_PUBLISHABLE_KEY` | `sb_publishable_…` |
| `FUTBEAT_API_URL` | `https://<ref>.supabase.co/functions/v1/futbeat-api` |

`FUTBEAT_API_PUBLIC_TOKEN` desaparece en esta variante: el `Authorization` es
el token de sesión del usuario.

## Sesión

1. **Primer arranque sin sesión guardada** → invitado:
   `POST {SUPABASE_URL}/auth/v1/signup` · cabecera `apikey: <publishable>` ·
   cuerpo `{}`. Respuesta: `access_token`, `refresh_token`, `expires_in`,
   `user.is_anonymous = true`. Guardar en el almacenamiento seguro que ya usa
   la app.
2. **Renovación**: `POST /auth/v1/token?grant_type=refresh_token`
   `{ "refresh_token": … }` antes de `expires_in`, o tras un 401.
3. **Nunca** crear otro invitado mientras exista un `refresh_token` que solo
   falló por red: se perderían los favoritos sincronizados del invitado.
   Solo si Auth responde `refresh_token_not_found`/`…_already_used` se crea
   un invitado nuevo.
4. Sin red, la app sigue funcionando con SQLite; la sesión se renueva al
   volver la conexión (sin borrarla).

## Llamadas a `futbeat-api`

Cabeceras en **todas** las rutas:

```
apikey: <publishable>
Authorization: Bearer <access_token de la sesión (invitado o registrado)>
```

| Respuesta | Significado | Acción de la app |
|---|---|---|
| 200/404/503 | Igual que hoy | Sin cambios |
| 401 `SESSION_REQUIRED` o `INVALID_CREDENTIALS`/`INVALID_JWT` | Sin sesión válida | Renovar una vez y repetir; si falla, mostrar caché |
| 429 `RATE_LIMITED` + `Retry-After` | Límite alcanzado (`reason`: `identity_minute`, `identity_hour`, `ip_minute`, `global_minute`, `isolate_minute`) | No reintentar antes de `Retry-After`; mostrar caché |

Con navegación pasiva las respuestas no traen `enrichmentPending`,
`lineupEnrichmentPending`, `history: requested` ni `pendingRemote`: no hay
nada "en camino" por haber abierto una pantalla. La app no debe esperar
refrescos por esos indicadores.

## Pasar de invitado a cuenta

### A) Crear cuenta desde el invitado (se conserva TODO)

Se vincula la identidad al mismo usuario anónimo: el `user.id` no cambia,
favoritos y preferencias siguen ahí sin migrar nada.

- **Correo**: `PUT /auth/v1/user` con la sesión del invitado y
  `{ "email": …, "password": … }`. Tras confirmar el correo, el usuario deja
  de ser anónimo (`is_anonymous=false` en el siguiente token).
- **Google**: vinculación de identidad (`linkIdentity`, flujo PKCE ya
  existente apuntando a `/auth/v1/user/identities/authorize?provider=google`
  con la sesión del invitado). Requiere *manual linking* habilitado.
- **Facebook**: igual que Google, cuando esté aprobado (sigue oculto).

### B) Entrar a una cuenta que ya existe (otro `user.id`)

1. Con la sesión **del invitado**: `POST /rest/v1/rpc/futbeat_issue_guest_merge_ticket`
   (cuerpo `{}`) → `{ ticket, expiresAt }` (10 minutos, un solo uso). Guardar
   solo en memoria.
2. Iniciar sesión en la cuenta (correo, Google o recuperación).
3. Con la sesión **de la cuenta**: `POST /rest/v1/rpc/futbeat_redeem_guest_merge_ticket`
   `{ "p_ticket": ticket }` → `{ merged, follows, interests, preferences, devicesDisabled }`.
   Une favoritos e intereses; en preferencias gana la cuenta (solo se
   rellenan campos vacíos); desactiva los dispositivos push del invitado.
4. Sincronizar favoritos locales como hoy (`futbeat_sync_push_follows`) y
   registrar el dispositivo push bajo la cuenta.

Si el canje falla (ticket vencido, sin red), la cuenta sigue funcionando; los
favoritos locales se suben con la sincronización normal.

### Cerrar sesión

Volver a invitado con un **nuevo** usuario anónimo. Los datos locales que
pertenecían a la cuenta no deben quedar visibles para el nuevo invitado.

## Lo que la app NO debe hacer

- Llamar a GOAL u otro proveedor deportivo.
- Usar `service_role`, claves `sb_secret_`, la clave Preview o un token fijo.
- Reintentar en bucle ante 429/503.
- Crear invitados nuevos en cada arranque.
