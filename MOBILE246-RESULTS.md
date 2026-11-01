# MOBILE246 — continuación local de244/245

## Base y trabajo integrado

Rama codex/mobile-246, worktree F:/FutBeat/FutBeat/.codex-worktrees/mobile-246, creada desde57b9851. Ascendencia3977bc7->57b9851 verificada. No merge, rebase ni cherry-pick. Los cambios244/245 ya estaban integrados: no se copiaron otra vez.

## Correcciones terminadas

| Caso local medido | Antes | Después |
|---|---:|---:|
| Dos visitas a detalle parcial pasivo |3 lecturas|2 lecturas|
| Tres visitas a detalle parcial pasivo |5 lecturas|3 lecturas|
| Calendario400/401/403/404/422/429|3 intentos|1 intento|
| Calendario con caché: lectura inicial y posterior error terminal|4 lecturas|2 lecturas conservando el partido|
|503 transitorio que luego responde200|3 lecturas|3 lecturas y recuperación|
| Precarga encolada tras cambiar fecha|día anterior y nuevo|solo fecha seleccionada,HTTP0|

La ruta ordinaria conserva su fallback de hidratación. El modo pasivo se identifica por su interceptor explícitamente instalado, no por inferir permisos de un campo del cuerpo. Ausencias/errores no se convierten en partidos ni tablas inventados.

## Regresiones y fiabilidad

- Primer pase completo:1.569 PASS / 3 FAIL; log conservado en artifacts/mobile246/full-suite-first-parallel.log.
- Comparación de los tres archivos originales contra MOBILE245 y MOBILE246:34 PASS / 1 FAIL en ambos. El fallo común era el fixture programado con fecha fija ya caducado.
- Al corregir la elegibilidad del fixture, la carrera real apareció en ambas direcciones. Guard de generación: callback obsoleto no consume precarga y reprograma la fecha actual.
- LIVE: se observa ACK ordenado y las dos lecturas completas antes de medir estabilidad; se mantienen300ms de observación, intervalos originales y expectativa de cero nuevas lecturas. No se modificó producción.
- Calendario: solo el caso positivo usa2s de margen de test; los casos negativos conservan400ms y la aplicación conserva sus plazos productivos.
- Pase final completo:1.573 PASS / 0 FAIL,197s según log. Analyze limpio21,6s. Goldens sin modificaciones.19 casos más que MOBILE245.

Commits locales:bee70aca(reapertura),ec16b80d(calendario),c0a0f9fa(estilo),abc3b671(carrera de fecha),dabdeea6(sincronización de pruebas).

## APK conservadas y procedencia

+35 de entrega:827c6b7,SHA25662033802724A935BB3325C20ACED42823EB70355E3110ACB009F8BCAC6D6E4A8.
+36:546615f201f41c1d8552366c2e3e345219b5b434,SHA25681B1C4EF5B09C1C39570B0837E18D73F14BAFA6A0B747FC650B140897CA9A5E4.
Hashes, paquete y firmas verificados nuevamente con Python/aapt/apksigner; cuatro ELF arm64 requeridos presentes. FirmaQA común6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362.827c6b7 es ancestro de546615f2; el código de+36 coincide con3977bc7. Modo local-cache-only,DEMO=false,APIloopback,OAuth/Push/anuncios apagados. +37 anterior preservada; no se reinstaló ninguna.

QA +38 offline compilada y verificada desde dabdeea67a71b2bf8cd40993ef1c6e37272eb4c4; build319,6s. Archivo artifacts/mobile246/futbeat-qa-1.0.0+38-local-cache-dabdeea6.apk;111124712bytes. SHA-256:62464130F20D461C79D1DAFB7833262785B884EBEE2AA85EEFB4B133D1EDA155. Paquete com.futbeat.futbeat.qa,version1.0.0/code38,minSDK24/target36,firmaQA indicada y cuatro ELF requeridos arm64 verificados. Misma configuración aislada, sin activación conectada;NO INSTALADA.

## QA física y límites

BLOCKED:01nov23:14:11–12UTC,no ACK del servidor ADB local dentro del precheck de1s. No se distinguió conexión TCP de respuesta de protocolo. No se inició un cliente ADB de comandos, no se reinició servidor, no hubo instalación, apertura, cambios de red ni borrado de datos. Identidad actual/PID/pantallas/latencias/fotos del A32:NOT VERIFIED. READY del watchdog no alcanzado. No hay capturas físicas nuevas.

QA123 observadoDISARMED; launcher y failsafe coinciden con los hashes anteriores. Ninguna tarea o configuración QA123 fue modificada.

CI publicado de la base#235 permaneceFAIL:1537PASS/11goldens heredados y36PNG idénticos a su base exacta. MOBILE246 no se publicó: no hay CI remoto nuevo que declararPASS. La suite local nueva sí está aprobada.

## Continuidad real

Misma automatización futbeat-mobile245-12-continuaciones-locales:ACTIVE,máximo12horarias,fecha de creación y límite conservados; ninguna duplicada. Historial reciente y ledger:0 continuaciones programadas completadas todavía. Esta sesión es manual y no consume una programada. Bloqueo atómico execution.lock probado: un segundo intento devuelveEEXIST y conserva propietario. Solo el dueño libera el bloqueo.

La app registró6297,933s(1h44m58s) para244/245 y71,470s para la aprobación/registro, separado del desarrollo. Sesión manual246 observada desde23:03:42UTC hasta 2026-11-01T23:40:20.840Z; este intervalo incluye espera de herramientas y build, no equivale a tiempo efectivo de programación. No hay medición de horas efectivas de programación/CPU ni evidencia de12horas trabajadas.

Siguiente tarea segura:PENDING_NOT_IMPLEMENTED,reproducir MatchScreen con ACK pasivo y standingsPending=true; el código mantiene temporizadores de refresco de Tabla, pero el contrato pasivo no promete hidratación. Mantener la prueba ordinaria de seis lecturas y no activar rutas/whitelist. Reproducir antes de corregir. LIVE paginado/duplicados/correcciones ya está cubierto; no repetir una auditoría general.

Sin consultas a producción,GOAL,migraciones,despliegues,push,PR ni cambios en ramas ajenas. La QA conectada permanece desactivada; el último handoff local de Claude es candidato no autorizado y no prueba estado productivo actual.
