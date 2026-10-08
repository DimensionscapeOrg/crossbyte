package crossbyte._internal.brotli.codec.encode.hash;
import haxe.ds.Vector;
import crossbyte._internal.brotli.codec.DefaultFunctions;

/**
 * ...
 * @author 
 */
class Hashers
{
  // For kBucketSweep == 1, enabling the dictionary lookup makes compression
  // a little faster (0.5% - 1%) and it compresses 0.15% better on small text
  // and html inputs.
  /*var H1=HashLongestMatchQuickly(16, 1, true);
  var H2=HashLongestMatchQuickly(16, 2, false);
  var H3=HashLongestMatchQuickly(16, 4, false);
  var H4=HashLongestMatchQuickly(17, 4, true);
  var H5=HashLongestMatch(14, 4, 4);
  var H6=HashLongestMatch(14, 5, 4);
  var H7=HashLongestMatch(15, 6, 10);
  var H8=HashLongestMatch(15, 7, 10);
  var H9=HashLongestMatch(15, 8, 16);*/

  /*
   * The quick hashers, one set per thread, kept between calls.
   *
   * Each is a table of 2^16 or 2^17 entries, which would be most of the cost
   * of compressing a small response if every call allocated and cleared one.
   * Kept, a table only needs clearing where the next input will look (see
   * HashLongestMatchQuickly.Prepare), and the output is the same as with a
   * fresh one. Per thread because a compressor
   * uses its table throughout a call, and compressing is synchronous, so a
   * thread never has two calls using one table at once.
   *
   * The slower hashers, for quality 5 and up, are made per call: their
   * tables grow with what they store, up to 32 MB at quality 9, which is too
   * much to hold on to for a quality nothing uses by default.
   */
  #if target.threaded
  static var __kept:sys.thread.Tls<Vector<HashLongestMatchQuickly>> = new sys.thread.Tls();
  #else
  static var __kept:Vector<HashLongestMatchQuickly>;
  #end

  static function Kept(type:Int):HashLongestMatchQuickly {
    #if target.threaded
    var kept:Vector<HashLongestMatchQuickly> = __kept.value;
    if (kept == null) {
      kept = new Vector<HashLongestMatchQuickly>(5);
      __kept.value = kept;
    }
    #else
    var kept:Vector<HashLongestMatchQuickly> = __kept;
    if (kept == null) {
      kept = __kept = new Vector<HashLongestMatchQuickly>(5);
    }
    #end
    var hasher:HashLongestMatchQuickly = kept[type];
    if (hasher == null) {
      hasher = switch (type) {
        case 1: new HashLongestMatchQuickly(16, 1, true);
        case 2: new HashLongestMatchQuickly(16, 2, false);
        case 3: new HashLongestMatchQuickly(16, 4, false);
        default: new HashLongestMatchQuickly(17, 4, true);
      }
      kept[type] = hasher;
    }
    return hasher;
  }

  /** Readies the hasher for `type`, before any input has arrived. **/
  public function Init(type:Int) {
    switch (type) {
      case 1: this.hash_h1=Kept(1);
      case 2: this.hash_h2=Kept(2);
      case 3: this.hash_h3=Kept(3);
      case 4: this.hash_h4=Kept(4);
      case 5: this.hash_h5=new HashLongestMatch(14, 4, 4);
      case 6: this.hash_h6=new HashLongestMatch(14, 5, 4);
      case 7: this.hash_h7=new HashLongestMatch(15, 6, 10);
      case 8: this.hash_h8=new HashLongestMatch(15, 7, 10);
      case 9: this.hash_h9=new HashLongestMatch(15, 8, 16);
      default:
    }
  }

  /**
   * Clears the hasher for a call, once the first block is in the ring
   * buffer: `data` from 0, masked by `mask`. `size_hint` is the whole
   * input's length when known, or -1.
   */
  public function Prepare(type:Int, size_hint:Int, data:Vector<UInt>, mask:Int) {
    switch (type) {
      case 1: this.hash_h1.Prepare(size_hint, data, mask);
      case 2: this.hash_h2.Prepare(size_hint, data, mask);
      case 3: this.hash_h3.Prepare(size_hint, data, mask);
      case 4: this.hash_h4.Prepare(size_hint, data, mask);
      default:
        // Made fresh, and cleared as they were made.
    }
  }
  public function WarmupHashHashLongestMatchQuickly(size:Int, dict:Vector<UInt>, hasher:HashLongestMatchQuickly) {
    for (i in 0...size) {
      hasher.Store(dict,0, i);
    }
  }
  public function WarmupHashHashLongestMatch(size:Int, dict:Vector<UInt>, hasher:HashLongestMatch) {
    for (i in 0...size) {
      hasher.Store(dict,0, i);
    }
  }

  // Custom LZ77 window.
  public function PrependCustomDictionary(
      type:Int, size:Int, dict:Vector<UInt>) {
    switch (type) {
      case 1: WarmupHashHashLongestMatchQuickly(size, dict, this.hash_h1);
      case 2: WarmupHashHashLongestMatchQuickly(size, dict, this.hash_h2);
      case 3: WarmupHashHashLongestMatchQuickly(size, dict, this.hash_h3);
      case 4: WarmupHashHashLongestMatchQuickly(size, dict, this.hash_h4);
      case 5: WarmupHashHashLongestMatch(size, dict, this.hash_h5);
      case 6: WarmupHashHashLongestMatch(size, dict, this.hash_h6);
      case 7: WarmupHashHashLongestMatch(size, dict, this.hash_h7);
      case 8: WarmupHashHashLongestMatch(size, dict, this.hash_h8);
      case 9: WarmupHashHashLongestMatch(size, dict, this.hash_h9);
      default:
    }
  }

  public var hash_h1:HashLongestMatchQuickly;
  public var hash_h2:HashLongestMatchQuickly;
  public var hash_h3:HashLongestMatchQuickly;
  public var hash_h4:HashLongestMatchQuickly;
  public var hash_h5:HashLongestMatch;
  public var hash_h6:HashLongestMatch;
  public var hash_h7:HashLongestMatch;
  public var hash_h8:HashLongestMatch;
  public var hash_h9:HashLongestMatch;
	public function new() 
	{
		
	}
	
}
