package crossbyte.test;

#if macro
import haxe.macro.Context;
import sys.FileSystem;
import sys.io.File;

/**
 * Fails the build when a test exists that nothing will run.
 *
 * Six separate times this class of gap shipped here: a case registered in
 * a group no entry point calls; a group unreachable from `addAll`; a case
 * whose body is `#if cpp` sitting only in a group the interpreter runs,
 * so it compiled out where it was registered and was unregistered where
 * it compiled. Every one looked like coverage in the source and executed
 * nothing, and each was found by accident rather than by the harness.
 *
 * A test that never runs is worse than a missing one, because it reads as
 * protection. This turns that into a compile error.
 *
 * Wire it in with `--macro crossbyte.test.SuiteCoverage.check()`.
 */
class SuiteCoverage {
	private static inline var SUITES:String = "tests/crossbyte/test/TestSuites.hx";
	private static inline var ROOT:String = "tests";

	public static function check():Void {
		if (!FileSystem.exists(SUITES) || !FileSystem.exists(ROOT)) {
			// Compiled from somewhere other than the repository root; there
			// is nothing to inspect, and guessing would be worse than
			// staying quiet.
			return;
		}

		var source:String = File.getContent(SUITES);
		var groups:Map<String, GroupBody> = __parseGroups(source);

		var everywhere:Map<String, Bool> = __closure(groups, "addAll");
		var natively:Map<String, Bool> = __closure(groups, "addNativeSmoke");

		var problems:Array<String> = [];

		// A group nothing calls is dead weight that still looks registered.
		for (name in groups.keys()) {
			if (name == "addAll" || name == "addNativeSmoke") {
				continue;
			}
			if (!__isReferenced(groups, name)) {
				problems.push('group $name is defined but no other group calls it, so nothing it registers ever runs');
			}
		}

		for (test in __findTests()) {
			if (test.exempt != null) {
				continue;
			}

			if (!everywhere.exists(test.name)) {
				problems.push('${test.name} extends utest.Test but is registered in no TestSuites group (${test.file}).\n'
					+ '      Register it, or mark the class @:suiteExempt("why") if it is a hand-run harness.');
				continue;
			}

			// The recurring one. A case guarded to cpp that lives only in a
			// group the interpreter runs compiles out where it is
			// registered and is unregistered where it compiles.
			if (test.cppOnly && !natively.exists(test.name)) {
				problems.push('${test.name} has cpp-only conditional code but is not reachable from addNativeSmoke (${test.file}).\n'
					+ '      Its guarded body compiles nowhere it is registered. Add its group to addNativeSmoke, or register the case there directly.');
			}
		}

		if (problems.length > 0) {
			Context.error("Test suite coverage check failed:\n  - " + problems.join("\n  - "), Context.currentPos());
		}
	}

	/**
	 * Splits `TestSuites` into its group functions and records, for each,
	 * the cases it adds and the groups it delegates to.
	 */
	private static function __parseGroups(source:String):Map<String, GroupBody> {
		var groups:Map<String, GroupBody> = new Map();
		var marker:String = "public static function add";
		var parts:Array<String> = source.split(marker);

		for (i in 1...parts.length) {
			var chunk:String = parts[i];
			var open:Int = chunk.indexOf("(");
			if (open < 0) {
				continue;
			}

			var name:String = "add" + chunk.substr(0, open);
			var body:String = chunk;

			var cases:Array<String> = [];
			var addCase:EReg = ~/addCase\(new ([A-Za-z0-9_\.]+)\(\)\)/;
			var rest:String = body;
			while (addCase.match(rest)) {
				cases.push(addCase.matched(1));
				rest = addCase.matchedRight();
			}

			var subs:Array<String> = [];
			var call:EReg = ~/\b(add[A-Z][A-Za-z0-9_]*)\(runner\)/;
			rest = body;
			while (call.match(rest)) {
				subs.push(call.matched(1));
				rest = call.matchedRight();
			}

			groups.set(name, {cases: cases, subs: subs});
		}

		return groups;
	}

