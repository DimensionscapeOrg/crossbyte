package crossbyte.rpc;

import utest.Assert;

/**
	A contract of three hundred methods, built and answered on every target.

	On the jvm Haxe's backend reaches every method of a class through one
	generated method, `_hx_getField`, which fails to load past 32 KB; a
	commands class made four methods for each request and a handler two, so
	the jvm loaded neither past about 160 methods. The build now makes the
	helpers static or inlined, and names the limit when a class passes it.
**/
class RPCWideSurfaceTest extends utest.Test {
	public function testThreeHundredMethodsAnswer():Void {
		final link = LinkedConnection.pair();
		final commands = new WideCommands();
		final client = new RPCSession<WideCommands>(link.client, commands);
		final server = new RPCSession(link.server, null, new WideHandler());
		final heard = new WideHeard();
		Assert.equals(1000, commands.w0(1000).result);
		commands.w0Then(2000, heard);
		Assert.equals(1150, commands.w150(1000).result);
		commands.w150Then(2000, heard);
		Assert.equals(1299, commands.w299(1000).result);
		commands.w299Then(2000, heard);
		Assert.same([2000, 2150, 2299], heard.answers);
		client.close();
		server.close();
	}
}

interface WideContract {
	function w0(value:Int):Int;
	function w1(value:Int):Int;
	function w2(value:Int):Int;
	function w3(value:Int):Int;
	function w4(value:Int):Int;
	function w5(value:Int):Int;
	function w6(value:Int):Int;
	function w7(value:Int):Int;
	function w8(value:Int):Int;
	function w9(value:Int):Int;
	function w10(value:Int):Int;
	function w11(value:Int):Int;
	function w12(value:Int):Int;
	function w13(value:Int):Int;
	function w14(value:Int):Int;
	function w15(value:Int):Int;
	function w16(value:Int):Int;
	function w17(value:Int):Int;
	function w18(value:Int):Int;
	function w19(value:Int):Int;
	function w20(value:Int):Int;
	function w21(value:Int):Int;
	function w22(value:Int):Int;
	function w23(value:Int):Int;
	function w24(value:Int):Int;
	function w25(value:Int):Int;
	function w26(value:Int):Int;
	function w27(value:Int):Int;
	function w28(value:Int):Int;
	function w29(value:Int):Int;
	function w30(value:Int):Int;
	function w31(value:Int):Int;
	function w32(value:Int):Int;
	function w33(value:Int):Int;
	function w34(value:Int):Int;
	function w35(value:Int):Int;
	function w36(value:Int):Int;
	function w37(value:Int):Int;
	function w38(value:Int):Int;
	function w39(value:Int):Int;
	function w40(value:Int):Int;
	function w41(value:Int):Int;
	function w42(value:Int):Int;
	function w43(value:Int):Int;
	function w44(value:Int):Int;
	function w45(value:Int):Int;
	function w46(value:Int):Int;
	function w47(value:Int):Int;
	function w48(value:Int):Int;
	function w49(value:Int):Int;
	function w50(value:Int):Int;
	function w51(value:Int):Int;
	function w52(value:Int):Int;
	function w53(value:Int):Int;
	function w54(value:Int):Int;
	function w55(value:Int):Int;
	function w56(value:Int):Int;
	function w57(value:Int):Int;
	function w58(value:Int):Int;
	function w59(value:Int):Int;
	function w60(value:Int):Int;
	function w61(value:Int):Int;
	function w62(value:Int):Int;
	function w63(value:Int):Int;
	function w64(value:Int):Int;
	function w65(value:Int):Int;
	function w66(value:Int):Int;
	function w67(value:Int):Int;
	function w68(value:Int):Int;
	function w69(value:Int):Int;
	function w70(value:Int):Int;
	function w71(value:Int):Int;
	function w72(value:Int):Int;
	function w73(value:Int):Int;
	function w74(value:Int):Int;
	function w75(value:Int):Int;
	function w76(value:Int):Int;
	function w77(value:Int):Int;
	function w78(value:Int):Int;
	function w79(value:Int):Int;
	function w80(value:Int):Int;
	function w81(value:Int):Int;
	function w82(value:Int):Int;
	function w83(value:Int):Int;
	function w84(value:Int):Int;
	function w85(value:Int):Int;
	function w86(value:Int):Int;
	function w87(value:Int):Int;
	function w88(value:Int):Int;
	function w89(value:Int):Int;
	function w90(value:Int):Int;
	function w91(value:Int):Int;
	function w92(value:Int):Int;
	function w93(value:Int):Int;
	function w94(value:Int):Int;
	function w95(value:Int):Int;
	function w96(value:Int):Int;
	function w97(value:Int):Int;
	function w98(value:Int):Int;
	function w99(value:Int):Int;
	function w100(value:Int):Int;
	function w101(value:Int):Int;
	function w102(value:Int):Int;
	function w103(value:Int):Int;
	function w104(value:Int):Int;
	function w105(value:Int):Int;
	function w106(value:Int):Int;
	function w107(value:Int):Int;
	function w108(value:Int):Int;
	function w109(value:Int):Int;
	function w110(value:Int):Int;
	function w111(value:Int):Int;
	function w112(value:Int):Int;
	function w113(value:Int):Int;
	function w114(value:Int):Int;
	function w115(value:Int):Int;
	function w116(value:Int):Int;
	function w117(value:Int):Int;
	function w118(value:Int):Int;
	function w119(value:Int):Int;
	function w120(value:Int):Int;
	function w121(value:Int):Int;
	function w122(value:Int):Int;
	function w123(value:Int):Int;
	function w124(value:Int):Int;
	function w125(value:Int):Int;
	function w126(value:Int):Int;
	function w127(value:Int):Int;
	function w128(value:Int):Int;
	function w129(value:Int):Int;
	function w130(value:Int):Int;
	function w131(value:Int):Int;
	function w132(value:Int):Int;
	function w133(value:Int):Int;
	function w134(value:Int):Int;
	function w135(value:Int):Int;
	function w136(value:Int):Int;
	function w137(value:Int):Int;
	function w138(value:Int):Int;
	function w139(value:Int):Int;
	function w140(value:Int):Int;
	function w141(value:Int):Int;
	function w142(value:Int):Int;
	function w143(value:Int):Int;
	function w144(value:Int):Int;
	function w145(value:Int):Int;
	function w146(value:Int):Int;
	function w147(value:Int):Int;
	function w148(value:Int):Int;
	function w149(value:Int):Int;
	function w150(value:Int):Int;
	function w151(value:Int):Int;
	function w152(value:Int):Int;
	function w153(value:Int):Int;
	function w154(value:Int):Int;
	function w155(value:Int):Int;
	function w156(value:Int):Int;
	function w157(value:Int):Int;
	function w158(value:Int):Int;
	function w159(value:Int):Int;
	function w160(value:Int):Int;
	function w161(value:Int):Int;
	function w162(value:Int):Int;
	function w163(value:Int):Int;
	function w164(value:Int):Int;
	function w165(value:Int):Int;
	function w166(value:Int):Int;
	function w167(value:Int):Int;
	function w168(value:Int):Int;
	function w169(value:Int):Int;
	function w170(value:Int):Int;
	function w171(value:Int):Int;
	function w172(value:Int):Int;
	function w173(value:Int):Int;
	function w174(value:Int):Int;
	function w175(value:Int):Int;
	function w176(value:Int):Int;
	function w177(value:Int):Int;
	function w178(value:Int):Int;
	function w179(value:Int):Int;
	function w180(value:Int):Int;
	function w181(value:Int):Int;
	function w182(value:Int):Int;
	function w183(value:Int):Int;
	function w184(value:Int):Int;
	function w185(value:Int):Int;
	function w186(value:Int):Int;
	function w187(value:Int):Int;
	function w188(value:Int):Int;
	function w189(value:Int):Int;
	function w190(value:Int):Int;
	function w191(value:Int):Int;
	function w192(value:Int):Int;
	function w193(value:Int):Int;
	function w194(value:Int):Int;
	function w195(value:Int):Int;
	function w196(value:Int):Int;
	function w197(value:Int):Int;
	function w198(value:Int):Int;
	function w199(value:Int):Int;
	function w200(value:Int):Int;
	function w201(value:Int):Int;
	function w202(value:Int):Int;
	function w203(value:Int):Int;
	function w204(value:Int):Int;
	function w205(value:Int):Int;
	function w206(value:Int):Int;
	function w207(value:Int):Int;
	function w208(value:Int):Int;
	function w209(value:Int):Int;
	function w210(value:Int):Int;
	function w211(value:Int):Int;
	function w212(value:Int):Int;
	function w213(value:Int):Int;
	function w214(value:Int):Int;
	function w215(value:Int):Int;
	function w216(value:Int):Int;
	function w217(value:Int):Int;
	function w218(value:Int):Int;
	function w219(value:Int):Int;
	function w220(value:Int):Int;
	function w221(value:Int):Int;
	function w222(value:Int):Int;
	function w223(value:Int):Int;
	function w224(value:Int):Int;
	function w225(value:Int):Int;
	function w226(value:Int):Int;
	function w227(value:Int):Int;
	function w228(value:Int):Int;
	function w229(value:Int):Int;
	function w230(value:Int):Int;
	function w231(value:Int):Int;
	function w232(value:Int):Int;
	function w233(value:Int):Int;
	function w234(value:Int):Int;
	function w235(value:Int):Int;
	function w236(value:Int):Int;
	function w237(value:Int):Int;
	function w238(value:Int):Int;
	function w239(value:Int):Int;
	function w240(value:Int):Int;
	function w241(value:Int):Int;
	function w242(value:Int):Int;
	function w243(value:Int):Int;
	function w244(value:Int):Int;
	function w245(value:Int):Int;
	function w246(value:Int):Int;
	function w247(value:Int):Int;
	function w248(value:Int):Int;
	function w249(value:Int):Int;
	function w250(value:Int):Int;
	function w251(value:Int):Int;
	function w252(value:Int):Int;
	function w253(value:Int):Int;
	function w254(value:Int):Int;
	function w255(value:Int):Int;
	function w256(value:Int):Int;
	function w257(value:Int):Int;
	function w258(value:Int):Int;
	function w259(value:Int):Int;
	function w260(value:Int):Int;
	function w261(value:Int):Int;
	function w262(value:Int):Int;
	function w263(value:Int):Int;
	function w264(value:Int):Int;
	function w265(value:Int):Int;
	function w266(value:Int):Int;
	function w267(value:Int):Int;
	function w268(value:Int):Int;
	function w269(value:Int):Int;
	function w270(value:Int):Int;
	function w271(value:Int):Int;
	function w272(value:Int):Int;
	function w273(value:Int):Int;
	function w274(value:Int):Int;
	function w275(value:Int):Int;
	function w276(value:Int):Int;
	function w277(value:Int):Int;
	function w278(value:Int):Int;
	function w279(value:Int):Int;
	function w280(value:Int):Int;
	function w281(value:Int):Int;
	function w282(value:Int):Int;
	function w283(value:Int):Int;
	function w284(value:Int):Int;
	function w285(value:Int):Int;
	function w286(value:Int):Int;
	function w287(value:Int):Int;
	function w288(value:Int):Int;
	function w289(value:Int):Int;
	function w290(value:Int):Int;
	function w291(value:Int):Int;
	function w292(value:Int):Int;
	function w293(value:Int):Int;
	function w294(value:Int):Int;
	function w295(value:Int):Int;
	function w296(value:Int):Int;
	function w297(value:Int):Int;
	function w298(value:Int):Int;
	function w299(value:Int):Int;
}

