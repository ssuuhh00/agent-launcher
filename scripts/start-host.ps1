# agent-launcher 서버 실행 (로그인 시 자동 실행 바로가기가 이 파일을 부른다)
$Host.UI.RawUI.WindowTitle = 'agent-launcher'
Set-Location (Split-Path -Parent $PSScriptRoot)
node src/server.js
