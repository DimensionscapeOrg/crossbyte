package crossbyte.http;

import utest.Assert;

@:access(crossbyte.http.HTTPRequestHandler)
class HTTPRequestHandlerTest extends utest.Test {
	public function testRootContainmentRejectsSiblingPrefix():Void {
		#if windows
		var root = "C:\\www";
		Assert.isTrue(HTTPRequestHandler.__isWithinRoot(root, "C:\\www"));
		Assert.isTrue(HTTPRequestHandler.__isWithinRoot(root, "C:\\www\\static\\index.html"));
		Assert.isTrue(HTTPRequestHandler.__isWithinRoot(root, "c:/WWW/static/index.html"));
		Assert.isFalse(HTTPRequestHandler.__isWithinRoot(root, "C:\\www2\\secret.txt"));
		#else
		var root = "/var/www";
		Assert.isTrue(HTTPRequestHandler.__isWithinRoot(root, "/var/www"));
		Assert.isTrue(HTTPRequestHandler.__isWithinRoot(root, "/var/www/static/index.html"));
		Assert.isFalse(HTTPRequestHandler.__isWithinRoot(root, "/var/www2/secret.txt"));
		#end
	}
}