@:rpcContract(WideContract)
private class WideCommands extends RPCCommands {
	public function new() {}
}

private class WideHandler extends RPCHandler implements WideContract {
	public function new() {}

	public function w0(value:Int):Int {
		return value + 0;
	}

	public function w1(value:Int):Int {
		return value + 1;
	}

	public function w2(value:Int):Int {
		return value + 2;
	}

	public function w3(value:Int):Int {
		return value + 3;
	}

	public function w4(value:Int):Int {
		return value + 4;
	}

	public function w5(value:Int):Int {
		return value + 5;
	}

	public function w6(value:Int):Int {
		return value + 6;
	}

	public function w7(value:Int):Int {
		return value + 7;
	}

	public function w8(value:Int):Int {
		return value + 8;
	}

	public function w9(value:Int):Int {
		return value + 9;
	}

	public function w10(value:Int):Int {
		return value + 10;
	}

	public function w11(value:Int):Int {
		return value + 11;
	}

	public function w12(value:Int):Int {
		return value + 12;
	}

	public function w13(value:Int):Int {
		return value + 13;
	}

	public function w14(value:Int):Int {
		return value + 14;
	}

	public function w15(value:Int):Int {
		return value + 15;
	}

	public function w16(value:Int):Int {
		return value + 16;
	}

