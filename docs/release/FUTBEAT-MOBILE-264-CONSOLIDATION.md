# MOBILE264 — consolidación de Android 1.0

Rama candidata: `codex/mobile-264-integration`. Base de código `d7085ec0696b11cc53dfcbb6d31ad263144e9285`. El worktree de MOBILE261 y su automatización quedan separados del candidato. Los nueve commits siguientes se verificaron por ascendencia.

| Commit integrado | Evidencia del cambio |
| --- | --- |
| `9745333a` | Notificaciones muestra las preferencias de la cuenta activa al guardar. |
| `1f2f4a96` | Separa búsqueda de jugadores y sugerencias. Equivale a MOBILE262 `01d2c402`. |
| `bdaac8fe` | Descarta respuestas LIVE del alcance anterior. Equivale a MOBILE263 `724409f9`. |
| `9e59d5b6` | Mantiene el partido abierto al llegar contexto parcial. Equivale a `9964e928`. |
| `a7247cfc` | Invalida el enlace de recuperación anterior. Equivale a `45928a7f`. |
| `f54c5baa` | Conserva el aviso de datos guardados al filtrar. Equivale a `4ea156a4`. |
| `c3885c0e` | Un calendario vacío con cobertura parcial queda sin confirmar. |
| `da7f0d3e` | Una pantalla de alertas retenida recarga el perfil reconciliado de la nueva cuenta. |
| `d7085ec0` | Espera la primera emisión de caché sin depender de 30 ms. Equivale a `5f6f92f5`. |

MOBILE259 `92531b60` y MOBILE260 `1719ecb6` son ancestros directos por historial, con cero parches exclusivos en sus ramas de integración según git cherry. Los cuatro arreglos y la prueba de MOBILE263 tienen equivalentes en el candidato. Los informes históricos de MOBILE262 y MOBILE263 se conservaron tal como estaban. Sus resultados se atribuyen a sus respectivos SHAs. Las hipótesis no reproducidas de MOBILE263 se conservan como pendientes, sin incorporar borradores.

## Decisión R05

La preparación local se puede reanudar cuando existe confirmación persistida y ligada al UID. Si el proceso termina tras recibir la confirmación pero antes de persistirla, el reinicio no puede distinguir el borrado exitoso de un fallo remoto. Un 401 también puede ser un problema de sesión. El cliente conserva NO CONFIRMADO y evita repetir automáticamente la operación. R05 requiere evidencia durable ligada a la operación o verificación autorizada del contrato. Los favoritos locales se conservan para invitado.

## Gate de Internal Testing

**NO-GO.** Faltan CI Linux del candidato, verificar en Play la clave pública de subida activa y su correspondencia con el firmante, verificar el versionCode disponible y aprobar la configuración oficial. Se requiere QA física del artefacto exacto y autorización del contrato conectado. R05 sigue abierto. También quedan por reproducir el caso de recuperación reemplazada entre la respuesta PUT y el alta de sesión y las transiciones de alertas sin reconciliación.

La PR en borrador apunta a codex/mobile-252-release, base habilitada para FutBeat checks. La publicación en Internal Testing requiere autorización separada después de verificar el AAB exacto.
