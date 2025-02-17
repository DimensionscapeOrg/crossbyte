package crossbyte.rpc;

import crossbyte.net.INetConnection;

@:generic
final class RPCCommandAgent<T:RPCCommands> extends RPCAgent{
    public var commands(get, never):RPCCommands;

    @:noPrivateAccess
    private var __commands:RPCCommands;

    private inline function get_commands():RPCCommands{
        return __commands;
    }

    public inline function new(connection:INetConnection, commands:RPCCommands):Void{
        super(connection);
        __commands = commands;
    }
}