package crossbyte.sys;

import crossbyte.core.CrossByte;
import crossbyte.events.NativeProcessEvent;
import haxe.io.Bytes;
import utest.Assert;
import crossbyte.test.Require;

@:access(crossbyte.core.CrossByte)
class NativeProcessTest extends utest.Test {
	// Every wait below returns the moment its predicate holds, so this ceiling
	// costs nothing when the child behaves and only decides how loaded a machine
	// has to get before a passing test reports a failure. Spawning a process is
	// not reliably a three-second operation on a busy CI runner.
	private static inline var TIMEOUT:Float = 15.0;

	// Every target with processes and threads but the interpreter: cpp, hl,
	// neko and the jvm, none of which but cpp names an OS when it is built,
	// so support is not decided by asking for one. The interpreter's process
	// calls hold every thread while they wait, so it refuses, and says why.
	public function testSupportFlagMatchesTarget():Void {
		#if (nodejs || (sys && target.threaded && !eval))
		Assert.isTrue(NativeProcess.isSupported);
		#else
		Assert.isFalse(NativeProcess.isSupported);
		#end
	}

	public function testStartThrowsWhenUnsupported():Void {
		#if (sys && target.threaded && !eval)
		Assert.pass();
		#else
		// An IllegalOperationError, which says the target cannot, rather than
		// an ArgumentError, which says the caller passed something wrong; and
		// on the interpreter, why.
		var proc = new NativeProcess();
		var thrown:Dynamic = null;
		try {
			proc.start(new NativeProcessStartupInfo("echo"));
		} catch (e:Dynamic) {
			thrown = e;
		}
		Assert.isTrue(Std.isOfType(thrown, crossbyte.errors.IllegalOperationError), "start threw " + thrown);
		#if eval
		Assert.isTrue(Std.string(thrown).indexOf("interpreter") >= 0, "the refusal did not name the interpreter: " + thrown);
		#end
		Assert.isFalse(proc.running);
		#end
	}

