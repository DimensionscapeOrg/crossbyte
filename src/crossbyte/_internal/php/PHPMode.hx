package crossbyte._internal.php;

enum PHPMode {
	Connect(address:String, port:Int);
	Launch(address:String, port:Int, phpCgiPath:String, ?phpIniPath:String);
}
