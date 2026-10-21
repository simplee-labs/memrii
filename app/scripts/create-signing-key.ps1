param(
    [string]$KeyDirectory = (Join-Path $env:USERPROFILE '.memrii/keys'),
    [string]$Keytool = (Join-Path $env:ProgramFiles 'Android/Android Studio/jbr/bin/keytool.exe')
)
$ErrorActionPreference = 'Stop'
$keyPath = Join-Path $KeyDirectory 'memrii-upload.jks'
$passwordPath = Join-Path $KeyDirectory 'memrii-upload-password.xml'
if ((Test-Path -LiteralPath $keyPath) -or (Test-Path -LiteralPath $passwordPath)) {
    throw 'An existing memrii signing identity or password file exists. Inspect it; do not overwrite it.'
}
if (!(Test-Path -LiteralPath $Keytool)) { throw 'Set -Keytool to your JDK keytool executable.' }
New-Item -ItemType Directory -Path $KeyDirectory -Force | Out-Null
$password = Read-Host 'Choose the memrii signing password (input hidden; at least 6 characters)' -AsSecureString
$confirmation = Read-Host 'Confirm the signing password (input hidden)' -AsSecureString
$firstPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
$secondPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmation)
try {
    $first = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstPtr)
    $second = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondPtr)
    if ($first.Length -lt 6 -or $first -cne $second) { throw 'Passwords must match and contain at least 6 characters.' }
    $env:MEMRII_STORE_PASSWORD = $first
    & $Keytool -genkeypair -keystore $keyPath -storetype JKS -alias memrii-upload -keyalg RSA -keysize 4096 -validity 10000 -dname 'CN=memrii upload, O=simplee-labs' -storepass:env MEMRII_STORE_PASSWORD -keypass:env MEMRII_STORE_PASSWORD
    if ($LASTEXITCODE -ne 0) { throw 'Key generation failed.' }
    # Windows DPAPI: encrypted for this Windows user on this machine. Never commit.
    $password | Export-Clixml -LiteralPath $passwordPath
    & $Keytool -list -v -keystore $keyPath -alias memrii-upload -storepass:env MEMRII_STORE_PASSWORD
    if ($LASTEXITCODE -ne 0) { throw 'Certificate inspection failed.' }
    Write-Host "Created signing key at $keyPath. Back up the key and your chosen password privately."
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstPtr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondPtr)
    Remove-Item Env:MEMRII_STORE_PASSWORD -ErrorAction SilentlyContinue
    $first = $null
    $second = $null
}
