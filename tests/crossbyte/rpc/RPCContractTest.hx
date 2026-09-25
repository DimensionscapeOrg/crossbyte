package crossbyte.rpc;

import crossbyte.rpc.RPCParentFixtures;
import crossbyte.rpc._internal.RPCOps;
import crossbyte.utils.Hash;
import utest.Assert;

/**
	RPC surfaces built from parts: contracts that extend other contracts, and
	handlers that extend other handlers.

	A contract read only its own methods, so one built from reusable ones had
	stubs for part of itself and a handler that answered part of it. A
	handler could not extend another at all: the macro made `ping` and
	`dispatch` again in the subclass, which Haxe refused without `override`.
**/
class RPCContractTest extends utest.Test {
	// ----------------------------------------------------------- contracts

	public function testAContractCarriesTheMethodsOfTheContractsItExtends():Void {
		var link = LinkedConnection.pair();
		var commands = new GreeterCommands();
		var handler = new FullGreeterHandler();
		var clientSession = new RPCSession<GreeterCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		// `label` is declared by Labelled, which Greeter extends.
		Assert.equals("label-3", commands.label(3).result);
		commands.greet("ada");
		Assert.same(["ada"], handler.greeted);
	}

	public function testAContractReachedTwiceGivesItsMethodsOnce():Void {
		var link = LinkedConnection.pair();
		var commands = new DiamondCommands();
		var handler = new DiamondHandler();
		var clientSession = new RPCSession<DiamondCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		// Base comes in through Left and through Right.
		Assert.equals(8, commands.twice(4).result);
		commands.left();
		commands.right();
		Assert.same(["left", "right"], handler.calls);
	}

	public function testAGenericContractTakesTheTypeItsExtensionGivesIt():Void {
		var link = LinkedConnection.pair();
		var commands = new NamesCommands();
		var handler = new NamesHandler();
		var clientSession = new RPCSession<NamesCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		commands.rename(5, "grace");
		Assert.equals("grace", commands.fetch(5).result);
	}

	// ----------------------------------------------------------------- ops

	public function testAnOpIsTheHashOfTheMethodsNameAlone():Void {
		Assert.equals(Hash.fnv1a32(haxe.io.Bytes.ofString("label")), RPCOps.opOf("label"));
	}

	public function testTwoNamesThatHashAlikeAreFound():Void {
		// Found by search: FNV-1a gives both 0xa1bc9a4f. On one connection
		// they would be one method, so a surface declaring both fails to build.
		Assert.equals(RPCOps.opOf("glbvs"), RPCOps.opOf("yacxa"));
		Assert.same(["glbvs", "yacxa"], RPCOps.firstClash(["label", "glbvs", "greet", "yacxa"]));
	}

	public function testAMethodReachedTwiceIsNotAClash():Void {
		Assert.isNull(RPCOps.firstClash(["label", "greet", "label", "ping"]));
	}

	// ---------------------------------------------------------- hierarchies

	public function testAHandlerAnswersTheMethodsOfTheHandlerItExtends():Void {
		var link = LinkedConnection.pair();
		var commands = new ParentChildCommands();
		var handler = new ChildHandler();
		var clientSession = new RPCSession<ParentChildCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);
		var ended = false;
		link.server.onClose = _ -> ended = true;
		link.server.onError = _ -> ended = true;

