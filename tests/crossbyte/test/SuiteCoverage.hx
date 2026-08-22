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
 * The seventh came through the same door from the other side: a case whose
 * body needs jvm, in a class registered under `#if cpp`. Registration and
 * body were each conditional, each read as complete on its own, and nothing
 * asked whether one target satisfied both at once -- so it compiled where it
 * was unregistered and was unregistered where it compiled.
 *
 * So registrations are no longer read as plain text. Each is kept with the
 * conditionals around it and replayed against every target the project builds
 * -- cpp, eval, jvm, js and Node -- and a case that no single target both
 * registers and compiles is an error like the rest. Guards naming a define
 * this cannot decide, `windows` or `subset_io`, are treated as satisfiable
 * everywhere and never fail a build.
 *
 * A test that never runs is worse than a missing one, because it reads as
 * protection. This turns that into a compile error.
 *
 * `-D suite_topology` prints the other half of the answer: which entry points
 * reach each case, and which targets register it.
 *
 * Wire it in with `--macro crossbyte.test.SuiteCoverage.check()`.
 */
class SuiteCoverage {
	private static inline var SUITES:String = "tests/crossbyte/test/TestSuites.hx";
	private static inline var PORTABLE:String = "tests/crossbyte/test/PortableSuite.hx";
	private static inline var SERVER:String = "tests/crossbyte/test/ServerSuite.hx";
	private static inline var ROOT:String = "tests";

	// The identifiers this checker will decide. Anything outside it --
	// `windows`, `final`, `subset_io` -- is left undecided on purpose: an
	// undecided guard counts as satisfiable everywhere, and so never fails a
	// build. That costs gaps this cannot see; deciding a define it had
	// misread would cost a build broken over nothing.
	private static inline var DECIDABLE:String = ",cpp,hxcpp,eval,interp,java,jvm,js,nodejs,sys,target.sys,neko,hl,php,python,lua,cs,flash,html5,air,static,";

	private static inline var NO:Int = 0;
	private static inline var YES:Int = 1;
	private static inline var MAYBE:Int = 2;

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
		var entries:Map<String, Array<Registration>> = __parseEntryPoints(groups);

		var everywhere:Map<String, Bool> = __closure(groups, "addAll");
		var natively:Map<String, Bool> = __closure(groups, "addNativeSmoke");

		// What each target registers, as opposed to what the source reads as
		// registering. Every check above this line is deliberately blind to
		// `#if`: they ask whether a name appears in a group at all, which is the
		// right question for "is this wired up". It is the wrong question for
		// "does this run", and the gap between the two is where a case hides.
		var worlds:Array<World> = __worlds();
		var direct:Array<Registration> = __directCases();
		var registered:Map<String, Map<String, Bool>> = new Map();

		for (world in worlds) {
			registered.set(world.name, __registeredIn(groups, entries, direct, world.defines));
		}

		var problems:Array<String> = [];

		// Everything below reads conditionals off whole lines. If a suite file
		// opened one inline and never closed it there, the guards recorded
		// above are wrong -- and wrong guards are worse than none, so say so
		// and skip the checks that would be drawn from them.
		var readable:Bool = __lines(source).sound;

