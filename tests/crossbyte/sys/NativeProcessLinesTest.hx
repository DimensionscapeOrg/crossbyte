package crossbyte.sys;

import utest.Assert;
#if !(js && !nodejs)
import crossbyte.events.NativeProcessEvent;
#end

/**
	`STANDARD_OUTPUT_LINE` and `STANDARD_ERROR_LINE`: output split into lines
	the same way however it is cut into reads, the last line given as the
	stream closes, and a line's length bounded. Fed to `NativeProcess` as its
	readers feed it, with no child, so every target with the class runs it,
	Node and the interpreter included.
**/
@:access(crossbyte.sys.NativeProcess)
class NativeProcessLinesTest extends utest.Test {
	#if !(js && !nodejs)
	public function testLinesAreTheSameHoweverTheOutputIsCut():Void {
		var text:String = "alpha\r\nbeta\n\ngamma\r\nété €\ndelta";
		var expected:Array<String> = ["alpha", "beta", "", "gamma", "été €", "delta"];
		for (cut in [1, 2, 3, 5, 7, text.length]) {
			var lines = __feed([for (i in 0...Math.ceil(text.length / cut)) text.substr(i * cut, cut)]);
			Assert.same(expected, lines.out, 'cut every $cut');
		}
	}

	public function testACarriageReturnAndItsLineFeedInTwoReadsEndOneLine():Void {
		Assert.same(["one", "two"], __feed(["one\r", "\ntwo\r", "\n"]).out);
		// A carriage return alone is part of the line, not its end.
		Assert.same(["a\rb"], __feed(["a\rb\n"]).out);
	}

	public function testTheLastLineGoesAsTheStreamCloses():Void {
		var proc = new NativeProcess();
		var lines:Array<String> = [];
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_LINE, event -> lines.push(event.text));
		proc.__emitData(NativeProcess.STREAM_STDOUT, "first\nunfinished", false);
		Assert.same(["first"], lines);
		proc.__emitClose(NativeProcess.STREAM_STDOUT);
		Assert.same(["first", "unfinished"], lines);
		// Once.
		proc.__emitClose(NativeProcess.STREAM_STDOUT);
		Assert.same(["first", "unfinished"], lines);
	}

	public function testStandardErrorHasLinesOfItsOwn():Void {
		var lines = __feed(["out one\nout ", "two\n"], ["err one\ner", "r two"]);
		Assert.same(["out one", "out two"], lines.out);
		Assert.same(["err one", "err two"], lines.err);
	}

	public function testALongLineArrivesInPiecesOfTheLimit():Void {
		var proc = new NativeProcess();
		proc.maxLineLength = 4;
		var lines:Array<String> = [];
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_LINE, event -> lines.push(event.text));

		proc.__emitData(NativeProcess.STREAM_STDOUT, "abcdefghij\nwxyz\n", false);
		Assert.same(["abcd", "efgh", "ij", "wxyz"], lines);

		// Held to the limit while no line break comes, read by read: what is
		// kept never grows past it.
		lines = [];
		for (_ in 0...1000) {
			proc.__emitData(NativeProcess.STREAM_STDOUT, "xyz", false);
			Assert.isTrue(proc.__outPending.length <= 4, "held " + proc.__outPending.length);
		}
		// 3000 characters: 749 pieces, and the last four still held.
		Assert.equals(749, lines.length);
		Assert.equals(4, proc.__outPending.length);
		// A line exactly the limit long, then its CRLF split across reads, is
		// one line, not that line and an empty one.
		lines = [];
		proc.__outPending = "";
		proc.__emitData(NativeProcess.STREAM_STDOUT, "abcd\r", false);
		proc.__emitData(NativeProcess.STREAM_STDOUT, "\n", false);
		Assert.same(["abcd"], lines);

		Assert.raises(() -> proc.maxLineLength = 0, crossbyte.errors.ArgumentError);
		Assert.equals(NativeProcess.DEFAULT_MAX_LINE_LENGTH, new NativeProcess().maxLineLength);
	}

	public function testNothingIsSplitWhileNoOneListens():Void {
		var proc = new NativeProcess();
		var data:String = "";
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_DATA, event -> data += event.text);
		proc.__emitData(NativeProcess.STREAM_STDOUT, "a\nb", false);
		Assert.equals("a\nb", data);
		Assert.equals("", proc.__outPending);
	}

	private static function __feed(out:Array<String>, ?err:Array<String>):{out:Array<String>, err:Array<String>} {
		var proc = new NativeProcess();
		var lines = {out: [], err: []};
		proc.addEventListener(NativeProcessEvent.STANDARD_OUTPUT_LINE, event -> lines.out.push(event.text));
		proc.addEventListener(NativeProcessEvent.STANDARD_ERROR_LINE, event -> lines.err.push(event.text));
		for (piece in out) {
			proc.__emitData(NativeProcess.STREAM_STDOUT, piece, false);
		}
		if (err != null) {
			for (piece in err) {
				proc.__emitData(NativeProcess.STREAM_STDERR, piece, true);
			}
		}
		proc.__emitClose(NativeProcess.STREAM_STDOUT);
		proc.__emitClose(NativeProcess.STREAM_STDERR);
		return lines;
	}
	#else
	public function testABrowserHasNoProcesses():Void {
		Assert.pass();
	}
	#end
}
