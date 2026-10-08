# FutBeat Android smoke checklist

Este checklist complementa `scripts/qa/android-smoke.ps1`. Un resultado automático PASS no aprueba las verificaciones manuales.

## Uso

Desde la raíz del repositorio:

```powershell
.\scripts\qa\android-smoke.ps1 -ApkPath .\apps\mobile\build\app\outputs\flutter-apk\app-debug.apk
```

Con dispositivo explícito, ADB alternativo o carpeta de evidencias propia:

```powershell
.\scripts\qa\android-smoke.ps1 `
  -ApkPath C:\builds\app-debug.apk `
  -DeviceId R58MXXXXXX `
  -AdbPath C:\Android\platform-tools\adb.exe `
  -OutputDir C:\qa\futbeat-a32 `
  -Verbose
```

Para conservar la instalación actual o no tomar capturas:

```powershell
.\scripts\qa\android-smoke.ps1 -ApkPath C:\builds\app-debug.apk -SkipInstall -SkipScreenshots
```

Captura independiente:

```powershell
.\scripts\qa\capture-screen.ps1 -DeviceId R58MXXXXXX -OutputDir C:\qa\screens -Name match-center
```

Pruebas locales de helpers, sin dispositivo:

```powershell
.\scripts\qa\android-smoke.tests.ps1
```

## Automático

- [ ] ADB localizado y ejecutable.
- [ ] Un solo dispositivo listo, o `-DeviceId` explícito.
- [ ] APK existe y declara `com.futbeat.futbeat`.
- [ ] Espacio de `/data` suficiente cuando Android permite comprobarlo.
- [ ] Instalación `adb install -r` correcta, o `-SkipInstall` indicado.
- [ ] Package instalado y versión registrada.
- [ ] Arranque, force-stop y segundo arranque correctos.
- [ ] Proceso permanece activo tras ambos arranques.
- [ ] App Link de recovery sin token abre la app sin crash.
- [ ] Fallback de recovery sin token abre la app sin crash.
- [ ] Logcat filtrado y sanitizado sin crash fatal.
- [ ] Capturas automáticas generadas, salvo `-SkipScreenshots`.
- [ ] `REPORT.md` generado con alcance y resultado global.

## Manual en Galaxy A32

Registrar PASS, FAIL o N/A y una observación breve. No introducir credenciales reales en las evidencias.

- [ ] Arranque frío.
- [ ] Onboarding completo.
- [ ] Crear cuenta abre Auth completo.
- [ ] Login abre Auth completo.
- [ ] Google visible.
- [ ] Facebook visible.
- [ ] Email visible.
- [ ] Explorar.
- [ ] Favoritos.
- [ ] Partidos.
- [ ] Competition Group Card.
- [ ] Match Center.
- [ ] Previa.
- [ ] Timeline.
- [ ] Alineación.
- [ ] Estadísticas.
- [ ] Tabla.
- [ ] H2H.
- [ ] Player Profile.
- [ ] Team Profile.
- [ ] Competition Profile.
- [ ] Perfil y Configuración.
- [ ] Notificaciones, sin conceder permiso salvo decisión expresa del tester.
- [ ] Ads en cuenta FREE.
- [ ] Navegación atrás.
- [ ] Cierre y reapertura.

## Acciones deliberadamente excluidas

El harness no automatiza login, logout, credenciales, OAuth, compras, restauración de compras, permisos de notificaciones, borrado de cuenta, limpieza de datos ni desinstalación.