	public function w17(value:Int):Int {
		return value + 17;
	}

	public function w18(value:Int):Int {
		return value + 18;
	}

	public function w19(value:Int):Int {
		return value + 19;
	}

	public function w20(value:Int):Int {
		return value + 20;
	}

	public function w21(value:Int):Int {
		return value + 21;
	}

	public function w22(value:Int):Int {
		return value + 22;
	}

	public function w23(value:Int):Int {
		return value + 23;
	}

	public function w24(value:Int):Int {
		return value + 24;
	}

	public function w25(value:Int):Int {
		return value + 25;
	}

	public function w26(value:Int):Int {
		return value + 26;
	}

	public function w27(value:Int):Int {
		return value + 27;
	}

	public function w28(value:Int):Int {
		return value + 28;
	}

	public function w29(value:Int):Int {
		return value + 29;
	}

	public function w30(value:Int):Int {
		return value + 30;
	}

	public function w31(value:Int):Int {
		return value + 31;
	}

	public function w32(value:Int):Int {
		return value + 32;
	}

	public function w33(value:Int):Int {
		return value + 33;
	}

	public function w34(value:Int):Int {
		return value + 34;
	}

	public function w35(value:Int):Int {
		return value + 35;
	}

	public function w36(value:Int):Int {
		return value + 36;
	}

