package crossbyte._internal.compression;

import crossbyte._internal.brotli.Brotli;
import haxe.io.Bytes;
import haxe.Timer;
import utest.Assert;

/**
 * The pure Brotli codec, as a peer reaches it: every request body sent with
 * `Content-Encoding: br` and every response a client asked for in br decodes
 * through here, on whichever thread happened to receive it.
 */
class BrotliCodecTest extends utest.Test {
	/**
	 * Four bytes declaring a 16 MB metadata block, and then the end.
	 *
	 * The loop skipping metadata asked for more input, was told there was
	 * none, and went round again with the same length still to skip: forever,
	 * and without allocating, so no output ceiling ever tripped. One POST
	 * carrying these bytes stopped a server answering anyone, since its
	 * timeouts and its rate limiter all run on the thread that was stuck.
	 */
	public function testATruncatedMetadataBlockFailsRatherThanSpinning():Void {
		for (hex in ["ecffff7f", "2c01aa", "2c01", "2c"]) {
			var started:Float = Timer.stamp();
			Assert.raises(() -> Brotli.decompress(Bytes.ofHex(hex), 1 << 20), null, hex + " decoded");
			Assert.isTrue(Timer.stamp() - started < 5.0, hex + " took " + (Timer.stamp() - started) + "s to fail");
		}
	}

	/**
	 * The same block, complete: three bytes of metadata between the header and
	 * an empty last meta-block. A decoder must skip them and produce nothing,
	 * which is what Node's zlib does with these six bytes.
	 */
	public function testAMetadataBlockIsSkipped():Void {
		Assert.equals(0, Brotli.decompress(Bytes.ofHex("2c01aabbcc03"), 1 << 20).length);
	}

	/**
	 * A stream that ends where the literal context map should begin.
	 *
	 * The decoder scanned that map before asking whether it had been read, so
	 * it walked a map that was never allocated: null. On eval and the jvm that
	 * surfaced as an exception from inside the decoder, and natively as a
	 * segfault, the fuzz suite took the whole native runner down with the
	 * first four bytes of a valid stream. It must be refused as the codec
	 * refuses any other damaged stream.
	 */
	public function testAStreamEndingBeforeItsContextMapIsRefused():Void {
		for (hex in ["1b500000", "1b5000"]) {
			var refusal:String = null;
			try {
				Brotli.decompress(Bytes.ofHex(hex), 1 << 20);
			} catch (e:Dynamic) {
				refusal = Std.string(e);
			}
			Assert.equals("Brotli decompression failed", refusal, hex);
		}
	}

	/**
	 * CF FF FF FF: a 16 MB window, then a 16 MB uncompressed meta-block, then
	 * nothing.
	 *
	 * The decoder allocated the window the stream header named before it read
	 * a byte of data, and only then found the data missing: a ring buffer of
	 * sixteen million entries, bytes or more each, for four bytes of input,
	 * whatever the caller's limit. A meta-block states its length up front, so
	 * one longer than the limit is refused as its header is read, and nothing
	 * is allocated for it.
	 */
	public function testAMetaBlockLongerThanTheLimitIsRefusedAtItsHeader():Void {
		var refusal:String = null;
		try {
			Brotli.decompress(Bytes.ofHex("cfffffff"), 1 << 20);
		} catch (e:Dynamic) {
			refusal = Std.string(e);
		}
		Assert.isTrue(refusal != null && refusal.indexOf("exceeded") >= 0, "refused as " + refusal);
	}

	/**
	 * Eighteen bytes asking for a 16 MB window and decoding to twelve, as a
	 * client is free to send them. Each allocated the whole window: 38.7 ms
	 * per request on a Node server, 137 ms on eval. The ring buffer now grows
	 * with the output, so this is a 1 KB buffer.
	 */
	public function testASmallStreamWithALargeWindowDecodesCheaply():Void {
		var body:Bytes = Bytes.ofHex("8f02807b226f6b223a200008747275657d03");
		var started:Float = Timer.stamp();
		for (i in 0...100) {
			Assert.equals('{"ok":true}', Brotli.decompress(body, 1 << 20).toString());
		}
		var elapsed:Float = Timer.stamp() - started;
		Assert.isTrue(elapsed < 3.0, "100 decodes took " + elapsed + "s");
	}

