package crossbyte.http.config;

enum abstract RewriteFlag(String) from String to String {
	var L:String = "L";
	var QSA:String = "QSA";
	var NC:String = "NC";
	var PT:String = "PT";
	var PHP: String = "PHP";
}