	public function w37(value:Int):Int {
		return value + 37;
	}

	public function w38(value:Int):Int {
		return value + 38;
	}

	public function w39(value:Int):Int {
		return value + 39;
	}

	public function w40(value:Int):Int {
		return value + 40;
	}

	public function w41(value:Int):Int {
		return value + 41;
	}

	public function w42(value:Int):Int {
		return value + 42;
	}

	public function w43(value:Int):Int {
		return value + 43;
	}

	public function w44(value:Int):Int {
		return value + 44;
	}

	public function w45(value:Int):Int {
		return value + 45;
	}

	public function w46(value:Int):Int {
		return value + 46;
	}

	public function w47(value:Int):Int {
		return value + 47;
	}

	public function w48(value:Int):Int {
		return value + 48;
	}

	public function w49(value:Int):Int {
		return value + 49;
	}

	public function w50(value:Int):Int {
		return value + 50;
	}

	public function w51(value:Int):Int {
		return value + 51;
	}

	public function w52(value:Int):Int {
		return value + 52;
	}

	public function w53(value:Int):Int {
		return value + 53;
	}

	public function w54(value:Int):Int {
		return value + 54;
	}

	public function w55(value:Int):Int {
		return value + 55;
	}

	public function w56(value:Int):Int {
		return value + 56;
	}

	public function w57(value:Int):Int {
		return value + 57;
	}

	public function w58(value:Int):Int {
		return value + 58;
	}

	public function w59(value:Int):Int {
		return value + 59;
	}

	public function w60(value:Int):Int {
		return value + 60;
	}

