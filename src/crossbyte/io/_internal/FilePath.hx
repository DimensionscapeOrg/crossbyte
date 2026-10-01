package crossbyte.io._internal;

/**
	Path arithmetic for `File`: strings in, strings out, nothing asked of the
	disk.

	Each function takes the platform's rules as an argument instead of asking
	which machine it runs on, so the Windows forms -- drive letters, UNC
	shares, `\\?\` -- are exercised on Linux too, and the POSIX ones on
	Windows.

	`\` is read as a separator on every platform, as `File.nativePath` reads
	it: a path normalized here with `\` left inside a segment would have it
	turned into a separator by the setter afterwards, and a `..\..` that
	normalization never saw would climb wherever it liked.
**/
class FilePath {
	/**
		Splits `path` into its root -- what `..` can never climb past -- and
		the segments after it, with empty and `.` segments dropped. `..`
		segments are kept as they are: `normalize` decides what they consume.

		Roots, written with the platform's separator:

		- POSIX: `/`. Anything else is relative, and its root is `""`.
		- Windows: a drive, `C:\`, which `C:x` -- relative to drive C's
		  working directory, a per-process setting nothing here can see -- is
		  taken to mean as well; a share, `\\server\share\`, which covers
		  `\\?\C:\` and `\\.\pipe\` too, since they have the same shape; and
		  a bare `\`, the root of whatever drive is current.
	**/
	public static function parse(path:String, windows:Bool):FilePathParts {
		var sep:String = windows ? "\\" : "/";
		var text:String = path == null ? "" : StringTools.replace(StringTools.replace(path, "/", sep), "\\", sep);
		var root:String = "";
		var rest:String = text;

		if (windows) {
			if (StringTools.startsWith(text, "\\\\")) {
				var after:String = text.substr(2);
				var serverEnd:Int = after.indexOf("\\");

				if (serverEnd < 0) {
					root = "\\\\" + after + "\\";
					rest = "";
				} else {
					var server:String = after.substr(0, serverEnd);
					var tail:String = after.substr(serverEnd + 1);
					var shareEnd:Int = tail.indexOf("\\");
					var share:String = shareEnd < 0 ? tail : tail.substr(0, shareEnd);
					root = "\\\\" + server + "\\" + (share == "" ? "" : share + "\\");
					rest = shareEnd < 0 ? "" : tail.substr(shareEnd + 1);
				}
			} else if (text.length >= 2 && text.charAt(1) == ":" && __isLetter(text.charCodeAt(0))) {
				root = text.substr(0, 2) + "\\";
				rest = text.substr(2);
			} else if (StringTools.startsWith(text, "\\")) {
				root = "\\";
				rest = text;
			}
		} else if (StringTools.startsWith(text, "/")) {
			root = "/";
			rest = text;
		}

		var segments:Array<String> = [];

		for (segment in rest.split(sep)) {
			if (segment != "" && segment != ".") {
				segments.push(segment);
			}
		}

		return {root: root, segments: segments};
	}

	/**
		Whether `path` names a place on its own, without a directory to be
		resolved against: it has a root.
	**/
	public static inline function isAbsolute(path:String, windows:Bool):Bool {
		return parse(path, windows).root != "";
	}

	/**
		Applies `..` to `segments`, starting from `start` already in place:
		each consumes the segment before it, and one with nothing left to
		consume above `floor` is ignored. Except on a relative path with no
		floor, whose `..` reaches somewhere the string cannot see -- the
		working directory's parent -- and is kept.

		`stopAt`, when given, is a second floor that is raised as the walk
		passes it: once the segments reach exactly `stopAt`, no `..` climbs
		back out of it. That is the application storage root's rule.
	**/
	public static function walk(start:Array<String>, segments:Array<String>, rooted:Bool, floor:Int, ?stopAt:Array<String>,
			windows:Bool = false):Array<String> {
		var out:Array<String> = start.copy();

		for (segment in segments) {
			if (segment == "..") {
				if (out.length > floor && out[out.length - 1] != "..") {
					out.pop();
				} else if (!rooted && floor == 0) {
					out.push("..");
				}
				continue;
			}

			out.push(segment);

			if (stopAt != null && out.length > floor && out.length == stopAt.length && sameSegments(out, stopAt, windows)) {
				floor = out.length;
			}
		}

		return out;
	}

