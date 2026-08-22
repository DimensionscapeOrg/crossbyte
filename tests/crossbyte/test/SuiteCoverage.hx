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
	private static inline var PORTABLE:String = "tests/crossbyte/test/PortableSuite.hx";
	private static inline var SERVER:String = "tests/crossbyte/test/ServerSuite.hx";
	private static inline var ROOT:String = "tests";

	public static function check():Void {
		if (!FileSystem.exists(SUITES) || !FileSystem.exists(ROOT)) {
			// Compiled from somewhere other than the repository root; there
			// is nothing to inspect, and guessing would be worse than
			// staying quiet.
			return;
		}

		// ServerSuite is a group in every sense except which file it is in,
		// and it lives in its own file for a compiler reason rather than an
		// organisational one: a JavaScript build that names TestSuites compiles
		// every group in it, thread locks and poll backends included. Folded in
		// here under its group name so the checks below cannot tell the
		// difference -- otherwise moving cases out of TestSuites would be a way
		// to make them invisible to the very check that exists to find cases
		// nothing runs.
		var source:String = File.getContent(SUITES) + (FileSystem.exists(SERVER) ? __asGroup(File.getContent(SERVER), "addHttpServer") : "");
		source = StringTools.replace(source, "ServerSuite.add(runner)", "addHttpServer(runner)");
		var groups:Map<String, GroupBody> = __parseGroups(source);

		// Every `tests/*Main.hx`, and which groups each one calls. Without
		// this the checker could only see two entry points and believed any
		// group the others called was dead -- while a group a main hand-listed
		// around was invisible to it entirely. `JsTestMain` kept its own copy
		// of the portable set for exactly that reason, and the two drifted.
		var entries:Map<String, Array<String>> = __parseEntryPoints();

		var everywhere:Map<String, Bool> = __closure(groups, "addAll");
		var natively:Map<String, Bool> = __closure(groups, "addNativeSmoke");

		var problems:Array<String> = [];

		// A group nothing calls is dead weight that still looks registered --
		// but "nothing" now includes the entry points, not just other groups.
		for (name in groups.keys()) {
			if (name == "addAll" || name == "addNativeSmoke") {
				continue;
			}
			if (!__isReferenced(groups, name) && !__isCalledByAnEntryPoint(entries, name)) {
				problems.push('group $name is defined but nothing calls it -- no other group, and no tests/*Main.hx -- so nothing it registers ever runs');
			}
		}

		// A main that lists cases itself is a second copy of a group, and a
		// second copy is the thing that drifts. Registering through a named
		// group instead puts the topology in one file the rest of this
		// function can actually read.
		for (main in entries.keys()) {
			var path:String = ROOT + "/" + main + ".hx";

			// Some entry points list cases on purpose: a harness that isolates
			// one group at a time behind `-D subset_*`, a target working around
			// a compiler defect in specific cases, a suite needing a live
			// server. Those say so in metadata, with the reason, rather than
			// being tolerated silently.
			if (__isTopologyExempt(path)) {
				continue;
			}

			var strays:Array<String> = __casesDeclaredIn(path);

			if (strays.length > 0) {
				problems.push('$main registers ${strays.length} case(s) directly (${strays[0]}${strays.length > 1 ? ", ..." : ""}).
'
					+ '      Put them in a TestSuites group and call that instead, so one list describes what runs where.');
			}
		}

		// Anything an entry point runs through a group has to be reachable from
		// addAll too, so no case ends up running on one target and nowhere else.
		for (main in entries.keys()) {
			for (group in entries.get(main)) {
				for (test in __closure(groups, group).keys()) {
					if (!everywhere.exists(test)) {
						problems.push('$test runs from $main via $group but is not reachable from addAll, so no other target runs it');
					}
				}
			}
		}

		// The portable set is a second list by necessity -- naming TestSuites
		// from a JavaScript build compiles groups that reference a listening
		// socket and a thread lock -- so the one thing that keeps it honest is
		// this: it may only name cases the full suite also runs.
		for (test in __casesDeclaredIn(PORTABLE)) {
			if (!everywhere.exists(test)) {
				problems.push('$test is in PortableSuite but not reachable from addAll, so it runs on the JavaScript targets and nowhere else.
'
					+ '      Register it in the TestSuites group for its subsystem as well.');
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

		if (Context.defined("suite_topology")) {
			__report(groups, entries);
		}

		if (problems.length > 0) {
			Context.error("Test suite coverage check failed:\n  - " + problems.join("\n  - "), Context.currentPos());
		}
	}

	/**
	 * Prints which entry points reach each case, under `-D suite_topology`.
	 *
	 * Three times in one week a green run turned out to be a suite that never
	 * compiled the code under test: a case guarded to cpp read on the
	 * interpreter, a case registered in addAll checked against the native
	 * smoke suite, a class the interpreter cannot even reference. Each cost
	 * an hour of reading TestSuites to answer a question the compiler already
	 * knows the answer to. It can simply say.
	 */
	private static function __report(groups:Map<String, GroupBody>, entries:Map<String, Array<String>>):Void {
		var reach:Map<String, Array<String>> = new Map();

		for (main in entries.keys()) {
			for (group in entries.get(main)) {
				for (test in __closure(groups, group).keys()) {
					if (!reach.exists(test)) {
						reach.set(test, []);
					}

					if (reach.get(test).indexOf(main) < 0) {
						reach.get(test).push(main);
					}
				}
			}
		}

		var names:Array<String> = [for (k in reach.keys()) k];
		names.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));

		Sys.println("Test topology -- which entry points run each case:");

		for (name in names) {
			var mains:Array<String> = reach.get(name);
			mains.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
			Sys.println("  " + name + "  <-  " + mains.join(", "));
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

	/**
	 * Renames a satellite suite's single `add` so it parses as a named group.
	 */
	private static function __asGroup(source:String, name:String):String {
		return StringTools.replace(source, "public static function add(", "public static function " + name + "(");
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

	/**
	 * Maps each `tests/*Main.hx` to the TestSuites groups it calls.
	 */
	private static function __parseEntryPoints():Map<String, Array<String>> {
		var out:Map<String, Array<String>> = new Map();

		for (entry in FileSystem.readDirectory(ROOT)) {
			if (entry.length < 7 || entry.substr(entry.length - 7) != "Main.hx") {
				continue;
			}

			var source:String = File.getContent(ROOT + "/" + entry);
			var calls:Array<String> = [];
			var call:EReg = ~/(?:TestSuites\.(add[A-Z][A-Za-z0-9_]*)|PortableSuite\.(add)|ServerSuite\.(add))/;
			var rest:String = source;

			while (call.match(rest)) {
				var matched:String = call.matched(1);

				if (matched != null) {
					calls.push(matched);
				} else {
					// Both are real groups an entry point may call directly;
					// neither is a hand-written list, which is what this
					// function exists to tell apart.
					calls.push(call.matched(2) != null ? "PortableSuite.add" : "addHttpServer");
				}

				rest = call.matchedRight();
			}

			out.set(entry.substr(0, entry.length - 3), calls);
		}

		return out;
	}

	/**
	 * Whether an entry point carries `@:topologyExempt("reason")`.
	 *
	 * The reason is required and never read: it is there so the next person
	 * finds an argument rather than a bare opt-out.
	 */
	private static function __isTopologyExempt(path:String):Bool {
		if (!FileSystem.exists(path)) {
			return false;
		}

		return ~/@:topologyExempt\(\s*"[^"]+"\s*\)/.match(File.getContent(path));
	}

	private static function __isCalledByAnEntryPoint(entries:Map<String, Array<String>>, name:String):Bool {
		for (calls in entries) {
			for (c in calls) {
				if (c == name) {
					return true;
				}
			}
		}

		return false;
	}

	/**
	 * The cases a file registers with a literal `addCase`, which in an entry
	 * point means a list kept outside TestSuites.
	 */
	private static function __casesDeclaredIn(path:String):Array<String> {
		if (!FileSystem.exists(path)) {
			return [];
		}

		var out:Array<String> = [];
		var addCase:EReg = ~/addCase\(new ([A-Za-z0-9_\.]+)\(\)\)/;
		var rest:String = File.getContent(path);

		while (addCase.match(rest)) {
			out.push(addCase.matched(1));
			rest = addCase.matchedRight();
		}

		return out;
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
