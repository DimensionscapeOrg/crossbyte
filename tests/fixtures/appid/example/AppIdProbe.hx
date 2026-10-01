package example;

/** Says what `System.applicationId` is, for SystemTest. **/
class AppIdProbe {
	public function new() {
		Sys.println("applicationId=" + crossbyte.sys.System.applicationId);
	}
}
