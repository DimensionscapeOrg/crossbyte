package crossbyte.http.config;

/** Flags that alter rewrite rule matching or routing behavior. */
enum abstract RewriteFlag(String) from String to String {
	/** Last rule: stop processing after this match. */
	var L:String = "L";
	/** Query string append: preserve and append the original query string. */
	var QSA:String = "QSA";
	/** Case-insensitive match. */
	var NC:String = "NC";
	/** Pass-through without rewriting the target path. */
	var PT:String = "PT";
	/** Route the request into the PHP bridge. */
	var PHP: String = "PHP";
}
