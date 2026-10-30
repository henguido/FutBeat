param([Parameter(Mandatory = $true)][string]$ApkPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
$apk = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ApkPath).Path)
try {
    $entries = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $apk.Entries) { [void]$entries.Add($entry.FullName) }
    $required = @(
        'lib/arm64-v8a/libflutter.so',
        'lib/arm64-v8a/libsqlite3.so',
        'lib/arm64-v8a/libdartjni.so',
        'lib/arm64-v8a/libdatastore_shared_counter.so'
    )
    $missing = @($required | Where-Object { -not $entries.Contains($_) })
    if ($missing.Count -gt 0) {
        throw "APK no puede iniciar FutBeat en arm64: faltan $($missing -join ', '). Ejecute flutter pub get en este worktree y recompile."
    }
    Write-Output 'Android arm64 native libraries: PASS'
} finally {
    $apk.Dispose()
}
