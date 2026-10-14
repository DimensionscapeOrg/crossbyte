package crossbyte.sys._internal;

#if ((cpp || jvm) && !macro)
import haxe.io.Bytes;
import haxe.io.Eof;
import haxe.io.Input;
import haxe.io.Output;

/**
	The child a `NativeProcess` runs, natively and on the jvm: `sys.io.Process`
	when it starts as this program runs, and otherwise a process started in
	the directory and with the environment its startup info gives, which
	`sys.io.Process` cannot do. The same members either way, named as
	`sys.io.Process` names them.
**/
@:noCompletion
class ChildProcess {
	public var stdin(default, null):Output;
	public var stdout(default, null):Input;
	public var stderr(default, null):Input;

	#if jvm
	/** The JDK's process, which `NativeProcess` waits on and reads the id of. **/
	public var javaProcess(default, null):java.lang.Process;
	#end

	@:noCompletion private var __process:Null<sys.io.Process> = null;
	#if cpp
	@:noCompletion private var __native:Dynamic = null;
	#end

	private function new() {}

	/**
		Starts `executable`. `directory` null starts it where this program
		runs; `environment` null gives it this program's environment, and
		otherwise is every variable it gets, each `NAME=value`.
	**/
	public static function start(executable:String, arguments:Array<String>, directory:Null<String>, environment:Null<Array<String>>):ChildProcess {
		var child:ChildProcess = new ChildProcess();
		if (directory == null && environment == null) {
			var process:sys.io.Process = new sys.io.Process(executable, arguments, false);
			child.__process = process;
			child.stdin = process.stdin;
			child.stdout = process.stdout;
			child.stderr = process.stderr;
			#if jvm
			child.javaProcess = @:privateAccess process.proc;
			#end
			return child;
		}

		#if cpp
		var handle:Dynamic = NativeSpawn.start(executable, arguments, directory, environment);
		child.__native = handle;
		child.stdin = new SpawnInput(handle);
		child.stdout = new SpawnOutput(handle, false);
		child.stderr = new SpawnOutput(handle, true);
		#else
		// The command line Haxe's own Process makes, quoted the same way, and
		// then the directory and the environment, which it has no way to set.
		var builder:java.lang.ProcessBuilder = @:privateAccess sys.io.Process.createProcessBuilder(executable, arguments);
		if (directory != null) {
			builder.directory(new java.io.File(directory));
		}
		if (environment != null) {
			var variables:java.util.Map<String, String> = builder.environment();
			variables.clear();
			for (entry in environment) {
				// From the second character: a name never starts with "=" here,
				// and Windows keeps some that do.
				var equals:Int = entry.indexOf("=", 1);
				variables.put(entry.substr(0, equals), entry.substr(equals + 1));
			}
		}
		var process:java.lang.Process = builder.start();
		child.javaProcess = process;
		child.stdin = new java.io.NativeOutput(process.getOutputStream());
		child.stdout = new java.io.NativeInput(process.getInputStream());
		child.stderr = new java.io.NativeInput(process.getErrorStream());
		#end
		return child;
	}

	public function kill():Void {
		if (__process != null) {
			__process.kill();
			return;
		}
		#if cpp
		NativeSpawn.kill(__native);
		#else
		javaProcess.destroy();
		#end
	}

	public function close():Void {
		if (__process != null) {
			__process.close();
			return;
		}
		#if cpp
		NativeSpawn.close(__native);
		#else
		javaProcess.destroy();
		#end
	}

	/** Waits for the child to end and answers its exit code. **/
	public function exitCode():Int {
		#if cpp
		if (__process == null) {
			return NativeSpawn.wait(__native);
		}
		#end
		#if jvm
		javaProcess.waitFor();
		return javaProcess.exitValue();
		#else
		var code:Null<Int> = __process.exitCode();
		return code == null ? 0 : code;
		#end
	}

	public function getPid():Int {
		if (__process != null) {
			return __process.getPid();
		}
		#if cpp
		return NativeSpawn.pid(__native);
		#else
		return -1;
		#end
	}
}

#if cpp
/** A spawned child's standard input. **/
private class SpawnInput extends Output {
	var handle:Dynamic;
	var one:Bytes = Bytes.alloc(1);

	public function new(handle:Dynamic) {
		this.handle = handle;
	}

	override public function writeByte(c:Int):Void {
		one.set(0, c);
		writeBytes(one, 0, 1);
	}

	override public function writeBytes(buffer:Bytes, offset:Int, length:Int):Int {
		var written:Int = NativeSpawn.write(handle, buffer.getData(), offset, length);
		if (written < 0) {
			// As hxcpp's process's stdin: a child that has closed its input, or
			// gone, is the end of the stream.
			throw new Eof();
		}
		return written;
	}

	override public function close():Void {
		super.close();
		NativeSpawn.closeInput(handle);
	}
}

/** A spawned child's standard output or standard error. **/
private class SpawnOutput extends Input {
	var handle:Dynamic;
	var fromError:Bool;
	var one:Bytes = Bytes.alloc(1);

	public function new(handle:Dynamic, fromError:Bool) {
		this.handle = handle;
		this.fromError = fromError;
	}

	override public function readByte():Int {
		readBytes(one, 0, 1);
		return one.get(0);
	}

	override public function readBytes(buffer:Bytes, offset:Int, length:Int):Int {
		var read:Int = NativeSpawn.read(handle, fromError, buffer.getData(), offset, length);
		if (read <= 0) {
			throw new Eof();
		}
		return read;
	}
}
#end
#end
