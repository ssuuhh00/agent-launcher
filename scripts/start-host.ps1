# agent-launcher 서버 실행. 로그인 때 시작프로그램 바로가기 → start-host-hidden.vbs가 이 파일을 창 없이 부른다
# node가 꺼지면 3초 뒤 다시 켜고(macOS launchd KeepAlive와 같은 역할), 이미 돌고 있으면 바로 끝난다
# 상태 확인·재시작·끄기는 host-ctl.ps1
$Host.UI.RawUI.WindowTitle = 'agent-launcher 서버'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
New-Item -ItemType Directory -Force (Join-Path $Root 'logs') | Out-Null

# 둘 이상 돌지 않게 이름 있는 뮤텍스로 막는다 (이전 실행이 강제 종료됐으면 Abandoned 예외와 함께 넘겨받는다)
$Mutex = New-Object System.Threading.Mutex($false, 'Local\agent-launcher-host')
try { $Owned = $Mutex.WaitOne(0) } catch { $Owned = $true }
if (-not $Owned) { Write-Host '이미 실행 중입니다 (host-ctl.ps1로 확인)'; exit }

while ($true) {
    # 서버 로그는 server.js가 logs\server.log에 남기고, 크래시 스택 같은 콘솔 출력은 logs\host-console.log에 쌓인다
    cmd.exe /c "node src\server.js >> logs\host-console.log 2>&1"
    Start-Sleep -Seconds 3
}
