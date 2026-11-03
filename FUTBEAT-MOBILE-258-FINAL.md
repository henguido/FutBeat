# MOBILE258 — cierre local de defectos Android 1.0

## Resultado

Rama `codex/mobile-258-integration`, base `07a54b2566d90d978c80c985a3708868a551127d`. Cambios locales, sin push/PR/merge. La candidata anterior y sus artefactos permanecen intactos. No se accedió al teléfono ni a producción.

## Correcciones verificadas

| Requisito | Defecto y resultado local |
|---|---|
| S06 / #220 | Favoritos también permanecen en su liga, conforme a la decisión expresa del propietario. Un único grupo Favoritos; identidad canónica deduplicada por sección, todos los partidos visibles. 82 pruebas de feed PASS; no se duplica precarga. |
| A09 | Respuestas tardías de login, recuperación y restauración no reviven una sesión cancelada. CTA/teclado no duplican envío. Escrituras y borrados de sesión mantienen el orden y no sobrescriben la cuenta nueva. 253 pruebas focales PASS con dobles; OAuth/correo real NOT VERIFIED. |
| A03/A07 | Guardar orden de competiciones no revierte país u otros campos cambiados durante la operación. Pruebas de carrera y persistencia locales. |
| M02/S02 | Eliminar el último favorito libera su scope LIVE; el cierre de un watch no rompe pausa/refresh de los otros. Dispose cancela recursos/HTTP y cierra streams. 63 pruebas LIVE relacionadas PASS. |
| M03/M08 | Retarget de Match Center reinicia recuperación para el nuevo ID. Tabla completa conserva fase/temporada/snapshot y no genera GET adicional. Intereses pendientes no acceden al WidgetRef desmontado. |

Commits fuente e integración exacta: `artifacts/mobile258/integration/ledger.json`. Commits propios: `7565d718`, `8c3a742d`, `fe31e1b9`, `54fdf02a`. No PNG golden modificado; no dependencias, SQL, Edge Functions o contratos productivos modificados.

## Firma y RC

Revisión MOBILE257 completada en la rama independiente `codex/mobile-257-upload-fingerprint`, commit `b35983e5c4dede57551bc67b2840ab0bb439a18f`. Workflow auditado SHA-256 `2e5361bcc820ed5e1ca2688d5bed4ca20aa26d08e43efdc1a9cffec37025f313`.

Permisos vacíos, sin checkout/acciones externas/artefactos privados; solo certificado público como salida. Primer push de creación e intento1 exigidos; reutilizaciones ordinarias fallan cerrado. 16 casos de preflight PASS, estructura YAML y tres scripts Bash PASS, revisión independiente sin bloqueo concreto. No se publicó ni ejecutó el workflow; no se accedió a secretos de GitHub. La limitación de un actor capaz de recrear la rama está documentada.

Verificación directa más segura: obtener de Play Console el certificado **de subida**, conservando contexto de sección/paquete, y comparar los bytes públicos exportados mediante SHA-256 del certificado X.509 (no hash del archivo PEM). El certificado de App Signing no sustituye al Upload Key Certificate. La huella91:DD…C5:D4 sigue presunta. Un AAB firmado histórico acredita su firmante histórico, no el secreto actual de CI. No se genera otra clave.

RC oficial sigue **NO-GO**: falta coincidencia del certificado activo, configuración release aprobada, validación vigente del versionCode5 en todos los tracks y QA del binario exacto. No se generó APK/AAB ni se aplicó el versionado propuesto.

## Límites y siguiente paso

Pruebas locales y simulaciones no equivalen a QA física o autenticación productiva. CI Linux de PR243 corresponde al antiguo HEAD07a54b25, no al nuevo código. Sin autorización de publicación nueva, CI remoto de esta integración no se ejecutó. Contrato conectado desplegado y su aceptación siguen dependiendo de Claude; no se presume su estado desde mocks.

Siguiente paso: revisar/publicar únicamente la consolidación móvil para CI si se autoriza, y autorizar separadamente la verificación pública del certificado CI o aportar el certificado público de subida de Play. Después congelar una única RC y probar su SHA exacto bajo controles acreditados. No se crearon automatizaciones ni se promete trabajo futuro desatendido.

## Validación final

**Suite completa final:1625PASS/0FAIL en103s, incluidos goldens. Analyze final PASS (12,8s).** Logs: `artifacts/mobile258/flutter-full-final.log` y `artifacts/mobile258/analyze-final.log`. El primer pase completo tuvo1623 PASS y2 fallos: las dos pruebas de precarga aún esperaban una sola fila global. Se corrigió únicamente esa expectativa al contrato confirmado, manteniendo0HTTP. Una advertencia de llaves en un test nuevo también se corrigió. Logs iniciales se conservan.

Tiempo de sesión medido desde el checkpoint20:07:11UTC: 1360.5s (22.7min), incluidos tiempos de pruebas. Preparación anterior no contabilizada; no se atribuyen12–18horas ni ejecución desatendida.
