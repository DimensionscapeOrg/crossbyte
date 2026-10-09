package crossbyte.rpc;

import utest.Assert;

/**
	A handler and commands of seventy methods, as a game server's can be:
	both build, load and answer on every target. On the jvm, a handler's
	dispatch with every decoder inlined into it, or a commands' reader with
	every answer read in its switch, passed the 32 KB of bytecode that
	Haxe's jvm backend can branch across, and the class failed to load.
**/
class RPCLargeSurfaceTest extends utest.Test {
	public function testSeventyMethodsAnswerEitherWay():Void {
		var link = LinkedConnection.pair();
		var commands = new LargeCommands();
		var client = new RPCSession<LargeCommands>(link.client, commands);
		var server = new RPCSession(link.server, null, new LargeHandler());
		var heard = new LargeHeard();
		Assert.equals(1000, commands.m0(1000).result);
		commands.m0Then(2000, heard);
		Assert.equals(1001, commands.m1(1000).result);
		commands.m1Then(2000, heard);
		Assert.equals(1002, commands.m2(1000).result);
		commands.m2Then(2000, heard);
		Assert.equals(1003, commands.m3(1000).result);
		commands.m3Then(2000, heard);
		Assert.equals(1004, commands.m4(1000).result);
		commands.m4Then(2000, heard);
		Assert.equals(1005, commands.m5(1000).result);
		commands.m5Then(2000, heard);
		Assert.equals(1006, commands.m6(1000).result);
		commands.m6Then(2000, heard);
		Assert.equals(1007, commands.m7(1000).result);
		commands.m7Then(2000, heard);
		Assert.equals(1008, commands.m8(1000).result);
		commands.m8Then(2000, heard);
		Assert.equals(1009, commands.m9(1000).result);
		commands.m9Then(2000, heard);
		Assert.equals(1010, commands.m10(1000).result);
		commands.m10Then(2000, heard);
		Assert.equals(1011, commands.m11(1000).result);
		commands.m11Then(2000, heard);
		Assert.equals(1012, commands.m12(1000).result);
		commands.m12Then(2000, heard);
		Assert.equals(1013, commands.m13(1000).result);
		commands.m13Then(2000, heard);
		Assert.equals(1014, commands.m14(1000).result);
		commands.m14Then(2000, heard);
		Assert.equals(1015, commands.m15(1000).result);
		commands.m15Then(2000, heard);
		Assert.equals(1016, commands.m16(1000).result);
		commands.m16Then(2000, heard);
		Assert.equals(1017, commands.m17(1000).result);
		commands.m17Then(2000, heard);
		Assert.equals(1018, commands.m18(1000).result);
		commands.m18Then(2000, heard);
		Assert.equals(1019, commands.m19(1000).result);
		commands.m19Then(2000, heard);
		Assert.equals(1020, commands.m20(1000).result);
		commands.m20Then(2000, heard);
		Assert.equals(1021, commands.m21(1000).result);
		commands.m21Then(2000, heard);
		Assert.equals(1022, commands.m22(1000).result);
		commands.m22Then(2000, heard);
		Assert.equals(1023, commands.m23(1000).result);
		commands.m23Then(2000, heard);
		Assert.equals(1024, commands.m24(1000).result);
		commands.m24Then(2000, heard);
		Assert.equals(1025, commands.m25(1000).result);
		commands.m25Then(2000, heard);
		Assert.equals(1026, commands.m26(1000).result);
		commands.m26Then(2000, heard);
		Assert.equals(1027, commands.m27(1000).result);
		commands.m27Then(2000, heard);
		Assert.equals(1028, commands.m28(1000).result);
		commands.m28Then(2000, heard);
		Assert.equals(1029, commands.m29(1000).result);
		commands.m29Then(2000, heard);
		Assert.equals(1030, commands.m30(1000).result);
		commands.m30Then(2000, heard);
		Assert.equals(1031, commands.m31(1000).result);
		commands.m31Then(2000, heard);
		Assert.equals(1032, commands.m32(1000).result);
		commands.m32Then(2000, heard);
		Assert.equals(1033, commands.m33(1000).result);
		commands.m33Then(2000, heard);
		Assert.equals(1034, commands.m34(1000).result);
		commands.m34Then(2000, heard);
		Assert.equals(1035, commands.m35(1000).result);
		commands.m35Then(2000, heard);
		Assert.equals(1036, commands.m36(1000).result);
		commands.m36Then(2000, heard);
		Assert.equals(1037, commands.m37(1000).result);
		commands.m37Then(2000, heard);
		Assert.equals(1038, commands.m38(1000).result);
		commands.m38Then(2000, heard);
		Assert.equals(1039, commands.m39(1000).result);
		commands.m39Then(2000, heard);
		Assert.equals(1040, commands.m40(1000).result);
		commands.m40Then(2000, heard);
		Assert.equals(1041, commands.m41(1000).result);
		commands.m41Then(2000, heard);
		Assert.equals(1042, commands.m42(1000).result);
		commands.m42Then(2000, heard);
		Assert.equals(1043, commands.m43(1000).result);
		commands.m43Then(2000, heard);
		Assert.equals(1044, commands.m44(1000).result);
		commands.m44Then(2000, heard);
		Assert.equals(1045, commands.m45(1000).result);
		commands.m45Then(2000, heard);
		Assert.equals(1046, commands.m46(1000).result);
		commands.m46Then(2000, heard);
		Assert.equals(1047, commands.m47(1000).result);
		commands.m47Then(2000, heard);
		Assert.equals(1048, commands.m48(1000).result);
		commands.m48Then(2000, heard);
		Assert.equals(1049, commands.m49(1000).result);
		commands.m49Then(2000, heard);
		Assert.equals(1050, commands.m50(1000).result);
		commands.m50Then(2000, heard);
		Assert.equals(1051, commands.m51(1000).result);
		commands.m51Then(2000, heard);
		Assert.equals(1052, commands.m52(1000).result);
		commands.m52Then(2000, heard);
		Assert.equals(1053, commands.m53(1000).result);
		commands.m53Then(2000, heard);
		Assert.equals(1054, commands.m54(1000).result);
		commands.m54Then(2000, heard);
		Assert.equals(1055, commands.m55(1000).result);
		commands.m55Then(2000, heard);
		Assert.equals(1056, commands.m56(1000).result);
		commands.m56Then(2000, heard);
		Assert.equals(1057, commands.m57(1000).result);
		commands.m57Then(2000, heard);
		Assert.equals(1058, commands.m58(1000).result);
		commands.m58Then(2000, heard);
		Assert.equals(1059, commands.m59(1000).result);
		commands.m59Then(2000, heard);
		Assert.equals(1060, commands.m60(1000).result);
		commands.m60Then(2000, heard);
		Assert.equals(1061, commands.m61(1000).result);
		commands.m61Then(2000, heard);
		Assert.equals(1062, commands.m62(1000).result);
		commands.m62Then(2000, heard);
		Assert.equals(1063, commands.m63(1000).result);
		commands.m63Then(2000, heard);
		Assert.equals(1064, commands.m64(1000).result);
		commands.m64Then(2000, heard);
		Assert.equals(1065, commands.m65(1000).result);
		commands.m65Then(2000, heard);
		Assert.equals(1066, commands.m66(1000).result);
		commands.m66Then(2000, heard);
		Assert.equals(1067, commands.m67(1000).result);
		commands.m67Then(2000, heard);
		Assert.equals(1068, commands.m68(1000).result);
		commands.m68Then(2000, heard);
		Assert.equals(1069, commands.m69(1000).result);
		commands.m69Then(2000, heard);
		Assert.equals(70, heard.values.length);
		for (i in 0...heard.values.length) {
			Assert.equals(2000 + i, heard.values[i]);
		}
		Assert.equals(0, heard.failures);
	}
}

