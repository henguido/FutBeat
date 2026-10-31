# QA227 — sesión supervisada de desarrollo (candidata local, no activada)

## Resultado y causa

QA123 cierra `.qa` si no existe un controlador QA123/QA126 propietario, aunque
un watcher QA2xx haya emitido GO. Es una protección de procesos huérfanos;
no evalúa si una pantalla solo usa SQLite. QA225-B/C requirieron parar y restaurar
esa tarea. El watchdog independiente, cierre por PID, STOP y restauración sí son
necesarios; una autorización distinta por cada recorrido no aporta aislamiento.

El cliente no llama directamente a GOAL. En esta base, las rutas normales sí
pueden registrar trabajo: match-context pide resultados/standings; match-detail
solicita detalle y fotos; `request=0` NO elimina la hidratación de fotografías.
Incluso `futbeat_read_calendar_range` puede escribir zonas, materializar, encolar
y despertar el worker. Por tanto no basta con añadir `request=0` al móvil.

## Política propuesta

Una aprobación explícita por sesión supervisada de hasta **180 minutos**, ligada
a ID, nonce, SHA instalado, paquete `.qa`, serial y caducidad. Se puede navegar,
cerrar y reabrir dentro de ella. Se conserva un solo QA123 y su failsafe independiente.
Nunca aceptar una sesión sin watchdog verificado; STOP o heartbeat perdido cierran
por el camino existente y se confirma PID. Otra ventana vigente bloquea esta sesión.
La caducidad de 180 minutos conserva el máximo del failsafe actual.

* `cache_only`: teléfono sin Wi-Fi/datos + build debug con
  `FUTBEAT_QA_LOCAL_CACHE_ONLY=true`, Ads/OAuth/Push desactivados. Bloqueo global de
  HttpClient antes del arranque, LIVE desactivado y banner QA LOCAL. SQLite y
  archivos de imágenes existentes siguen funcionando. Cero HTTP/GOAL: no necesita
  métricas de producción para navegar. Faltantes muestran los estados actuales.
  El arranque rechaza también DEMO=true para que este ensayo utilice solo datos
  reales que ya estén guardados.
* `stored_only`: **todavía no activable**. Adaptador local probado con rutas
  `/v1/qa-stored/calendar|match-context|match-detail`, máximo 60 peticiones por
  sesión, 12/minuto, 2 simultáneas, host/base fijados y sin redirects. STOP cancela
  las peticiones. Respuesta sin contrato `X-FutBeat-QA-Stored: v1` bloquea la sesión;
  jamás cae en rutas ordinarias. No se instala todavía en repositoryProvider:
  antes deben integrarse también el aislamiento de Auth/LIVE/medios y el monitor
  de salud independiente. El modo nativo sin red es la primera activación segura.

## Código entregado y límites de la prueba

`qa227-development-policy.ps1` es una biblioteca **no cargada** por el launcher
instalado. Valida aprobación separada y estado, APK realmente instalada, ADB,
modelo, red y ventanas concurrentes. `Invoke-QaDevelopmentSession` ofrece la
integración mediante callbacks con el launcher, heartbeat, watchdog y cierre
existentes; su prueba simula STOP, fallo del ejecutor y cierre no confirmado.
No crea tareas, procesos, aprobaciones reales ni gates. No se ha probado aún
como controlador activo en el A32 y no autoriza suspender el QA123 actual.

`qa227-stage-controller.ps1` genera las dos copias candidatas del launcher y
failsafe actuales en `artifacts/qa227/controller-candidate`, con hashes de sus
fuentes. La rama nueva usa el mismo proceso failsafe, heartbeat y recuperación
de cierre; no registra otra tarea. El launcher solo reconoce una sesión nueva
con la app cerrada, crea su ledger y mantiene al guardián independiente. El
failsafe conserva la expiración absoluta y su detección de heartbeat perdido.
Las sondas ADB del modo nuevo tienen timeout de 1,5 s; los controles ordinarios
conservan sus valores previos. No se instalaron esas copias.

Archivos previstos en el StateRoot **del QA123 existente**, una vez autorizado:
`qa227-development-approval.json` (emitido solo tras aprobación expresa del usuario)
y `qa227-development-state.json` (supervisor activo). Ambos deben tener ACL solo
usuario/SYSTEM/administradores y escritura atómica. No reutilizar archivos QA123,
QA126 o QA2xx como aprobación. El estado incluye el mismo session_id, nonce,
package, serial, apk_sha256, mode, expires_at; además status ACTIVE, stop false,
supervisor_heartbeat_at inicial vigente (15 s), http_requests, http_in_minute y
evidencia local_network_block_verified. Después, el launcher escribe únicamente
`qa227-supervisor-heartbeat.json`, sin sobrescribir STOP en el archivo de estado.
Ese heartbeat prueba vida del proceso, **no presencia humana**. La aprobación
exige un operador supervisando y no autoriza una QA desatendida. El guardián
conserva además el máximo existente de 8 s sin heartbeat del controlador.

