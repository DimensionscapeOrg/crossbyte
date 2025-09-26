package crossbyte.http.config;

enum abstract RewriteConditionType(String) from String to String{
	var FileExists:String = "FileExists";
	var DirExists:String = "DirExists";
	var Method:String = "Method";
	var Header:String = "Header";
}
