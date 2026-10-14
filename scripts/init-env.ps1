# Crea .env a partir de .env.example con un TRUCKCAR_JWT_SECRET aleatorio (Base64, 384 bits).
# No sobrescribe un .env existente: borrarlo primero para regenerarlo.
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
if (Test-Path '.env') {
    Write-Host '.env ya existe; no se modifica.'
    exit 0
}
$bytes = New-Object byte[] 48
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$secret = [Convert]::ToBase64String($bytes)
$content = (Get-Content '.env.example') -replace '^TRUCKCAR_JWT_SECRET=.*', "TRUCKCAR_JWT_SECRET=$secret"
# UTF-8 sin BOM: docker compose lee .env literalmente.
[IO.File]::WriteAllLines((Join-Path (Get-Location) '.env'), $content, (New-Object Text.UTF8Encoding $false))
Write-Host '.env creado con un TRUCKCAR_JWT_SECRET nuevo.'
