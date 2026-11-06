# FutBeat 1.0 — acciones mínimas hasta publicación

Preparación documental. Workflow CI `5a6551c` sin modificaciones. No se
autoriza ni ejecuta push, CI, firma, carga, QA conectada o publicación.

## Orden de cierre

1. CAPACITY 135: recibir confirmación explícita de cierre y de que no quedan
   operaciones activas. No inferirlo del horario. No se revisaron sus componentes.
2. Solicitar autorización para subir exclusivamente `codex/release-130-ci-play`
   y ejecutar el CI que su push dispara. Reconfirmar SHA y ausencia de PR
   abierto; no abrir PR ni publicar NEWS 131. Esperar resultados reales de
   analyze, 21 focales y suite completa, incluidos goldens sin regenerar.
3. Resolver únicamente fallos reproducibles. Registrar SHA y evidencia del run.
4. Cerrar datos/entradas de Console, firma, anuncios y backend necesarios para
   el MVP según `PLAY-130-PREPARATION.md`. No ejecutar esos servicios aquí.
5. Solicitar autorización específica para AAB firmado; inspeccionar firma,
   versión, permisos, flags, librerías nativas/16 KB y hash del artefacto.
6. Autorizar carga a Internal por separado; probar instalación y actualización
   desde Play antes de pedir publicación.

## Data Safety y declaraciones — pendientes, no respuestas precargadas

| Revisión | Evidencia que debe aportar el responsable |
|---|---|
| Cuenta | Email, user ID, datos OAuth realmente recibidos y retenidos |
| Preferencias | Favoritos/país: qué permanece local, qué se sincroniza y cómo se borra |
| Ads/SDKs | Datos efectivos de Mobile Ads/UMP y demás SDKs; finalidades y compartición según definiciones de Play |
| Seguridad | HTTPS, controles de cuenta y retención comprobados; no afirmar cifrado/retención sin evidencia |
| Eliminación | Flujo app y solicitud web funcional, datos eliminados y excepciones de retención claramente informadas |
| Declaraciones | Anuncios según funcionamiento final, audiencia, clasificación de contenido, acceso de revisores y permisos efectivos |

No marcar “no recopilamos datos” por ser gratuito ni “no compartimos” por
usar SDKs externos. Push/compra apagados no eliminan por sí solos sus SDKs
del binario. Revisar la configuración final antes de completar formularios.

## Enlaces y credenciales: acciones externas mínimas

- Propietario: leer Console para conocer versionCodes, certificados públicos
  upload/App Signing, elegibilidad y testing/formularios pendientes.
- Firma: reutilizar upload key existente, comprobar alias y SHA-256 contra
  upload certificate con contraseña interactiva; nunca pegar contraseña en
  comandos o chat. Archivo local ignorado; no generar otra clave para eludir
  una discrepancia. Procedimiento detallado en PLAY-130-PREPARATION.md.
- AdMob: App ID real en variable de entorno; banner unit real en dart define,
  mismo publisher y test ads false; confirmar UMP. No se proporcionaron valores.
- Web: verificar `/privacy`, `/terms`, `/data-deletion`, `/auth/reset` y
  `/.well-known/assetlinks.json`. Confirmar certificado App Signing y paquete;
  no considerar una URL declarada como ya validada.
- Claude: confirmar salud/cobertura/contratos y cuenta/borrado con evidencia
  acotada. No mezclarlo con nuevas funcionalidades o migraciones de Noticias.

## Smoke del AAB distribuido por Play, en ventana autorizada

Instalación limpia y actualización conservando preferencias; cold start/R8;
partidos del día, cambio de fecha, LIVE/final y correcciones; favoritos/país
tras reinicio y guest→cuenta; Match Center y perfiles; falta legítima de datos;
red lenta/error/reintento; registro/login/logout, reset abierto/cerrado y
borrado de cuenta QA; consentimiento/anuncios. Usar datos de prueba para
cuentas, no acciones sobre usuarios reales. Las capturas comerciales solo
se toman después de aceptar ese build. Ningún caso está PASS por este plan.

## Producción y recuperación

Si Console exige testing cerrado/acceso a producción, completarlo antes de
promover. Internal por sí solo no demuestra elegibilidad.
Primera publicación: países expresamente aprobados y alcance contenido;
Google Play no ofrece porcentajes para la primera release. Para actualizaciones
posteriores, propuesta 5% → 20% → 50% → 100% con revisión de métricas y un
ciclo real de partidos entre ampliaciones. No ampliar ante P0/P1 o degradación.

Rollback: detener distribución con autorización; los usuarios ya actualizados
conservan el binario hasta recibir hotfix. No subir código de versión menor ni
pedir desinstalar como procedimiento ordinario. Hotfix desde fuente estable,
versionCode mayor, misma firma y prueba de actualización. Claude gestiona
backend por separado. La primera publicación no tiene versión productiva
previa que pueda restaurarse.

## Criterio actual

NO-GO de publicación: falta suite real en Ubuntu, configuración externa y
smoke Play. NEWS 131 corregida localmente sigue separada y no condiciona el
cierre de 1.0. QA126 consta CANCELLED/NOT EXECUTED por información del
propietario; no se reutiliza como una prueba superada.