	public function w61(value:Int):Int {
		return value + 61;
	}

	public function w62(value:Int):Int {
		return value + 62;
	}

	public function w63(value:Int):Int {
		return value + 63;
	}

	public function w64(value:Int):Int {
		return value + 64;
	}

	public function w65(value:Int):Int {
		return value + 65;
	}

	public function w66(value:Int):Int {
		return value + 66;
	}

	public function w67(value:Int):Int {
		return value + 67;
	}

	public function w68(value:Int):Int {
		return value + 68;
	}

	public function w69(value:Int):Int {
		return value + 69;
	}

	public function w70(value:Int):Int {
		return value + 70;
	}

	public function w71(value:Int):Int {
		return value + 71;
	}

	public function w72(value:Int):Int {
		return value + 72;
	}

	public function w73(value:Int):Int {
		return value + 73;
	}

	public function w74(value:Int):Int {
		return value + 74;
	}

	public function w75(value:Int):Int {
		return value + 75;
	}

	public function w76(value:Int):Int {
		return value + 76;
	}

	public function w77(value:Int):Int {
		return value + 77;
	}

	public function w78(value:Int):Int {
		return value + 78;
	}

	public function w79(value:Int):Int {
		return value + 79;
	}

	public function w80(value:Int):Int {
		return value + 80;
	}

	public function w81(value:Int):Int {
		return value + 81;
	}

	public function w82(value:Int):Int {
		return value + 82;
	}

	public function w83(value:Int):Int {
		return value + 83;
	}

	public function w84(value:Int):Int {
		return value + 84;
	}

	public function w85(value:Int):Int {
		return value + 85;
	}

	public function w86(value:Int):Int {
		return value + 86;
	}

	public function w87(value:Int):Int {
		return value + 87;
	}

	public function w88(value:Int):Int {
		return value + 88;
	}

	public function w89(value:Int):Int {
		return value + 89;
	}

	public function w90(value:Int):Int {
		return value + 90;
	}

	public function w91(value:Int):Int {
		return value + 91;
	}

	public function w92(value:Int):Int {
		return value + 92;
	}

	public function w93(value:Int):Int {
		return value + 93;
	}

	public function w94(value:Int):Int {
		return value + 94;
	}

	public function w95(value:Int):Int {
		return value + 95;
	}

	public function w96(value:Int):Int {
		return value + 96;
	}

	public function w97(value:Int):Int {
		return value + 97;
	}

	public function w98(value:Int):Int {
		return value + 98;
	}

	public function w99(value:Int):Int {
		return value + 99;
	}

	public function w100(value:Int):Int {
		return value + 100;
	}

	public function w101(value:Int):Int {
		return value + 101;
	}

	public function w102(value:Int):Int {
		return value + 102;
	}

	public function w103(value:Int):Int {
		return value + 103;
	}

	public function w104(value:Int):Int {
		return value + 104;
	}

	public function w105(value:Int):Int {
		return value + 105;
	}

	public function w106(value:Int):Int {
		return value + 106;
	}

	public function w107(value:Int):Int {
		return value + 107;
	}

	public function w108(value:Int):Int {
		return value + 108;
	}

	public function w109(value:Int):Int {
		return value + 109;
	}

	public function w110(value:Int):Int {
		return value + 110;
	}

	public function w111(value:Int):Int {
		return value + 111;
	}

	public function w112(value:Int):Int {
		return value + 112;
	}

	public function w113(value:Int):Int {
		return value + 113;
	}

	public function w114(value:Int):Int {
		return value + 114;
	}

	public function w115(value:Int):Int {
		return value + 115;
	}

	public function w116(value:Int):Int {
		return value + 116;
	}

	public function w117(value:Int):Int {
		return value + 117;
	}

	public function w118(value:Int):Int {
		return value + 118;
	}

	public function w119(value:Int):Int {
		return value + 119;
	}

	public function w120(value:Int):Int {
		return value + 120;
	}

	public function w121(value:Int):Int {
		return value + 121;
	}

