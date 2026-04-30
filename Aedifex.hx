package;

import aedifex.build.Project;
import aedifex.build.ProjectSpec;

class Aedifex {
	public static final project:ProjectSpec = Project
		.library("crossbyte")
		.tags(["crossbyte", "networking", "http", "rpc", "server", "ipc", "tools"])
		.description("Cross-platform Haxe runtime and networking framework for event-driven applications, services, IPC, RPC, and systems-oriented tools.")
		.version("1.0.0-rc.1")
		.github("dimensionscapeorg/crossbyte")
		.license("Apache")
		.releaseNote("First 1.0 release candidate with polished samples, API docs, optional native extensions, and expanded runtime/networking coverage.")
		.contributor("Dimensionscape")
		.classPath("src")
		.source("src")
		.task("interp-tests", "haxe", ["ci/interp-tests.hxml"], null, "Run the fast interpreted CrossByte test suite.")
		.task("native-tests", "haxe", ["ci/native-tests.hxml"], null, "Build the native CrossByte smoke test executable.")
		.task("docs-api", "haxe", ["ci/docs-api.hxml"], null, "Generate CrossByte API XML/doc build artifacts.")
		.task("docs-site", "haxelib", [
			"run",
			"dox",
			"-i",
			"export/docs-api/crossbyte.xml",
			"-o",
			"export/docs-site",
			"--title",
			"CrossByte",
			"--toplevel-package",
			"crossbyte",
			"--include",
			"^crossbyte(\\.|$)",
			"--exclude",
			"\\._internal(\\.|$)",
			"-D",
			"version",
			"1.0.0-rc.1",
			"-D",
			"source-path",
			"https://github.com/dimensionscapeorg/crossbyte/blob/main/src/",
			"-D",
			"website",
			"https://github.com/dimensionscapeorg/crossbyte",
			"-D",
			"logo",
			"crossbyte.png",
			"-D",
			"description",
			"CrossByte API reference"
		], null, "Generate the browsable CrossByte dox site from the exported API XML.")
		.task("cpp-api-audit", "haxe", ["ci/cpp-api-audit.hxml"], null, "Perform the hxcpp API surface audit build.")
		.task("cpp-timer-burst-audit", "haxe", ["ci/cpp-timer-burst-audit.hxml"], null, "Type-check the timer burst API surface for hxcpp targets.")
		.task("localconnection-integration", "haxe", ["tests/integration/localconnection.hxml"], null, "Build the native local transport integration harness.")
		.task("sample-websocket-echo-check", "haxe", ["check.hxml"], "samples/websocket-echo", "Type-check the websocket echo sample.")
		.task("sample-websocket-echo-cpp", "haxe", ["cpp.hxml"], "samples/websocket-echo", "Build the websocket echo sample.")
		.task("sample-socket-chat-check", "haxe", ["check.hxml"], "samples/socket-chat", "Type-check the socket chat sample.")
		.task("sample-socket-chat-server-cpp", "haxe", ["server-cpp.hxml"], "samples/socket-chat", "Build the socket chat server sample.")
		.task("sample-socket-chat-client-cpp", "haxe", ["client-cpp.hxml"], "samples/socket-chat", "Build the socket chat client sample.")
		.task("sample-rpc-greeter-check", "haxe", ["check.hxml"], "samples/rpc-greeter", "Type-check the RPC greeter sample.")
		.task("sample-rpc-greeter-cpp", "haxe", ["cpp.hxml"], "samples/rpc-greeter", "Build the RPC greeter sample.")
		.task("sample-localconnection-check", "haxe", ["check.hxml"], "samples/localconnection", "Type-check the local transport sample.")
		.task("sample-localconnection-cpp", "haxe", ["cpp.hxml"], "samples/localconnection", "Build the local transport sample.")
		.task("sample-sharedchannel-check", "haxe", ["check.hxml"], "samples/sharedchannel", "Type-check the shared channel sample.")
		.task("sample-sharedchannel-cpp", "haxe", ["cpp.hxml"], "samples/sharedchannel", "Build the shared channel sample.")
		.task("sample-sharedobject-check", "haxe", ["check.hxml"], "samples/sharedobject", "Type-check the shared object sample.")
		.task("sample-sharedobject-cpp", "haxe", ["cpp.hxml"], "samples/sharedobject", "Build the shared object sample.")
		.task("sample-simple-application-check", "haxe", ["check.hxml"], "samples/simple-application", "Type-check the simple application sample.")
		.task("sample-simple-application-cpp", "haxe", ["cpp.hxml"], "samples/simple-application", "Build the simple application sample.")
		.task("sample-udp-check", "haxe", ["check.hxml"], "samples/udp", "Type-check the UDP sample.")
		.task("sample-udp-cpp", "haxe", ["cpp.hxml"], "samples/udp", "Build the UDP sample.")
		.task("sample-rudp-check", "haxe", ["check.hxml"], "samples/rudp", "Type-check the reliable datagram sample.")
		.task("sample-rudp-cpp", "haxe", ["cpp.hxml"], "samples/rudp", "Build the reliable datagram sample.")
		.task("sample-web-server-check", "haxe", ["check.hxml"], "samples/web-server", "Type-check the web server sample.")
		.task("sample-web-server-cpp", "haxe", ["cpp.hxml"], "samples/web-server", "Build the web server sample.")
		.task("sample-worker-check", "haxe", ["check.hxml"], "samples/worker", "Type-check the worker sample.")
		.task("sample-worker-cpp", "haxe", ["cpp.hxml"], "samples/worker", "Build the worker sample.")
		.done();
}
