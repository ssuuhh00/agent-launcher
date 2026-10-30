# agent-launcher 서버 실행 (로그인 시 자동 실행 바로가기가 이 파일을 창 없이 부른다)
# 창이 없어서 실수로 닫을 일이 없고, 서버가 꺼지면 10초 뒤 다시 띄운다 (macOS launchd의 KeepAlive와 같은 동작)
# 끄거나 다시 켜려면 scripts\stop-host.ps1
Set-Location (Split-Path -Parent $PSScriptRoot)

# 바로가기를 두 번 실행해도 서버는 하나만 돈다
$mutex = New-Object System.Threading.Mutex($false, 'Local\agent-launcher-host')
if (-not $mutex.WaitOne(0)) { exit }

while ($true) {
    node src/server.js
    Start-Sleep -Seconds 10
}
