package crossbyte.db.sqlite;

enum abstract SynchronousMode(Int) from Int to Int {
    var OFF    = 0;
    var NORMAL = 1;
    var FULL   = 2;
    var EXTRA  = 3;

    public static function fromInt(v:Int):SynchronousMode {
        return switch (v) {
            case 0: OFF;
            case 1: NORMAL;
            case 2: FULL;
            case 3: EXTRA;
            default: NORMAL;
        }
    }
}