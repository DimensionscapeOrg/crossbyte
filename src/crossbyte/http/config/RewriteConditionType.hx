package crossbyte.http.config;

/** Supported condition categories for HTTP rewrite rules. */
enum abstract RewriteConditionType(String) from String to String{
	/** Matches when a file exists. */
	var FileExists:String = "FileExists";
	/** Matches when a directory exists. */
	var DirExists:String = "DirExists";
	/** Matches against the HTTP request method. */
	var Method:String = "Method";
	/** Matches against a named request header. */
	var Header:String = "Header";
}