		Assert.equals("parent-1", commands.fromParent(1).result);
		Assert.equals("child-2", commands.fromChild(2).result);
		// Overridden in the child, and answered by the override.
		Assert.equals("child says 3", commands.said(3).result);
		commands.ping();
		Assert.isFalse(ended, "a handler that extends another did not answer ping");
	}

	public function testAWideHierarchyStillReachesEveryMethod():Void {
		// Five in the parent, five in the child, and ping: past the eight a
		// switch dispatches, so the child's dispatch is a perfect hash that
		// overrides the parent's switch.
		var link = LinkedConnection.pair();
		var commands = new WideFamilyCommands();
		var handler = new WideChildHandler();
		var clientSession = new RPCSession<WideFamilyCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		commands.p1(1);
		commands.p2(2);
		commands.p3(3);
		commands.p4(4);
		commands.p5(5);
		commands.c1(6);
		commands.c2(7);
		commands.c3(8);
		commands.c4(9);
		commands.c5(10);
		Assert.same(["p1:1", "p2:2", "p3:3", "p4:4", "p5:5", "c1:6", "c2:7", "c3:8", "c4:9", "c5:10"], handler.seen);
	}

	public function testAReusableHandlerAnswersForAContractThatExtendsItsOwn():Void {
		// LabelledHandler answers Labelled; GreeterHandler extends it and
		// answers Greeter, which extends Labelled, implementing only `greet`.
		var link = LinkedConnection.pair();
		var commands = new GreeterCommands();
		var handler = new GreeterHandler();
		var clientSession = new RPCSession<GreeterCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		Assert.equals("label-9", commands.label(9).result);
		commands.greet("alan");
		Assert.same(["alan"], handler.greeted);
	}

	public function testACommandsClassSendsAndReadsForTheOneItExtends():Void {
		// A commands class extends another: the stubs are inherited, and the
		// subclass reads the responses to its parent's calls as well as its own.
		var link = LinkedConnection.pair();
		var commands = new ExtendedCommands();
		var clientSession = new RPCSession<ExtendedCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new ChildHandler());
		var ended = false;
		link.server.onClose = _ -> ended = true;
		link.server.onError = _ -> ended = true;

		Assert.equals("parent-4", commands.fromParent(4).result);
		Assert.equals("child-5", commands.fromChild(5).result);
		commands.ping();
		Assert.isFalse(ended);
	}

	public function testAParentsUntypedMethodIsNotTypedDuringItsChildsBuild():Void {
		// NotingParentHandler.note declares no return type and reads a field of
		// the class that extends it. The child's build followed the parent's
		// method types, which typed `note` there and then, before the child had
		// its fields: "Class<NotingChildHandler> has no field noted". This class
		// did not compile. The parent's build now records what it dispatches.
		NotingChildHandler.noted = 0;
		var link = LinkedConnection.pair();
		var commands = new NotingCommands();
		var clientSession = new RPCSession<NotingCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new NotingChildHandler());

		commands.note(5);
		Assert.equals(5, NotingChildHandler.noted);
		Assert.equals(8, commands.twice(4).result);
	}

	public function testAChildReadsItsParentsTypesWhateverItsParentNamesThemBy():Void {
		// The parents name Bytes by an import alias and Int by a private
		// typedef, neither of which this module can name. Recorded as written,
		// the child could not read them; written with toComplexType(), as the
		// parent's types were read before, it could not either.
		var link = LinkedConnection.pair();
		var commands = new BlobChildCommands();
		var clientSession = new RPCSession<BlobChildCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new BlobChildHandler());

		Assert.equals("blob", commands.echoBlob(haxe.io.Bytes.ofString("blob")).result.toString());
		Assert.equals(8, commands.countOrNone(7).result);
		// Null<Count> is still optional on the wire once written out.
		Assert.equals(-1, commands.countOrNone(null).result);
		Assert.equals(14, commands.doubled(7).result);
	}

	public function testAContractIsReadWhateverItsModuleNamesItsTypesBy():Void {
		// MeasuredContract names its types by an alias and a private typedef of
		// its own module; the handler and commands class are in this one.
		var link = LinkedConnection.pair();
		var commands = new MeasuredCommands();
		var clientSession = new RPCSession<MeasuredCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, new MeasuredHandler());

		Assert.equals(4, commands.measure(haxe.io.Bytes.ofString("four"), null).result);
		Assert.equals(9, commands.measure(haxe.io.Bytes.ofString("four"), 5).result);
	}

	public function testContractCommandsExtendAlongWithTheirContracts():Void {
		var link = LinkedConnection.pair();
		var commands = new GreeterOnLabelledCommands();
		var handler = new GreeterHandler();
		var clientSession = new RPCSession<GreeterOnLabelledCommands>(link.client, commands);
		var serverSession = new RPCSession(link.server, null, handler);

		// `label` comes from LabelledCommands, `greet` from this class.
		Assert.equals("label-6", commands.label(6).result);
		commands.greet("ada");
		Assert.same(["ada"], handler.greeted);
	}
}

// ----------------------------------------------------------------- contracts

private interface Labelled {
	function label(id:Int):String;
}

private interface Greeter extends Labelled {
	function greet(name:String):Void;
}

@:rpcContract(Greeter)
private class GreeterCommands extends RPCCommands {
	public function new() {}
}

private class FullGreeterHandler extends RPCHandler implements Greeter {
	public var greeted:Array<String> = [];

	public function new() {}

	public function label(id:Int):String {
		return 'label-$id';
	}

	public function greet(name:String):Void {
		greeted.push(name);
	}
}

private interface Base {
	function twice(value:Int):Int;
}

private interface Left extends Base {
	function left():Void;
}

private interface Right extends Base {
	function right():Void;
}

private interface Both extends Left extends Right {}

@:rpcContract(Both)
private class DiamondCommands extends RPCCommands {
	public function new() {}
}

private class DiamondHandler extends RPCHandler implements Both {
	public var calls:Array<String> = [];

	public function new() {}

	public function twice(value:Int):Int {
		return value * 2;
	}

	public function left():Void {
		calls.push("left");
	}

	public function right():Void {
		calls.push("right");
	}
}

private interface Keyed<T> {
	function fetch(key:Int):T;
}

private interface Names extends Keyed<String> {
	function rename(key:Int, name:String):Void;
}

@:rpcContract(Names)
private class NamesCommands extends RPCCommands {
	public function new() {}
}

private class NamesHandler extends RPCHandler implements Names {
	var names:Map<Int, String> = new Map();

	public function new() {}

