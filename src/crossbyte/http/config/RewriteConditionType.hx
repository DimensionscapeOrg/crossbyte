package crossbyte.http.config;

/** Supported condition categories for HTTP rewrite rules. */
enum abstract RewriteConditionType(String) from String to String{
	/**
		Matches when the path, as the rules have it so far, names an existing
		file. A rule with this condition, or `DirExists`, is tried even for a
		request that names an existing file, which every other rule passes
		over: without `negate`, it is how a rewrite wins over a file that
		exists. See `HTTPServerConfig.tryFiles`.
	**/
	var FileExists:String = "FileExists";
	/** Matches when the path, as the rules have it so far, names an existing directory. See `FileExists`. */
	var DirExists:String = "DirExists";
	/** Matches against the HTTP request method. */
	var Method:String = "Method";
	/** Matches against a named request header. */
	var Header:String = "Header";
}
