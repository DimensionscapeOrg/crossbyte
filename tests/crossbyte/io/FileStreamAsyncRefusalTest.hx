package crossbyte.io;

import utest.Assert;

/**
	Where there are no threads, `openAsync` refuses to write rather than hang.

	Its writer is a worker that waits for writes. On a target with no threads
	the worker runs in the calling thread, so `openAsync(file, WRITE)` would
	sit in that wait, for writes its own caller could never make, and never
	return. Node is the target in the suites that has none.
**/
class FileStreamAsyncRefusalTest extends utest.Test {
	#if (nodejs || (sys && !target.threaded))
	public function testAnAsyncWriteIsRefusedWhereThereAreNoThreads():Void {
		var file:File = File.createTempFile();
		var stream = new FileStream();

		Assert.raises(() -> stream.openAsync(file, FileMode.WRITE), crossbyte.errors.IllegalOperationError);

		try stream.close() catch (_:Dynamic) {}
		if (file.exists) {
			file.deleteFile();
		}
	}
	#end
}
