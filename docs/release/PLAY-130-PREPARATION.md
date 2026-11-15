# Release 130 — preparación local de Google Play

Fecha: 2026-10-22. Rama de preparación: `codex/release-130-ci-play`, basada en
`6a6a34e2dc152ac254999572b3100587d794417f`. Este documento no autoriza build,
firma, carga, publicación, cambios en Console ni consultas de producción.

## Lista mínima para el propietario — cierre de esta iteración

No se requieren claves privadas para reunir la siguiente evidencia de Console:

1. Package oficial y lista de versionCodes ocupados en todos los tracks,
   incluidos borradores; confirmar si 5 puede usarse o cuál debe ser el siguiente.
2. En Integridad de la app/App signing, obtener los certificados públicos y
   huellas SHA-256 de **upload** y de **App Signing** por separado; confirmar
   que Play App Signing está habilitado y si existe rotación/upgrade vigente.
3. Estado de acceso a producción, verificación de la cuenta, testing exigido,
   tracks y tareas bloqueantes que muestra Console. No asumir elegibilidad
   porque Internal Testing ya funciona.
4. Formularios pendientes: Data Safety, anuncios, audiencia/clasificación,
   acceso del revisor y enlaces de privacidad/eliminación; ficha y países.

### Verificar la upload key, sin modificarla

En una terminal interactiva controlada, usar la upload key existente:

```text
keytool -list -v -keystore <ruta-segura-del-keystore> -alias <alias-existente>
```

Introducir la contraseña en el prompt, nunca como argumento `-storepass`,
en el historial, en CI o en este informe. Comparar SHA-256 del certificado
del alias con el certificado **upload** de Console. Confirmar que ese alias
es una entrada de clave privada utilizable para firmar, sin exportar la clave.
Una huella distinta bloquea la firma: no crear/reemplazar una clave para ocultarlo.
El certificado App Signing es el que firma la app instalada desde Play y el
que debe estar en assetlinks; no sustituye a la huella upload para esta comparación.
Esta sesión no abrió keystores ni ejecutó el comando anterior.

### Valores AdMob faltantes en esta candidata

| Entrada | Canal / condición |
|---|---|
| `FUTBEAT_ADMOB_APP_ID` | Variable de entorno del build, formato App ID con `~`; no dart-define |
| `FUTBEAT_ADMOB_MATCHES_FEED_ID` | Dart define de la unidad banner, formato con `/` |
| Configuración UMP | Verificar mensajes publicados y comportamiento requerido en las regiones objetivo |

Los dos IDs deben ser reales, corresponder a la app/unidad elegidas y compartir
publisher. Los guards solo validan formato, publisher y que no sean los IDs
de Google para pruebas; no prueban que la unidad esté aprobada/operativa.
`FUTBEAT_ADMOB_TEST_ADS=false`; no se inventan ni imprimen valores reales.

### Enlaces y declaraciones a comprobar

Privacidad `/privacy`, términos `/terms`, solicitud web `/data-deletion`,
recuperación `/auth/reset` y `/.well-known/assetlinks.json` en `https://futbeat.com`.
Confirmar contenido real, HTTPS, soporte y proceso de eliminación; comprobar
huella App Signing/paquete y reset con la app distribuida por Play. Confirmar
Google/redirects en la ventana autorizada; Facebook, Push y Premium apagados.
Data Safety debe reflejar cuenta, preferencias sincronizadas y SDKs efectivos;
no completar respuestas solo a partir de los flags. No se consultó ningún enlace.

### Qué cierra cada acción

| Acción | Requisitos técnicos y gates de esta release |
|---|---|
| Generar AAB local firmado | Autorización específica, CI válido del SHA, configuración aprobada, upload key/alias correctos, IDs reales, package/version y toolchain/lockfile controlados. No necesita credenciales de Play ni completar formularios para compilar, pero no se autoriza mientras sigan los gates críticos |
| Subir a Internal | Autorización distinta, acceso autorizado a Console, AAB inspeccionado con firma/versión aceptables y versionCode disponible, SDK/compatibilidad requeridos por Play y estado de cuenta que permita la carga |
| Publicar/promover | Otra autorización, QA física/productiva, acceso a producción/testing exigido, formularios/ficha/enlaces cerrados y revisión de Play. Subir no equivale a publicar |