		if (!readable) {
			problems.push('the suite files have a `#if`, `#else` or `#end` sharing a line with code without being closed on it.\n'
				+ '      Put the directive on a line of its own, so which targets register each case can be read off the file.');
		}

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
				for (test in __closure(groups, group.name).keys()) {
					if (!everywhere.exists(test)) {
						problems.push('$test runs from $main via ${group.name} but is not reachable from addAll, so no other target runs it');
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

			if (!readable) {
				// The suite files did not parse, which is already in the list.
				// Per-case verdicts drawn from a bad parse would only bury it.
				continue;
			}

			if (!test.sound) {
				problems.push('${test.file} has a conditional this check cannot follow: a `#if`, `#else` or `#end` shares a line with code without being closed on it.\n'
					+ '      Put the directive on a line of its own, so which targets reach each case can be read off the file.');
				continue;
			}

			// The seventh, and the first none of the checks above could have
			// found. Registration and body are each conditional, and each reads
			// as complete on its own: the class is registered here, the case is
			// written there. Nothing asked whether one target satisfies both at
			// once -- and ServerSocketTLSTest did not. Its `#else` branch held a
			// case that compiles only on jvm, inside a class registered only
			// under `#if cpp`, so it compiled where it was unregistered and was
			// unregistered where it compiled. The cpp check just above cannot see
			// that: it is this one inverted.
			var dead:Dead = __unreachable(test, worlds, registered);

			if (dead.registers.length == 0) {
				problems.push('${test.name} is registered only behind a conditional that no target the project builds satisfies (${test.file}).\n'
					+ '      Nothing in it runs anywhere. Widen the guard on its registration, or delete the class.');
				continue;
			}

			for (unreached in dead.cases) {
				problems.push('${test.name}.${unreached.name} runs on no target (${test.file}).\n'
					+ '      Its class is registered on ' + dead.registers.join(", ") + ', and its body compiles on '
					+ (unreached.compiles.length == 0 ? "no target at all" : unreached.compiles.join(", ")) + '.\n'
					+ '      Those do not overlap, so it compiles out wherever it is registered. Register the class where the body compiles, or widen the guard on the body.');
			}
		}

		if (Context.defined("suite_topology")) {
			__report(groups, entries, worlds, registered);
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
	private static function __report(groups:Map<String, GroupBody>, entries:Map<String, Array<Registration>>, worlds:Array<World>,
			registered:Map<String, Map<String, Bool>>):Void {
		var reach:Map<String, Array<String>> = new Map();

		for (main in entries.keys()) {
			for (group in entries.get(main)) {
				for (test in __closure(groups, group.name).keys()) {
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

		Sys.println("Test topology -- which entry points run each case, and which targets register it:");

		for (name in names) {
			var mains:Array<String> = reach.get(name);
			mains.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));

			var targets:Array<String> = [];

			for (world in worlds) {
				if (registered.get(world.name).exists(name)) {
					targets.push(world.name);
				}
			}

			Sys.println("  " + name + "  <-  " + mains.join(", ") + "  [" + (targets.length == 0 ? "no target" : targets.join(", ")) + "]");
		}
	}

	/**
	 * Splits `TestSuites` into its group functions and records, for each,
	 * the cases it adds and the groups it delegates to -- each with the
	 * conditionals it sits inside.
	 *
	 * Those conditionals are the whole reason this reads line by line rather
	 * than regexing a group's text in one go. `addCase(new X())` inside
	 * `#if cpp` and the same line outside it are indistinguishable to a
	 * regex over the body, and telling them apart is what makes "which
	 * targets actually register this" an answerable question.
	 */
	private static function __parseGroups(source:String):Map<String, GroupBody> {
		var groups:Map<String, GroupBody> = new Map();
		var declaration:EReg = ~/public static function (add[A-Za-z0-9_]*)[ \t]*\(/;
		var addCase:EReg = ~/addCase\(new ([A-Za-z0-9_\.]+)\(\)\)/;
		var call:EReg = ~/\b(add[A-Z][A-Za-z0-9_]*)\(runner\)/;
		var current:String = null;

		for (line in __lines(source).lines) {
			if (declaration.match(line.text)) {
				current = declaration.matched(1);

				if (!groups.exists(current)) {
					groups.set(current, {cases: [], subs: []});
				}

				continue;
			}

			if (current == null) {
				continue;
			}

			var group:GroupBody = groups.get(current);
			var rest:String = line.text;

			while (addCase.match(rest)) {
				group.cases.push({name: addCase.matched(1), cond: line.cond});
				rest = addCase.matchedRight();
			}

			rest = line.text;

			while (call.match(rest)) {
				var name:String = call.matched(1);

				// A group calling itself is not a delegation; __walk would
				// stop on it anyway, and __isReferenced already discounts it.
				if (name != current) {
					group.subs.push({name: name, cond: line.cond});
				}

				rest = call.matchedRight();
			}
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
			out.set(c.name, true);
		}
		for (s in group.subs) {
			__walk(groups, s.name, seen, out);
		}
	}

	/**
	 * Maps each `tests/*Main.hx` to the TestSuites groups it calls.
	 */
	private static function __parseEntryPoints(groups:Map<String, GroupBody>):Map<String, Array<Registration>> {
		var out:Map<String, Array<Registration>> = new Map();

		for (entry in FileSystem.readDirectory(ROOT)) {
			if (entry.length < 7 || entry.substr(entry.length - 7) != "Main.hx") {
				continue;
			}

			var calls:Array<Registration> = [];
			var call:EReg = ~/(?:TestSuites\.(add[A-Z][A-Za-z0-9_]*)|PortableSuite\.(add)|ServerSuite\.(add))/;

			for (line in __lines(File.getContent(ROOT + "/" + entry)).lines) {
				var rest:String = line.text;

				while (call.match(rest)) {
					var matched:String = call.matched(1);

					if (matched != null) {
						calls.push({name: matched, cond: line.cond});
					} else {
						// Both are real groups an entry point may call directly;
						// neither is a hand-written list, which is what this
						// function exists to tell apart.
						calls.push({name: call.matched(2) != null ? "PortableSuite.add" : "addHttpServer", cond: line.cond});
					}

					rest = call.matchedRight();
				}
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

	private static function __isCalledByAnEntryPoint(entries:Map<String, Array<Registration>>, name:String):Bool {
		for (calls in entries) {
			for (c in calls) {
				if (c.name == name) {
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
				if (s.name == name) {
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

		// The class, and every case in it, each with the conditionals around
		// it. Line by line for the same reason __parseGroups is: a case in an
		// `#else` and a case outside one are the same text to a regex, and
		// telling them apart is the point.
		var guarded:GuardedSource = __lines(source);
		var declaration:EReg = ~/class[ \t]+([A-Za-z0-9_]+)[ \t]+extends[ \t]+utest\.Test/;
		var exemption:EReg = ~/@:suiteExempt\("([^"]*)"\)/;
		var method:EReg = ~/public[ \t]+function[ \t]+(test[A-Za-z0-9_]*)[ \t]*\(/;
		var current:TestClass = null;
		var previous:String = "";

		for (line in guarded.lines) {
			if (declaration.match(line.text)) {
				var exempt:Null<String> = null;

				// It is written on the line above the class it exempts, or on
				// the same one.
				if (exemption.match(line.text) || exemption.match(previous)) {
					exempt = exemption.matched(1);
				}

				current = {
					name: pack + declaration.matched(1),
					file: path,
					cppOnly: cppOnly,
					exempt: exempt,
					cond: line.cond,
					methods: [],
					sound: guarded.sound
				};

				out.push(current);
			} else if (current != null && method.match(line.text)) {
				current.methods.push({name: method.matched(1), cond: line.cond});
			}

			previous = line.text;
		}
	}

	/**
	 * The targets this project builds, and what each one defines.
	 *
	 * Five, because ci/*.hxml names exactly five: --cpp, --jvm, --js for the
	 * browser and for Node, and --interp. A case has to be registered and
	 * compiled by one and the same target; the ones where no single target
	 * does both are what this list exists to find.
	 */
	private static function __worlds():Array<World> {
		return [
			__world("cpp", ["cpp", "hxcpp", "sys", "target.sys"]),
			__world("eval", ["eval", "interp", "sys", "target.sys"]),
			__world("jvm", ["java", "jvm", "sys", "target.sys"]),
			__world("js", ["js"]),
			__world("nodejs", ["js", "nodejs", "sys", "target.sys"])
		];
	}

	private static function __world(name:String, defines:Array<String>):World {
		var out:Map<String, Bool> = new Map();

		for (define in defines) {
			out.set(define, true);
		}

		return {name: name, defines: out};
	}

	/**
	 * The cases one target registers, following only the registrations its
	 * defines allow.
	 */
	private static function __registeredIn(groups:Map<String, GroupBody>, entries:Map<String, Array<Registration>>, direct:Array<Registration>,
			defines:Map<String, Bool>):Map<String, Bool> {
		var out:Map<String, Bool> = new Map();

		for (calls in entries) {
			for (call in calls) {
				if (__possible(call.cond, defines)) {
					__walkIn(groups, call.name, defines, new Map(), out);
				}
			}
		}

		for (registration in direct) {
			if (__possible(registration.cond, defines)) {
				out.set(registration.name, true);
			}
		}

		return out;
	}

	/**
	 * __walk, minus the registrations this target's defines rule out.
	 *
	 * That subtraction is the whole difference between "appears in a group"
	 * and "runs", and the space between the two is where cases have hidden.
	 */
	private static function __walkIn(groups:Map<String, GroupBody>, name:String, defines:Map<String, Bool>, seen:Map<String, Bool>,
			out:Map<String, Bool>):Void {
		if (seen.exists(name) || !groups.exists(name)) {
			return;
		}

		seen.set(name, true);

		var group:GroupBody = groups.get(name);

		for (c in group.cases) {
			if (__possible(c.cond, defines)) {
				out.set(c.name, true);
			}
		}

		for (s in group.subs) {
			if (__possible(s.cond, defines)) {
				__walkIn(groups, s.name, defines, seen, out);
			}
		}
	}

	/**
	 * Cases an entry point registers itself rather than through a group.
	 *
	 * `__casesDeclaredIn` answers nearly this question and is left alone: the
	 * check it feeds -- "this main keeps its own list" -- does not care which
	 * target the list is for. This walk does, so it needs the guards too.
	 */
	private static function __directCases():Array<Registration> {
		var out:Array<Registration> = [];
		var addCase:EReg = ~/addCase\(new ([A-Za-z0-9_\.]+)\(\)\)/;

		for (entry in FileSystem.readDirectory(ROOT)) {
			if (entry.length < 7 || entry.substr(entry.length - 7) != "Main.hx") {
				continue;
			}

			for (line in __lines(File.getContent(ROOT + "/" + entry)).lines) {
				var rest:String = line.text;

				while (addCase.match(rest)) {
					out.push({name: addCase.matched(1), cond: line.cond});
					rest = addCase.matchedRight();
				}
			}
		}

		return out;
	}

	/**
	 * The cases in a class that no one target both registers and compiles.
	 *
	 * Both halves are put to the same target rather than to each other, which
	 * is the only way to show that where a case is registered and where it
	 * compiles ever meet.
	 */
	private static function __unreachable(test:TestClass, worlds:Array<World>, registered:Map<String, Map<String, Bool>>):Dead {
		var registers:Array<String> = [];
		var live:Array<World> = [];

		for (world in worlds) {
			if (__possible(test.cond, world.defines) && registered.get(world.name).exists(test.name)) {
				registers.push(world.name);
				live.push(world);
			}
		}

		var cases:Array<DeadCase> = [];

		for (method in test.methods) {
			var runs:Bool = false;

			for (world in live) {
				if (__possible(method.cond, world.defines)) {
					runs = true;
					break;
				}
			}

			if (runs) {
				continue;
			}

			// Where it would have run had something registered it there. This is
			// the half of the message that says what to do about it.
			var compiles:Array<String> = [];

			for (world in worlds) {
				if (__possible(test.cond, world.defines) && __possible(method.cond, world.defines)) {
					compiles.push(world.name);
				}
			}

			cases.push({name: method.name, compiles: compiles});
		}

		return {registers: registers, cases: cases};
	}

	/**
	 * Every line of a file paired with the conditionals it sits inside, an
	 * `#else` carrying the negation of the branches before it.
	 *
	 * Directives are read only where they begin a line, which is how they are
	 * written throughout this suite. A balanced inline `#if a x #else y #end`
	 * is left alone and is harmless; an unbalanced one would quietly shift
	 * every guard after it, so the stack is checked and `sound` reports the
	 * answer rather than the caller assuming it.
	 */
	private static function __lines(source:String):GuardedSource {
		var out:Array<GuardedLine> = [];
		var stack:Array<Frame> = [];
		var sound:Bool = true;

		for (line in source.split("\n")) {
			var directive:String = StringTools.trim(line);
			var comment:Int = directive.indexOf("//");

			if (comment >= 0) {
				directive = StringTools.trim(directive.substr(0, comment));
			}

			// `#elseif` before `#else`, which is a prefix of it.
			if (StringTools.startsWith(directive, "#elseif")) {
				if (stack.length == 0) {
					sound = false;
					continue;
				}

				var branch:String = StringTools.trim(directive.substr(7));
				var frame:Frame = stack[stack.length - 1];
				frame.cur = __negate(frame.seen);
				frame.cur.push({expr: branch, negated: false});
				frame.seen.push(branch);
				continue;
			}

			if (StringTools.startsWith(directive, "#if")) {
				var opened:String = StringTools.trim(directive.substr(3));
				stack.push({cur: [{expr: opened, negated: false}], seen: [opened]});
				continue;
			}

			if (directive == "#else") {
				if (stack.length == 0) {
					sound = false;
					continue;
				}

				stack[stack.length - 1].cur = __negate(stack[stack.length - 1].seen);
				continue;
			}

			if (directive == "#end") {
				if (stack.length == 0) {
					sound = false;
					continue;
				}

				stack.pop();
				continue;
			}

			var cond:Array<Guard> = [];

			for (frame in stack) {
				for (guard in frame.cur) {
					cond.push(guard);
				}
			}

			out.push({text: line, cond: cond});
		}

		return {lines: out, sound: sound && stack.length == 0};
	}

	private static function __negate(exprs:Array<String>):Array<Guard> {
		var out:Array<Guard> = [];

		for (expr in exprs) {
			out.push({expr: expr, negated: true});
		}

		return out;
	}

	/**
	 * Whether a target can satisfy every conditional a line sits inside.
	 *
	 * A guard this cannot decide counts as satisfiable, so the answer is "no"
	 * only where the target genuinely rules the line out. A gap missed that
	 * way costs a case that still runs somewhere else; a wrong "no" would cost
	 * a build broken over a define the checker misread.
	 */
	private static function __possible(cond:Array<Guard>, defines:Map<String, Bool>):Bool {
		for (guard in cond) {
			var value:Int = __evaluate(guard.expr, defines);

			if (guard.negated) {
				value = __not(value);
			}

			if (value == NO) {
				return false;
			}
		}

		return true;
	}

	private static function __not(value:Int):Int {
		return value == MAYBE ? MAYBE : (value == YES ? NO : YES);
	}

	private static function __evaluate(expr:String, defines:Map<String, Bool>):Int {
		return __any({tokens: __tokens(expr), pos: 0}, defines);
	}

	private static function __any(cursor:Cursor, defines:Map<String, Bool>):Int {
		var value:Int = __all(cursor, defines);

		while (__peek(cursor) == "||") {
			cursor.pos++;
			var right:Int = __all(cursor, defines);
			value = (value == YES || right == YES) ? YES : ((value == MAYBE || right == MAYBE) ? MAYBE : NO);
		}

		return value;
	}

	private static function __all(cursor:Cursor, defines:Map<String, Bool>):Int {
		var value:Int = __unary(cursor, defines);

		while (__peek(cursor) == "&&") {
			cursor.pos++;
			var right:Int = __unary(cursor, defines);
			value = (value == NO || right == NO) ? NO : ((value == MAYBE || right == MAYBE) ? MAYBE : YES);
		}

		return value;
	}

	private static function __unary(cursor:Cursor, defines:Map<String, Bool>):Int {
		var token:String = __peek(cursor);

		if (token == null) {
			return MAYBE;
		}

		cursor.pos++;

		if (token == "!") {
			return __not(__unary(cursor, defines));
		}

		if (token == "(") {
			var value:Int = __any(cursor, defines);

			if (__peek(cursor) == ")") {
				cursor.pos++;
			}

			return value;
		}

		if (!__isName(token)) {
			return MAYBE;
		}

		// `haxe_ver >= 4` and its kin: step over the comparison rather than
		// pretend to decide it.
		var next:String = __peek(cursor);

		if (next == ">=" || next == "<=" || next == "==" || next == "!=" || next == ">" || next == "<") {
			cursor.pos += 2;
			return MAYBE;
		}

		if (DECIDABLE.indexOf("," + token + ",") < 0) {
			return MAYBE;
		}

		return defines.exists(token) ? YES : NO;
	}

	private static function __peek(cursor:Cursor):String {
		return cursor.pos < cursor.tokens.length ? cursor.tokens[cursor.pos] : null;
	}

	private static function __isName(token:String):Bool {
		var code:Int = token.charCodeAt(0);
		return (code >= "a".code && code <= "z".code) || (code >= "A".code && code <= "Z".code) || code == "_".code;
	}

	/**
	 * Splits a `#if` expression into names, operators and parentheses.
	 */
	private static function __tokens(expr:String):Array<String> {
		var out:Array<String> = [];
		var i:Int = 0;

		while (i < expr.length) {
			var c:String = expr.charAt(i);

			if (c == " " || c == "\t" || c == "\r") {
				i++;
				continue;
			}

			if (c == "(" || c == ")") {
				out.push(c);
				i++;
				continue;
			}

			if (c == "&" || c == "|") {
				var doubled:Bool = expr.charAt(i + 1) == c;
				out.push(doubled ? c + c : c);
				i += doubled ? 2 : 1;
				continue;
			}

			if (c == "!" || c == ">" || c == "<" || c == "=") {
				if (expr.charAt(i + 1) == "=") {
					out.push(c + "=");
					i += 2;
				} else {
					out.push(c);
					i++;
				}

				continue;
			}

			var word:String = "";

			while (i < expr.length) {
				var code:Int = expr.charCodeAt(i);
				var part:Bool = (code >= "a".code && code <= "z".code)
					|| (code >= "A".code && code <= "Z".code)
					|| (code >= "0".code && code <= "9".code)
					|| code == "_".code
					|| code == ".".code;

				if (!part) {
					break;
				}

				word += expr.charAt(i);
				i++;
			}

			if (word == "") {
				// Something not modelled here -- a string literal, say. Emit it
				// anyway, so the parser meets a token it cannot name and answers
				// "maybe".
				out.push(c);
				i++;
			} else {
				out.push(word);
			}
		}

		return out;
	}
}

private typedef GroupBody = {
	var cases:Array<Registration>;
	var subs:Array<Registration>;
}

private typedef TestClass = {
	var name:String;
	var file:String;
	var cppOnly:Bool;
	var exempt:Null<String>;
	var cond:Array<Guard>;
	var methods:Array<Registration>;
	var sound:Bool;
}

/**
 * One `#if` a line sits inside, and whether the line is in a branch that
 * negates it.
 */
private typedef Guard = {
	var expr:String;
	var negated:Bool;
}

/**
 * A name written down somewhere, and the conditionals around where it is
 * written.
 */
private typedef Registration = {
	var name:String;
	var cond:Array<Guard>;
}

/**
 * A target the project builds, and the defines it compiles with.
 */
private typedef World = {
	var name:String;
	var defines:Map<String, Bool>;
}

private typedef GuardedLine = {
	var text:String;
	var cond:Array<Guard>;
}

/**
 * A file's lines with their guards, and whether its conditionals balanced --
 * if they did not, the guards are not to be trusted.
 */
private typedef GuardedSource = {
	var lines:Array<GuardedLine>;
	var sound:Bool;
}

/**
 * One `#if` being read: the branch open right now, and every branch condition
 * seen so far, which is what its `#else` has to negate.
 */
private typedef Frame = {
	var cur:Array<Guard>;
	var seen:Array<String>;
}

private typedef Cursor = {
	var tokens:Array<String>;
	var pos:Int;
}

/**
 * What a class does not run: the targets that do register it, and the cases
 * none of those targets compile.
 */
private typedef Dead = {
	var registers:Array<String>;
	var cases:Array<DeadCase>;
}

private typedef DeadCase = {
	var name:String;
	var compiles:Array<String>;
}
#else
/**
 * Compile-time only; see the macro build of this class.
 */
class SuiteCoverage {}
#end