	public function w122(value:Int):Int {
		return value + 122;
	}

	public function w123(value:Int):Int {
		return value + 123;
	}

	public function w124(value:Int):Int {
		return value + 124;
	}

	public function w125(value:Int):Int {
		return value + 125;
	}

	public function w126(value:Int):Int {
		return value + 126;
	}

	public function w127(value:Int):Int {
		return value + 127;
	}

	public function w128(value:Int):Int {
		return value + 128;
	}

	public function w129(value:Int):Int {
		return value + 129;
	}

	public function w130(value:Int):Int {
		return value + 130;
	}

	public function w131(value:Int):Int {
		return value + 131;
	}

	public function w132(value:Int):Int {
		return value + 132;
	}

	public function w133(value:Int):Int {
		return value + 133;
	}

	public function w134(value:Int):Int {
		return value + 134;
	}

	public function w135(value:Int):Int {
		return value + 135;
	}

	public function w136(value:Int):Int {
		return value + 136;
	}

	public function w137(value:Int):Int {
		return value + 137;
	}

	public function w138(value:Int):Int {
		return value + 138;
	}

	public function w139(value:Int):Int {
		return value + 139;
	}

	public function w140(value:Int):Int {
		return value + 140;
	}

	public function w141(value:Int):Int {
		return value + 141;
	}

	public function w142(value:Int):Int {
		return value + 142;
	}

	public function w143(value:Int):Int {
		return value + 143;
	}

	public function w144(value:Int):Int {
		return value + 144;
	}

	public function w145(value:Int):Int {
		return value + 145;
	}

	public function w146(value:Int):Int {
		return value + 146;
	}

	public function w147(value:Int):Int {
		return value + 147;
	}

	public function w148(value:Int):Int {
		return value + 148;
	}

	public function w149(value:Int):Int {
		return value + 149;
	}

	public function w150(value:Int):Int {
		return value + 150;
	}

	public function w151(value:Int):Int {
		return value + 151;
	}

	public function w152(value:Int):Int {
		return value + 152;
	}

	public function w153(value:Int):Int {
		return value + 153;
	}

	public function w154(value:Int):Int {
		return value + 154;
	}

	public function w155(value:Int):Int {
		return value + 155;
	}

	public function w156(value:Int):Int {
		return value + 156;
	}

	public function w157(value:Int):Int {
		return value + 157;
	}

	public function w158(value:Int):Int {
		return value + 158;
	}

	public function w159(value:Int):Int {
		return value + 159;
	}

	public function w160(value:Int):Int {
		return value + 160;
	}

	public function w161(value:Int):Int {
		return value + 161;
	}

	public function w162(value:Int):Int {
		return value + 162;
	}

	public function w163(value:Int):Int {
		return value + 163;
	}

	public function w164(value:Int):Int {
		return value + 164;
	}

	public function w165(value:Int):Int {
		return value + 165;
	}

	public function w166(value:Int):Int {
		return value + 166;
	}

	public function w167(value:Int):Int {
		return value + 167;
	}

	public function w168(value:Int):Int {
		return value + 168;
	}

	public function w169(value:Int):Int {
		return value + 169;
	}

	public function w170(value:Int):Int {
		return value + 170;
	}

	public function w171(value:Int):Int {
		return value + 171;
	}

	public function w172(value:Int):Int {
		return value + 172;
	}

	public function w173(value:Int):Int {
		return value + 173;
	}

	public function w174(value:Int):Int {
		return value + 174;
	}

	public function w175(value:Int):Int {
		return value + 175;
	}

	public function w176(value:Int):Int {
		return value + 176;
	}

	public function w177(value:Int):Int {
		return value + 177;
	}

	public function w178(value:Int):Int {
		return value + 178;
	}

	public function w179(value:Int):Int {
		return value + 179;
	}

	public function w180(value:Int):Int {
		return value + 180;
	}

	public function w181(value:Int):Int {
		return value + 181;
	}

	public function w182(value:Int):Int {
		return value + 182;
	}

