# agent-launcher 클라이언트(Windows PC) 설정: 다른 기기(맥 등)의 MCP 서버를 Claude Code에 등록한다
#   powershell -ExecutionPolicy Bypass -File scripts\setup-client.ps1 [-HostName 호스트] [-Token 토큰] [-Port 8765] [-Name agent-launcher-mac]
param([string]$HostName, [string]$Token, [int]$Port = 8765, [string]$Name = 'agent-launcher-mac')
$ErrorActionPreference = 'Stop'

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { throw 'claude(Claude Code)가 설치되어 있지 않습니다.' }
if (-not $HostName) { $HostName = Read-Host '호스트 주소 (Tailscale 기기 이름 또는 100.x.x.x IP)' }
if (-not $Token) {
    $secure = Read-Host '토큰 (호스트 config.json의 token)' -AsSecureString
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
$Url = "http://${HostName}:${Port}/mcp"

Write-Host "연결 확인: $Url"
$body = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
$headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json, text/event-stream' }
try {
    Invoke-WebRequest -Uri $Url -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 5 -UseBasicParsing | Out-Null
    Write-Host '연결 성공'
} catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -eq 401) { throw '토큰이 틀렸습니다.' }
    if (-not $status) { throw '서버에 닿지 않습니다. 호스트가 켜져 있는지, 양쪽 Tailscale이 연결돼 있는지 확인하세요.' }
    throw "예상치 못한 응답(HTTP $status)"
}

# 등록된 게 없으면 remove가 stderr를 내는데, PowerShell 5.1은 Stop 모드에서 이걸 오류로 보고 멈춘다
$ErrorActionPreference = 'Continue'
claude mcp remove $Name -s user 2>$null | Out-Null
$ErrorActionPreference = 'Stop'
claude mcp add --transport http --scope user $Name $Url --header "Authorization: Bearer $Token"
Write-Host '등록 완료. 새 claude 세션을 열고 /mcp 로 확인하세요.'