private class LargeHeard implements RPCIntReceiver {
	public final values:Array<Int> = [];
	public var failures:Int = 0;

	public function new() {}

	public function onInt(call:Int, value:Int):Void {
		values.push(value);
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		failures++;
	}
}

private class LargeCommands extends RPCCommands {
	public function new() {}

	@:rpc public function m0(value:Int):RPCResponse<Int> {}

	@:rpc public function m1(value:Int):RPCResponse<Int> {}

	@:rpc public function m2(value:Int):RPCResponse<Int> {}

	@:rpc public function m3(value:Int):RPCResponse<Int> {}

	@:rpc public function m4(value:Int):RPCResponse<Int> {}

	@:rpc public function m5(value:Int):RPCResponse<Int> {}

	@:rpc public function m6(value:Int):RPCResponse<Int> {}

	@:rpc public function m7(value:Int):RPCResponse<Int> {}

	@:rpc public function m8(value:Int):RPCResponse<Int> {}

	@:rpc public function m9(value:Int):RPCResponse<Int> {}

	@:rpc public function m10(value:Int):RPCResponse<Int> {}

	@:rpc public function m11(value:Int):RPCResponse<Int> {}

	@:rpc public function m12(value:Int):RPCResponse<Int> {}

	@:rpc public function m13(value:Int):RPCResponse<Int> {}

	@:rpc public function m14(value:Int):RPCResponse<Int> {}

	@:rpc public function m15(value:Int):RPCResponse<Int> {}

	@:rpc public function m16(value:Int):RPCResponse<Int> {}

