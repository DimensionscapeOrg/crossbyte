package crossbyte.sys;

/**
 * What `NativeProcess.start` starts: the executable and its arguments, and
 * optionally the directory it starts in and the environment it gets.
 *
 * From AIR: `executable` and `arguments`, by the same names, and
 * `workingDirectory`, which is a path here as `executable` is.
 *
 * ```haxe
 * var info = new NativeProcessStartupInfo("/opt/game/bin/instance", ["--realm", "eu-1"]);
 * info.workingDirectory = "/opt/game";
 * info.environment = ["GAME_MODE" => "ranked", "DATABASE_PASSWORD" => null];
 * ```
 *
 * Natively, on the jvm and on Node; HashLink and neko start a child only
 * where and as this program runs, and `start` throws there when either is
 * set.
 */
class NativeProcessStartupInfo {
	public var executable:String;

	/**
		The arguments, each reaching the program as one.

		On Windows the jvm and Node quote only an argument that needs it, and so
		does a native start given a `workingDirectory` or an `environment`.
		Otherwise natively, and on HashLink and neko, each goes in quotes, as
		Haxe's `sys.io.Process` writes them. Programs read either as they
		should, but `cmd.exe` takes a quoted word for the name of a program,
		never one of its own commands: there `cmd.exe /C echo hi` runs an
		`echo.exe` from the PATH, or fails where there is none. Run a program
		instead.
	**/
	public var arguments:Array<String>;

	/**
		The directory the child starts in, or null (the default) for this
		program's working directory. It must be a directory that exists, or
		`start` throws an `ArgumentError`.

		With it set, an `executable` given as a relative path (`bin/server`) is
		still read from this program's working directory, on every target, as
		it would be without it; a bare name (`node`) is looked for on the
		PATH.
	**/
	public var workingDirectory:Null<String> = null;

	/**
		Variables for the child, by name: each added to this program's
		environment, or set over the one of that name there. A null value
		takes that variable out, so a child need not see a secret this program
		holds. Null (the default) gives the child this program's environment as
		it is. See `inheritEnvironment` for an environment of these alone.

		On Windows names are matched in any case, as Windows matches them, so
		`path` sets `Path`. A name must not be empty or hold `=`, and neither
		a name nor a value may hold a NUL; `start` throws an `ArgumentError`
		for one that does.

		A bare `executable` is looked for on this program's PATH natively and
		on the jvm, and on the child's on Node, which differ only when this
		sets `PATH`: give the full path then.
	**/
	public var environment:Null<Map<String, String>> = null;

	/**
		Whether the child's environment starts from this program's (the
		default) before `environment` is applied. `false` gives it the
		variables in `environment` and nothing else. On Windows many programs
		need `SystemRoot` to start, and on every system a bare `executable`
		may need `PATH`; pass those on when they are needed.
	**/
	public var inheritEnvironment:Bool = true;

	public function new(executable:String, ?arguments:Array<String>) {
		this.executable = executable;
		this.arguments = arguments != null ? arguments : [];
	}
}
