# Runs RudpPump-<variant>.exe from export/perf-rt/bin interleaved, `reps`
# rounds, appending each PUMP line to `log`, then prints per variant the
# median of the runs' best and median user time per datagram and the
# allocation per datagram.
param(
	[string]$variants = "before,after",
	[int]$reps = 4,
	[string]$extra = "sessions=200 rounds=400 samples=5 allocrounds=100",
	[string]$log = "$env:TEMP\rudp-pump.txt",
	[string]$main = "RudpPump"
)
$bin = Join-Path (Get-Location) "export/perf-rt/bin"
for ($r = 1; $r -le $reps; $r++) {
	foreach ($v in $variants.Split(",")) {
		$a = @($extra.Split(" ") | Where-Object { $_ -ne "" }) + @("label=$v")
		& (Join-Path $bin "$main-$v.exe") @a | Where-Object { $_ -match "^PUMP" } | ForEach-Object { "rep=$r $_" } | Tee-Object -FilePath $log -Append | Out-Null
	}
}
function Median($xs) { $s = @($xs | Sort-Object); if ($s.Count -eq 0) { return 0 }; return $s[[int][Math]::Floor($s.Count / 2)] }
$rows = Get-Content $log | ForEach-Object {
	if ($_ -match "label=(\S+) .*allocPerDatagram=(\d+)B .*userPerDatagram best=([\d.]+)ns median=([\d.]+)ns kernelPerRound median=([\d.]+)us") {
		[pscustomobject]@{ v = $matches[1]; alloc = [double]$matches[2]; best = [double]$matches[3]; med = [double]$matches[4]; kernel = [double]$matches[5] }
	}
}
foreach ($g in ($rows | Group-Object v)) {
	"{0,-10} runs={1} userPerDatagram: best-of-runs median {2:N0} ns (bests {3}), medians median {4:N0} ns; alloc {5:N0} B/datagram; kernel/round median {6:N0} us" -f $g.Name, $g.Count,
		(Median ($g.Group | ForEach-Object { $_.best })), (($g.Group | ForEach-Object { [Math]::Round($_.best) }) -join ","),
		(Median ($g.Group | ForEach-Object { $_.med })), (Median ($g.Group | ForEach-Object { $_.alloc })), (Median ($g.Group | ForEach-Object { $_.kernel }))
}
