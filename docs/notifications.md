# Notificaciones en la app (Flutter)

Este documento describe la parte cliente de las notificaciones push de
FutBeat (`apps/mobile`). El pipeline de servidor (outbox, despachador, FCM)
está en `docs/LIVE-PUSH.md`.

## Flags de build requeridos

Push está **desactivado** salvo que el build reciba todos estos
`--dart-define` (valores públicos del proyecto Firebase, nunca secretos):

| Flag | Contenido |
| --- | --- |
| `FUTBEAT_PUSH_ENABLED` | `true` para activar push en este build |
| `FUTBEAT_FIREBASE_API_KEY` | API key pública de la app Firebase |
| `FUTBEAT_FIREBASE_APP_ID` | App ID de Firebase (Android `com.futbeat.futbeat` o iOS) |
| `FUTBEAT_FIREBASE_SENDER_ID` | Messaging sender ID |
| `FUTBEAT_FIREBASE_PROJECT_ID` | Project ID |

`PushService.configured` es `FUTBEAT_PUSH_ENABLED && FUTBEAT_FIREBASE_APP_ID
!= ''`. Sin esos flags la app compila y funciona igual: no se inicializa
Firebase, no se escucha `onMessage`, no se muestra el aviso para activar y el
botón "Activar avisos" no aparece. La cuenta, los favoritos y las
preferencias se sincronizan igualmente (no dependen de push).

Ejemplo local (archivo ignorado por Git, sin commitear):

```json
{
  "FUTBEAT_PUSH_ENABLED": "true",
  "FUTBEAT_FIREBASE_API_KEY": "<api key pública>",
  "FUTBEAT_FIREBASE_APP_ID": "<app id>",
  "FUTBEAT_FIREBASE_SENDER_ID": "<sender id>",
  "FUTBEAT_FIREBASE_PROJECT_ID": "<project id>"
}
```

```
flutter build apk --dart-define-from-file=futbeat-push.json
```

En CI (`.github/workflows/beta-android.yml`) los flags figuran solo como
placeholders comentados; para activarlos hay que añadir los valores como
inputs o variables del repositorio. No se versionan `google-services.json`
ni `GoogleService-Info.plist`: las opciones se pasan por `--dart-define`.

## Preferencias

Perfil → Notificaciones y el paso "Alertas" del onboarding muestran, en este
orden (`lib/features/profile/notification_options.dart`):

| Interruptor | Clave de servidor |
| --- | --- |
| Inicio de partido | `notify_kickoff` |
| Gol | `notify_goals` |
| Gol anulado/corregido | `notify_goal_annulled` (nueva) |
| Tarjeta roja | `notify_red_cards` (nueva) + `notify_cards` (legado) |
| Resultado final | `notify_final` |
| Jugador favorito titular | `notify_player_starter` (nueva) |
| Jugador favorito en el banquillo | `notify_player_bench` (nueva) |
| Entra al campo | `notify_player_sub_in` (nueva) |
| Sale del campo | `notify_player_sub_out` (nueva) |
| Noticias | `notify_news` |
| Transferencias | `notify_transfers` |

Compatibilidad con servidores antiguos:

- `notify_cards` se mantiene igual a `notify_red_cards` (los servidores
  viejos lo aplican a todas las tarjetas).
- `notify_lineups` = titular **o** banquillo.
- Al leer un perfil sin claves nuevas, éstas heredan la clave que sustituyen
  (`notify_red_cards` ← `notify_cards`, `notify_goal_annulled` ←
  `notify_goals`, titular/banquillo ← `notify_lineups`); cambios de campo
  empiezan activados.
- El almacenamiento local guarda todas las claves (camelCase).

### Contrato del RPC

El guardado llama primero a
`futbeat_update_profile_preferences(p_preferences jsonb)` con:

```json
{
  "display_name": "…", "language_code": "es", "timezone": "device",
  "hour_format": "system",
  "notify_kickoff": true, "notify_goals": true, "notify_final": true,
  "notify_cards": true, "notify_lineups": true, "notify_news": true,
  "notify_transfers": true, "notify_red_cards": true,
  "notify_goal_annulled": true, "notify_player_starter": true,
  "notify_player_bench": true, "notify_player_sub_in": true,
  "notify_player_sub_out": true
}
```

Si PostgREST responde 404 / `PGRST202` (función inexistente) usa
`futbeat_sync_user_profile_v2` con las siete claves antiguas y no vuelve a
probar el RPC nuevo en esa sesión. Cualquier otro error se propaga (el perfil
queda marcado como pendiente y se reintenta en la siguiente reconciliación).
La lectura (`futbeat_read_user_profile`) acepta claves camelCase o
snake_case.

## Mensajes

- **Primer plano** (`FirebaseMessaging.onMessage`): banner in-app
  (`SnackBar` flotante con el estilo de la app) con título/cuerpo y acción
  "Ver" cuando hay destino.
- **Segundo plano / app cerrada** (`onMessageOpenedApp`,
  `getInitialMessage`): abre el destino. Si la app aún está en `/start` u
  onboarding, espera a llegar al shell.
- Destino desde `data`: `matchId` → `/match/<id>`, si no `playerId` →
  `/player/<id>`, si no `teamId` → `/team/<id>`.

Todo está en `lib/core/push_messages.dart` y sólo se crea cuando
`PushService.configured`.

## Aviso para activar

Tras iniciar sesión (o crear cuenta con sesión) y tras el primer favorito
añadido en la sesión, se ofrece "Activa las notificaciones" en una hoja
descartable. Sólo si push está configurado, hay sesión y el dispositivo no
está activado, y como mucho una vez cada 7 días
(`futbeat.push.prompt.shownAt`).

## Sincronización de cuenta (diagnóstico)

La sincronización de favoritos (`futbeat_sync_push_follows`) y perfil no
depende de push: corre al iniciar sesión, al restaurar la sesión y en cada
cambio de favoritos, y se reintenta cada 10 minutos y al volver a primer
plano. `futbeat_read_user_profile` crea la fila de preferencias del usuario
en el servidor en la primera lectura, así que una cuenta sin fila de
preferencias nunca completó una lectura autenticada desde la app.
