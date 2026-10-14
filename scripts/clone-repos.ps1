# Clona (o actualiza) los repositorios de TruckCar como carpetas hermanas dentro de este repo.
# Uso: powershell -ExecutionPolicy Bypass -File scripts\clone-repos.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$repos = 'User-Identity','api-gateway','fleets-drivers','Community-Alerts','Load-Allocation',
         'AI-powered-fleet-allocation','Route-AI-agent','Routing-Restrictions','Notifications','truckcar-frontend'
foreach ($repo in $repos) {
    if (Test-Path (Join-Path $repo '.git')) {
        Write-Host "== ${repo}: actualizando main"
        git -C $repo pull --ff-only origin main
    } else {
        Write-Host "== ${repo}: clonando"
        git clone "https://github.com/TRUCKCAR-APP/$repo.git" $repo
    }
}
