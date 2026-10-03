# Writes the given files as they were at a commit into a class path of their
# own, for an A/B's "before" build (build-ab.ps1 -before <dir>):
#
#   powershell -File tests/perf/realtime/before-from.ps1 -commit c253e329 -dir <dir> -files "crossbyte/net/NetConnection.hx,..."
#
# Paths are relative to src/, or to the repository root when they start with
# "tests/" (written at the class path's root, under their file name).
param(
	[string]$commit = "c253e329",
	[string]$dir,
	[string]$files
)
foreach ($f in $files.Split(",")) {
	if ($f -eq "") { continue }
	if ($f.StartsWith("tests/")) {
		$src = $f
		$dst = Join-Path $dir (Split-Path $f -Leaf)
	} else {
		$src = "src/$f"
		$dst = Join-Path $dir $f
	}
	New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
	# Through Python: PowerShell 5 would write a byte-order mark, or re-encode.
	python -c "import subprocess,sys; open(sys.argv[2],'wb').write(subprocess.run(['git','show',sys.argv[1]],capture_output=True,check=True).stdout)" "${commit}:$src" $dst
	if ($LASTEXITCODE -ne 0) { Write-Error "could not write $src"; exit 1 }
}
