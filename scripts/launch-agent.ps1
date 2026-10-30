# 워크스페이스 폴더에서 claude를 새 터미널로 띄우고 claude.exe의 PID를 출력한다 (start_agent가 호출)
# 입력은 환경변수로 받는다: AL_EXE, AL_ARGS(JSON 배열), AL_CWD, AL_TITLE, AL_TERMINAL(wt | console)
$ErrorActionPreference = 'Stop'
$exe = $env:AL_EXE
$argv = @($env:AL_ARGS | ConvertFrom-Json)
$cwd = $env:AL_CWD
$title = $env:AL_TITLE

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($env:AL_TERMINAL -ne 'console' -and $wt) {
    # Windows Terminal의 'agent-launcher' 창에 워크스페이스별 탭으로 연다.
    # wt.exe는 바로 끝나므로, 새로 생긴 claude.exe를 찾아 PID를 얻는다
    # 이미 떠 있던 claude는 빼고, 이름이 정확히 일치하는 것만 잡는다 (ai / ai_seminar처럼 겹치는 이름 대비)
    $before = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | ForEach-Object ProcessId)
    $pattern = '(--remote-control|--name) "?' + [regex]::Escape($title) + '"?(\s|$)'
    # 탭은 PowerShell로 열고 그 안에서 claude를 실행한다. claude가 끝나도 탭이 PowerShell 프롬프트로 남는다
    # 명령은 -EncodedCommand로 넘겨서 wt의 ; 구분자나 따옴표, 한글 경로 문제를 피한다
    $quote = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $command = '& ' + (& $quote $exe) + ' ' + (($argv | ForEach-Object { & $quote $_ }) -join ' ')
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $shell = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $shell) { $shell = Get-Command powershell.exe }
    & $wt.Source -w agent-launcher new-tab --title $title --suppressApplicationTitle -d $cwd $shell.Source -NoExit -EncodedCommand $encoded
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        $p = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
            Where-Object { $before -notcontains $_.ProcessId -and $_.CommandLine -match $pattern } |
            Sort-Object CreationDate | Select-Object -First 1
        if ($p) { $p.ProcessId; exit 0 }
    }
    throw 'Windows Terminal에서 claude 프로세스를 찾지 못했습니다.'
} else {
    $quoted = ($argv | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    (Start-Process -FilePath $exe -ArgumentList $quoted -WorkingDirectory $cwd -PassThru).Id
}
