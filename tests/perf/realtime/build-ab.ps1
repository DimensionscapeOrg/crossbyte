# Builds realtime harness mains natively into export/perf-rt/<name>/ and
# copies each exe to export/perf-rt/bin/<main>-<name>.exe.
#
#   -name    a label: "after" for the worktree's src, "before" for a copy
#   -before  a class path searched before src (listed after it: Haxe looks
#            at later class paths first), holding the files as they were
#   -mains   comma-separated main classes from tests/perf/realtime
#
#   powershell -File tests/perf/realtime/build-ab.ps1 -name before -before <dir> -mains "RudpLoad,RudpPump"
param(
	[string]$name = "after",
	[string]$before = "",
	[string]$mains = "RudpLoad",
	[string]$defines = ""
)
$env:HXCPP_COMPILE_THREADS = "4"
$out = "export/perf-rt/$name"
$bin = "export/perf-rt/bin"
New-Item -ItemType Directory -Force $bin | Out-Null
foreach ($main in $mains.Split(",")) {
	$exe = "$out/$main.exe"
	if (Test-Path $exe) { Remove-Item $exe }
	$a = @("-cp", "src", "-cp", "tests/perf/realtime")
	if ($before -ne "") { $a += @("-cp", $before) }
	$a += @("-D", "windows", "-D", "HXCPP_M64", "-main", $main, "--cpp", $out)
	foreach ($d in ($defines.Split(",") | Where-Object { $_ -ne "" })) { $a += @("-D", $d) }
	$log = "$out-$main.log"
	& haxe @a *> $log
	if ($LASTEXITCODE -eq 0 -and (Test-Path $exe)) {
		Copy-Item $exe "$bin/$main-$name.exe" -Force
		"built $main-$name"
	} else {
		"FAILED $main-$name (exit $LASTEXITCODE), see $log"
		Get-Content $log | Select-String "rror|characters" | Select-Object -First 10
	}
	Start-Sleep -Milliseconds 1100
}
