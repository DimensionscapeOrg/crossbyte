package crossbyte.net;

enum Reason {
	Timeout;
	Closed;
	Code(code:Int, ?message:String);
	Error(msg:String);
}
