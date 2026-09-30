package crossbyte._internal.brotli.codec.encode;
import haxe.ds.Vector;
import haxe.io.Bytes;
import crossbyte._internal.brotli.codec.DefaultFunctions.*;
import crossbyte._internal.brotli.codec.encode.Port.*;

/**
 * ...
 * @author
 */
class RingBuffer
{
  // Zeroed bytes kept past the data: hashing reads four bytes at the last
  // position, and a match compares one byte past its longest length.
  static inline var kSlack:Int = 8;

  function WriteTail(bytes:Vector<UInt>, n:Int) {
    var masked_pos:Int = pos_ & mask_;
    if (PREDICT_FALSE(masked_pos < tail_size_)) {
      // Just fill the tail buffer with the beginning data.
      var p:Int = (1 << window_bits_) + masked_pos;
      memcpy(buffer_,p, bytes,0, Std.int(Math.min(n, tail_size_ - masked_pos)));
    }
  }
  // Size of the ringbuffer is (1 << window_bits) + tail_size_.
	var window_bits_:Int;
	var mask_:Int;
  var tail_size_:Int;

  // Position to write in the ring buffer.
  var pos_:Int;
  // The actual ring buffer containing the data and the copy of the beginning
  // as a tail.
	var buffer_:Vector<UInt>;//*
	var buffer_off:Int;

  // When the whole input is known to fit one write, the buffer holds just
  // that and never wraps: see new().
  var exact_:Bool;

	/**
	 * @param exact_size When at least 0, the whole input is this many bytes
	 *        and arrives in writes that never wrap: the buffer is allocated at
	 *        that size rather than at the window's, and the tail -- a copy of
	 *        the start for reads that cross the end -- is never needed.
	 *
	 *        The window's size was allocated whatever the input: 2^23 + 2^16
	 *        entries for a two-byte body, per call, which is most of what
	 *        compressing a small response cost.
	 */
	public function new(window_bits:Int, tail_bits:Int, exact_size:Int = -1)
	{
		this.window_bits_ = window_bits;
        this.mask_=(1 << window_bits) - 1;
        this.tail_size_=1 << tail_bits;
        this.pos_=0;
    exact_ = exact_size >= 0 && exact_size <= tail_size_ && exact_size <= mask_;
    var buflen:Int = exact_ ? exact_size : (1 << window_bits_) + tail_size_;
    buffer_ = new Vector(buflen + kSlack);
    for (i in 0...kSlack) {
      buffer_[buflen + i] = 0;
    }
	}
  // Push bytes into the ring buffer.
public function Write(bytes:Vector<UInt>, n:Int) {
    if (exact_) {
      memcpy(buffer_,pos_, bytes,0, n);
      pos_ += n;
      return;
    }
    var masked_pos:Int = pos_ & mask_;
    // The length of the writes is limited so that we do not need to worry
    // about a write
    WriteTail(bytes, n);
    if (PREDICT_TRUE(masked_pos + n <= (1 << window_bits_))) {
      // A single write fits.
      memcpy(buffer_,masked_pos, bytes,0, n);
    } else {
      // Split into two writes.
      // Copy into the end of the buffer, including the tail buffer.
      memcpy(buffer_,masked_pos, bytes,0,
             Std.int(Math.min(n, ((1 << window_bits_) + tail_size_) - masked_pos)));
      // Copy into the begining of the buffer
      memcpy(buffer_,0, bytes,0 + ((1 << window_bits_) - masked_pos),
             n - ((1 << window_bits_) - masked_pos));
    }
    pos_ += n;
  }

  /**
   * Pushes `n` bytes of `source` from `offset`, without the copy into a
   * Vector that Write takes.
   */
  public function WriteBytes(source:Bytes, offset:Int, n:Int) {
    if (exact_) {
      for (i in 0...n) {
        buffer_[pos_ + i] = source.get(offset + i);
      }
      pos_ += n;
      return;
    }
    var block:Vector<UInt> = new Vector<UInt>(n);
    for (i in 0...n) {
      block[i] = source.get(offset + i);
    }
    Write(block, n);
  }
  // Logical cursor position in the ring buffer.
  public function position():Int { return this.pos_; }
  // Bit mask for getting the physical position for a logical position.
  public function mask():Int { return this.mask_; }
  public function start() { return this.buffer_; }

}
