# FutBeat en Supabase — bloque 0.3

## Estado verificado

Proyecto `izlmruqawgagwdcsjhte`, nombre FutBeat, PostgreSQL 17, región us-east-1.
Se inspeccionó vacío antes de aplicar las migraciones. Se trasladaron desde la
base local 7 entidades (1 competición, 4 equipos, 2 partidos), 7 equivalencias y
1 lote con respuesta original y snapshot. Se conservaron sus IDs y fecha original;
el traslado no cuenta como actualización deportiva.

La función HTTPS `futbeat-api` sirve exclusivamente `GET /v1/snapshot`.
La plataforma verifica el JWT. El cliente usa la clave pública legacy anon del
proyecto para compatibilidad con esa verificación, no una clave de servidor.
Esto habilita lectura de datos deportivos públicos; no es inicio de sesión del usuario.
Las credenciales `SUPABASE_SERVICE_ROLE_KEY` permanecen en el entorno de la función.

La función SQL es `SECURITY INVOKER`, tiene search_path vacío y solo recibe permiso
de ejecución el rol de servidor. Las tres tablas privadas tienen RLS y no hay
acceso de anon/authenticated al esquema o a la función SQL. El cliente nunca recibe
el lote original ni el historial de importaciones.

## APK conectado

El archivo local `.local-data/cloud-build.json` (ignorado por Git) contiene
`FUTBEAT_API_URL` y `FUTBEAT_API_PUBLIC_TOKEN`. Solo son URL y clave pública.

```powershell
./scripts/mobile.ps1 build apk --debug --dart-define-from-file=../../.local-data/cloud-build.json
```

La ruta de configuración se interpreta desde `apps/mobile`. La URL base es
`https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-api`.
Compilar sin esa opción mantiene la demo sin conexión. El APK conectado requiere
internet, pero no requiere la computadora, ADB ni la API local encendida.
Para comprobarlo: abre Partidos, toca una fecha disponible, abre un partido y un
equipo. Hoy puede estar vacío porque la fuente gratuita tiene cobertura parcial.

## Verificación

- Migraciones remotas `20260916025345` y `20260916025352` verificadas en el historial.
- API real: 200 con token público, 401 sin token.
- Cliente Flutter/Dio: prueba HTTPS real aprobada contra el proyecto.
- Permisos SQL: anon y authenticated sin ejecución, service_role con ejecución;
  tres tablas con RLS, anon sin acceso al esquema privado.
- Asesor de seguridad: tres avisos informativos de RLS sin políticas. Es
  deliberado: las tablas privadas deniegan acceso a clientes y el servidor usa
  su rol dedicado. No se añadieron políticas públicas para silenciar el aviso.
  [Explicación del asesor](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy).

## Límites y siguiente bloque

Esta entrega conecta la lectura remota y traslada un lote validado. **No hay
sincronización automática remota todavía**. `npm run data:sync` actualiza solamente
la base local, no Supabase. La app avisa cuando el lote supera seis horas; refrescar
vuelve a consultar el lote existente. Falta crear el proceso remoto de ingesta con
cuotas, bloqueos, reintentos y registro de fallos antes de activar un calendario.
No hay datos LIVE, login de usuarios, Realtime, tabla calculada o notificaciones.
El APK es de desarrollo y no se publica en tiendas.
