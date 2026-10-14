# Comprueba el aislamiento: los microservicios no responden desde el host y el gateway si.
# Uso: powershell -ExecutionPolicy Bypass -File scripts\verify-isolation.ps1   (con docker compose up -d)
$failed = $false
$services = [ordered]@{ '8080'='user-identity'; '8081'='fleets-drivers'; '8082'='community-alerts'; '8083'='load-allocation';
                        '8084'='routing-restrictions'; '8085'='ai-fleet-allocation'; '8086'='route-ai-agent'; '8087'='notifications' }
function Get-Status($url) {
    try { return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 4).StatusCode } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } return 0 }
}
Write-Host '== Puertos internos desde el host (deben estar cerrados)'
foreach ($port in $services.Keys) {
    if ((Get-Status "http://localhost:$port/actuator/health") -ne 0) {
        Write-Host "  FALLA :$port ($($services[$port])) responde desde el host"; $failed = $true
    } else { Write-Host "  OK    :$port ($($services[$port])) cerrado" }
}
Write-Host '== Puertas de entrada publicas'
foreach ($url in 'http://localhost:8000/actuator/health', 'http://localhost:5500/index.html') {
    $code = Get-Status $url
    if ($code -eq 200) { Write-Host "  OK    $url -> 200" } else { Write-Host "  FALLA $url -> $code"; $failed = $true }
}
Write-Host '== Resolucion interna por nombre (dentro de truckcar-network)'
$code = docker run --rm --network truckcar-network curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' http://load-allocation:8083/actuator/health
if ($code -eq '200') { Write-Host '  OK    load-allocation:8083 -> 200' } else { Write-Host "  FALLA load-allocation:8083 -> $code"; $failed = $true }
if ($failed) { exit 1 } else { exit 0 }
