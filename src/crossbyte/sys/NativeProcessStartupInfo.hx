package crossbyte.sys;

/**
 * What `NativeProcess.start` starts: the executable and its arguments.
 *
 * From AIR: those two of `NativeProcessStartupInfo`'s members, by the same
 * names.
 */
class NativeProcessStartupInfo {
	public var executable:String;

	/**
		The arguments, each reaching the program as one.

		On Windows, natively, on HashLink and on neko each goes in quotes, as
		Haxe's `sys.io.Process` writes them. Programs read that as they should,
		but `cmd.exe` takes a quoted word for the name of a program, never one
		of its own commands: `cmd.exe /C echo hi` runs an `echo.exe` from the
		PATH there, or fails where there is none. Run a program instead. The
		jvm and Node quote only an argument that needs it.
	**/
	public var arguments:Array<String>;

	public function new(executable:String, ?arguments:Array<String>) {
		this.executable = executable;
		this.arguments = arguments != null ? arguments : [];
	}
}
