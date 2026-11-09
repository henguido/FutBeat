# FutBeat — contrato pendiente para el modelo de producción

Base aprobada: PR #248, f255404d3029f12122ea91b3246e1a8368da3fb0. Se conserva la misma rama y el cliente existente. Ningún nuevo binario, instalación, credencial ni servicio activado en esta preparación.

## Decisión de producto

Un único APK con configuración pública común (origen HTTPS y clave publishable pública, si el contrato la necesita). No lleva la clave privada/revocable de Preview ni secretos administrativos. Entrar como invitado no pide configurar nada. Las cuentas obtienen sus sesiones normales y mantienen favoritos/preferencias aislados. Los tokens de sesión no son claves de instalación entregadas manualmente.

## Qué se reutiliza

- Auth, PKCE Google/Facebook, correo, recuperación y persistencia de PushService existentes.
- La lógica existente de primera vinculación y aislamiento de favoritos/país/alertas.
- ApiRepository, SQLite, Match Center, fotos y el lector pasivo con sus límites, ACK, caché y cancelación ya probados.
- La clave privada Preview queda intacta y excluida de release por guardas existentes.

## Información exacta necesaria de Claude

No hay un contrato oficial nuevo en los handoffs disponibles: API277/281/284 siguen describiendo el acceso Preview por clave compartida. RC1-BACKEND/EXEC tratan resultados y cuota, no esta autenticación. Esta solicitud no autoriza cambios productivos.

1. Endpoint oficial y lista de rutas GET, prefijos y formato JSON/errores/ACK. Confirmar qué coincide con API277 para adaptar el lector existente sin reimplementarlo. Ningún fallback que genere demanda, request=1, ingesta ni llamada de proveedor.
2. Política de invitado: lectura pública con credencial pública de proyecto o sesión anónima emitida automáticamente. Si es Auth anónimo, fijar creación, renovación, persistencia, is_anonymous, vinculación y salida sin presentarlo como una cuenta registrada. No activar anonymous sign-ins desde Android.
3. Cabeceras de cuenta: JWT de sesión verificado por servidor, permisos por identidad, expiración/revocación/401 y reglas de renovación. El móvil no decide autorización por decodificar claims. Confirmar disponibilidad de Google/Facebook/correo y callbacks.
4. Límites globales, por usuario y por origen de invitado; concurrencia, Retry-After y protección de creación de sesiones. Los límites en un APK se pueden eludir: no prueban protección global.
5. Semántica de caché: qué lecturas son públicas y cuáles personales. Las personales se separan por cuenta; respuestas en vuelo de A no pueden actualizar B después de cerrar o cambiar sesión.
6. Evidencia de contrato/commit/hash, pruebas multicliente, cero demandas por navegación y autorización de activación. No entregar secretos administrativos ni reutilizar el token Preview como acceso público.

## Prueba local añadida

En mobile261_release_journey_test.dart se reutiliza el servidor de Auth/seguimientos existente y se añaden dos instalaciones simultáneas con SQLite en archivos y almacenes seguros independientes. Comparten exactamente LiveRealtimeConfig. Se comprueba invitado local sin crear cuenta implícita, preferencias propias, logins A/B simultáneos, fusión de favoritos sin mezclar cuentas, tokens distintos, cierre/reapertura de ambos y logout de A sin alterar B. Es LOCAL_PASS con dobles, no aceptación de dos Android reales ni prueba de los límites globales del servidor.

PushService acepta opcionalmente el almacén seguro para esta prueba; el constructor por defecto conserva FlutterSecureStorage. No se cambian rutas, lógica de autenticación, UI ni configuración activa.

Documentación primaria: https://supabase.com/docs/guides/auth/auth-anonymous distingue usuario Auth anónimo de la clave anon pública: un usuario anónimo usa rol authenticated e is_anonymous. Por eso no se activa ese mecanismo sin su política servidor. El índice changelog.md no pudo leerse con el lector web; no se implementa una API nueva a partir de supuestos.

## Recorrido real cuando exista contrato aprobado

- Compilar una única APK candidata normal con configuración pública común, sin bandera/clave Preview. Verificar manifiesto, paquete, firma, hash y ausencia de secretos administrativos antes de instalar.
- Inventariar dos dispositivos compatibles y preservar apps/datos. Solo el A32 RF8R32GQWGL está disponible actualmente; segundo dispositivo NOT VERIFIED. No instalar mientras falten contrato/configuración.
- Mismo SHA en ambos; invitado abre datos reales sin registro/configuración. Verificar cuotas globales con evidencia servidor, no solo contadores locales.
- A y B inician sesión; favoritos y preferencias separados; invitado mantiene sus selecciones al vincular. Recuperación de cuenta por el proveedor real, sin registrar credenciales.
- Calendario, LIVE almacenado/frescura, Match Center, cronología, alineaciones/ausencias, estadísticas, fotos y Tabla. No inventar datos faltantes.
- Descargar, terminar proceso, desconectar y reabrir desde SQLite en ambos. Restaurar conectividad y conservar datos. Sin cambios en QA123.

Estado: NO-GO conectado para este modelo hasta recibir contrato y evidencia. No se declara que la Preview validada sea una prueba del modelo oficial.