	public function w183(value:Int):Int {
		return value + 183;
	}

	public function w184(value:Int):Int {
		return value + 184;
	}

	public function w185(value:Int):Int {
		return value + 185;
	}

	public function w186(value:Int):Int {
		return value + 186;
	}

	public function w187(value:Int):Int {
		return value + 187;
	}

	public function w188(value:Int):Int {
		return value + 188;
	}

	public function w189(value:Int):Int {
		return value + 189;
	}

	public function w190(value:Int):Int {
		return value + 190;
	}

	public function w191(value:Int):Int {
		return value + 191;
	}

	public function w192(value:Int):Int {
		return value + 192;
	}

	public function w193(value:Int):Int {
		return value + 193;
	}

	public function w194(value:Int):Int {
		return value + 194;
	}

	public function w195(value:Int):Int {
		return value + 195;
	}

	public function w196(value:Int):Int {
		return value + 196;
	}

	public function w197(value:Int):Int {
		return value + 197;
	}

	public function w198(value:Int):Int {
		return value + 198;
	}

	public function w199(value:Int):Int {
		return value + 199;
	}

	public function w200(value:Int):Int {
		return value + 200;
	}

	public function w201(value:Int):Int {
		return value + 201;
	}

	public function w202(value:Int):Int {
		return value + 202;
	}

	public function w203(value:Int):Int {
		return value + 203;
	}

	public function w204(value:Int):Int {
		return value + 204;
	}

	public function w205(value:Int):Int {
		return value + 205;
	}

	public function w206(value:Int):Int {
		return value + 206;
	}

	public function w207(value:Int):Int {
		return value + 207;
	}

	public function w208(value:Int):Int {
		return value + 208;
	}

	public function w209(value:Int):Int {
		return value + 209;
	}

	public function w210(value:Int):Int {
		return value + 210;
	}

	public function w211(value:Int):Int {
		return value + 211;
	}

	public function w212(value:Int):Int {
		return value + 212;
	}

	public function w213(value:Int):Int {
		return value + 213;
	}

	public function w214(value:Int):Int {
		return value + 214;
	}

	public function w215(value:Int):Int {
		return value + 215;
	}

	public function w216(value:Int):Int {
		return value + 216;
	}

	public function w217(value:Int):Int {
		return value + 217;
	}

	public function w218(value:Int):Int {
		return value + 218;
	}

	public function w219(value:Int):Int {
		return value + 219;
	}

	public function w220(value:Int):Int {
		return value + 220;
	}

	public function w221(value:Int):Int {
		return value + 221;
	}

	public function w222(value:Int):Int {
		return value + 222;
	}

	public function w223(value:Int):Int {
		return value + 223;
	}

	public function w224(value:Int):Int {
		return value + 224;
	}

	public function w225(value:Int):Int {
		return value + 225;
	}

	public function w226(value:Int):Int {
		return value + 226;
	}

	public function w227(value:Int):Int {
		return value + 227;
	}

	public function w228(value:Int):Int {
		return value + 228;
	}

	public function w229(value:Int):Int {
		return value + 229;
	}

	public function w230(value:Int):Int {
		return value + 230;
	}

	public function w231(value:Int):Int {
		return value + 231;
	}

	public function w232(value:Int):Int {
		return value + 232;
	}

	public function w233(value:Int):Int {
		return value + 233;
	}

	public function w234(value:Int):Int {
		return value + 234;
	}

	public function w235(value:Int):Int {
		return value + 235;
	}

	public function w236(value:Int):Int {
		return value + 236;
	}

	public function w237(value:Int):Int {
		return value + 237;
	}

	public function w238(value:Int):Int {
		return value + 238;
	}

	public function w239(value:Int):Int {
		return value + 239;
	}

	public function w240(value:Int):Int {
		return value + 240;
	}

	public function w241(value:Int):Int {
		return value + 241;
	}

	public function w242(value:Int):Int {
		return value + 242;
	}

	public function w243(value:Int):Int {
		return value + 243;
	}

