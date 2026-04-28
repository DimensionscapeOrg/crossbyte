package crossbyte.auth;

/** Shared secret material used by authentication helpers such as JWT signers. */
typedef Secret = {
    /** Optional key identifier used to select a specific secret. */
    @:optional var key:String; 
    /** Secret bytes represented as a string payload. */
    var secret:String;
}
