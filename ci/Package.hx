package;

import haxe.Json;
import sys.FileSystem;
import sys.io.File;

/**
	Builds the haxelib release: `dist/crossbyte-<version>.zip`, the version
	read from haxelib.json.

	`haxe ci/package.hxml`

	It holds what `-lib crossbyte` reads -- the sources, with every native
	extension's C++ and Build.xml under `src`, the std overrides, and
	`extraParams.hxml`, which names the host and turns those overrides on --
	plus the documents haxelib shows and the samples. Tests, CI and anything
	a build writes stay out.

	Taken from the commit, not the working tree, through `git archive`: what
	ships is what was committed, and in the repository's own line endings. A
	Windows checkout holds its text as CRLF, and a line break inside a Haxe
	string literal is the file's, so a package zipped from it gave every
	multi-line literal a `\r` on every platform.
**/
class Package {
	static final PATHS:Array<String> = [
		"haxelib.json",
		"README.md",
		"CHANGELOG.md",
		"LICENSE",
		"crossbyte.png",
		"extraParams.hxml",
		"src",
		"std",
		"samples"
	];

	static function main():Void {
		var meta:Dynamic = Json.parse(File.getContent("haxelib.json"));
		var version:String = meta.version;
		if (version == null || version == "") {
			Sys.println("haxelib.json names no version");
			Sys.exit(1);
		}

		for (path in PATHS) {
			if (!FileSystem.exists(path)) {
				Sys.println('$path is missing');
				Sys.exit(1);
			}
		}

		// What was committed is what ships: refuse to package over changes to
		// what would go in, which the archive would silently leave out.
		var status = new sys.io.Process("git", ["status", "--porcelain", "--"].concat(PATHS));
		var dirty:String = StringTools.trim(status.stdout.readAll().toString());
		status.close();
		if (dirty != "") {
			Sys.println("uncommitted changes to what would be packaged:\n" + dirty);
			Sys.exit(1);
		}

		if (!FileSystem.exists("dist")) {
			FileSystem.createDirectory("dist");
		}
		var zip:String = 'dist/crossbyte-$version.zip';
		var code:Int = Sys.command("git", ["-c", "core.autocrlf=false", "archive", "--format=zip", "-9", "-o", zip, "HEAD", "--"].concat(PATHS));
		if (code != 0) {
			Sys.println("git archive failed");
			Sys.exit(code);
		}
		Sys.println('$zip: ${FileSystem.stat(zip).size} bytes');
	}
}
