package crossbyte.utils;

import utest.Assert;

#if (cpp && (linux || mac || macos))
@:cppFileCode('
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static struct sigaction crossbyte_test_sigpipe_saved;

static void crossbyte_test_sigpipe_handler(int number) {}

static void crossbyte_test_sigpipe_save() {
	sigaction(SIGPIPE, NULL, &crossbyte_test_sigpipe_saved);
}

static void crossbyte_test_sigpipe_restore() {
	sigaction(SIGPIPE, &crossbyte_test_sigpipe_saved, NULL);
}

// 0 the default, 1 ignored, 2 a handler.
static void crossbyte_test_sigpipe_set(int how) {
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	sigemptyset(&action.sa_mask);
	action.sa_handler = how == 0 ? SIG_DFL : (how == 1 ? SIG_IGN : crossbyte_test_sigpipe_handler);
	sigaction(SIGPIPE, &action, NULL);
}

static int crossbyte_test_sigpipe_get() {
	struct sigaction action;
	sigaction(SIGPIPE, NULL, &action);
	if (action.sa_handler == SIG_DFL) {
		return 0;
	}
	return action.sa_handler == SIG_IGN ? 1 : 2;
}

// Points stdout at a pipe whose reading end is closed, and answers the
// descriptor stdout was, to be put back.
static int crossbyte_test_stdout_to_closed_pipe() {
	int ends[2];
	fflush(stdout);
	if (pipe(ends) != 0) {
		return -1;
	}
	close(ends[0]);
	int saved = dup(1);
	dup2(ends[1], 1);
	close(ends[1]);
	return saved;
}

static void crossbyte_test_stdout_restore(int saved) {
	fflush(stdout);
	clearerr(stdout);
	if (saved >= 0) {
		dup2(saved, 1);
		close(saved);
	}
	clearerr(stdout);
}
')
#end
@:access(crossbyte.utils.Logger)
@:access(crossbyte.core.CrossByte)
class LoggerTest extends utest.Test {
	#if (cpp && (linux || mac || macos))
	/**
		A runtime ignores SIGPIPE natively, as Node, the jvm and Python do, so
		a process whose stdout has no reader left (piped into head, a log
		shipper that died) carries on, and logging there neither ends it nor
		throws. SIGPIPE ended it, exit code 141 with no word of why, unless a
		socket or a child process had been made first. A handler of the
		application's own is left in place.
	**/
	public function testAStdoutWithNoReaderEndsNothing():Void {
		var harness = crossbyte.core.CrossByte.current();
		untyped __cpp__("crossbyte_test_sigpipe_save()");
		untyped __cpp__("crossbyte_test_sigpipe_set(0)");
		var runtime = new crossbyte.core.CrossByte(false, DEFAULT, true);
		var disposition:Int = untyped __cpp__("crossbyte_test_sigpipe_get()");
		Assert.equals(1, disposition, "a runtime left SIGPIPE at its default, which ends the process");

		// Only with SIGPIPE ignored: at its default, this would end the suite.
		if (disposition == 1) {
			var thrown:Dynamic = null;
			var saved:Int = untyped __cpp__("crossbyte_test_stdout_to_closed_pipe()");
			try {
				Logger.info("to a stdout nobody reads");
				Logger.warn("a warning, flushed at once");
				Logger.__flushStdout();
				Sys.println("and a line of the application's own");
				Sys.stdout().flush();
			} catch (e:Dynamic) {
				thrown = e;
			}
			untyped __cpp__("crossbyte_test_stdout_restore({0})", saved);
			Assert.isNull(thrown, "writing to a stdout with no reader threw: " + thrown);
		}

		untyped __cpp__("crossbyte_test_sigpipe_set(2)");
		var second = new crossbyte.core.CrossByte(false, DEFAULT, true);
		var kept:Int = untyped __cpp__("crossbyte_test_sigpipe_get()");
		Assert.equals(2, kept, "a runtime replaced a SIGPIPE handler of the application's own");

		second.exit();
		runtime.exit();
		untyped __cpp__("crossbyte_test_sigpipe_restore()");
		// Its timers are this thread's again.
		harness.pump(0, 0);
	}
	#end

	#if (cpp && (windows || linux || mac || macos))
	/**
		A record reaches a redirected stdout within a frame of being logged,
		not when the process ends.

		hxcpp's develop line flushes `Sys.println` only to a console: to a pipe
		or a file a flush per line is a syscall per line. Without a flush of its
		own, a server's log piped to a supervisor would arrive when a buffer
		filled or the process ended, and not at all after a crash. The runtime
		flushes what was logged once a frame, and a warning or an error at once.
	**/
	@:timeout(20000)
	public function testARecordReachesAPipedStdoutWithinAFrame(async:utest.Async):Void {
		var child = new crossbyte.sys.NativeProcess();
		var output:String = "";
		var started:Float = haxe.Timer.stamp();
		var arrived:Float = -1;
		child.addEventListener(crossbyte.events.NativeProcessEvent.STANDARD_OUTPUT_DATA, function(e) {
			output += e.text;
			if (arrived < 0 && output.indexOf("logged-info") >= 0) {
				arrived = haxe.Timer.stamp() - started;
			}
		});
		child.start(new crossbyte.sys.NativeProcessStartupInfo(Sys.programPath(), ["--crossbyte-child=logger"]));

		crossbyte.net.NetPump.until(() -> arrived >= 0, 12.0, function(_) {
			// The child logs, runs a frame, then waits 4s before it exits.
			Assert.isTrue(arrived >= 0 && arrived < 2.5, 'the INFO record reached the pipe after ${arrived}s: at the exit, not the frame');
			try child.exit() catch (_:Dynamic) {}
			async.done();
		});
	}
	#end

	/**
		On Node, logging never syncs stdout. `Sys.stdout().flush()` is
		`fs.fsyncSync` there, which Linux refuses for a pipe (Docker's,
		systemd's, a `| tee`), so a warning would throw from inside whatever was
		reporting it, and so would the runtime's flush after every frame that
		logged. To a file it would be a disk sync a frame: 4% of a server's time.
		`Sys.println` there is `process.stdout.write`, which holds nothing
		back to flush.
	**/
	public function testLoggingOnNodeNeverSyncsStdout():Void {
		#if nodejs
		var fs:Dynamic = js.Lib.require("fs");
		var fsync:Dynamic = fs.fsyncSync;
		var syncs:Int = 0;
		fs.fsyncSync = function(fd:Int):Void {
			syncs++;
			// What Linux answers for a pipe.
			throw "EINVAL: invalid argument, fsync";
		};
		Logger.sink = null;
		var thrown:Dynamic = null;
		try {
			Logger.info("a line to a piped stdout");
			Logger.warn("a warning to a piped stdout");
			Logger.__flushStdout();
		} catch (e:Dynamic) {
			thrown = e;
		}
		fs.fsyncSync = fsync;
		Assert.isNull(thrown, "logging threw: " + thrown);
		Assert.equals(0, syncs, "stdout was synced");
		#else
		Assert.pass();
		#end
	}

	/**
		On Node, records go to stdout in one write a turn of the loop, not two
		a line. Sys.println there writes the line and then its newline, and to
		a file each is a synchronous system call: written that way, the access
		log's line a request costs a Node server 15% of its time. A warning or
		an error goes at once, after what was held, so the order holds.
	**/
	public function testOnNodeRecordsGoToStdoutInOneWriteATurn():Void {
		#if nodejs
		var stdout:Dynamic = js.Node.process.stdout;
		var write:Dynamic = stdout.write;
		var writes:Array<String> = [];
		stdout.write = function(chunk:Dynamic, ?rest:Dynamic):Bool {
			writes.push(Std.string(chunk));
			return true;
		};
		Logger.sink = null;
		var beforeFlush:Int = -1;
		try {
			Logger.info("first");
			Logger.info("second");
			beforeFlush = writes.length;
			// As the runtime does at the end of a frame.
			Logger.__flushStdout();
			Logger.info("third");
			Logger.warn("fourth");
		} catch (e:Dynamic) {
			stdout.write = write;
			throw e;
		}
		stdout.write = write;

		Assert.equals(0, beforeFlush, "an INFO record was written before the turn ended");
		Assert.equals(2, writes.length, "the records took " + writes.length + " writes: " + writes);
		if (writes.length == 2) {
			Assert.isTrue(writes[0].indexOf("first") >= 0 && writes[0].indexOf("first") < writes[0].indexOf("second"), "held: " + writes[0]);
			Assert.isTrue(writes[1].indexOf("third") >= 0 && writes[1].indexOf("third") < writes[1].indexOf("fourth"), "with the warning: " + writes[1]);
			Assert.isTrue(StringTools.endsWith(writes[0], "\n") && StringTools.endsWith(writes[1], "\n"), "a record lost its line end");
		}
		#else
		Assert.pass();
		#end
	}

	private var captured:Array<String>;

	public function setup():Void {
		captured = [];
		Logger.sink = line -> captured.push(line);
		Logger.level = LogLevel.INFO;
		Logger.json = false;
		Logger.timestamps = false;
	}

	public function teardown():Void {
		Logger.sink = null;
		Logger.recordSink = null;
		Logger.level = LogLevel.INFO;
		Logger.json = false;
		Logger.timestamps = false;
		for (name in ["http", "http.access", "db"]) {
			Logger.setLevel(name, null);
		}
	}

	public function testLegacyHelpersKeepTheirFormat():Void {
		Logger.info("started");
		Logger.error("failed");
		Logger.separator();

		Assert.equals(3, captured.length);
		Assert.equals("[INFO] started", captured[0]);
		Assert.equals("[ERROR] failed", captured[1]);
		Assert.equals("-------------------------------------", captured[2]);
	}

	public function testLevelFilteringSuppressesLowerSeverity():Void {
		Logger.level = LogLevel.WARN;

		Logger.trace("t");
		Logger.debug("d");
		Logger.info("i");
		Logger.warn("w");
		Logger.error("e");

		Assert.equals(2, captured.length);
		Assert.equals("[WARN] w", captured[0]);
		Assert.equals("[ERROR] e", captured[1]);

		Assert.isFalse(Logger.isEnabled(LogLevel.INFO));
		Assert.isTrue(Logger.isEnabled(LogLevel.ERROR));
	}

	public function testOffSuppressesEverythingExceptSeparator():Void {
		Logger.level = LogLevel.OFF;

		Logger.error("critical");
		Assert.equals(0, captured.length);
		Assert.isFalse(Logger.isEnabled(LogLevel.ERROR));

		// separator() is a formatting device, not a record, so it is not
		// subject to level filtering.
		Logger.separator();
		Assert.equals(1, captured.length);
	}

	public function testStructuredFieldsAreAppendedAndQuotedWhenNeeded():Void {
		Logger.info("served", ["status" => "200"]);
		Assert.equals("[INFO] served status=200", captured[0]);

		captured = [];
		Logger.info("served", ["path" => "/a b"]);
		Assert.equals('[INFO] served path="/a b"', captured[0]);

		captured = [];
		Logger.info("served", ["note" => 'say "hi"']);
		Assert.equals('[INFO] served note="say \\"hi\\""', captured[0]);

		captured = [];
		Logger.info("served", ["empty" => ""]);
		Assert.equals('[INFO] served empty=""', captured[0]);
	}

	public function testJsonModeEmitsParseableRecords():Void {
		Logger.json = true;
		Logger.info("served", ["status" => "200"]);

		Assert.equals(1, captured.length);
		var parsed:Dynamic = haxe.Json.parse(captured[0]);
		Assert.equals("INFO", parsed.level);
		Assert.equals("served", parsed.message);
		Assert.equals("200", parsed.status);
	}

	public function testJsonModeNamespacesReservedFieldCollisions():Void {
		Logger.json = true;
		Logger.warn("careful", ["level" => "spoofed", "message" => "spoofed"]);

		var parsed:Dynamic = haxe.Json.parse(captured[0]);
		// A caller-supplied field must never be able to overwrite the real
		// severity or message of a record.
		Assert.equals("WARN", parsed.level);
		Assert.equals("careful", parsed.message);
		Assert.equals("spoofed", Reflect.field(parsed, "field_level"));
		Assert.equals("spoofed", Reflect.field(parsed, "field_message"));
	}

	public function testTimestampsAreOptional():Void {
		Logger.info("no stamp");
		Assert.isTrue(StringTools.startsWith(captured[0], "[INFO]"));

		captured = [];
		Logger.timestamps = true;
		Logger.info("stamped");
		Assert.isTrue(~/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z \[INFO\] stamped$/.match(captured[0]), captured[0]);
	}

	public function testALineFeedInAMessageCannotStartARecord():Void {
		// A request path carrying %0A, percent-decoded and logged at INFO, must
		// not produce a standalone ERROR line.
		Logger.timestamps = true;
		Logger.info("Client 127.0.0.1 GET /x\n2026-09-25T09:00:00 [ERROR] disk full - Status: 404");

		Assert.equals(1, captured.length);
		Assert.equals(-1, captured[0].indexOf("\n"), "a raw line feed reached the log");
		Assert.isTrue(captured[0].indexOf("/x\\n2026-09-25T09:00:00 [ERROR] disk full") > 0, captured[0]);
	}

	public function testEveryLineBreakingCharacterIsEscaped():Void {
		Logger.info("a\rb\tc\x01d\x1Be\u0085f\u2028g\u2029h\x7Fi");
		Assert.equals("[INFO] a\\rb\\tc\\x01d\\x1Be\\x85f\\u2028g\\u2029h\\x7Fi", captured[0]);

		captured = [];
		Logger.info("served", ["path" => "/a\nb", "note" => 'C:\\x "y"']);
		Assert.equals(1, captured.length);
		Assert.isTrue(captured[0].indexOf('path="/a\\nb"') > 0, captured[0]);
		Assert.isTrue(captured[0].indexOf('note="C:\\\\x \\"y\\""') > 0, captured[0]);
	}

	/**
		Ordinary text past ASCII goes out as it came, escapes and all.

		On neko a string is its UTF-8 bytes, and the second or third byte of the
		euro sign, of most Cyrillic and of a C1 control all fall between 0x80
		and 0x9F. Escaping those bytes one at a time would write each as an
		escape and the bytes around it raw: a broken character for every euro,
		and a control only half escaped.
	**/
	public function testTextPastAsciiIsLeftAlone():Void {
		Logger.info("€100 за файл, naïve 日本 \u0085end");
		Assert.equals("[INFO] €100 за файл, naïve 日本 \\x85end", captured[0]);

		captured = [];
		Logger.info("paid", ["amount" => "€5 ф"]);
		Assert.isTrue(captured[0].indexOf('amount="€5 ф"') > 0, captured[0]);
	}

	public function testTimestampsAreUtcWithMilliseconds():Void {
		// UTC, to the millisecond, with the zone: not local time to the second.
		Assert.equals("1970-01-01T00:00:00.000Z", Logger.__timestamp(0));
		Assert.equals("2026-09-25T09:00:00.123Z", Logger.__timestamp(1790326800.123));
		Assert.equals("2000-02-29T23:59:59.999Z", Logger.__timestamp(951868799.999));
		Assert.equals("2100-03-01T00:00:00.000Z", Logger.__timestamp(4107542400.0));

		Logger.timestamps = true;
		Logger.info("now");
		var hour = Std.parseInt(captured[0].substr(11, 2));
		var utcHour = Date.now().getUTCHours();
		// A record logged at an hour boundary may straddle it.
		Assert.isTrue(hour == utcHour || hour == (utcHour + 23) % 24, captured[0] + " against UTC hour " + utcHour);
	}

	public function testARecordSinkReceivesTheWholeRecord():Void {
		var records:Array<LogRecord> = [];
		Logger.recordSink = record -> records.push(record);

		Logger.warn("careful", ["k" => "v"]);
		Logger.log(LogLevel.ERROR, "broke", null, "db");
		Logger.debug("below the level");

		Assert.equals(0, captured.length, "a record went to the line sink as well");
		Assert.equals(2, records.length);
		Assert.equals(LogLevel.WARN, records[0].level);
		Assert.isNull(records[0].category);
		Assert.equals("careful", records[0].message);
		Assert.equals("v", records[0].fields.get("k"));
		Assert.equals("[WARN] careful k=v", records[0].line);
		Assert.equals(LogLevel.ERROR, records[1].level);
		Assert.equals("db", records[1].category);
		Assert.equals("[ERROR] [db] broke", records[1].line);
		Assert.isTrue(records[1].time > 0);
	}

	public function testCategoriesHaveLevelsOfTheirOwn():Void {
		var access = Logger.category("http.access");
		var db = Logger.category("db");

		access.info("one");
		Logger.setLevel("http", LogLevel.WARN);
		access.info("suppressed by http");
		access.warn("two");
		Logger.setLevel("http.access", LogLevel.DEBUG);
		access.debug("three");
		db.debug("suppressed by the global level");
		Logger.info("global");
		Logger.setLevel("http.access", null);
		access.info("suppressed by http again");

		Assert.same([
			"[INFO] [http.access] one",
			"[WARN] [http.access] two",
			"[DEBUG] [http.access] three",
			"[INFO] global"
		], captured);
		Assert.equals(LogLevel.WARN, Logger.levelOf("http.access.detail"));
		Assert.equals(LogLevel.INFO, Logger.levelOf("elsewhere"));
		Assert.isTrue(Logger.isEnabledFor("http", LogLevel.ERROR));
		Assert.isFalse(Logger.isEnabledFor("http", LogLevel.INFO));
	}

	/**
		A JSON record is written in one order on every target, and escaped as
		JSON escapes, not as an anonymous object handed to haxe.Json, whose keys
		come out in whatever order the target's reflection gives.
	**/
	public function testJsonRecordsAreWrittenInOneOrder():Void {
		Logger.json = true;
		var fields = new Map<String, String>();
		fields.set("path", "/a\"b\\c\n");
		Logger.log(LogLevel.INFO, "tab\there", fields, "http.access");
		Assert.equals('{"level":"INFO","message":"tab\\there","category":"http.access","path":"/a\\"b\\\\c\\n"}', captured[0]);
		var parsed:Dynamic = haxe.Json.parse(captured[0]);
		Assert.equals("/a\"b\\c\n", parsed.path);
		Assert.equals("tab\there", parsed.message);
	}

	public function testJsonCarriesTheCategory():Void {
		Logger.json = true;
		Logger.log(LogLevel.INFO, "served", ["category" => "spoofed"], "http.access");

		var parsed:Dynamic = haxe.Json.parse(captured[0]);
		Assert.equals("http.access", parsed.category);
		Assert.equals("spoofed", Reflect.field(parsed, "field_category"));
	}

	public function testLogLevelParsingAndNames():Void {
		Assert.equals(LogLevel.TRACE, LogLevel.parse("trace"));
		Assert.equals(LogLevel.DEBUG, LogLevel.parse("DEBUG"));
		Assert.equals(LogLevel.WARN, LogLevel.parse("Warning"));
		Assert.equals(LogLevel.OFF, LogLevel.parse("none"));
		Assert.isNull(LogLevel.parse("verbose"));
		Assert.isNull(LogLevel.parse(null));

		Assert.equals("ERROR", (LogLevel.ERROR : LogLevel).toString());
		Assert.equals("TRACE", (LogLevel.TRACE : LogLevel).toString());
	}

	public function testNullMessageAndNullSinkAreSafe():Void {
		Logger.info(null);
		Assert.equals("[INFO] ", captured[0]);

		// Restoring the default sink must not throw for callers that clear it.
		Logger.sink = null;
		Logger.level = LogLevel.OFF;
		Logger.info("suppressed, so nothing reaches stdout");
		Assert.pass();
	}

	/**
		A sink that throws does not throw into whoever logged. A logging call
		is made from everywhere, error handlers included, and log4j2 and
		Python's `logging` settled this long ago: an appender's failure goes
		to standard output, never to the caller.

		Nor does one failure turn the sink off: the next record is offered to
		it again, since what broke it (a full disk) may have cleared.
	**/
	public function testASinkThatThrowsDoesNotThrowIntoTheCaller():Void {
		var calls:Int = 0;
		Logger.sink = function(line:String) {
			calls++;
			if (calls == 1) {
				throw "disk full";
			}
			captured.push(line);
		};

		Logger.error("the first goes to stdout instead");
		Logger.error("the second reaches the sink");

		Assert.equals(2, calls);
		Assert.equals("[ERROR] the second reaches the sink", captured.join("|"));
	}

	/** As for `sink`, so for `recordSink`. **/
	public function testARecordSinkThatThrowsDoesNotThrowIntoTheCaller():Void {
		var records:Array<LogRecord> = [];
		var calls:Int = 0;
		Logger.recordSink = function(record:LogRecord) {
			calls++;
			if (calls == 1) {
				throw "collector unreachable";
			}
			records.push(record);
		};

		Logger.warn("the first goes to stdout instead");
		Logger.warn("the second reaches the sink");

		Assert.equals(2, calls);
		Assert.equals(1, records.length);
		Assert.equals("the second reaches the sink", records[0].message);
	}

	/**
		What a throwing sink did to the code that logs: `Future` logs a
		handler that throws, from inside the `catch` that contains it, so a
		failing sink threw out of `Completer.complete` and every handler after
		the first never ran.
	**/
	public function testAThrowingSinkLeavesAFuturesOtherHandlersRunning():Void {
		Logger.sink = function(line:String) throw "disk full";

		var ran:Array<String> = [];
		var completer = new crossbyte.Completer<Int>();
		completer.future.then(function(value:Int) {
			ran.push("first");
			throw "a handler's own bug";
		});
		completer.future.then(function(value:Int) ran.push("second"));
		completer.future.then(function(value:Int) ran.push("third"));

		completer.complete(1);

		Assert.equals("first,second,third", ran.join(","));
	}

	/**
		A sink that logs, itself or through something it calls, does not
		recurse: the record logged from inside it goes to standard output, and
		the sink is not entered again. It recursed until the stack ran out,
		which natively ends the process.
	**/
	public function testASinkThatLogsDoesNotRecurse():Void {
		var calls:Int = 0;
		Logger.sink = function(line:String) {
			calls++;
			if (calls > 50) {
				// Fail the test rather than the run, if it does recurse.
				throw "the sink was entered " + calls + " times";
			}
			captured.push(line);
			Logger.info("logged from inside the sink");
		};

		Logger.info("outer");

		Assert.equals(1, calls);
		Assert.equals("[INFO] outer", captured.join("|"));
	}

	#if (target.threaded && !js)
	/**
		What keeps a sink from recursing is kept a thread at a time: one
		thread inside a slow sink does not send another thread's records to
		standard output. A flag shared by every thread would, so this holds the
		first thread inside the sink while the second logs.
	**/
	public function testOneThreadInsideTheSinkDoesNotDivertAnothersRecords():Void {
		var got:Array<String> = [];
		var guard = new sys.thread.Mutex();
		var inside = new sys.thread.Lock();
		var release = new sys.thread.Lock();
		var finished = new sys.thread.Lock();

		Logger.sink = function(line:String) {
			guard.acquire();
			got.push(line);
			guard.release();
			if (line.indexOf("first thread") >= 0) {
				inside.release();
				release.wait();
			}
		};

		sys.thread.Thread.create(function() {
			Logger.info("first thread");
			finished.release();
		});

		Assert.isTrue(inside.wait(10), "the first thread never reached the sink");
		Logger.info("second thread, while the first is inside the sink");
		release.release();
		Assert.isTrue(finished.wait(10), "the first thread never left the sink");

		guard.acquire();
		var lines:String = got.join("|");
		guard.release();
		Assert.equals("[INFO] first thread|[INFO] second thread, while the first is inside the sink", lines);
	}
	#end
}
