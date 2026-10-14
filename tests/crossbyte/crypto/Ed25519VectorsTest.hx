package crossbyte.crypto;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IllegalOperationError;
import haxe.io.Bytes;
import utest.Assert;

/**
	Ed25519 held to RFC 8032's test vectors (section 7.1) wherever it runs,
	natively and on PHP. The signatures are fixed, so a signature made on one
	target is the one every other target makes and verifies: no run across
	processes is needed to show a PHP service and a native server agree.
**/
class Ed25519VectorsTest extends utest.Test {
	/** seed, public key, message, signature; hex, from RFC 8032 7.1. **/
	private static final VECTORS:Array<Array<String>> = [
		[
			"9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
			"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
			"",
			"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
		],
		[
			"4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
			"3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
			"72",
			"92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
		],
		[
			"c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
			"fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
			"af82",
			"6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"
		],
		[
			"833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
			"ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
			"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
			"dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704"
		]
	];

	/** libsodium's secret key: the seed, then the public key. **/
	private static function secretKeyOf(vector:Array<String>):Bytes {
		var secretKey:Bytes = Bytes.alloc(Ed25519.SECRET_KEY_BYTES);
		secretKey.blit(0, Bytes.ofHex(vector[0]), 0, 32);
		secretKey.blit(32, Bytes.ofHex(vector[1]), 0, 32);
		return secretKey;
	}

	#if (cpp || php)
	public function testItIsSupportedHere():Void {
		Assert.isTrue(Ed25519.isSupported);
		Assert.isNull(Ed25519.unsupportedReason);
	}

	public function testSigningMakesTheRfcSignatures():Void {
		for (vector in VECTORS) {
			var signature:Bytes = Ed25519.signDetached(Bytes.ofHex(vector[2]), secretKeyOf(vector));
			Assert.equals(vector[3], signature.toHex(), 'the signature of "${vector[2]}"');
		}
	}

	public function testTheRfcSignaturesVerify():Void {
		for (vector in VECTORS) {
			var message:Bytes = Bytes.ofHex(vector[2]);
			var signature:Bytes = Bytes.ofHex(vector[3]);
			var publicKey:Bytes = Bytes.ofHex(vector[1]);
			Assert.isTrue(Ed25519.verifyDetached(signature, message, publicKey), 'the signature of "${vector[2]}"');

			// One bit of the signature, of the message, or another key.
			var bent:Bytes = Bytes.ofHex(vector[3]);
			bent.set(10, bent.get(10) ^ 1);
			Assert.isFalse(Ed25519.verifyDetached(bent, message, publicKey));
			var longer:Bytes = Bytes.ofHex(vector[2] + "00");
			Assert.isFalse(Ed25519.verifyDetached(signature, longer, publicKey));
			var other:Bytes = Bytes.ofHex(VECTORS[(VECTORS.indexOf(vector) + 1) % VECTORS.length][1]);
			Assert.isFalse(Ed25519.verifyDetached(signature, message, other));
		}
	}

	public function testANullMessageIsTheEmptyOne():Void {
		var vector:Array<String> = VECTORS[0];
		Assert.equals(vector[3], Ed25519.signDetached(null, secretKeyOf(vector)).toHex());
		Assert.isTrue(Ed25519.verifyDetached(Bytes.ofHex(vector[3]), null, Bytes.ofHex(vector[1])));
	}

	public function testAFreshKeyPairSignsAndVerifies():Void {
		var pair:SigningKeyPair = Ed25519.keypair();
		Assert.equals(Ed25519.PUBLIC_KEY_BYTES, pair.publicKey.length);
		Assert.equals(Ed25519.SECRET_KEY_BYTES, pair.secretKey.length);
		// The secret key ends with the public key, as libsodium lays it out.
		Assert.equals(pair.publicKey.toHex(), pair.secretKey.sub(32, 32).toHex());

		var message:Bytes = Bytes.ofString("connect token");
		var signature:Bytes = Ed25519.signDetached(message, pair.secretKey);
		Assert.equals(Ed25519.SIGNATURE_BYTES, signature.length);
		Assert.isTrue(Ed25519.verifyDetached(signature, message, pair.publicKey));
		Assert.isFalse(Ed25519.verifyDetached(signature, Bytes.ofString("connect tokens"), pair.publicKey));
		Assert.isFalse(Ed25519.keypair().publicKey.toHex() == pair.publicKey.toHex());
	}

	public function testWrongLengthsAreRefusedNotThrownFor():Void {
		var vector:Array<String> = VECTORS[1];
		var message:Bytes = Bytes.ofHex(vector[2]);
		var signature:Bytes = Bytes.ofHex(vector[3]);
		var publicKey:Bytes = Bytes.ofHex(vector[1]);
		Assert.isFalse(Ed25519.verifyDetached(null, message, publicKey));
		Assert.isFalse(Ed25519.verifyDetached(signature.sub(0, 63), message, publicKey));
		Assert.isFalse(Ed25519.verifyDetached(signature, message, publicKey.sub(0, 31)));
		Assert.isFalse(Ed25519.verifyDetached(signature, message, null));
	}

	public function testASecretKeyOfTheWrongLengthIsAnArgumentError():Void {
		Assert.raises(() -> Ed25519.signDetached(Bytes.ofString("x"), Bytes.alloc(32)), ArgumentError);
		Assert.raises(() -> Ed25519.signDetached(Bytes.ofString("x"), null), ArgumentError);
	}
	#else
	public function testItSaysWhyNotHere():Void {
		Assert.isFalse(Ed25519.isSupported);
		Assert.notNull(Ed25519.unsupportedReason);
		var vector:Array<String> = VECTORS[0];
		Assert.raises(() -> Ed25519.keypair(), IllegalOperationError);
		Assert.raises(() -> Ed25519.signDetached(Bytes.ofHex(vector[2]), secretKeyOf(vector)), IllegalOperationError);
		Assert.raises(() -> Ed25519.verifyDetached(Bytes.ofHex(vector[3]), Bytes.ofHex(vector[2]), Bytes.ofHex(vector[1])), IllegalOperationError);
	}
	#end
}
