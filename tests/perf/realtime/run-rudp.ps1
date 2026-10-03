# Runs RudpLoad builds from export/perf-rt/bin interleaved, `reps` rounds,
# and appends each RESULT/COUNT line to `log`. A variant is a build's name,
# optionally followed by +key=value arguments of its own:
#   powershell -File tests/perf/realtime/run-rudp.ps1 -variants "before,after+ackdelay=0,after" -reps 3 -extra "sessions=500 rate=30 seconds=10" -countfile <file>
# Summarize with summarize.ps1 -logs <log>.
param(
	[string]$variants = "before,after",
	[int]$reps = 3,
	[string]$extra = "sessions=1000 rate=30 seconds=10",
	[string]$log = "$env:TEMP\rudp-results.txt",
	[string]$countfile = "",
	[string]$main = "RudpLoad"
)
$bin = Join-Path (Get-Location) "export/perf-rt/bin"
for ($r = 1; $r -le $reps; $r++) {
	foreach ($variant in $variants.Split(",")) {
		$parts = $variant.Split("+")
		$exe = Join-Path $bin "$main-$($parts[0]).exe"
		$a = @($extra.Split(" ") | Where-Object { $_ -ne "" }) + @("label=$variant")
		if ($parts.Count -gt 1) { $a += $parts[1..($parts.Count - 1)] }
		if ($countfile -ne "") { $a += @("count=1", "countfile=$countfile") }
		$lines = & $exe @a
		foreach ($line in $lines) {
			if ($line -match "^(RESULT|COUNT client)") {
				"rep=$r $line" | Tee-Object -FilePath $log -Append | Out-Null
			}
		}
	}
}
