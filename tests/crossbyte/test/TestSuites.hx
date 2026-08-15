package crossbyte.test;

import utest.Runner;

class TestSuites {
	public static function addAuth(runner:Runner):Void {
		runner.addCase(new crossbyte.auth.AuthSupportTest());
		runner.addCase(new crossbyte.auth.jwt.JWTTest());
		runner.addCase(new crossbyte.auth.jwt.EdDSAJwtTest());
	}

	public static function addCrypto(runner:Runner):Void {
		runner.addCase(new crossbyte.crypto.CryptoTest());
		runner.addCase(new crossbyte.crypto.SodiumExpansionTest());
		runner.addCase(new crossbyte.crypto.password.BCryptHardeningTest());
	}

	public static function addCore(runner:Runner):Void {
		runner.addCase(new crossbyte.core.CrossByteTest());
		runner.addCase(new crossbyte.core.CrossByteRunningFlagTest());
	}

	public static function addFoundation(runner:Runner):Void {
		runner.addCase(new crossbyte.foundation.FoundationConstructsTest());
	}

	public static function addErrors(runner:Runner):Void {
		runner.addCase(new crossbyte.errors.ErrorsTest());
	}

	public static function addEvents(runner:Runner):Void {
		runner.addCase(new crossbyte.events.EventDispatcherTest());
		runner.addCase(new crossbyte.events.EventsSupportTest());
	}

	public static function addDataStructures(runner:Runner):Void {
		runner.addCase(new crossbyte.ds.Array2DTest());
		runner.addCase(new crossbyte.ds.CollectionsTest());
		runner.addCase(new crossbyte.ds.BloomFilterTest());
		runner.addCase(new crossbyte.ds.OrderedMapTest());
		runner.addCase(new crossbyte.ds.BitmapDataTest());
		runner.addCase(new crossbyte._internal.compression.CompressionRoundTripTest());
	}

	public static function addHttp(runner:Runner):Void {
		#if cpp
		runner.addCase(new crossbyte.http.HTTPRequestHandlerTest());
		#end
		runner.addCase(new crossbyte.http.HTTPSupportTest());
		runner.addCase(new crossbyte.http.RateLimiterTest());
		runner.addCase(new crossbyte._internal.http.HttpTest());
		runner.addCase(new crossbyte.http.HTTPHardeningTest());
	}

	public static function addIO(runner:Runner):Void {
		runner.addCase(new crossbyte.io.ByteArrayTest());
		runner.addCase(new crossbyte.io.ByteArrayInputTest());
		runner.addCase(new crossbyte.io.ByteArrayIOTest());
		runner.addCase(new crossbyte.io.ByteArrayOutputTest());
		runner.addCase(new crossbyte.io.FileTest());
		runner.addCase(new crossbyte.io.FileStreamTest());
		runner.addCase(new crossbyte.io.ByteArrayCorrectnessTest());
	}

	public static function addURL(runner:Runner):Void {
		runner.addCase(new crossbyte.url.URLTest());
		runner.addCase(new crossbyte.url.URLLoaderHttpTest());
		runner.addCase(new crossbyte.url.URLLoaderTest());
		runner.addCase(new crossbyte.url.URLVariablesTest());
	}

	public static function addMath(runner:Runner):Void {
		runner.addCase(new crossbyte.math.MathTest());
	}

	public static function addIPC(runner:Runner):Void {
		runner.addCase(new crossbyte.ipc.LocalConnectionTest());
		runner.addCase(new crossbyte.ipc.SharedChannelTest());
		runner.addCase(new crossbyte.ipc.SharedObjectTest());
		runner.addCase(new crossbyte.ipc.LocalConnectionSendGuardTest());
	}

	public static function addDatabase(runner:Runner):Void {
		runner.addCase(new crossbyte.db.DBSupportTest());
		runner.addCase(new crossbyte.db.PostgresConnectionTest());
		runner.addCase(new crossbyte.db.MongoConnectionTest());
		runner.addCase(new crossbyte.db.DBParameterBindingTest());
	}

	public static function addSystem(runner:Runner):Void {
		runner.addCase(new crossbyte.sys.NativeProcessTest());
		runner.addCase(new crossbyte.sys.ProcessLifecycleTest());
		runner.addCase(new crossbyte.sys.SysSupportTest());
		runner.addCase(new crossbyte.sys.WorkerTest());
		runner.addCase(new crossbyte.sys.TaskPoolTest());
	}

	public static function addNet(runner:Runner):Void {
		runner.addCase(new crossbyte.net.DatagramSocketTest());
		runner.addCase(new crossbyte.net.EndpointTest());
		runner.addCase(new crossbyte.net.NetConnectionTest());
		runner.addCase(new crossbyte.net.NetHostTest());
		runner.addCase(new crossbyte._internal.socket.poll.PollBackendRegistryTest());
		runner.addCase(new crossbyte._internal.socket.FlexSocketTest());
		runner.addCase(new crossbyte.net.ReliableDatagramProtocolTest());
		runner.addCase(new crossbyte.net.ReliableDatagramSocketTest());
		#if cpp
		runner.addCase(new crossbyte.net.SocketTest());
		runner.addCase(new crossbyte.net.ServerSocketTLSTest());
		#end
		runner.addCase(new crossbyte.net.WebSocketTest());
		runner.addCase(new crossbyte._internal.websocket.WebSocketFrameTest());
		runner.addCase(new crossbyte.net.RUDPHardeningTest());
	}

	public static function addRPC(runner:Runner):Void {
		runner.addCase(new crossbyte.rpc.RPCTest());
		runner.addCase(new crossbyte.rpc.RPCRobustnessTest());
	}

	public static function addResources(runner:Runner):Void {
		runner.addCase(new crossbyte.resources.ResourcesTest());
	}

	public static function addTimers(runner:Runner):Void {
		runner.addCase(new crossbyte.timer.GlobalTimerTest());
		runner.addCase(new crossbyte.timer.HaxeTimerTest());
		runner.addCase(new crossbyte.timer.TimerHeapTest());
	}

	public static function addUtils(runner:Runner):Void {
		runner.addCase(new crossbyte.utils.UtilsTest());
	}

	public static function addAll(runner:Runner):Void {
		addAuth(runner);
		addCrypto(runner);
		addCore(runner);
		addFoundation(runner);
		addErrors(runner);
		addEvents(runner);
		addDataStructures(runner);
		addMath(runner);
		addHttp(runner);
		addIO(runner);
		addURL(runner);
		addIPC(runner);
		addDatabase(runner);
		addSystem(runner);
		addNet(runner);
		addRPC(runner);
		addResources(runner);
		addTimers(runner);
		addUtils(runner);
	}

	public static function addNativeSmoke(runner:Runner):Void {
		addCrypto(runner);
		addCore(runner);
		addErrors(runner);
		addEvents(runner);
		addHttp(runner);
		addSystem(runner);
		addNet(runner);
		addRPC(runner);
		addTimers(runner);
	}
}
