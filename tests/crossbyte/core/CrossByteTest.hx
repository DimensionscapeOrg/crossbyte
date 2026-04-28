package crossbyte.core;

import crossbyte.errors.IllegalOperationError;
import crossbyte.utils.ThreadUtil;
import utest.Assert;
#if (cpp || neko || hl)
import sys.thread.Deque;
import sys.thread.Thread;
#end

@:access(crossbyte.core.CrossByte)
class CrossByteTest extends utest.Test {
	public function testMakeRequiresPrimordialRuntime():Void {
		var primordial = CrossByte.__primordial;
		CrossByte.__primordial = null;

		var threw = throwsIllegalOperationError(() -> CrossByte.make());
		CrossByte.__primordial = primordial;

		Assert.isTrue(threw);
	}

	public function testCurrentRestoresPrimordialAfterHostDrivenChildExit():Void {
		#if (cpp || neko || hl)
		var primordial = CrossByte.current();
		var child = new CrossByte(false, DEFAULT, true);

		Assert.equals(child, CrossByte.current());

		child.exit();
		Assert.equals(primordial, CrossByte.current());
		Assert.isTrue(ThreadUtil.isPrimordial);
		#else
		Assert.pass();
		#end
	}

	public function testCurrentThrowsOnForeignThreadWithoutRuntime():Void {
		#if (cpp || neko || hl)
		var queue:Deque<String> = new Deque();
		Thread.create(() -> {
			try {
				CrossByte.current();
				queue.add("no-throw");
			} catch (_:IllegalOperationError) {
				queue.add("illegal-operation");
			} catch (_:Dynamic) {
				queue.add("wrong-error");
			}
		});

		Assert.equals("illegal-operation", queue.pop(true));
		Assert.isTrue(ThreadUtil.isPrimordial);
		#else
		Assert.pass();
		#end
	}

	public function testThreadUtilRecognizesPrimordialThread():Void {
		Assert.isTrue(ThreadUtil.isPrimordial);
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
