# 대상 프로세스의 콘솔에 Ctrl+C를 보내 정상 종료를 유도한다 (stop_agent가 호출)
param([Parameter(Mandatory = $true)][int]$TargetPid)

Add-Type -Namespace Native -Name Console -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint groupId);
'@

# 내 콘솔을 떼고 대상의 콘솔에 붙은 뒤, 나 자신은 Ctrl+C를 무시하도록 설정
[Native.Console]::FreeConsole() | Out-Null
if (-not [Native.Console]::AttachConsole($TargetPid)) { exit 1 }
[Native.Console]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) | Out-Null

# 한 번에 안 끝나는 경우(확인 질문 등)를 위해 두 번 보낸다
[Native.Console]::GenerateConsoleCtrlEvent(0, 0) | Out-Null
Start-Sleep -Milliseconds 500
[Native.Console]::GenerateConsoleCtrlEvent(0, 0) | Out-Null
[Native.Console]::FreeConsole() | Out-Null
exit 0
