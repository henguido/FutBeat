# FutBeat 1.0 · firma para Internal Testing

Google recibió la solicitud de restablecimiento de clave. El propietario reportó el 26 de noviembre de 2026 como fecha prevista. Antes de firmar, comprobar en Play Console que el certificado de carga activo tiene SHA-256 `F6:92:F7:0E:52:DC:61:E0:E7:9A:87:23:09:B7:19:C5:62:48:33:E3:2D:E0:3A:E2:17:55:D6:85:98:00:E0:FE` y que el explorador de App Bundles no contiene el código 16.

La configuración pública aprobada de Internal Testing se conserva en `artifacts/rc248-local-build/release-20261110-225404-433/internal-public.json` dentro del repositorio principal. Su SHA-256 es `75DE9E727E45BD55DDD7E96D5398B63EFF00746A3A3234BDBFC8922C538E47C4`. Usa la API del proyecto, clave publicable, sesión de usuario, R05 y Google OAuth activados. Ads, push, Facebook, demo y caché exclusiva están desactivados. La firma lee el almacén PKCS#12 protegido y su contraseña DPAPI bajo el perfil de Windows del propietario.

Desde el checkout candidato con el SHA congelado y el árbol rastreado limpio, ejecutar en PowerShell 7, sustituyendo el SHA por el del candidato confirmado y copiando la huella directamente del certificado de carga activo de Play.

```powershell
& ./scripts/release/Build-FutBeatOfficial.ps1 `
  -ExpectedHead '<SHA congelado>' `
  -ActivatedPlaySha256 '<SHA-256 completo del certificado activo de Play>' `
  -Version16Available `
  -PublicConfig ../rc248-local-build/release-20261110-225404-433/internal-public.json `
  -FlutterSdk ./flutter-sdk `
  -GradleUserHome ../rc248-local-build/gradle-offline-20261110 `
  -BundletoolJar ./artifacts/bundletool-all-1.18.3.jar `
  -Output ./artifacts/FutBeat-1.0.0-16-official.aab
```

El script verifica la entrada privada y el certificado, compila, comprueba el firmante y valida el AAB con bundletool. También coteja paquete `com.futbeat.futbeat`, versión `1.0.0 (16)`, manifiesto sin modo debug, callback OAuth oficial y App Link de recuperación. Devuelve el SHA-256 del archivo final.

Cotejar el certificado de distribución de Play con el archivo público de App Links. La aceptación de OAuth distribuido por Play requiere instalar el binario servido por ese canal tras una subida autorizada. Mantener bloqueada la republicación BE14 hasta verificar una versión distribuida compatible y su recepción real de `VERIFIED`.
