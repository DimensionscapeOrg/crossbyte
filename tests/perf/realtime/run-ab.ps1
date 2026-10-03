# Runs one harness main from several builds, interleaved, and prints each
# run's result line prefixed with the rep and the build:
#
#   powershell -File tests/perf/realtime/run-ab.ps1 -main ClusterBench -builds "cluster-before,fix" -reps 3 -mainArgs "nodes=1024" -log <file>
#
# Each build is export/perf-rt/<build>/<main>.exe (see build-ab.ps1). Only
# the lines the mains print as results (an upper-case tag and a space) are
# kept.
param(
	[string]$main,
	[string]$builds,
	[int]$reps = 3,
	[string]$mainArgs = "",
	[string]$log = "$env:TEMP\ab-results.txt"
)
for ($r = 1; $r -le $reps; $r++) {
	foreach ($b in $builds.Split(",")) {
		$exe = Join-Path (Get-Location) "export/perf-rt/$b/$main.exe"
		$a = @($mainArgs.Split(" ") | Where-Object { $_ -ne "" }) + @("label=$b")
		& $exe @a 2>&1 | ForEach-Object {
			$line = "$_"
			if ($line -match "^[A-Z]+ ") {
				"rep=$r $line" | Tee-Object -FilePath $log -Append
			}
		}
	}
}
