package;

/**
	Aedifex's generated entry point, as its template writes it: every
	application Aedifex builds starts here, at a class of this name, which
	constructs the project's own main class. SystemTest builds this to check
	which name `System.applicationId` gives such an application.
**/
class ProgramMain {
	private static var __entryClass:Dynamic;

	static function main():Void {
		__entryClass = new example.AppIdProbe();
	}
}
