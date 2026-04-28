import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class TestMain {
	public static function main():Void {
		var crossByte = new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new crossbyte.auth.jwt.JWTTest());
		runner.addCase(new crossbyte.ds.Array2DTest());
		runner.addCase(new crossbyte.ds.CollectionsTest());
		runner.addCase(new crossbyte.http.HTTPRequestHandlerTest());
		runner.addCase(new crossbyte._internal.http.HttpTest());
		runner.addCase(new crossbyte.io.ByteArrayTest());
		runner.addCase(new crossbyte.url.URLTest());
		runner.addCase(new crossbyte.url.URLLoaderHttpTest());
		runner.addCase(new crossbyte.url.URLLoaderTest());
		runner.addCase(new crossbyte.url.URLVariablesTest());
		runner.addCase(new crossbyte.ipc.LocalConnectionTest());
		runner.addCase(new crossbyte.ipc.SharedObjectTest());
		runner.addCase(new crossbyte.db.PostgresConnectionTest());
		runner.addCase(new crossbyte.db.MongoConnectionTest());
		runner.addCase(new crossbyte.sys.NativeProcessTest());
		runner.addCase(new crossbyte.sys.WorkerTest());
		runner.addCase(new crossbyte.sys.TaskPoolTest());
		runner.addCase(new crossbyte.net.DatagramSocketTest());
		runner.addCase(new crossbyte._internal.socket.FlexSocketTest());
		runner.addCase(new crossbyte.net.ReliableDatagramProtocolTest());
		runner.addCase(new crossbyte.net.ReliableDatagramSocketTest());
		runner.addCase(new crossbyte.net.SocketTest());
		runner.addCase(new crossbyte.net.WebSocketTest());
		runner.addCase(new crossbyte.resources.ResourcesTest());
		runner.addCase(new crossbyte.timer.TimerHeapTest());
		Report.create(runner);
		runner.run();
	}
}
