param(
    [string]$KeyDirectory = (Join-Path $env:USERPROFILE '.memrii/keys'),
    [string]$Bash = (Join-Path $env:ProgramFiles 'Git/bin/bash.exe')
)
$ErrorActionPreference = 'Stop'
$password = Import-Clixml -LiteralPath (Join-Path $KeyDirectory 'memrii-upload-password.xml')
$passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
try {
    $env:MEMRII_STORE_FILE = (Join-Path $KeyDirectory 'memrii-upload.jks').Replace('\', '/')
    $env:MEMRII_KEY_ALIAS = 'memrii-upload'
    $env:MEMRII_STORE_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)
    $env:MEMRII_KEY_PASSWORD = $env:MEMRII_STORE_PASSWORD
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Push-Location $repoRoot
    try {
        $buildCommand = @'
set -euo pipefail
version="$(awk '/^version:/ {gsub(/\r/, "", $2); print $2; exit}' app/pubspec.yaml)"
defines=()
if [[ -n "${MEMRII_DART_DEFINES_FILE:-}" ]]; then
    defines+=("--dart-define-from-file=$MEMRII_DART_DEFINES_FILE")
fi
(cd app && flutter clean && flutter build apk --release --flavor prod --target lib/main.dart "${defines[@]}")
mkdir -p releases
cp app/build/app/outputs/flutter-apk/app-prod-release.apk "releases/memrii-${version}.apk"
'@
        & $Bash -lc $buildCommand.Replace("`r`n", "`n")
        if ($LASTEXITCODE -ne 0) { throw 'Signed release build failed.' }
    } finally { Pop-Location }
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
    'MEMRII_STORE_FILE', 'MEMRII_KEY_ALIAS', 'MEMRII_STORE_PASSWORD', 'MEMRII_KEY_PASSWORD' | ForEach-Object {
        Remove-Item "Env:$_" -ErrorAction SilentlyContinue
    }
}