	/**
	 * 4,200 bytes of noise under a 1 KB window, as Node's zlib writes them: a
	 * run of uncompressed meta-blocks, each wrapping the ring buffer.
	 *
	 * Flushing a wrapped ring buffer in the middle of an uncompressed block
	 * added the buffer's size back to the bytes still to copy, so the decoder
	 * read on past the block into whatever followed and refused a valid
	 * stream. Any window small enough to wrap on incompressible data did it.
	 */
	public function testIncompressibleDataUnderASmallWindowDecodes():Void {
		var expected:Bytes = Bytes.alloc(4200);
		var state:Int = 0x2468ACE1;
		for (i in 0...expected.length) {
			state ^= state << 13;
			state ^= state >>> 17;
			state ^= state << 5;
			expected.set(i, (state >>> 16) & 0xFF);
		}

		var decoded:Bytes = Brotli.decompress(Bytes.ofHex(SMALL_WINDOW_NOISE), 1 << 20);
		Assert.equals(expected.length, decoded.length);
		Assert.equals(0, expected.compare(decoded), "decoded bytes differ");
	}

	/** 174 bytes of English as Node's zlib writes them at quality 11: 53 bytes, mostly references into the static dictionary. **/
	private static inline var DICTIONARY_TEXT:String = "The government information about the international community was available through the university library, although the development of the environment remained controversial.";

	private static inline var DICTIONARY_STREAM:String = "a215009c34884bd81d68c981536b4be449eb1e9a47af5771363226381b58c05bb1e9b80fa23021ed853645b28fb233a93a2d3b9a08";

	public function testAStreamOfDictionaryReferencesDecodes():Void {
		Assert.equals(DICTIONARY_TEXT, Brotli.decompress(Bytes.ofHex(DICTIONARY_STREAM), 1 << 20).toString());
	}

	#if target.threaded
	/**
	 * Eight threads meeting the codec for the first time at once.
	 *
	 * The dictionary tables were marked built before they were built, so a
	 * thread arriving while another built them read a dictionary that was
	 * null or half filled: on the jvm seven threads in eight threw, in six
	 * runs of six, and natively about one run in nine crashed the process.
	 * URLLoader decodes on up to sixteen pool threads, so a burst of loads at
	 * startup is exactly this. Each thread decodes a stream made of dictionary
	 * references, which reads the dictionary, and encodes text, which reads
	 * the hash built from it.
	 */
	public function testThreadsMeetingTheCodecAtOnceAllSucceed():Void {
		var threads:Int = 8;
		var packed:Bytes = Bytes.ofHex(DICTIONARY_STREAM);

		for (round in 0...10) {
			crossbyte._internal.brotli.codec.BrotliCodec.__forgetTables();

			var go = new sys.thread.Lock();
			var results = new sys.thread.Deque<String>();
			for (i in 0...threads) {
				sys.thread.Thread.create(() -> {
					go.wait();
					try {
						var decoded:String = Brotli.decompress(packed, 1 << 20).toString();
						var again:String = Brotli.decompress(Brotli.compress(Bytes.ofString(DICTIONARY_TEXT)), 1 << 20).toString();
						results.add(decoded == DICTIONARY_TEXT && again == DICTIONARY_TEXT ? "ok" : "decoded wrongly: " + decoded);
					} catch (e:Dynamic) {
						results.add("threw: " + Std.string(e));
					}
				});
			}

			for (i in 0...threads) {
				go.release();
			}
			for (i in 0...threads) {
				var result:String = results.pop(true);
				Assert.equals("ok", result, "round " + round + ", thread " + i + ": " + result);
			}
		}
	}
	#end