No se generó AAB ni se suministraron credenciales en esta iteración.

## Estado comprobado en fuente

| Área | Estado local verificable | Bloqueo real |
|---|---|---|
| Identidad | `applicationId` y namespace `com.futbeat.futbeat`; versión `1.0.0+5` | Confirmar en Play que `versionCode 5` está libre en todos los tracks |
| Toolchain | Flutter fijado a 3.47.4 en CI; Java/JVM 17; SDK Android administrado por Flutter | Confirmar package, min/target/compile SDK y páginas de 16 KB en el AAB autorizado |
| Firma | Release exige `storeFile`, `storePassword`, `keyAlias` y `keyPassword`; sin fallback a debug | `key.properties` y keystore no están en este worktree. Reusar la upload key aprobada y comparar su certificado con Play |
| Certificados | Huellas históricas: Play App Signing `D3:07:B7:E2:F9:D3:99:FA:3C:6C:C3:14:B6:DE:B0:01:39:B3:F6:09:A9:6B:87:EB:FB:76:48:12:D1:0D:CD:E4`; upload `C9:D4:5B:74:C4:7F:2B:8F:81:6B:A6:1F:14:76:F3:BC:C1:76:D9:6C:54:20:4E:A9:B3:E6:79:F8:0D:9E:4F:4F` | Son evidencia histórica, no una lectura actual de Console ni del keystore efectivo |
| AdMob | Gradle rechaza IDs ausentes, IDs de prueba, formato inválido y publishers distintos; UMP es fail-closed | Faltan en este worktree el App ID productivo `FUTBEAT_ADMOB_APP_ID` y la unidad banner `FUTBEAT_ADMOB_MATCHES_FEED_ID`; no deben inventarse ni copiarse a Git |
| Permisos | Manifest fuente: `INTERNET` y `POST_NOTIFICATIONS`; callbacks exportados solo con filtros explícitos | Revisar el manifest fusionado porque Firebase/AndroidX pueden aportar permisos adicionales |
| App Links | HTTPS `futbeat.com/auth/reset`, fallback `com.futbeat.futbeat://password-reset` y OAuth `com.futbeat.futbeat://login-callback` | Revalidar `assetlinks.json` con certificado Play y redirects OAuth; probar instalación distribuida por Play |
| Funciones apagadas | Facebook y Push deben permanecer `false`; IDs Premium deben omitirse | Confirmar los defines efectivos del AAB, no solo la intención documental |
| Legales | La app referencia `/privacy`, `/terms` y `/data-deletion`; existe UI autenticada de eliminación | Verificar contenido público, soporte operativo y backend de borrado; no se consultaron web ni producción |

No se encontró ningún `key.properties`, JKS, keystore o certificado privado en
este worktree. Los IDs AdMob reales tampoco están presentes. Es el estado
correcto para preparación sin secretos, pero impide producir un AAB válido.

## Información de ficha preparada

Antes de abrir Console, reunir sin inventar:

- nombre público `FutBeat`, idioma principal y países del primer lanzamiento;
- descripción corta y completa coherentes con el alcance 1.0 congelado;
- icono 512×512, feature graphic 1024×500 y capturas reales del AAB candidato;
- categoría, etiquetas, correo y sitio de soporte operativos;
- URL de privacidad `https://futbeat.com/privacy`;
- URL de términos `https://futbeat.com/terms`;
- URL e instrucciones de eliminación `https://futbeat.com/data-deletion`;
- instrucciones de acceso para revisión, incluyendo cuenta de prueba si el
  contenido autenticado no puede evaluarse de otro modo;
- países, precio gratuito, audiencia objetivo y clasificación de contenido.