	public function fetch(key:Int):String {
		return names.get(key);
	}

	public function rename(key:Int, name:String):Void {
		names.set(key, name);
	}
}

// --------------------------------------------------------------- hierarchies

private class ParentChildCommands extends RPCCommands {
	public function new() {}

	@:rpc public function fromParent(id:Int):RPCResponse<String> {}

	@:rpc public function fromChild(id:Int):RPCResponse<String> {}

	@:rpc public function said(id:Int):RPCResponse<String> {}
}

private class BaseCommands extends RPCCommands {
	public function new() {}

	@:rpc public function fromParent(id:Int):RPCResponse<String> {}
}

private class ExtendedCommands extends BaseCommands {
	public function new() {
		super();
	}

	@:rpc public function fromChild(id:Int):RPCResponse<String> {}
}

@:rpcContract(Labelled)
private class LabelledCommands extends RPCCommands {
	public function new() {}
}

@:rpcContract(Greeter)
private class GreeterOnLabelledCommands extends LabelledCommands {
	public function new() {
		super();
	}
}

private class ParentHandler extends RPCHandler {
	public function new() {}

	@:rpc public function fromParent(id:Int):String {
		return 'parent-$id';
	}

	@:rpc public function said(id:Int):String {
		return 'parent says $id';
	}
}

private class ChildHandler extends ParentHandler {
	public function new() {
		super();
	}

	@:rpc public function fromChild(id:Int):String {
		return 'child-$id';
	}

	override public function said(id:Int):String {
		return 'child says $id';
	}
}

private class NotingParentHandler extends RPCHandler {
	public function new() {}

	// No return type, and a body that reads the class that extends this one.
	@:rpc public function note(value:Int) {
		NotingChildHandler.noted += value;
	}
}

private class NotingChildHandler extends NotingParentHandler {
	public static var noted:Int = 0;

	public function new() {
		super();
	}

	@:rpc public function twice(value:Int):Int {
		return value * 2;
	}
}

private class NotingCommands extends RPCCommands {
	public function new() {}

	@:rpc public function note(value:Int):Void {}

	@:rpc public function twice(value:Int):RPCResponse<Int> {}
}

private class BlobChildHandler extends BlobParentHandler {
	public function new() {
		super();
	}

	@:rpc public function doubled(value:Int):Int {
		return value * 2;
	}
}

private class BlobChildCommands extends BlobParentCommands {
	public function new() {
		super();
	}

	@:rpc public function doubled(value:Int):RPCResponse<Int> {}
}

@:rpcContract(MeasuredContract)
private class MeasuredCommands extends RPCCommands {
	public function new() {}
}

private class MeasuredHandler extends RPCHandler implements MeasuredContract {
	public function new() {}

	public function measure(data:haxe.io.Bytes, extra:Null<Int>):Int {
		return data.length + (extra == null ? 0 : extra);
	}
}

private class WideFamilyCommands extends RPCCommands {
	public function new() {}

	@:rpc public function p1(v:Int):Void {}

	@:rpc public function p2(v:Int):Void {}

	@:rpc public function p3(v:Int):Void {}

	@:rpc public function p4(v:Int):Void {}

	@:rpc public function p5(v:Int):Void {}

	@:rpc public function c1(v:Int):Void {}

	@:rpc public function c2(v:Int):Void {}

	@:rpc public function c3(v:Int):Void {}

	@:rpc public function c4(v:Int):Void {}

	@:rpc public function c5(v:Int):Void {}
}

private class WideParentHandler extends RPCHandler {
	public var seen:Array<String> = [];

	public function new() {}

	@:rpc public function p1(v:Int):Void {
		seen.push("p1:" + v);
	}

	@:rpc public function p2(v:Int):Void {
		seen.push("p2:" + v);
	}

	@:rpc public function p3(v:Int):Void {
		seen.push("p3:" + v);
	}

	@:rpc public function p4(v:Int):Void {
		seen.push("p4:" + v);
	}

	@:rpc public function p5(v:Int):Void {
		seen.push("p5:" + v);
	}
}

private class WideChildHandler extends WideParentHandler {
	public function new() {
		super();
	}

	@:rpc public function c1(v:Int):Void {
		seen.push("c1:" + v);
	}

	@:rpc public function c2(v:Int):Void {
		seen.push("c2:" + v);
	}

	@:rpc public function c3(v:Int):Void {
		seen.push("c3:" + v);
	}

	@:rpc public function c4(v:Int):Void {
		seen.push("c4:" + v);
	}

	@:rpc public function c5(v:Int):Void {
		seen.push("c5:" + v);
	}
}

private class LabelledHandler extends RPCHandler implements Labelled {
	public function new() {}

	public function label(id:Int):String {
		return 'label-$id';
	}
}

private class GreeterHandler extends LabelledHandler implements Greeter {
	public var greeted:Array<String> = [];

	public function new() {
		super();
	}

	public function greet(name:String):Void {
		greeted.push(name);
	}
}
