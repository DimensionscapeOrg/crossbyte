package crossbyte.db.mysql;

/** Connection settings for `MySQLConnection`. */
typedef MySQLConfig = {
    var host:String;
    @:optional var port:Int;
    var user:String;
    var password:String;
    var database:String;
    @:optional var socket:String;
    @:optional var charset:String; 
    @:optional var timeZone:String; 
    @:optional var sqlMode:String;  
}
