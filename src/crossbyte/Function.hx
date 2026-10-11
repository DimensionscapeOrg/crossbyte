package crossbyte;

/**
 * Any function, whatever it takes and returns: `haxe.Constraints.Function`.
 * A value of this type is called through `Dynamic`, so where the arguments
 * are known, a function type (`Event->Void`) is checked when it is passed
 * and called directly.
 *
 * @author Christopher Speciale
 */
typedef Function = haxe.Constraints.Function;
