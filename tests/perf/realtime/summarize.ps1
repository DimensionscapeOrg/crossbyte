# Summarizes run-rudp.ps1 logs: per label, the valid runs (inputs at least
# 98% of expected), with user and kernel CPU, datagrams the server read and
# sent, and user and total CPU per datagram.
param([string]$logs)
$rows = @()
foreach ($log in $logs.Split(",")) {
	$lines = Get-Content $log
	for ($i = 0; $i -lt $lines.Count; $i++) {
		if ($lines[$i] -match "label=(\S+) .*inputs=(\d+) expectedInputs=(\d+) user=([\d.]+)s kernel=([\d.]+)s.*datagramsIn=(\d+)") {
			$row = [ordered]@{ label = $matches[1]; inputs = [int]$matches[2]; expected = [int]$matches[3]; user = [double]$matches[4]; kernel = [double]$matches[5]; dIn = [int]$matches[6]; dOut = 0 }
			if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match "sent by the server\): (\d+)") { $row.dOut = [int]$matches[1] }
			$rows += [pscustomobject]$row
		}
	}
}
function Median($xs) { $s = @($xs | Sort-Object); if ($s.Count -eq 0) { return 0 }; return $s[[int][Math]::Floor($s.Count / 2)] }
foreach ($g in ($rows | Group-Object label)) {
	$v = @($g.Group | Where-Object { $_.inputs -ge 0.98 * $_.expected })
	if ($v.Count -eq 0) { "{0}: no valid runs of {1}" -f $g.Name, $g.Count; continue }
	$u = Median ($v | ForEach-Object { $_.user }); $k = Median ($v | ForEach-Object { $_.kernel })
	$din = Median ($v | ForEach-Object { $_.dIn }); $dout = Median ($v | ForEach-Object { $_.dOut })
	$upd = Median ($v | ForEach-Object { $_.user / ($_.dIn + $_.dOut) * 1e9 })
	$tpd = Median ($v | ForEach-Object { ($_.user + $_.kernel) / ($_.dIn + $_.dOut) * 1e9 })
	"{0,-12} valid={1}/{2} user={3} ({4}) kernel={5} ({6}) in={7} out={8} user/datagram={9:N0}ns cpu/datagram={10:N0}ns" -f $g.Name, $v.Count, $g.Count, $u, (($v | ForEach-Object { $_.user }) -join ","), $k, (($v | ForEach-Object { $_.kernel }) -join ","), $din, $dout, $upd, $tpd
}