	/** Node's zlib, quality 5, BROTLI_PARAM_LGWIN 10, over the 4,200 bytes testIncompressibleDataUnderASmallWindowDecodes makes. **/
	private static final SMALL_WINDOW_NOISE:String = [
		"219c410466ab79866022cb5dd88c8bb419884f74474f46e7b8f3d1a61573b48eb9d55d44bf75c633202317558a06b64e909c46057f476555",
		"c14b0e1c8d9cb55b433129fe1058f7927209eb4f99427354feb73a847cf5b66356d57bdd74174fcb1a6385e9a4b1f53c73d828d71aa1d11e",
		"03f2fd6caf6074642f41809d200512b6544063d4a28a29d9395a359e2fd72a474d4257cf843fdb71840d68c8d77c41eb2b5e1521c43ea259",
		"fdf5f7174416de44a1f74ea26957ac16273bb539c62e7033c36b8f8a382f1a4331da7a6f1483d7ff0cac3cc46a64f3243da0c77978713b4b",
		"71a46c3017b4f8008a8c2fc6267c52727472c605cad08ca165ec3c6713b9c1548ed8147cf377c5959acc8f1f1156f972b51c3a7856701cf3",
		"378d4b76941679ab747d89794da1f409a286deb7ab828cee97931a26834c8b2208c89ec231fbc21d04abd8b308c8c0764a0c78e02a743e5f",
		"0b5dba90b57fcf211dc9b021facfc11c14de904b6bb91b06aab0fe8da677924907d6c888af4694970dd972d7dd76a5d41b5504a43324fb08",
		"3a00a89ec45a3b0cd9b01c03e6c28eeda6a8c069cf317a3b5c958d2d71c95daf2d76aa430a749c3b33bf7d1bd78edfac5a9770bb3d5e0b0a",
		"50785ee3f9149f82426596fe45411bd652f6a7256a88c8233d74d3523757844af1406aa686cf052ed16f549ac3dc054be53dbdff78bfa2fc",
		"6c7ff11b1686e26f6db39f7fbe6b4fe5b2915b21fe40407c334814770d55b294c25c636d9f3a63a3fccb7ef02bab917e6b6789c27cfe6620",
		"d87f130592ea37532b3b657f1e1725d85d9d69b0d489ec913e1acfd8b5f96f1e30a417cae9420efaaf1149eef5d47b5908958e5c371e0ff8",
		"96bb66c62c174b2463b2497d6200fe969678a2a66c9a4e0a37e478acf4a819f48d6a82496cb14495cd2ab7c92c381ccaad219b9ff08b9f6f",
		"d5bc5058db81b6d46bcf1eabf5c2d7aeee258ca773631c47a1f45789e405e903cb11b721417031e809dd809ef1934d8d5a6bb7f0caeee8f3",
		"2190557c5f3cd918ef25decf516602e0eea645b7b67dd42de01e3aff7e3ac248a0b5b8396fcdb57c2d0e489509a3017e38cf1d9c10b4c238",
		"27c9c08efdbf736c8e203595a501feccdc0dd190e00a098a082f19f72d4bab86e022f3b62619b356599ce2e5345ef38f8f3180c0ce04097d",
		"95cb79145cddc05b08158f84f4528ce5c857fdba86d68ce16e4757cac5ab952869a9ed0c54fad4ea0ae4cdff94fb8c16583b05e6b1ccf945",
		"d5b3d6b3e2e4d29e66a75c5697d26d9dd1d6ec3c51642b65b6724128ac778afe63f3a674527925d3533df22ee5033ea2f6b34b39548a337a",
		"3eae6cca757f788af81930fd82b1f0dc95449f0bee95bcbf7ed9bc41c6256617d80ecb8c518fb81b88e3da78f7edc4b416a98724777d614b",
		"eeea915b02d69e52f3a5807896df74303bf5af368bebd057451711df9d731f199d1a0590faa3938cc217e875eeff4d1a2c6864271563c92f",
		"c484faaa4a9c65d813b441316bf52eaf0361620e3faaaef886b683001577644a0ce677335e577f8c5d82301a93f36f609e6ec79bf4bf81cd",
		"3f7f16fb138a1a8487325cb37257a7611bb98969a776115806dbe661b47210d559fd71151a22da414ad591ca19ea8ba9b50dfc63719dcd56",
		"0d572ea6cc08368a0a8f5d52a29e02504ca1c3bdc14a682f2fc4ee087981749ab201ea0a97666d0e347659bc118ddd041e34cf4d09d3d3a1",
		"362aedea6e77dd391cc7ad087cc018e89be901a742052b49dd5c8cb474130484d407094143edfe818ce1434000d66bff8d642bdc6ae69af3",
		"9562769d38baf12c4056159f59986282e1cb274557ebc002b5a48b057ea185ecc726b8b5ef0d0b9fde90135d3256e8fb258db5a9a7f82f50",
		"38739d1d687ede9281181a377a1f069821fe9342546a2f55651dc56a37a426ec7182f233d49e80092239326db1e44af3d0f89ff9f861f36b",
		"7b681d0b71c5134876966da68e2e35dbc2f4ec8127420e9aedeee7971d65eabfec528b178a80ca86c53497bdde4b6d53b38679280488fb5c",
		"924bfbf47ca944bc7785c5bbf1f941a7184e0cd583dfd0d908ddb8a961ce1b367ed8e19f9a6153f7125af6ef765e5ae765b1cb1d0672da7c",
		"04846bb7cf39bb45d923071fb08296f7f19fb1662ee27141cc86ced0c16f2c1f79aa593a054c2530d6749702723df82fb57918581701e17b",
		"f104b5b16703f5dbd02095208123e4cea95c7447b2196eed494f00afe84ff71bcadbdf597eb75567acc19900f16f90cff07a21b393a0c78f",
		"91d73f63a346a774da7c31d8b436cd26602fc9ed1f9f52e424c2c4839165df9c2a22a95f4f35f0dfff3f6e738b79a0961dc56c9f92522738",
		"2698c66687b00036250cbdbb588c0b578a4c355eba8224254af13633f478b83d69b9f938e568acdc1b30e8eac79d34ab2feb59fd0667951e",
		"539e635da1c310814459dbc415684cce8dc3594d885ecd5b8e7d71321d6e5c6f9988a0453d9af65a10779a5a1d4577e5c4abba1e2319e57a",
		"19175a645fdd4d3fbf123e82ce417e48f8badad0826482aa6546513b2dd20aed26c83b734529ce0480d01693c137e2723760bf6efaefffad",
		"ce85a1214a4549ed0ca4563443740e955ab88e8a58979dd618d660a571071c20cba7756c7e488db394dea7e3c892a30aa5473b631aef4719",
		"5d199d53d1bd3b6ddbf628f0e6f6297795324cdb1467542d9394a6aeed24ac84180ec0a48173fbdfec1e2e1ddfc42ff8e548155657b8d187",
		"23e43938d3d6ff49ce9f73a201e872823dacd1a2423c33cbc13be4a9e06cc2a5125fe09c05007ec412c5546ae7fae3e57433d76bdbf75ec5",
		"0068cc0d8595008e0c9003ed13063ccfe0e3b0b4815611e6a77f4d139a4488e05308ba5afd136b33dba62a58dca3deb4e09eb38e5e65b95a",
		"d41e749ff656ce486cfa11010518437b2daa37b8a7fcb41e36da4a85cbb86994a671d73aca07d6dd494b63b493a72790ef3aaf80b68a2e97",
		"8dc9e37a09be2016a58dfa7f56bca3e50a60b3368f9e0af2dc31a391fe66d1f392548c47416daf15058e002acb87b85ca018e9b2dde99fae",
		"0b807f02eeda769a204dacfdce55545c5da143e8ed6b59e0d4ede3f388197befb4c389885715ab01009cd60e0cf551a0fd11732f35dc39bb",
		"7bfa45d82456c4dbd6c52f6af71649d4d7a4302e643c2034400fd5b09b839e6d056be87264b1a1b75db6c29e804698252fc31fa7e43b0395",
		"8f62ac9f8900faef0b70295e182390b148d6a4e0f9b3837f67c23047a303350efcd031542dbeb4c5a49ff8e46c82f13714291e265b0a5fc1",
		"9e9f6fe1498e013951f8a5c1fa26f0c034a1d5c8e967581baca7e5755da1bba9653c6ff6f83335d2888dc94032ba9729b7f48fc5e58c3967",
		"40ad0574cf6239d3b4a31645fe72bc39c4e9650adf162f04b592e0df0bb7d2e2101c31f2dea22b4fdb1fac9d398ef6eeea6be97d493b00e6",
		"86a5f4ebbeba0fbfb11d1f4496cc54921e6c47eb52a51587e322f0e624fe17f965c7fdcd37b0ac2ef577f9f9d0413098b79c2827dc57e352",
		"575c1a16ab1d23350e58c7b36d223ac00e5bd451febf1fe97dee39f422c7227749bb1466116778c55fd24f38ab093f7615c902a625610329",
		"5efd483dbadd5a2483b167e41b221ed76c997bfb2c00c1649eab47ab2dbe06124968a862ef27075f759ee97307033cf578e49d588b7a18c5",
		"a89939ee6e671eadc97f4606566e27ce375baccf558020fe4d23ba707ef32278cd1d5e7615d6098e0fcb778bc95b813f9848739aa18553ee",
		"506b62703fd32de334dd0986d3031c8deeea1c7dd9f3a7a1ec507db50904b7aa900e85481d2a8c27517383187363906ff07a0f62ceaead59",
		"061270492bd1150be795b0afde9e84b19e9aa8cd56129bb09b64e895df1a1d42083c9ec4a65d0cdf0e02137d68778bf7a3257ef27c3440f9",
		"1a9336deff43869b9b20681e4a2343e1debab4bb2f2ae49b52b6d4c39a4ac705aeb116920ac540c16cbc385554eeb985b455e612a1dfc813",
		"ce66ebce17a2264fb13b79a284027116adb424410977a0c5157f2f6d4f4b7c061b50bbef7119275028e3ec2aef4ba02d6458e7ad9ca8dc49",
		"cf78130ed110a2367407893216933270e1d1c9a44a8b4a266d4ca0acc59b939b55b06cc760130e6de53417462e95d5b0874f3a047bb68a5b",
		"f30c7b06d3ad63a0b6841f4744aa8412a176d00e83204115f04bc2991e410ce4893ca46777ce63345fab2505f39bdf8e05d58572ae23e257",
		"74f7e4604eb78eb8bf3e64232b1ac3226a707e1dd1f6a10d6ed4e32b5b407e2e1186f49eb36edfb6a7acc9efece5d7ca7ec986f31425922c",
		"7ce79c11a82e7a03f29b7762ea08f224ebc13144fc5a16511e8dd48f470ba0a95999836f2c068b231c76811a18d896cb26f98d0a0b750067",
		"a2550f7603e2fcaef92f49ce1714cf25d9919ff8ff6ae4448a8da80ad71ba477f858bdfff4ebba9fe4917a62281b2d6c66157a99b5e5a9b3",
		"e93aca59b05c006b34ad9b8a5a8b5d5e83a288818aab24eef3ae0b749bc6d5afcd1b3f9c951ce9558d9197ed6c52bef542e670285834aa1a",
		"541cdecb7fad22762cf00f7fc4195bf9bebff83b18e3f472fd8e3375e13d4503a3eeca38bc6ca3125aa1165caf83519c4edf644bc20b653d",
		"2038ee3fd26de59b55bb873c4d46adaadacff503ec57df2766dfa54bae476ee1fbc6d2d6f3f7c97617cccaf8f41f5778939e88ca99f90bb8",
		"64036f2f84fe379f6db8294f49b0baab54ed092c462120d6149eb1607646defb552849bf65ac3f57b3e7ae8baebb6ae8d8241eb7d7d74289",
		"5d92132b738344b7820af15a0a3a07256c492678a79c508c6a17a8d3d1c9e8691da871c9db08dafa6464d28f3655502469a810f056479ce1",
		"50ffe46815c6af778ea0c71f29471b2b411187efdd75b585c4f947628b518310be50522b85ba9822b2317f9ad2db1e5a88a361a8317c55fc",
		"70d9863c32a4950e740e1d9e9421b279533fc72e30d4b20aa727b77d16bf200a125f72a50b19dc46055e1e9095c3b10476837dbf37f82f22",
		"c47528fc70fe0864ab576f965024c53115937830aa204b9b9a0eaf174ec0b0f23ed3f9d017dc545c159905fcdf504c2823dd0b8cb4c11547",
		"1e76da8758f625eab86645793eb4a496533524e0af4219f85f008d6a44541914732c919d915720aa3f9dde00b9a0a404a1cd9f6a05cb596d",
		"ba73788c3003a6e4989f52ab2c190334d6b0212a5f38e5029a6b0730cf16e1de68ae87b45ecf1dff491d89a6ed57acca6bbc8a9d043ce138",
		"bfbdf5e34ecff0679db7c32c70722e44aabd88dd3ff8b3c3fa48b8d8de86cc4bbdd6395c905512f80eb6013c0acfcf92a082b28563739e30",
		"44fb45113f33e666e1a4122a0b1441ae4e5c060e692d8b06c6167849c45e6cc4f9a85beb411ae0bfcc0bf9bab6be91d7381437e77dc3eb69",
		"1d2059241204b1bc2e84da54aa4d16438045249f9cf90b3213c942b9731c9ffae650252424e42ed119c9acea43e59ab9b6c62376085c05d7",
		"0aa43f9b42cf5055e52656c718a95d931af7d1d291dfcf3a14e3c985e3bade7608ac992c63dd14ae4c811d72ec47c84e3965ccaffda1e80f",
		"99e27fc2550ac9aa41bfefca67d6230a06be0e0aabe514097b493bd6ea9810a632f51582a2563cbe1746c35b889005ee7b4790281a13db88",
		"dad6728c76b27eec5577171b05172919ea2e46a1f73e91c08d33dd20354d6985e361c18340e428c8b589565ba39d230e239baef61d3e7c30",
		"df1ac9ee152531978fd50e2c643774c34ce03e17cd1ed1e7477f0d8aff8ceb919627342315a41d63a697eeec847b1a4e19b6aeedb0e85ef3",
		"9ff8ce73ed8fc0aee5b8c942e10ba68080040235c3ac4341080791c5d358c4449d84b549b901d4429d68bd85da470ee4849db1639483e346",
		"138242de03"
	].join("");
}
