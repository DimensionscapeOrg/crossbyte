package crossbyte.net;

enum abstract Protocol(Int) from Int to Int {
	var TCP:Int = 0;
	var UDP:Int = 1;
	var WEBSOCKET:Int = 2;
}