	public function testStartEmitEventsAndExitCode():Void {
		#if (sys && target.threaded && !eval)
		var proc = new NativeProcess();
		var output:String = "";
		var exited:Bool = false;
		var exitCode:Int = -1;
		var stdoutClosed:Bool = false;
		var stderrClosed:Bool = false;

		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, event -> output += event.text);
		proc.addEventListener(NativeProcessEvent.EXIT, event -> {
			exited = true;
			exitCode = event.exitCode;
		});
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_CLOSE, _ -> stdoutClosed = true);
		proc.addEventListener(NativeProcessEvent.STANDARD_ERROR_CLOSE, _ -> stderrClosed = true);

		var info = getDefaultInfo();
		proc.start(info);

		pumpUntil(() -> exited, TIMEOUT);

		Assert.isTrue(exited);
		Assert.equals(0, exitCode);
		Assert.isTrue(stdoutClosed);
		Assert.isTrue(stderrClosed);
		Require.notNull(output);
		Assert.isTrue(output.indexOf("nativeprocess_smoke") >= 0);
		#else
		Assert.pass();
		#end
	}

	/**
		The child's own id, while it runs and on the event that ends it.

		The id is read through `getPid()`, which every target's
		`sys.io.Process` has, not looked up as a `pid` field by reflection,
		which none has: that would read -1 on every target that runs the child
		on a thread, cpp included.
	**/
	public function testThePidIsTheChilds():Void {
		#if (sys && target.threaded && !eval)
		var proc = new NativeProcess();
		var exited:Bool = false;
		var exitPid:Int = -1;

		proc.addEventListener(NativeProcessEvent.EXIT, event -> {
			exited = true;
			exitPid = event.pid;
		});

		proc.start(getDefaultInfo());
		var pid:Int = proc.pid;

		pumpUntil(() -> exited, TIMEOUT);

		Assert.isTrue(exited);
		Assert.equals(pid, exitPid);
		#if jvm
		// The one place there is no id to have: Java 8 on Windows keeps the
		// child's handle and no way to learn its id, as `pid` documents. The
		// jvm's own getPid() answers -1 everywhere, Linux and Java 9 included.
		if (System.isWindows && Std.parseFloat(java.lang.System.getProperty("java.specification.version")) < 9) {
			Assert.equals(-1, pid);
			return;
		}
		#end
		Assert.isTrue(pid > 0, "the running child reported pid " + pid);
		#else
		Assert.pass();
		#end
	}

	/**
		A child with nothing to say does not stop the runtime while it runs.

		On hl a child's output is read, and its exit waited for, in natives that
		do not tell the collector the thread is waiting, and the collector stops
		every thread until each reaches a safe point. Unless those waits are
		marked, the first collection after the start would hold the whole
		runtime until the child spoke or ended: about five seconds between two
		ticks, for a child quiet for five seconds.
	**/
	public function testAQuietChildDoesNotStopTheRuntime():Void {
		#if (sys && target.threaded && !eval)
		var proc = new NativeProcess();
		var exited:Bool = false;
		proc.addEventListener(NativeProcessEvent.EXIT, _ -> exited = true);
		proc.start(getQuietInfo(2));

		var runtime = CrossByte.current();
		var garbage:Array<Bytes> = [];
		var last:Float = haxe.Timer.stamp();
		var longest:Float = 0.0;
		var deadline:Float = last + TIMEOUT;
		while (!exited && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);
			// Garbage enough that the collector runs while the child is quiet.
			for (_ in 0...10) {
				garbage.push(Bytes.alloc(100000));
			}
			if (garbage.length > 100) {
				garbage = [];
			}
			crossbyte.sys.System.sleep(0.001);
			var now:Float = haxe.Timer.stamp();
			if (now - last > longest) {
				longest = now - last;
			}
			last = now;
		}

		Assert.isTrue(exited, "the quiet child never exited");
		Assert.isTrue(longest < 1.0, "the runtime stopped for " + Math.round(longest * 1000) + " ms while the child said nothing");
		#else
		Assert.pass();
		#end
	}

	/**
		A character a read cuts in two arrives whole. Decoding each read of a
		child's output on its own would turn a UTF-8 character split across two
		(at a 4096-byte boundary, or wherever the pipe hands back less) into
		two replacement characters. Node decodes across reads already. Here the
		output arrives a byte per read.
	**/
	@:access(crossbyte.sys.NativeProcess)
	public function testACharacterSplitBetweenReadsArrivesWhole():Void {
		#if (sys && target.threaded && !eval && !hl)
		var expected:String = "aé€\u{1F600}b";
		var proc = new NativeProcess();
		var text:String = "";
		var closed = false;
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, event -> text += event.text);
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_CLOSE, _ -> closed = true);

		proc.__running = true;
		proc.__worker = new Worker();
		proc.__worker.addEventListener(crossbyte.events.ThreadEvent.PROGRESS, proc.__onWorkerProgress);
		proc.__worker.doWork = _ -> proc.__readStream(NativeProcess.STREAM_STDOUT, new ByteAtATime(Bytes.ofString(expected)));
		proc.__worker.run();

		pumpUntil(() -> closed, TIMEOUT);
		proc.__running = false;

		Assert.isTrue(closed);
		Assert.equals(expected, text);
		#else
		Assert.pass();
		#end
	}

	/**
		The worker that waited for a child survives the runtime dispatching
		the child's `EXIT` first, and the child is closed all the same.

		The worker sends its completion and then closes the child, and must
		not close it through the field `EXIT` clears: a runtime that got there
		first would leave the worker closing null, an access violation natively
		that the `try` around the close cannot catch, with the child's handles
		left for the collector to close. The test hook holds the worker at that
		moment until the runtime has dispatched `EXIT`.
	**/
	public function testAChildWhoseExitIsDispatchedFirstIsStillClosed():Void {
		#if (sys && target.threaded && !eval)
		var proc = new NativeProcess();
		var exited:Bool = false;
		var dispatched = new sys.thread.Lock();
		var resumed:Bool = false;
		proc.addEventListener(NativeProcessEvent.EXIT, _ -> {
			exited = true;
			dispatched.release();
		});
		@:privateAccess NativeProcess.__afterCompleteForTest = () -> {
			// Released from inside the EXIT listener; the runtime finishes
			// dispatching it a moment later.
			dispatched.wait(TIMEOUT);
			crossbyte.sys.System.sleep(0.1);
			resumed = true;
		};

		try {
			proc.start(getDefaultInfo());
			pumpUntil(() -> exited, TIMEOUT);
			// The worker goes on from where the hook held it, after EXIT, and
			// is given a moment to finish.
			waitUntil(() -> resumed, TIMEOUT);
			crossbyte.sys.System.sleep(0.5);
		} catch (error:Dynamic) {
			@:privateAccess NativeProcess.__afterCompleteForTest = null;
			throw error;
		}
		@:privateAccess NativeProcess.__afterCompleteForTest = null;

		Assert.isTrue(exited, "the child never exited");
		Assert.isTrue(resumed, "the worker never went on past its completion");
		#else
		Assert.pass();
		#end
	}

	/**
		A child writing faster than the runtime dispatches is held to at most
		`MAX_OUTPUT_AHEAD` bytes ahead of it; past that the child waits on its
		pipe, rather than its output being read as fast as it comes and queued
		without limit (here a 2 MB file, every byte of it waiting in this
		process while the runtime does not pump). All of it still arrives once
		the runtime does.
	**/
	public function testAChattyChildIsHeldToABoundedBacklog():Void {
		#if (sys && target.threaded && !eval)
		var path:String = haxe.io.Path.join([Sys.getCwd(), "nativeprocess-backlog-" + Std.random(1000000) + ".txt"]);
		var line:String = "0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopq\n";
		var buffer = new StringBuf();
		for (_ in 0...32768) {
			buffer.add(line);
		}
		var content:String = buffer.toString();
		sys.io.File.saveContent(path, content);

		var proc = new NativeProcess();
		var received:Int = 0;
		var exited:Bool = false;
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, event -> received += event.text.length);
		var errors:String = "";
		proc.addEventListener(NativeProcessEvent.STANDARD_ERROR_DATA, event -> errors += event.text);
		proc.addEventListener(NativeProcessEvent.EXIT, _ -> exited = true);

		try {
			// The file written out exactly, by a program rather than a shell
			// builtin: hxcpp quotes each argument, and cmd.exe takes a quoted
			// "type" for a program it cannot find.
			proc.start(System.isWindows ? new NativeProcessStartupInfo("powershell.exe", [
				"-NoProfile",
				"-NonInteractive",
				"-Command",
				"[Console]::Out.Write([IO.File]::ReadAllText('" + path + "'))"
			]) : new NativeProcessStartupInfo("cat", [path]));
			// Not pumped: nothing is dispatched, so the readers can only queue.
			// Until the queue stops growing, as it does once the readers wait
			// or the child has written everything.
			var queued:Int = -1;
			var steady:Int = 0;
			var deadline:Float = haxe.Timer.stamp() + TIMEOUT;
			while (steady < 10 && haxe.Timer.stamp() < deadline) {
				crossbyte.sys.System.sleep(0.05);
				var now:Int = @:privateAccess proc.__worker.__outbox.length;
				steady = now == queued && now > 0 ? steady + 1 : 0;
				queued = now;
			}
			Assert.isTrue(queued > 0 && queued <= 72, queued + " pieces of output were queued ahead of the runtime");

			pumpUntil(() -> exited, TIMEOUT * 2);
			Assert.isTrue(exited, "the child never exited");
			Assert.equals(content.length, received, "not all of the output arrived: " + received + " of " + content.length + " bytes, exit code " + proc.exitCode + ", stderr " + errors);
		} catch (error:Dynamic) {
			try sys.FileSystem.deleteFile(path) catch (_:Dynamic) {}
			throw error;
		}
		try sys.FileSystem.deleteFile(path) catch (_:Dynamic) {}
		#else
		Assert.pass();
		#end
	}

	public function testExitEventDispatchesOnOwningRuntimeTick():Void {
		#if (sys && target.threaded && !eval)
		var primordial = CrossByte.current();
		var child = new CrossByte(false, DEFAULT, true);
		var proc = new NativeProcess();
		var exited = false;
		var exitRuntime:CrossByte = null;

		proc.addEventListener(NativeProcessEvent.EXIT, _ -> {
			exited = true;
			exitRuntime = CrossByte.current();
		});

		proc.start(getDefaultInfo());
		waitUntil(() -> proc.exitCode == 0, TIMEOUT);

		primordial.pump(1 / 60, 0);
		Assert.isFalse(exited);

		pumpRuntimeUntil(child, () -> exited, TIMEOUT);

		Assert.isTrue(exited);
		Assert.equals(child, exitRuntime);

		child.exit();
		#else
		Assert.pass();
		#end
	}

	/**
		A child started in another directory writes there; one given a path
		that is not a directory is refused before anything starts.
	**/
	public function testAWorkingDirectoryIsWhereTheChildStarts():Void {
		#if (sys && target.threaded && !eval && !hl && !neko)
		var directory:String = __temporaryDirectory("cwd");
		var info = System.isWindows ? __powershell("Set-Content -Path marker.txt -Value here") : new NativeProcessStartupInfo("sh", ["-c", "echo here > marker.txt"]);
		info.workingDirectory = directory;
		var result = __run(info);

		Assert.equals(0, result.exitCode, result.errors);
		Assert.isTrue(sys.FileSystem.exists(haxe.io.Path.join([directory, "marker.txt"])), "the child did not write in " + directory);
		Assert.isFalse(sys.FileSystem.exists(haxe.io.Path.join([Sys.getCwd(), "marker.txt"])), "the child wrote where this program runs");
		__remove(directory);

		var missing = getDefaultInfo();
		missing.workingDirectory = directory + "-absent";
		Assert.raises(() -> new NativeProcess().start(missing), crossbyte.errors.ArgumentError);
		var file = getDefaultInfo();
		file.workingDirectory = __writeFile(__temporaryDirectory("file"), "not-a-directory.txt", "x");
		Assert.raises(() -> new NativeProcess().start(file), crossbyte.errors.ArgumentError);
		#else
		Assert.pass();
		#end
	}

	/**
		A relative path to the program is read from this program's working
		directory, as it is without a working directory, on every target: not
		from the child's, as POSIX's exec would read it after the child has
		changed directory.
	**/
	public function testARelativeExecutableIsReadFromHereNotTheChilds():Void {
		#if (sys && target.threaded && !eval && !hl && !neko)
		var programs:String = __temporaryDirectory("programs", Sys.getCwd());
		var name:String = haxe.io.Path.withoutDirectory(programs);
		var program:String;
		if (System.isWindows) {
			program = haxe.io.Path.join([programs, "hostname.exe"]);
			sys.io.File.copy(haxe.io.Path.join([Sys.getEnv("SystemRoot"), "System32", "hostname.exe"]), program);
		} else {
			program = haxe.io.Path.join([programs, "echo"]);
			sys.io.File.copy(sys.FileSystem.exists("/bin/echo") ? "/bin/echo" : "/usr/bin/echo", program);
			Sys.command("chmod", ["755", program]);
		}
		var elsewhere:String = __temporaryDirectory("elsewhere");
		var info = new NativeProcessStartupInfo(name + "/" + haxe.io.Path.withoutDirectory(program), System.isWindows ? [] : ["relative"]);
		info.workingDirectory = elsewhere;
		var result = __run(info);

		Assert.equals(0, result.exitCode, "exit code " + result.exitCode + ": " + result.errors);
		Assert.isTrue(StringTools.trim(result.output).length > 0, "the program wrote nothing");
		__remove(programs);
		__remove(elsewhere);
		#else
		Assert.pass();
		#end
	}

	/**
		Variables given are added to this program's, override one of the same
		name, and a null takes one out; with `inheritEnvironment` off the child
		has those alone.
	**/
	public function testTheEnvironmentIsAddedToOverriddenAndTakenFrom():Void {
		#if (sys && target.threaded && !eval && !hl && !neko)
		// A variable this program has on every system, taken out of the child.
		var taken:String = System.isWindows ? "TEMP" : "HOME";
		var info = System.isWindows ? __powershell("Write-Output ('[' + $env:CB_CHILD_VAR + '][' + $env:TEMP + '][' + ($env:Path.Length -gt 0) + ']')") : new NativeProcessStartupInfo("sh", [
			"-c",
			"echo \"[$CB_CHILD_VAR][${HOME-unset}][${PATH:+path}]\""
		]);
		info.environment = ["CB_CHILD_VAR" => "a value with spaces", taken => null];
		var result = __run(info);
		Assert.equals(0, result.exitCode, result.errors);
		Assert.equals(System.isWindows ? "[a value with spaces][][True]" : "[a value with spaces][unset][path]", StringTools.trim(result.output));

		// Set over a variable this program has, in another case on Windows,
		// which matches names in any case.
		var over = System.isWindows ? __powershell("Write-Output ('[' + $env:TEMP + ']')") : new NativeProcessStartupInfo("sh", ["-c", "echo \"[$HOME]\""]);
		over.environment = [(System.isWindows ? "temp" : "HOME") => "replaced"];
		var replaced = __run(over);
		Assert.equals("[replaced]", StringTools.trim(replaced.output), replaced.errors);
		#else
		Assert.pass();
		#end
	}

	public function testWithoutInheritingTheChildHasTheGivenVariablesAlone():Void {
		#if (sys && target.threaded && !eval && !hl && !neko)
		var info:NativeProcessStartupInfo;
		if (System.isWindows) {
			info = __powershell("Write-Output ('[' + $env:CB_ALONE + '][' + $env:USERNAME + '][' + $env:TEMP + ']')");
			// What PowerShell needs to start at all, and where it keeps its
			// caches, which without SystemDrive it makes in a folder named
			// %SystemDrive% where it runs.
			info.environment = ["CB_ALONE" => "1", "SystemRoot" => Sys.getEnv("SystemRoot"), "SystemDrive" => Sys.getEnv("SystemDrive")];
		} else {
			info = new NativeProcessStartupInfo("/bin/sh", ["-c", "echo \"[$CB_ALONE][${HOME-unset}][${USER-unset}]\""]);
			info.environment = ["CB_ALONE" => "1"];
		}
		info.inheritEnvironment = false;
		var directory:String = __temporaryDirectory("alone");
		info.workingDirectory = directory;
		var result = __run(info);
		__removeTree(directory);
		Assert.equals(0, result.exitCode, result.errors);
		Assert.equals(System.isWindows ? "[1][][]" : "[1][unset][unset]", StringTools.trim(result.output));
		#else
		Assert.pass();
		#end
	}

	public function testAnEnvironmentNoSystemCanHoldIsRefused():Void {
		#if (sys && target.threaded && !eval && !hl && !neko)
		for (bad in [["" => "x"], ["A=B" => "x"], ["A\x00B" => "x"], ["OK" => "a\x00b"]]) {
			var info = getDefaultInfo();
			info.environment = bad;
			var proc = new NativeProcess();
			Assert.raises(() -> proc.start(info), crossbyte.errors.ArgumentError);
			Assert.isFalse(proc.running);
		}
		#else
		Assert.pass();
		#end
	}

	/**
		HashLink and neko cannot give a child a directory or an environment of
		its own, and say so rather than start it without them.
	**/
	public function testHashLinkAndNekoRefuseADirectoryOrAnEnvironment():Void {
		#if (hl || neko)
		var withDirectory = getDefaultInfo();
		withDirectory.workingDirectory = Sys.getCwd();
		Assert.raises(() -> new NativeProcess().start(withDirectory), crossbyte.errors.IllegalOperationError);
		var withEnvironment = getDefaultInfo();
		withEnvironment.environment = ["A" => "1"];
		Assert.raises(() -> new NativeProcess().start(withEnvironment), crossbyte.errors.IllegalOperationError);
		#else
		Assert.pass();
		#end
	}

	/**
		A child started with an environment of its own (natively, through
		CrossByte's own spawner) is read, written to, ended and waited for as
		any other is.
	**/
	public function testAChildWithAnEnvironmentIsReadWrittenAndEnded():Void {
		#if (sys && target.threaded && !eval && !hl && !neko)
		// Its input echoed back with its exit code chosen, through the pipe.
		var echo = System.isWindows ? __powershell("$t = [Console]::In.ReadToEnd(); [Console]::Out.Write('<' + $t + '>'); [Console]::Error.Write('err'); exit 3") : new NativeProcessStartupInfo("sh", [
			"-c",
			"t=$(cat); printf '<%s>' \"$t\"; printf err >&2; exit 3"
		]);
		echo.environment = ["CB_SPAWNED" => "1"];
		var proc = new NativeProcess();
		var output:String = "";
		var errors:String = "";
		var exitCode:Int = -100;
		var exited:Bool = false;
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, event -> output += event.text);
		proc.addEventListener(NativeProcessEvent.STANDARD_ERROR_DATA, event -> errors += event.text);
		proc.addEventListener(NativeProcessEvent.EXIT, event -> {
			exited = true;
			exitCode = event.exitCode;
		});
		proc.start(echo);
		Assert.isTrue(proc.pid > 0 #if jvm || proc.pid == -1 #end, "pid " + proc.pid);
		proc.standardInput.writeString("through stdin");
		proc.standardInput.flush();
		proc.closeInput();
		pumpUntil(() -> exited, TIMEOUT);
		Assert.isTrue(exited);
		Assert.equals(3, exitCode);
		Assert.equals("<through stdin>", output);
		Assert.equals("err", errors);

		// One that would run for a minute, ended.
		var quiet = getQuietInfo(60);
		quiet.environment = ["CB_SPAWNED" => "1"];
		var long = new NativeProcess();
		var ended:Bool = false;
		long.addEventListener(NativeProcessEvent.EXIT, _ -> ended = true);
		var started:Float = haxe.Timer.stamp();
		long.start(quiet);
		long.exit();
		pumpUntil(() -> ended, TIMEOUT);
		Assert.isTrue(ended, "the child was not ended");
		Assert.isTrue(haxe.Timer.stamp() - started < 30, "ending the child took " + (haxe.Timer.stamp() - started) + " s");
		#else
		Assert.pass();
		#end
	}

	public function testAProgramThatIsNotThereIsRefusedAtStart():Void {
		#if ((cpp || jvm) && !eval)
		var info = new NativeProcessStartupInfo("crossbyte-no-such-program-" + Std.random(1000000));
		info.environment = ["CB_SPAWNED" => "1"];
		var proc = new NativeProcess();
		Assert.raises(() -> proc.start(info));
		Assert.isFalse(proc.running);
		#else
		Assert.pass();
		#end
	}

	/** Lines from a real child, from both of its streams and both spawners. **/
	public function testAChildsLinesArriveOneAtATime():Void {
		#if (sys && target.threaded && !eval)
		for (own in [false, true]) {
			#if (hl || neko)
			if (own) {
				continue;
			}
			#end
			var info = System.isWindows ? __powershell("[Console]::Out.Write('one' + [char]13 + [char]10 + 'two' + [char]10 + 'thr'); [Console]::Out.Flush(); Start-Sleep -Milliseconds 100; [Console]::Out.Write('ee'); [Console]::Error.Write('e1' + [char]10 + 'e2' + [char]10)") : new NativeProcessStartupInfo("sh", [
				"-c",
				"printf 'one\\r\\ntwo\\nthr'; sleep 0.1; printf 'ee'; printf 'e1\\ne2\\n' >&2"
			]);
			if (own) {
				info.environment = ["CB_SPAWNED" => "1"];
			}
			var proc = new NativeProcess();
			var lines:Array<String> = [];
			var errorLines:Array<String> = [];
			var exited:Bool = false;
			proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_LINE, event -> lines.push(event.text));
			proc.addEventListener(NativeProcessEvent.STANDARD_ERROR_LINE, event -> errorLines.push(event.text));
			proc.addEventListener(NativeProcessEvent.EXIT, _ -> exited = true);
			proc.start(info);
			pumpUntil(() -> exited, TIMEOUT);
			Assert.isTrue(exited);
			Assert.same(["one", "two", "three"], lines, "own spawner: " + own);
			Assert.same(["e1", "e2"], errorLines, "own spawner: " + own);
		}
		#else
		Assert.pass();
		#end
	}

	private static function __powershell(command:String):NativeProcessStartupInfo {
		return new NativeProcessStartupInfo("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", command]);
	}

	/** Runs `info` to its end, pumping the runtime, and answers what it said. **/
	private static function __run(info:NativeProcessStartupInfo):{exitCode:Int, output:String, errors:String} {
		var proc = new NativeProcess();
		var output:String = "";
		var errors:String = "";
		var exitCode:Int = -100;
		var exited:Bool = false;
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, event -> output += event.text);
		proc.addEventListener(NativeProcessEvent.STANDARD_ERROR_DATA, event -> errors += event.text);
		proc.addEventListener(NativeProcessEvent.EXIT, event -> {
			exited = true;
			exitCode = event.exitCode;
		});
		proc.start(info);
		pumpUntil(() -> exited, TIMEOUT);
		return {exitCode: exited ? exitCode : -101, output: output, errors: errors};
	}

	private static var __made:Int = 0;

	private static function __temporaryDirectory(label:String, ?under:String):String {
		var root:String = under;
		if (root == null) {
			for (candidate in [Sys.getEnv("TEMP"), Sys.getEnv("TMP"), Sys.getEnv("TMPDIR"), "/tmp"]) {
				if (candidate != null && candidate != "" && sys.FileSystem.exists(candidate)) {
					root = candidate;
					break;
				}
			}
		}
		var path:String = haxe.io.Path.join([root, 'crossbyte-np-$label-${Std.random(1000000)}-${__made++}']);
		sys.FileSystem.createDirectory(path);
		return path;
	}

	private static function __writeFile(directory:String, name:String, content:String):String {
		var path:String = haxe.io.Path.join([directory, name]);
		sys.io.File.saveContent(path, content);
		return path;
	}

	private static function __removeTree(path:String):Void {
		try {
			if (sys.FileSystem.isDirectory(path)) {
				for (entry in sys.FileSystem.readDirectory(path)) {
					__removeTree(haxe.io.Path.join([path, entry]));
				}
				sys.FileSystem.deleteDirectory(path);
			} else {
				sys.FileSystem.deleteFile(path);
			}
		} catch (_:Dynamic) {}
	}

	private static function __remove(directory:String):Void {
		try {
			for (entry in sys.FileSystem.readDirectory(directory)) {
				sys.FileSystem.deleteFile(haxe.io.Path.join([directory, entry]));
			}
			sys.FileSystem.deleteDirectory(directory);
		} catch (_:Dynamic) {}
	}

	// Asked of the machine rather than the compiler: hl and neko have no
	// `windows` define, and their bytecode runs on whichever OS it is given to.
	//
	// On Windows a program, not a command of cmd.exe's: natively, on hl and on
	// neko each argument goes in quotes, and cmd.exe takes a quoted "echo" for
	// a program's name. That ran only where an echo.exe was on the PATH (Git's,
	// in its own shell and on CI), and failed with exit code 1 elsewhere.
	@:noCompletion private static function getDefaultInfo():NativeProcessStartupInfo {
		if (System.isWindows) {
			return new NativeProcessStartupInfo("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "Write-Output nativeprocess_smoke"]);
		}
		return new NativeProcessStartupInfo("sh", ["-c", "echo nativeprocess_smoke"]);
	}

	/** A child that prints nothing and ends after about `seconds`. **/
	@:noCompletion private static function getQuietInfo(seconds:Int):NativeProcessStartupInfo {
		if (System.isWindows) {
			return new NativeProcessStartupInfo("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds " + seconds]);
		}
		return new NativeProcessStartupInfo("sh", ["-c", "sleep " + seconds]);
	}

	@:noCompletion private static function pumpUntil(predicate:Void->Bool, timeoutSeconds:Float):Void {
		pumpRuntimeUntil(CrossByte.current(), predicate, timeoutSeconds);
	}

	@:noCompletion private static function pumpRuntimeUntil(runtime:CrossByte, predicate:Void->Bool, timeoutSeconds:Float):Void {
		var deadline = haxe.Timer.stamp() + timeoutSeconds;
		while (!predicate() && haxe.Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.0);
			crossbyte.sys.System.sleep(0.001);
		}
	}

	@:noCompletion private static function waitUntil(predicate:Void->Bool, timeoutSeconds:Float):Void {
		var deadline = haxe.Timer.stamp() + timeoutSeconds;
		while (!predicate() && haxe.Timer.stamp() < deadline) {
			crossbyte.sys.System.sleep(0.001);
		}
	}

	@:noCompletion private static function throws(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}
}

/** A child's output that arrives one byte per read, then ends. **/
private class ByteAtATime extends haxe.io.Input {
	private final source:Bytes;
	private var at:Int = 0;

	public function new(source:Bytes) {
		this.source = source;
	}

	override public function readByte():Int {
		if (at >= source.length) {
			throw new haxe.io.Eof();
		}
		return source.get(at++);
	}

	override public function readBytes(buffer:Bytes, pos:Int, len:Int):Int {
		if (at >= source.length) {
			throw new haxe.io.Eof();
		}
		buffer.set(pos, source.get(at++));
		return 1;
	}
}
