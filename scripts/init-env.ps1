# Genera .env a partir de .env.example: cada variable vacía marcada [secreto] recibe un valor aleatorio
# (TRUCKCAR_JWT_SECRET: Base64 de 384 bits; el resto, 32 caracteres hexadecimales).
# Con un .env existente no cambia nada de lo que ya tiene: solo agrega las variables que le falten.
# Las contraseñas de base de datos se aplican al crear cada rol: con un volumen postgis_data anterior, copie en .env
# las que ya usa ese volumen en lugar de las generadas.
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
function New-RandomBytes([int]$count) { $bytes = New-Object byte[] $count; $rng.GetBytes($bytes); return $bytes }
function New-Secret([string]$key) {
    if ($key -eq 'TRUCKCAR_JWT_SECRET') { return [Convert]::ToBase64String((New-RandomBytes 48)) }
    return -join ((New-RandomBytes 16) | ForEach-Object { $_.ToString('x2') })
}

$created = -not (Test-Path '.env')
$existing = if ($created) { @() } else { Get-Content '.env' }
$output = New-Object System.Collections.Generic.List[string]
$added = New-Object System.Collections.Generic.List[string]
$secretNext = $false
foreach ($line in Get-Content '.env.example') {
    if ($line -match '^#.*\[secreto\]') { $secretNext = $true }
    if ($line -match '^([A-Z0-9_]+)=(.*)$') {
        $key = $Matches[1]; $value = $Matches[2]
        $missing = $created -or -not ($existing | Where-Object { $_ -match "^$key=" })
        if ($missing) {
            if ($secretNext -and $value -eq '') { $value = New-Secret $key }
            if ($created) { $output.Add("$key=$value") } else { $added.Add("$key=$value") }
        }
        $secretNext = $false
    } elseif ($created) {
        $output.Add($line)
    }
}

# UTF-8 sin BOM: docker compose lee .env literalmente.
$utf8 = New-Object Text.UTF8Encoding $false
$path = Join-Path (Get-Location) '.env'
if ($created) {
    [IO.File]::WriteAllLines($path, $output, $utf8)
    Write-Host '.env creado con secretos aleatorios.'
} elseif ($added.Count -gt 0) {
    [IO.File]::AppendAllLines($path, [string[]](@('', '# Agregadas por scripts/init-env.ps1') + $added), $utf8)
    Write-Host ('Variables agregadas a .env: ' + (($added | ForEach-Object { $_.Split('=')[0] }) -join ' '))
} else {
    Write-Host '.env ya tiene todas las variables de .env.example; no se modifica.'
}
