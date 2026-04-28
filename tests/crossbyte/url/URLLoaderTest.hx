package crossbyte.url;

import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ThreadEvent;
import haxe.io.Bytes;
import utest.Assert;

@:access(crossbyte.url.URLLoader)
class URLLoaderTest extends utest.Test {
	public function testParseTextBinaryAndVariables():Void {
		var loader = new URLLoader();

		loader.dataFormat = TEXT;
		loader.__parseData(Bytes.ofString("hello"));
		Assert.equals("hello", loader.data);

		var bytes = Bytes.ofString("raw");
		loader.dataFormat = BINARY;
		loader.__parseData(bytes);
		Assert.equals(bytes, loader.data);

		loader.dataFormat = VARIABLES;
		loader.__parseData(Bytes.ofString("a=1&a=2"));
		var variables:URLVariables = loader.data;
		Assert.same(["1", "2"], variables.all("a"));
	}

	public function testWorkerCompleteParsesDataAndClearsBusyState():Void {
		var loader = new URLLoader();
		var completeEvents = 0;
		loader.__busy = true;
		loader.addEventListener(Event.COMPLETE, _ -> completeEvents++);

		loader.__onWorkerComplete(new ThreadEvent(ThreadEvent.COMPLETE, Bytes.ofString("done")));

		Assert.equals("done", loader.data);
		Assert.equals(1, completeEvents);
		Assert.isFalse(loader.__busy);
	}

	public function testWorkerProgressDispatchesLoadedAndTotalInCorrectOrder():Void {
		var loader = new URLLoader();
		var loaded = 0;
		var total = 0;
		loader.addEventListener(ProgressEvent.PROGRESS, event -> {
			loaded = event.bytesLoaded;
			total = event.bytesTotal;
		});

		loader.__onWorkerProgress(new ThreadEvent(ThreadEvent.PROGRESS, {
			type: "progress",
			value: {bytesLoaded: 25, bytesTotal: 100}
		}));

		Assert.equals(25, loaded);
		Assert.equals(100, total);
		Assert.equals(25, loader.bytesLoaded);
		Assert.equals(100, loader.bytesTotal);
	}

	public function testWorkerProgressDispatchesStatus():Void {
		var loader = new URLLoader();
		var status = 0;
		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, event -> {
			status = event.status;
		});

		loader.__onWorkerProgress(new ThreadEvent(ThreadEvent.PROGRESS, {
			type: "status",
			value: 204
		}));

		Assert.equals(204, status);
	}

	public function testWorkerErrorHandlesObjectWithBody():Void {
		var loader = new URLLoader();
		var errorText:String = null;
		loader.dataFormat = TEXT;
		loader.addEventListener(IOErrorEvent.IO_ERROR, event -> {
			errorText = event.text;
		});

		loader.__onWorkerError(new ThreadEvent(ThreadEvent.ERROR, {
			msg: "failed",
			dataBytes: Bytes.ofString("body")
		}));

		Assert.equals("failed", errorText);
		Assert.equals("body", loader.data);
		Assert.isFalse(loader.__busy);
	}

	public function testWorkerErrorHandlesPlainMessage():Void {
		var loader = new URLLoader();
		var errorText:String = null;
		loader.addEventListener(IOErrorEvent.IO_ERROR, event -> {
			errorText = event.text;
		});

		loader.__onWorkerError(new ThreadEvent(ThreadEvent.ERROR, "boom"));

		Assert.equals("boom", errorText);
		Assert.isFalse(loader.__busy);
	}
}
