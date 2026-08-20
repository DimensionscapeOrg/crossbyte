package crossbyte._internal.websocket;

// Not built for the browser: an alias of the raw TCP socket above.
#if !(js && !nodejs)

typedef FlexSocket = crossbyte._internal.socket.FlexSocket;
typedef HostInfo = crossbyte._internal.socket.FlexSocket.HostInfo;
typedef Sockets = crossbyte._internal.socket.FlexSocket.Sockets;
#end