	@:rpc public function m17(value:Int):RPCResponse<Int> {}

	@:rpc public function m18(value:Int):RPCResponse<Int> {}

	@:rpc public function m19(value:Int):RPCResponse<Int> {}

	@:rpc public function m20(value:Int):RPCResponse<Int> {}

	@:rpc public function m21(value:Int):RPCResponse<Int> {}

	@:rpc public function m22(value:Int):RPCResponse<Int> {}

	@:rpc public function m23(value:Int):RPCResponse<Int> {}

	@:rpc public function m24(value:Int):RPCResponse<Int> {}

	@:rpc public function m25(value:Int):RPCResponse<Int> {}

	@:rpc public function m26(value:Int):RPCResponse<Int> {}

	@:rpc public function m27(value:Int):RPCResponse<Int> {}

	@:rpc public function m28(value:Int):RPCResponse<Int> {}

	@:rpc public function m29(value:Int):RPCResponse<Int> {}

	@:rpc public function m30(value:Int):RPCResponse<Int> {}

	@:rpc public function m31(value:Int):RPCResponse<Int> {}

	@:rpc public function m32(value:Int):RPCResponse<Int> {}

	@:rpc public function m33(value:Int):RPCResponse<Int> {}

	@:rpc public function m34(value:Int):RPCResponse<Int> {}

	@:rpc public function m35(value:Int):RPCResponse<Int> {}

	@:rpc public function m36(value:Int):RPCResponse<Int> {}

	@:rpc public function m37(value:Int):RPCResponse<Int> {}

	@:rpc public function m38(value:Int):RPCResponse<Int> {}

	@:rpc public function m39(value:Int):RPCResponse<Int> {}

	@:rpc public function m40(value:Int):RPCResponse<Int> {}

	@:rpc public function m41(value:Int):RPCResponse<Int> {}

	@:rpc public function m42(value:Int):RPCResponse<Int> {}

	@:rpc public function m43(value:Int):RPCResponse<Int> {}

	@:rpc public function m44(value:Int):RPCResponse<Int> {}

	@:rpc public function m45(value:Int):RPCResponse<Int> {}

	@:rpc public function m46(value:Int):RPCResponse<Int> {}

	@:rpc public function m47(value:Int):RPCResponse<Int> {}

	@:rpc public function m48(value:Int):RPCResponse<Int> {}

	@:rpc public function m49(value:Int):RPCResponse<Int> {}

	@:rpc public function m50(value:Int):RPCResponse<Int> {}

	@:rpc public function m51(value:Int):RPCResponse<Int> {}

	@:rpc public function m52(value:Int):RPCResponse<Int> {}

	@:rpc public function m53(value:Int):RPCResponse<Int> {}

	@:rpc public function m54(value:Int):RPCResponse<Int> {}

	@:rpc public function m55(value:Int):RPCResponse<Int> {}

	@:rpc public function m56(value:Int):RPCResponse<Int> {}

	@:rpc public function m57(value:Int):RPCResponse<Int> {}

	@:rpc public function m58(value:Int):RPCResponse<Int> {}

	@:rpc public function m59(value:Int):RPCResponse<Int> {}

	@:rpc public function m60(value:Int):RPCResponse<Int> {}

	@:rpc public function m61(value:Int):RPCResponse<Int> {}

	@:rpc public function m62(value:Int):RPCResponse<Int> {}

	@:rpc public function m63(value:Int):RPCResponse<Int> {}

	@:rpc public function m64(value:Int):RPCResponse<Int> {}

	@:rpc public function m65(value:Int):RPCResponse<Int> {}

	@:rpc public function m66(value:Int):RPCResponse<Int> {}

	@:rpc public function m67(value:Int):RPCResponse<Int> {}

	@:rpc public function m68(value:Int):RPCResponse<Int> {}

	@:rpc public function m69(value:Int):RPCResponse<Int> {}
}

private class LargeHandler extends RPCHandler {
	public function new() {}

	@:rpc public function m0(value:Int):Int {
		return value + 0;
	}

	@:rpc public function m1(value:Int):Int {
		return value + 1;
	}

	@:rpc public function m2(value:Int):Int {
		return value + 2;
	}

	@:rpc public function m3(value:Int):Int {
		return value + 3;
	}

	@:rpc public function m4(value:Int):Int {
		return value + 4;
	}

	@:rpc public function m5(value:Int):Int {
		return value + 5;
	}

	@:rpc public function m6(value:Int):Int {
		return value + 6;
	}

	@:rpc public function m7(value:Int):Int {
		return value + 7;
	}

	@:rpc public function m8(value:Int):Int {
		return value + 8;
	}

	@:rpc public function m9(value:Int):Int {
		return value + 9;
	}

