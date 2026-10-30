# agent-launcher 호스트(Windows PC) 설정
#   powershell -ExecutionPolicy Bypass -File scripts\setup-host.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

Write-Host '[1/5] 필수 프로그램 확인'
foreach ($cmd in 'node', 'npm', 'claude') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "$cmd 이(가) 설치되어 있지 않습니다." }
}

Write-Host '[2/5] 패키지 설치'
npm install --no-fund --no-audit
if ($LASTEXITCODE -ne 0) { throw 'npm install 실패' }

Write-Host '[3/5] config.json 준비'
node scripts/init-config.mjs
$Port = node -p "require('./config.json').port"
$Token = node -p "require('./config.json').token"

Write-Host '[4/5] 방화벽: Tailscale 대역(100.64.0.0/10)에서만 접속 허용'
$RuleName = 'agent-launcher (Tailscale)'
if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
    Write-Host '  이미 규칙이 있습니다.'
} else {
    Write-Host '  관리자 권한 창(UAC)이 뜨면 허용해 주세요.'
    $cmd = "New-NetFirewallRule -DisplayName '$RuleName' -Direction Inbound -Protocol TCP -LocalPort $Port -RemoteAddress 100.64.0.0/10 -Action Allow -Profile Any"
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command', $cmd
}

Write-Host '[5/5] 로그인 시 자동 실행 등록 (시작프로그램 폴더 바로가기)'
$Shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'agent-launcher.lnk'
$Shell = New-Object -ComObject WScript.Shell
$Link = $Shell.CreateShortcut($Shortcut)
$PowerShell = (Get-Command powershell.exe).Source
$HostArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$Root\scripts\start-host.ps1`""
$Wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($Wt) {
    # 에이전트가 뜨는 Windows Terminal 'agent-launcher' 창에 '서버' 탭으로 띄운다 (로그인 직후에는 첫 탭)
    # 에이전트를 다 꺼도 서버 탭이 남아서 창이 사라지지 않는다
    $Link.TargetPath = $Wt.Source
    $Link.Arguments = "-w agent-launcher new-tab --title 서버 --suppressApplicationTitle -d `"$Root`" `"$PowerShell`" $HostArgs"
    $Link.WindowStyle = 1  # 예전 바로가기의 최소화(7) 값이 남지 않게 보통 창으로
} else {
    $Link.TargetPath = $PowerShell
    $Link.Arguments = $HostArgs
    $Link.WindowStyle = 7  # Windows Terminal이 없으면 최소화된 PowerShell 창으로
}
$Link.WorkingDirectory = $Root
$Link.Save()

Write-Host ''
Write-Host '설정 완료. 지금 서버를 켜려면 시작프로그램 바로가기를 실행하거나 다시 로그인하세요:'
Write-Host "  Start-Process '$Shortcut'"
Write-Host ''
Write-Host '클라이언트(맥북)에서 쓸 정보:'
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    Write-Host "  호스트: $(tailscale ip -4)  (또는 Tailscale 기기 이름)"
} else {
    Write-Host '  호스트: Tailscale을 설치하면 확인할 수 있습니다 (https://tailscale.com/download)'
}
Write-Host "  포트:   $Port"
Write-Host "  토큰:   $Token"
Write-Host ''
Write-Host 'PC가 절전 모드에 들어가면 요청을 받을 수 없습니다. 설정 > 전원에서 절전 시간을 "안 함"으로 두세요.'