	/**
		`path` with `.` dropped and each `..` consuming its parent, never past
		the root. A relative path keeps the `..` it cannot resolve.
	**/
	public static function normalize(path:String, windows:Bool):String {
		var parts:FilePathParts = parse(path, windows);
		return join(parts.root, walk([], parts.segments, parts.root != "", 0), windows);
	}

	/** `root` and `segments` as one path, with the platform's separator. **/
	public static function join(root:String, segments:Array<String>, windows:Bool):String {
		var body:String = segments.join(windows ? "\\" : "/");

		if (root == "") {
			return body == "" ? "." : body;
		}

		return root + body;
	}

	/**
		Whether two roots name the same volume. Windows compares drive
		letters and share names without regard to case, as it does.
	**/
	public static function sameRoot(a:String, b:String, windows:Bool):Bool {
		return windows ? a.toLowerCase() == b.toLowerCase() : a == b;
	}

	/**
		Whether two lists of segments are the same, compared the way the
		platform compares names: without regard to case on Windows, exactly
		elsewhere.

		Exactly on macOS as well, although its default volume is
		case-insensitive. This decides whether a path is inside a directory,
		and for that a mismatch must fail closed: a different case reads as
		outside, and is refused, rather than a directory on a case-sensitive
		volume that only differs in case reading as inside.
	**/
	public static function sameSegments(a:Array<String>, b:Array<String>, windows:Bool, count:Int = -1):Bool {
		var n:Int = count < 0 ? a.length : count;

		if (count < 0 && a.length != b.length) {
			return false;
		}

		if (a.length < n || b.length < n) {
			return false;
		}

		for (i in 0...n) {
			if (windows ? a[i].toLowerCase() != b[i].toLowerCase() : a[i] != b[i]) {
				return false;
			}
		}

		return true;
	}

	/**
		How to get from `from` to `to`, as `/`-separated segments, or null.

		Null when the two are on different volumes, whatever `useDotDot`
		says, and when `to` is not `from` or below it and `useDotDot` is
		false. `""` when they are the same place. Both are normalized first,
		and both must be absolute or both relative.
	**/
	public static function relative(from:String, to:String, useDotDot:Bool, windows:Bool):Null<String> {
		var a:FilePathParts = parse(from, windows);
		var b:FilePathParts = parse(to, windows);

		if (!sameRoot(a.root, b.root, windows)) {
			return null;
		}

		var rooted:Bool = a.root != "";
		var fromSegments:Array<String> = walk([], a.segments, rooted, 0);
		var toSegments:Array<String> = walk([], b.segments, rooted, 0);
		var common:Int = 0;

		while (common < fromSegments.length && common < toSegments.length
			&& sameSegments([fromSegments[common]], [toSegments[common]], windows)) {
			common++;
		}

		// A relative path that starts by climbing has no place in common with
		// one that does not: neither says where the working directory is.
		if (!rooted && common < fromSegments.length && fromSegments[common] == "..") {
			return null;
		}

		if (common < fromSegments.length && !useDotDot) {
			return null;
		}

		var out:Array<String> = [];

		for (_ in common...fromSegments.length) {
			out.push("..");
		}

		for (i in common...toSegments.length) {
			out.push(toSegments[i]);
		}

		return out.join("/");
	}

	private static inline function __isLetter(code:Null<Int>):Bool {
		return code != null && ((code >= "A".code && code <= "Z".code) || (code >= "a".code && code <= "z".code));
	}
}

typedef FilePathParts = {
	var root:String;
	var segments:Array<String>;
}
