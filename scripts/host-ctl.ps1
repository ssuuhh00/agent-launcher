# 창 없이 도는 agent-launcher 서버 관리: status(기본) | start | restart | stop
# server.js를 pull한 뒤에는 restart. 켜 둔 claude 에이전트(터미널 탭)는 건드리지 않는다
param([ValidateSet('status', 'start', 'restart', 'stop')][string]$Action = 'status')
$Root = Split-Path -Parent $PSScriptRoot
$PidFile = Join-Path $Root 'logs\host.pid'
$Port = 8765
$Config = Join-Path $Root 'config.json'
if (Test-Path $Config) { $p = (Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json).port; if ($p) { $Port = $p } }

function Get-Listener { Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1 }
# start-host.ps1 감시 루프 (PID 파일이 가리키는 프로세스가 PowerShell일 때만)
function Get-Loop {
    if (-not (Test-Path $PidFile)) { return $null }
    $proc = Get-Process -Id ([int](Get-Content $PidFile)) -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -eq 'powershell') { $proc }
}
function Start-Loop {
    if (Get-Loop) { return }
    # Start-Process의 Hidden은 처음부터 숨긴 채로 만들어서 창이 깜빡이지 않는다
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSScriptRoot\start-host.ps1`""
}
function Wait-Listener([bool]$Want) {
    for ($i = 0; $i -lt 60; $i++) { if ([bool](Get-Listener) -eq $Want) { return }; Start-Sleep -Milliseconds 250 }
}
function Stop-Node { $l = Get-Listener; if ($l) { Stop-Process -Id $l.OwningProcess -Force; Wait-Listener $false } }

switch ($Action) {
    'start'   { Start-Loop; Wait-Listener $true }
    'restart' { Stop-Node; Start-Loop; Wait-Listener $true }  # 루프가 있으면 node만 끄면 3초 뒤 새 코드로 다시 뜬다
    'stop'    { $loop = Get-Loop; if ($loop) { Stop-Process -Id $loop.Id -Force }; Stop-Node; Remove-Item $PidFile -ErrorAction SilentlyContinue }
}

$l = Get-Listener
$loop = Get-Loop
if ($l) { "서버: 실행 중 (node PID $($l.OwningProcess), 포트 $Port)" } else { '서버: 꺼짐' }
if ($loop) { "감시 루프: 실행 중 (PID $($loop.Id))" } else { '감시 루프: 없음' }
"로그: $(Join-Path $Root 'logs\server.log')"
