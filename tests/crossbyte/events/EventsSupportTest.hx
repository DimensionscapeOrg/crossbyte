package crossbyte.events;

import crossbyte.errors.SQLError;
import crossbyte.io.File;
import crossbyte.io.ByteArray;
import crossbyte.url.URLRequestHeader;
import utest.Assert;

class EventsSupportTest extends utest.Test {
	public function testClonePreservesSubclassPayloads():Void {
		var fileEvent:FileListEvent = cast (new FileListEvent(FileListEvent.DIRECTORY_LISTING, [new File("memory://a.txt")]).clone());
		Assert.equals(FileListEvent.DIRECTORY_LISTING, fileEvent.type);
		Assert.equals(1, fileEvent.files.length);

		var threadEvent = cast new ThreadEvent(ThreadEvent.UPDATE, {message: "hello"}).clone();
		Assert.equals(ThreadEvent.UPDATE, threadEvent.type);
		Assert.equals("hello", threadEvent.message.message);

		var taskEvent = cast new TaskEvent<String>(TaskEvent.COMPLETE, null, "done").clone();
		Assert.equals(TaskEvent.COMPLETE, taskEvent.type);
		Assert.equals("done", taskEvent.result);

		var tickEvent = cast new TickEvent(TickEvent.TICK, 0.25).clone();
		Assert.equals(TickEvent.TICK, tickEvent.type);
		Assert.equals(0.25, tickEvent.delta);
	}

	public function testSpecializedEventsCloneRichMetadata():Void {
		var httpEvent = new HTTPStatusEvent(HTTPStatusEvent.HTTP_STATUS, 206, true);
		httpEvent.responseURL = "https://example.test/final";
		httpEvent.responseHeaders = [new URLRequestHeader("Content-Type", "text/plain")];
		var httpClone:HTTPStatusEvent = httpEvent.clone();
		Assert.equals(206, httpClone.status);
		Assert.equals(true, httpClone.redirected);
		Assert.equals("https://example.test/final", httpClone.responseURL);
		Assert.equals(1, httpClone.responseHeaders.length);

		var payload:ByteArray = haxe.io.Bytes.ofString("ping");
		var datagramClone:DatagramSocketDataEvent = cast new DatagramSocketDataEvent(DatagramSocketDataEvent.DATA, "::1", 5000, "::1", 6000, payload).clone();
		Assert.equals("::1", datagramClone.srcAddress);
		Assert.equals(5000, datagramClone.srcPort);
		Assert.equals("::1", datagramClone.dstAddress);
		Assert.equals(6000, datagramClone.dstPort);
		Assert.equals("ping", datagramClone.data.toString());

		var ioClone:IOErrorEvent = cast new IOErrorEvent(IOErrorEvent.IO_ERROR, "disk full", 42).clone();
		Assert.equals(IOErrorEvent.IO_ERROR, ioClone.type);
		Assert.equals("disk full", ioClone.text);
		Assert.equals(42, ioClone.errorID);

		var sqlError = new SQLError("query", "extra", "boom", 7);
		var sqlClone:SQLErrorEvent = cast new SQLErrorEvent(SQLErrorEvent.ERROR, sqlError).clone();
		Assert.equals(sqlError, sqlClone.error);
	}

	public function testEventConstantsAndStringsAreStable():Void {
		Assert.equals("setSavepoint", SQLEvent.SET_SAVEPOINT);
		Assert.equals("commit", SQLEvent.COMMIT);
		Assert.isTrue(StatusEvent.STATUS == "status");
		Assert.isFalse(StatusEvent.STATUS != "status");

		var status = new StatusEvent(StatusEvent.STATUS, "200", "ok");
		Assert.equals("[StatusEvent type=status code=200 level=ok]", status.toString());

		var httpStatus = new HTTPStatusEvent(HTTPStatusEvent.HTTP_RESPONSE_STATUS, 200, false);
		Assert.equals("[HTTPStatusEvent], type:httpResponseStatus, status:200, redirected:false", httpStatus.toString());

		var base = new Event(Event.COMPLETE);
		Assert.equals("complete", base.toString());
	}
}
