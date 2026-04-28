package crossbyte.http.config;

/** Condition attached to a rewrite rule and evaluated before the rule applies. */
typedef RewriteCondition = {
  /** Kind of condition to evaluate. */
  public var type:RewriteConditionType;            
  /** Input key such as a header name when the condition type requires one. */
  public var key:String;                     
  /** Pattern or value used by the condition. */
  public var pattern:String;                  
  /** Inverts the final condition result when `true`. */
  public var negate:Bool;                     
}
