# Builds the perf server from the worktree's src as it stands (or from
# another source folder, such as an index snapshot made with
# `git checkout-index -a --prefix=export/idx/`), into one incremental
# folder, and copies the exe aside as bin/<stage>.exe, so each fix's before
# and after stay runnable side by side.
#   powershell -File tests/perf/http/build-stage.ps1 <stage> [server|client] [src folder]
param([string]$stage, [string]$what = "server", [string]$src = "src")
$ErrorActionPreference = "Stop"
$env:HXCPP_COMPILE_THREADS = "4"
# Off CPUs 24-31, where the measurements run; the compiler inherits this.
[System.Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity = [IntPtr]0x00FFFFFF
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Set-Location $root
New-Item -ItemType Directory -Force export\perf-http\bin | Out-Null
if ($what -eq "client") {
	$dir = "export\perf-http\client-after"; $main = "PerfHttpClient"
} else {
	$dir = "export\perf-http\after"; $main = "PerfHttpServer"
}
$exe = "$main.exe"
if (Test-Path "$dir\$exe") { Remove-Item -Force "$dir\$exe" }
# hxcpp judges staleness by the second.
Start-Sleep -Seconds 1
haxe -cp tests/perf/http -cp $src -D windows -D HXCPP_M64 -main $main --cpp $dir *> "export\perf-http\build-$stage.log"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$dir\$exe")) { "build $stage FAILED"; exit 1 }
$suffix = if ($what -eq "client") { "-client" } else { "" }
Copy-Item -Force "$dir\$exe" "export\perf-http\bin\$stage$suffix.exe"
"built $stage$suffix"
