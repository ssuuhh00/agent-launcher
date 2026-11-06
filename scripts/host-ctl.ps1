# 창 없이 도는 agent-launcher 서버 관리 (Windows): status(기본) | start | restart | stop
#   stop    감시 루프까지 끄므로 자동으로 다시 켜지지 않는다. start를 하거나 다음 로그인 때 다시 켜진다
#   restart server.js를 pull한 뒤. 켜 둔 claude 에이전트(터미널 탭)는 어느 쪽이든 건드리지 않는다
param([ValidateSet('status', 'start', 'restart', 'stop')][string]$Action = 'status')
$Root = Split-Path -Parent $PSScriptRoot
$Port = 8765
$Config = Join-Path $Root 'config.json'
if (Test-Path $Config) { $p = (Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json).port; if ($p) { $Port = $p } }

function Get-Listener { Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1 }
# start-host.ps1 감시 루프와 그 아래 cmd.exe → node.exe. PID 파일 대신 명령줄로 찾아서 어떻게 켰든 다 잡는다
# 에이전트(claude)는 Windows Terminal 쪽 프로세스라 여기에 걸리지 않는다
function Get-HostProcs {
    $all = Get-CimInstance Win32_Process
    $loops = @($all | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'start-host\.ps1' })
    $cmds = @($all | Where-Object { $_.Name -eq 'cmd.exe' -and $loops.ProcessId -contains $_.ParentProcessId })
    $nodes = @($all | Where-Object { $_.Name -eq 'node.exe' -and $cmds.ProcessId -contains $_.ParentProcessId })
    [pscustomobject]@{ Loops = $loops; Children = $cmds + $nodes }
}
function Wait-Until([scriptblock]$Cond) { for ($i = 0; $i -lt 60; $i++) { if (& $Cond) { return }; Start-Sleep -Milliseconds 250 } }
function Start-Loop {
    if ((Get-HostProcs).Loops) { return }
    # Start-Process의 Hidden은 처음부터 숨긴 채로 만들어서 창이 깜빡이지 않는다
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSScriptRoot\start-host.ps1`""
}
function Stop-Node { $l = Get-Listener; if ($l) { Stop-Process -Id $l.OwningProcess -Force -ErrorAction SilentlyContinue }; Wait-Until { -not (Get-Listener) } }

switch ($Action) {
    'start'   { Start-Loop; Wait-Until { Get-Listener } }
    # 루프가 있으면 node만 끄면 3초 뒤 새 코드로 다시 뜬다
    'restart' { Stop-Node; Start-Loop; Wait-Until { Get-Listener } }
    'stop' {
        $h = Get-HostProcs
        # 루프를 먼저 꺼야 node를 끈 뒤 다시 띄우지 않는다
        $h.Loops + $h.Children | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Node  # 루프 밖에서 떠 있던 서버까지
    }
}

$l = Get-Listener
$loops = (Get-HostProcs).Loops
if ($l) { "서버: 실행 중 (node PID $($l.OwningProcess), 포트 $Port)" } else { '서버: 꺼짐' }
if ($loops) { "자동 재시작: 켜짐 (감시 루프 PID $(($loops | ForEach-Object ProcessId) -join ', '))" } else { '자동 재시작: 꺼짐 (start로 켜거나 다음 로그인 때 켜진다)' }
"로그: $(Join-Path $Root 'logs\server.log')"
