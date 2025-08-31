package crossbyte.net;

enum Reason {
	Closed;
	Code(code:Int, ?message:String);
	Error(msg:String);
}
