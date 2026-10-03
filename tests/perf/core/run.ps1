# Runs PerfCore scenarios, A (export/baseline/src) and B (src) interleaved, each process
# pinned to CPUs 24-31 so the numbers do not compete with other measurements
# on this machine. From the repository root, after building:
#
#   & ./tests/perf/core/run.ps1 -Scenario tick -Params 100,1000 -Reps 3
#   & ./tests/perf/core/run.ps1 -Target jvm -Scenario tick -Params 1000
#
# -Target cpp|jvm|node   which build to run (cpp by default).
# -Builds b              runs only B, the tree as it is; any build name is
#                        export/perf-core-<name>/PerfCore.exe natively.
# Prints each process's RESULT line, prefixed with its build.
param(
	[string]$Scenario = "tick",
	[int[]]$Params = @(1000),
	[int]$Reps = 3,
	[double]$Seconds = 3,
	[string[]]$Builds = @("a", "b"),
	[string]$Target = "cpp"
)

$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$out = Join-Path $env:TEMP ("perfcore-" + [guid]::NewGuid().ToString() + ".txt")

foreach ($param in $Params) {
	for ($rep = 1; $rep -le $Reps; $rep++) {
		foreach ($build in $Builds) {
			$scenarioArgs = @($Scenario, "$param", "$Seconds")
			switch ($Target) {
				"jvm" {
					$exe = "java"
					$argv = @("-jar", (Join-Path $root "export/perf-core-jvm/$build.jar")) + $scenarioArgs
				}
				"node" {
					$exe = "node"
					$argv = @((Join-Path $root "export/perf-core-node/$build.js")) + $scenarioArgs
				}
				default {
					$exe = Join-Path $root "export/perf-core-$build/PerfCore.exe"
					$argv = $scenarioArgs
				}
			}
			$p = Start-Process -FilePath $exe -ArgumentList $argv -NoNewWindow -PassThru -RedirectStandardOutput $out
			try { $p.ProcessorAffinity = [IntPtr]0xFF000000 } catch {}
			$p.WaitForExit()
			$line = Get-Content $out | Where-Object { $_ -like "RESULT*" }
			Write-Output ("$Target $build rep$rep " + $line)
		}
	}
}
Remove-Item -Force -ErrorAction SilentlyContinue $out
