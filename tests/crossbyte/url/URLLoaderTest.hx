package crossbyte.url;

import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.HTTPStatusEvent;
import crossbyte.events.IOErrorEvent;
import crossbyte.events.ProgressEvent;
import crossbyte.http.HTTPCancelToken;
import crossbyte.url._internal.LoaderRun;
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

	/** A load in progress as far as `loader` knows, with nothing running behind it. */
	private static function inProgress(loader:URLLoader):LoaderRun {
		var run = new LoaderRun(loader, CrossByte.current(), new URLRequest("http://127.0.0.1/"), new HTTPCancelToken());
		loader.__load = run;
		loader.__busy = true;
		return run;
	}

	public function testCompleteParsesDataAndClearsBusyState():Void {
		var loader = new URLLoader();
		var run = inProgress(loader);
		var completeEvents = 0;
		var busyInListener:Null<Bool> = null;
		loader.addEventListener(Event.COMPLETE, _ -> {
			completeEvents++;
			busyInListener = loader.__busy;
		});

		loader.__deliver(run, Complete(Bytes.ofString("done")));

		Assert.equals("done", loader.data);
		Assert.equals(1, completeEvents);
		Assert.isFalse(loader.__busy);
		// Free already when the listener runs, so it can start the next load.
		Assert.isFalse(busyInListener);
	}

	public function testProgressDispatchesLoadedAndTotalInCorrectOrder():Void {
		var loader = new URLLoader();
		var run = inProgress(loader);
		var loaded = 0;
		var total = 0;
		loader.addEventListener(ProgressEvent.PROGRESS, event -> {
			loaded = event.bytesLoaded;
			total = event.bytesTotal;
		});

		loader.__deliver(run, Progress(25, 100));

		Assert.equals(25, loaded);
		Assert.equals(100, total);
		Assert.equals(25, loader.bytesLoaded);
		Assert.equals(100, loader.bytesTotal);
	}

	public function testStatusIsDispatched():Void {
		var loader = new URLLoader();
		var run = inProgress(loader);
		var status = 0;
		loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, event -> {
			status = event.status;
		});

		loader.__deliver(run, Status(204));

		Assert.equals(204, status);
	}

	public function testErrorKeepsTheBody():Void {
		var loader = new URLLoader();
		var run = inProgress(loader);
		var errorText:String = null;
		loader.dataFormat = TEXT;
		loader.addEventListener(IOErrorEvent.IO_ERROR, event -> {
			errorText = event.text;
		});

		loader.__deliver(run, Failure("failed", Bytes.ofString("body")));

		Assert.equals("failed", errorText);
		Assert.equals("body", loader.data);
		Assert.isFalse(loader.__busy);
	}

	public function testErrorWithoutABody():Void {
		var loader = new URLLoader();
		var run = inProgress(loader);
		var errorText:String = null;
		loader.addEventListener(IOErrorEvent.IO_ERROR, event -> {
			errorText = event.text;
		});

		loader.__deliver(run, Failure("boom", null));

		Assert.equals("boom", errorText);
		Assert.isFalse(loader.__busy);
	}

	public function testWhatAClosedLoadSendsIsDropped():Void {
		var loader = new URLLoader();
		var run = inProgress(loader);
		var events = 0;
		loader.addEventListener(Event.COMPLETE, _ -> events++);
		loader.addEventListener(IOErrorEvent.IO_ERROR, _ -> events++);

		loader.close();

		Assert.isFalse(loader.__deliver(run, Complete(Bytes.ofString("late"))));
		Assert.isFalse(loader.__deliver(run, Failure("late", null)));
		Assert.equals(0, events);
		Assert.isNull(loader.data);
	}
}