## Handoff puntual para Claude (sin envío ni despliegue)

La ruta candidata está desactivada por defecto mediante
`FUTBEAT_QA_STORED_READS_ENABLED`. Usa solo RPC de lectura de contexto, detalle,
media y videos; nunca request/hydration/wake. La nueva lectura de calendario
requiere `scripts/qa/qa227-stored-calendar.sql`: SELECT de materialización ya
existente, sin reconstrucción; devuelve stale explícito o 404. PGlite verifica
lectura dentro de transacción READ ONLY y rollback sin perder la tabla.
Ese SQL es una propuesta, **no una migración aplicada**. Claude debe reconciliarla
con v44, verificar las definiciones efectivamente desplegadas y sus dependencias
antes de aprobarla. No modificar sus ramas ni activar la variable de entorno.
No se ha medido ninguna demanda o cuota productiva en QA227: los contadores cero
corresponden al adaptador local y al RPC mock, no a un ensayo online.

## Activación y reversión

1. Revisar y aprobar **ambas** copias generadas del QA123 existente y la biblioteca.
   Comparar `BASELINE-HASHES.json` contra los scripts activos justo antes de
   instalarlos; STOP si difieren. Ninguna excepción de proceso huérfano puede
   instalarse aislada del watchdog. Guardar XML y copias como en QA225-C;
   comprobar ausencia de otra ventana y app cerrada.
2. Solo con autorización específica, detener el launcher con la app cerrada,
   copiar juntos launcher, failsafe y biblioteca al mismo directorio existente,
   y volver a iniciar la misma tarea. Verificar un proceso, heartbeat y XML.
   Generar una APK QA `cache_only` marcada y verificar flags/SHA/firma antes de
   autorizar su instalación. No sustituir +32 durante una QA. Inicializar una
   aprobación nueva y estado únicamente tras consentimiento expreso; retirar
   archivos de heartbeat/cierre de la sesión anterior para evitar reutilización.
3. Ensayo offline de la integración activa: abrir/cerrar/reabrir; matar supervisor;
   pérdida de heartbeat, red habilitada, ADB perdido/recuperado y STOP. Exigir
   cierre por PID en <=30 s con ADB disponible; sin confirmación, NO PASS.
4. Tras ese ensayo, aprobar una sesión de desarrollo por jornada/bloque (hasta
   180 min). No solicitar nuevos gates por pantalla. Las pruebas online normales
   de la APK +32 mantienen el gate vigente hasta aprobar stored_only completo.
5. Restauración: cerrar `.qa`, confirmar PID vacío, retirar la aprobación/estado
   de desarrollo, restaurar los scripts respaldados si se instalaron, mantener
   la tarea habilitada y comprobar Running, heartbeat DISARMED, XML y hashes.
   Si ADB falla, registrar CIERRE NO CONFIRMADO y reintentar al recuperarlo.

**GO para revisión y ensayo local autorizado; NO-GO para eliminar hoy los gates
online o cambiar el controlador instalado.** No se han tocado tareas, APK,
producción, claves, cron ni configuración remota.

## Validación ejecutada

- Flutter funcional: 1.334 PASS (goldens históricos excluidos); nuevas regresiones
  de SQLite, transporte, STOP y configuración; analyze limpio.
- Configuración de arranque: modo desactivado, local seguro, Ads sin desactivar
  y DEMO activo. Los dos últimos se rechazan antes de inicializar la app.
- Política/control local: 40 PASS, incluyendo lectura real de archivos sintéticos,
  exclusión de ventanas, ADB perdido, watchdog perdido, cierre no confirmado y
  excepción del controlador. Estas pruebas no actúan sobre el A32.
- Failsafe candidato: 4 PASS ejecutando la rama nueva en otro proceso PowerShell,
  con ADB mock y DryRun (válido, heartbeat ausente, STOP y red activa). No se
  presenta SIMULATED_FORCE_STOP como cierre físico. Ambas copias pasan el parser.
- Backend relevante: 22 PASS; cuatro cubren específicamente las rutas nuevas y
  el SQL en PGlite READ ONLY. `npm run check`, sintaxis TypeScript con Node y
  sintaxis PowerShell comprobadas. Deno no está disponible en PATH; falta el
  type-check de Edge en CI. No se presenta Node como sustituto de ese control.
- Estado operativo leído al finalizar: QA123 Running, un proceso, DISARMED;
  launcher y XML iguales al respaldo QA225-C. Diez gates locales históricos:
  cuatro CLOSED, cuatro STOP, dos EXPIRED; ninguno vigente. No se activó un modo
  nuevo ni se probó producción durante QA227.