	public function w244(value:Int):Int {
		return value + 244;
	}

	public function w245(value:Int):Int {
		return value + 245;
	}

	public function w246(value:Int):Int {
		return value + 246;
	}

	public function w247(value:Int):Int {
		return value + 247;
	}

	public function w248(value:Int):Int {
		return value + 248;
	}

	public function w249(value:Int):Int {
		return value + 249;
	}

	public function w250(value:Int):Int {
		return value + 250;
	}

	public function w251(value:Int):Int {
		return value + 251;
	}

	public function w252(value:Int):Int {
		return value + 252;
	}

	public function w253(value:Int):Int {
		return value + 253;
	}

	public function w254(value:Int):Int {
		return value + 254;
	}

	public function w255(value:Int):Int {
		return value + 255;
	}

	public function w256(value:Int):Int {
		return value + 256;
	}

	public function w257(value:Int):Int {
		return value + 257;
	}

	public function w258(value:Int):Int {
		return value + 258;
	}

	public function w259(value:Int):Int {
		return value + 259;
	}

	public function w260(value:Int):Int {
		return value + 260;
	}

	public function w261(value:Int):Int {
		return value + 261;
	}

	public function w262(value:Int):Int {
		return value + 262;
	}

	public function w263(value:Int):Int {
		return value + 263;
	}

	public function w264(value:Int):Int {
		return value + 264;
	}

	public function w265(value:Int):Int {
		return value + 265;
	}

	public function w266(value:Int):Int {
		return value + 266;
	}

	public function w267(value:Int):Int {
		return value + 267;
	}

	public function w268(value:Int):Int {
		return value + 268;
	}

	public function w269(value:Int):Int {
		return value + 269;
	}

	public function w270(value:Int):Int {
		return value + 270;
	}

	public function w271(value:Int):Int {
		return value + 271;
	}

	public function w272(value:Int):Int {
		return value + 272;
	}

	public function w273(value:Int):Int {
		return value + 273;
	}

	public function w274(value:Int):Int {
		return value + 274;
	}

	public function w275(value:Int):Int {
		return value + 275;
	}

	public function w276(value:Int):Int {
		return value + 276;
	}

	public function w277(value:Int):Int {
		return value + 277;
	}

	public function w278(value:Int):Int {
		return value + 278;
	}

	public function w279(value:Int):Int {
		return value + 279;
	}

	public function w280(value:Int):Int {
		return value + 280;
	}

	public function w281(value:Int):Int {
		return value + 281;
	}

	public function w282(value:Int):Int {
		return value + 282;
	}

	public function w283(value:Int):Int {
		return value + 283;
	}

	public function w284(value:Int):Int {
		return value + 284;
	}

	public function w285(value:Int):Int {
		return value + 285;
	}

	public function w286(value:Int):Int {
		return value + 286;
	}

	public function w287(value:Int):Int {
		return value + 287;
	}

	public function w288(value:Int):Int {
		return value + 288;
	}

	public function w289(value:Int):Int {
		return value + 289;
	}

	public function w290(value:Int):Int {
		return value + 290;
	}

	public function w291(value:Int):Int {
		return value + 291;
	}

	public function w292(value:Int):Int {
		return value + 292;
	}

	public function w293(value:Int):Int {
		return value + 293;
	}

	public function w294(value:Int):Int {
		return value + 294;
	}

	public function w295(value:Int):Int {
		return value + 295;
	}

	public function w296(value:Int):Int {
		return value + 296;
	}

	public function w297(value:Int):Int {
		return value + 297;
	}

	public function w298(value:Int):Int {
		return value + 298;
	}

	public function w299(value:Int):Int {
		return value + 299;
	}
}

private class WideHeard implements RPCIntReceiver {
	public final answers:Array<Int> = [];

	public function new() {}

	public function onInt(call:Int, value:Int):Void {
		answers.push(value);
	}

	public function onFailure(call:Int, failure:RPCFailure):Void {
		answers.push(-1);
	}
}