No reutilizar capturas de una variante QA, datos ficticios o pantallas que
prometan Push, Premium, Facebook o Noticias enriquecidas si quedan apagados.

## Data Safety — checklist de cierre

Responder según el AAB y servicios efectivamente habilitados. La presencia de
un SDK exige revisar su documentación incluso si una pantalla está apagada.

| Categoría de Play | Evidencia que debe cerrarse | Declaración que no debe presumirse |
|---|---|---|
| Información personal | Email, identificador de cuenta y datos OAuth realmente recibidos/guardados | “No se recopila” por usar un proveedor externo |
| Actividad en la app | Favoritos, preferencias, país y sincronización asociados a usuario | Que todo permanece solo en el dispositivo |
| Identificadores | Identificador de usuario, instalación y publicidad usados por Auth/Ads/Push habilitados | Que desactivar la UI elimina toda operación del SDK |
| Diagnósticos | Datos que Google Mobile Ads, UMP, Firebase y Play puedan procesar | Que no hay diagnósticos solo porque no existe Crashlytics/Sentry |
| Compartición | Transferencias a Google/servicios para anuncios, consentimiento, OAuth y hosting | “No compartido” sin aplicar las definiciones y excepciones de Play |
| Seguridad | HTTPS en tránsito, controles de cuenta y mecanismo de eliminación | Cifrado en reposo o retención que no estén comprobados |
| Eliminación | Borrado desde la app y solicitud web accesible sin reinstalar | Que una ruta o botón demuestra ejecución backend |

También deben completarse: declaración de anuncios **Sí** si el AAB conserva
Google Mobile Ads; audiencia objetivo; contenido; acceso de revisores; manejo
de datos infantiles si se seleccionan menores; y cualquier declaración de
permisos sensibles que aparezca en el manifest fusionado.

## Procedimiento controlado para un AAB futuro

1. Cerrar CI Flutter del SHA que se va a firmar y conservar artefactos/logs.
2. En Play Console, confirmar paquete, tracks y que `versionCode 5` está libre.
3. En el entorno controlado, instalar únicamente la upload key existente y
   `key.properties`; verificar alias y certificado público sin imprimir claves.
4. Comparar SHA-256 del certificado de upload con Console. No confundirlo con
   el certificado de App Signing usado en dispositivos y App Links.
5. Proveer por canal seguro el App ID y banner AdMob productivos del mismo
   publisher. Mantener test ads, Facebook, Push y Premium apagados.
6. Ejecutar el build release con lockfile estricto y archivo local de defines
   aprobado. Registrar SHA Git, hashes de lockfile/config pública redaccionada
   y versiones de Flutter/Java/Gradle.
7. Antes de cualquier carga, inspeccionar el AAB: package/version, firma,
   manifest fusionado, `debuggable=false`, permisos, IDs AdMob sin revelar el
   valor completo, librerías nativas y compatibilidad de 16 KB. Calcular SHA-256.
8. Guardar AAB, símbolos y evidencia en ubicación controlada. Solicitar una
   autorización separada para subir a Internal; construir no autoriza cargar.
9. Tras carga autorizada, instalar desde Play y validar firma distribuida,
   App Links, login/reset/borrado, UMP/anuncios, cold start/R8 y flujos críticos.
10. Solo con QA y declaraciones cerradas solicitar autorización separada para
    promoción/publicación. Nunca subir un `versionCode` inferior como rollback.

## Intervención externa necesaria del propietario

Estas son las únicas acciones que no pueden cerrarse en fuente local:

1. Leer Play Console: códigos usados, App Signing/upload, elegibilidad, tracks,
   testing requerido y formularios pendientes.
2. Proveer de forma segura la upload key existente y los dos IDs AdMob
   productivos; confirmar configuración UMP y OAuth. No pegarlos en tickets.
3. Verificar que privacidad, términos, eliminación y `assetlinks.json` están
   públicos y contienen el contenido/certificado correctos.
4. Aprobar por separado: generación del AAB, carga a Internal, prueba Play y
   publicación. Ninguna de esas autorizaciones está implícita aquí.
