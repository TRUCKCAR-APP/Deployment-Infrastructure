# Comprueba el aislamiento de red: los microservicios no responden desde el host, el gateway solo sirve la API (su
# actuator y el de los servicios no se alcanzan desde fuera), Prometheus si los alcanza dentro de truckcar-network y
# las herramientas de observabilidad solo escuchan en 127.0.0.1.
# Uso: powershell -ExecutionPolicy Bypass -File scripts\verify-isolation.ps1   (con docker compose up -d)
$failed = $false
function Ok($msg) { Write-Host "  OK    $msg" }
function Fail($msg) { Write-Host "  FALLA $msg"; $script:failed = $true }
function Get-Status($url) {
    try { return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 4).StatusCode } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } return 0 }
}
function Get-InternalStatus($url) {
    return docker run --rm --network truckcar-network curlimages/curl:8.10.1 -s -o /dev/null -w '%{http_code}' --max-time 5 $url
}

$ports = [ordered]@{ '8080'='user-identity'; '8081'='fleets-drivers'; '8082'='community-alerts'; '8083'='load-allocation';
                     '8084'='routing-restrictions'; '8085'='ai-fleet-allocation'; '8086'='route-ai-agent'; '8087'='notifications';
                     '8090'='actuator del gateway'; '6432'='pgbouncer'; '4318'='otel-collector'; '3200'='tempo'; '9127'='pgbouncer-exporter' }
Write-Host '== Puertos internos desde el host (deben estar cerrados)'
foreach ($port in $ports.Keys) {
    if ((Get-Status "http://localhost:$port/") -ne 0) { Fail ":$port ($($ports[$port])) responde desde el host" }
    else { Ok ":$port ($($ports[$port])) cerrado" }
}

Write-Host '== Puertas de entrada publicas'
$code = Get-Status 'http://localhost:8000/api/v1/loads'
if ($code -eq 401) { Ok 'api-gateway :8000 exige JWT (/api/v1/loads -> 401)' } else { Fail "api-gateway /api/v1/loads -> $code (se esperaba 401)" }
$code = Get-Status 'http://localhost:5500/index.html'
if ($code -eq 200) { Ok 'frontend :5500 -> 200' } else { Fail "frontend :5500 -> $code" }

Write-Host '== El actuator no se alcanza a traves del gateway'
foreach ($path in '/actuator/health', '/actuator/prometheus', '/api/v1/loads/%2e%2e/%2e%2e/%2e%2e/actuator/prometheus') {
    $code = Get-Status "http://localhost:8000$path"
    if ($code -eq 200) { Fail "$path -> 200 (expuesto)" } else { Ok "$path -> $code" }
}

Write-Host '== Dentro de truckcar-network (Prometheus)'
foreach ($target in 'http://load-allocation:8083/actuator/health', 'http://load-allocation:8083/actuator/prometheus',
                    'http://api-gateway:8090/actuator/prometheus', 'http://pgbouncer-exporter:9127/metrics') {
    $code = Get-InternalStatus $target
    if ($code -eq '200') { Ok "$target -> 200" } else { Fail "$target -> $code" }
}

Write-Host '== Observabilidad solo en 127.0.0.1 del host'
foreach ($svc in 'truckcar-grafana', 'truckcar-prometheus') {
    $bind = (docker port $svc | Select-Object -First 1)
    if ("$bind" -match '127\.0\.0\.1:') { Ok "$svc -> $bind" } else { Fail "$svc publicado como '$bind'" }
}
if ($failed) { exit 1 } else { exit 0 }
