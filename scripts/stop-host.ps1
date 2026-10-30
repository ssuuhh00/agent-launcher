# 창 없이 도는 agent-launcher 서버를 끈다. -Restart를 주면 끈 뒤 시작프로그램 바로가기로 다시 켠다
#   powershell -ExecutionPolicy Bypass -File scripts\stop-host.ps1 [-Restart]
# 서버가 켠 에이전트(claude)는 건드리지 않는다. 다시 켠 서버가 state.json으로 기억한다
param([switch]$Restart)

# 다시 띄우는 반복문(start-host.ps1)을 먼저 끄고, 그다음 node 서버를 끈다
$hosts = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'start-host\.ps1' -and $_.ProcessId -ne $PID }
$servers = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object { $_.CommandLine -match 'src[\\/]server\.js' }
foreach ($p in @($hosts) + @($servers)) {
    if ($p) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "종료: $($p.Name) $($p.ProcessId)"
    }
}
if (-not $hosts -and -not $servers) { Write-Host '실행 중인 서버가 없습니다.' }

if ($Restart) {
    Start-Sleep -Seconds 1
    $shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'agent-launcher.lnk'
    if (-not (Test-Path $shortcut)) { throw "시작프로그램 바로가기가 없습니다. 먼저 scripts\setup-host.ps1을 실행하세요." }
    Start-Process $shortcut
    Write-Host '다시 켰습니다. logs\server.log에서 listening을 확인하세요.'
}