	private static function __closure(groups:Map<String, GroupBody>, entry:String):Map<String, Bool> {
		var seen:Map<String, Bool> = new Map();
		var out:Map<String, Bool> = new Map();
		__walk(groups, entry, seen, out);
		return out;
	}

	private static function __walk(groups:Map<String, GroupBody>, name:String, seen:Map<String, Bool>, out:Map<String, Bool>):Void {
		if (seen.exists(name) || !groups.exists(name)) {
			return;
		}
		seen.set(name, true);

		var group:GroupBody = groups.get(name);
		for (c in group.cases) {
			out.set(c, true);
		}
		for (s in group.subs) {
			__walk(groups, s, seen, out);
		}
	}

	private static function __isReferenced(groups:Map<String, GroupBody>, name:String):Bool {
		for (other in groups.keys()) {
			if (other == name) {
				continue;
			}
			for (s in groups.get(other).subs) {
				if (s == name) {
					return true;
				}
			}
		}
		return false;
	}

	private static function __findTests():Array<TestClass> {
		var out:Array<TestClass> = [];
		__scan(ROOT, out);
		return out;
	}

	private static function __scan(directory:String, out:Array<TestClass>):Void {
		for (entry in FileSystem.readDirectory(directory)) {
			var path:String = directory + "/" + entry;
			if (FileSystem.isDirectory(path)) {
				__scan(path, out);
				continue;
			}
			if (entry.length < 3 || entry.substr(entry.length - 3) != ".hx") {
				continue;
			}
			__inspect(path, out);
		}
	}

	private static function __inspect(path:String, out:Array<TestClass>):Void {
		var source:String = File.getContent(path);

		// A UTF-8 BOM ahead of `package` once made a properly registered
		// suite look orphaned, so strip it before matching anything.
		if (source.length > 0 && source.charCodeAt(0) == 0xFEFF) {
			source = source.substr(1);
		}

		var pack:String = "";
		var packageDecl:EReg = ~/(^|\n)[ \t]*package[ \t]+([A-Za-z0-9_\.]+)[ \t]*;/;
		if (packageDecl.match(source)) {
			pack = packageDecl.matched(2) + ".";
		}

		// Conditional code anywhere in the file that only exists on cpp.
		// Deliberately coarse: a guard mentioning cpp and not naming
		// another target is treated as cpp-only, because a false positive
		// costs a registration and a false negative costs a silent gap.
		var cppOnly:Bool = false;
		for (line in source.split("\n")) {
			var trimmed:String = StringTools.trim(line);
			if (trimmed.indexOf("#if") != 0) {
				continue;
			}
			if (trimmed.indexOf("cpp") < 0) {
				continue;
			}
			if (trimmed.indexOf("!cpp") >= 0 || trimmed.indexOf("jvm") >= 0 || trimmed.indexOf("java") >= 0 || trimmed.indexOf("eval") >= 0) {
				continue;
			}
			cppOnly = true;
			break;
		}

		var declaration:EReg = ~/(@:suiteExempt\("([^"]*)"\)[ \t\r\n]*)?class[ \t]+([A-Za-z0-9_]+)[ \t]+extends[ \t]+utest\.Test/;
		var rest:String = source;
		while (declaration.match(rest)) {
			out.push({
				name: pack + declaration.matched(3),
				file: path,
				cppOnly: cppOnly,
				exempt: declaration.matched(2)
			});
			rest = declaration.matchedRight();
		}
	}
}

private typedef GroupBody = {
	var cases:Array<String>;
	var subs:Array<String>;
}

private typedef TestClass = {
	var name:String;
	var file:String;
	var cppOnly:Bool;
	var exempt:Null<String>;
}
#else
/**
 * Compile-time only; see the macro build of this class.
 */
class SuiteCoverage {}
#end
