package crossbyte.core;

import crossbyte.errors.IllegalOperationError;
import utest.Assert;

@:access(crossbyte.core.CrossByte)
class CrossByteTest extends utest.Test {
	public function testMakeRequiresPrimordialRuntime():Void {
		var primordial = CrossByte.__primordial;
		CrossByte.__primordial = null;

		var threw = throwsIllegalOperationError(() -> CrossByte.make());
		CrossByte.__primordial = primordial;

		Assert.isTrue(threw);
	}

	@:noCompletion private static function throwsIllegalOperationError(fn:Void->Void):Bool {
		try {
			fn();
			return false;
		} catch (_:IllegalOperationError) {
			return true;
		} catch (_:Dynamic) {
			return false;
		}
	}
}