	@:rpc public function m10(value:Int):Int {
		return value + 10;
	}

	@:rpc public function m11(value:Int):Int {
		return value + 11;
	}

	@:rpc public function m12(value:Int):Int {
		return value + 12;
	}

	@:rpc public function m13(value:Int):Int {
		return value + 13;
	}

	@:rpc public function m14(value:Int):Int {
		return value + 14;
	}

	@:rpc public function m15(value:Int):Int {
		return value + 15;
	}

	@:rpc public function m16(value:Int):Int {
		return value + 16;
	}

	@:rpc public function m17(value:Int):Int {
		return value + 17;
	}

	@:rpc public function m18(value:Int):Int {
		return value + 18;
	}

	@:rpc public function m19(value:Int):Int {
		return value + 19;
	}

	@:rpc public function m20(value:Int):Int {
		return value + 20;
	}

	@:rpc public function m21(value:Int):Int {
		return value + 21;
	}

	@:rpc public function m22(value:Int):Int {
		return value + 22;
	}

	@:rpc public function m23(value:Int):Int {
		return value + 23;
	}

	@:rpc public function m24(value:Int):Int {
		return value + 24;
	}

	@:rpc public function m25(value:Int):Int {
		return value + 25;
	}

	@:rpc public function m26(value:Int):Int {
		return value + 26;
	}

	@:rpc public function m27(value:Int):Int {
		return value + 27;
	}

	@:rpc public function m28(value:Int):Int {
		return value + 28;
	}

	@:rpc public function m29(value:Int):Int {
		return value + 29;
	}

	@:rpc public function m30(value:Int):Int {
		return value + 30;
	}

	@:rpc public function m31(value:Int):Int {
		return value + 31;
	}

	@:rpc public function m32(value:Int):Int {
		return value + 32;
	}

	@:rpc public function m33(value:Int):Int {
		return value + 33;
	}

	@:rpc public function m34(value:Int):Int {
		return value + 34;
	}

	@:rpc public function m35(value:Int):Int {
		return value + 35;
	}

	@:rpc public function m36(value:Int):Int {
		return value + 36;
	}

	@:rpc public function m37(value:Int):Int {
		return value + 37;
	}

	@:rpc public function m38(value:Int):Int {
		return value + 38;
	}

	@:rpc public function m39(value:Int):Int {
		return value + 39;
	}

	@:rpc public function m40(value:Int):Int {
		return value + 40;
	}

	@:rpc public function m41(value:Int):Int {
		return value + 41;
	}

	@:rpc public function m42(value:Int):Int {
		return value + 42;
	}

	@:rpc public function m43(value:Int):Int {
		return value + 43;
	}

	@:rpc public function m44(value:Int):Int {
		return value + 44;
	}

	@:rpc public function m45(value:Int):Int {
		return value + 45;
	}

	@:rpc public function m46(value:Int):Int {
		return value + 46;
	}

	@:rpc public function m47(value:Int):Int {
		return value + 47;
	}

	@:rpc public function m48(value:Int):Int {
		return value + 48;
	}

	@:rpc public function m49(value:Int):Int {
		return value + 49;
	}

	@:rpc public function m50(value:Int):Int {
		return value + 50;
	}

	@:rpc public function m51(value:Int):Int {
		return value + 51;
	}

	@:rpc public function m52(value:Int):Int {
		return value + 52;
	}

	@:rpc public function m53(value:Int):Int {
		return value + 53;
	}

	@:rpc public function m54(value:Int):Int {
		return value + 54;
	}

	@:rpc public function m55(value:Int):Int {
		return value + 55;
	}

	@:rpc public function m56(value:Int):Int {
		return value + 56;
	}

	@:rpc public function m57(value:Int):Int {
		return value + 57;
	}

	@:rpc public function m58(value:Int):Int {
		return value + 58;
	}

	@:rpc public function m59(value:Int):Int {
		return value + 59;
	}

	@:rpc public function m60(value:Int):Int {
		return value + 60;
	}

	@:rpc public function m61(value:Int):Int {
		return value + 61;
	}

	@:rpc public function m62(value:Int):Int {
		return value + 62;
	}

	@:rpc public function m63(value:Int):Int {
		return value + 63;
	}

	@:rpc public function m64(value:Int):Int {
		return value + 64;
	}

	@:rpc public function m65(value:Int):Int {
		return value + 65;
	}

	@:rpc public function m66(value:Int):Int {
		return value + 66;
	}

	@:rpc public function m67(value:Int):Int {
		return value + 67;
	}

	@:rpc public function m68(value:Int):Int {
		return value + 68;
	}

	@:rpc public function m69(value:Int):Int {
		return value + 69;
	}
}
