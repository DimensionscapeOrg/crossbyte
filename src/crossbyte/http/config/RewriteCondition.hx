package crossbyte.http.config;

/**
	Condition attached to a rewrite rule and evaluated before the rule applies.
	Built from an object literal (`@:structInit`): `key` may be left
	out where the condition needs none, and `negate` where it is `false`.
**/
@:structInit
final class RewriteCondition {
	/** Kind of condition to evaluate. */
	public var type:RewriteConditionType;

	/**
		Input key such as a header name when the condition type requires one. A
		header name is matched in any case, as HTTP compares them: `X-Test` and
		`x-test` name the same field.
	**/
	public var key:Null<String> = null;

	/** Pattern or value used by the condition. */
	public var pattern:String;

	/** Inverts the final condition result when `true`. */
	public var negate:Bool = false;
}
