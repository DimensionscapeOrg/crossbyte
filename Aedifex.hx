package;

import aedifex.build.Project;
import aedifex.build.ProjectSpec;

class Aedifex {
	public static final project:ProjectSpec = Project
		.library("crossbyte")
		.tags(["crossbyte", "networking", "http", "rpc", "server", "ipc", "tools"])
		.description("Cross-platform Haxe runtime and networking framework for event-driven applications, services, IPC, RPC, and systems-oriented tools.")
		.version("1.0.0-rc1")
		.github("dimensionscapeorg/crossbyte")
		.license("Apache-2.0")
		.releaseNote("First 1.0 release candidate with polished samples, API docs, optional native extensions, and expanded runtime/networking coverage.")
		.contributor("Dimensionscape")
		.classPath("src")
		.source("src")
		.task("interp-tests", "haxe", ["test.hxml"], null, "Run the fast interpreted CrossByte test suite.")
		.task("native-tests", "haxe", ["ci/native-tests.hxml"], null, "Build the native CrossByte smoke test executable.")
		.task("docs-api", "haxe", ["ci/docs-api.hxml"], null, "Generate CrossByte API XML/doc build artifacts.")
		.task("cpp-api-audit", "haxe", ["ci/cpp-api-audit.hxml"], null, "Perform the hxcpp API surface audit build.")
		.task("websocket-echo-sample", "haxe", ["ci/websocket-echo-sample.hxml"], null, "Build the websocket echo sample with CrossByte.")
		.done();
}
