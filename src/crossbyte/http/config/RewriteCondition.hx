package crossbyte.http.config;

typedef RewriteCondition = {
  public var type:RewriteConditionType;            
  public var key:String;                     
  public var pattern:String;                  
  public var negate:Bool;                     
}