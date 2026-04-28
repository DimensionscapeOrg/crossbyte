package crossbyte._internal.brotli.codec.encode.metablock;
import crossbyte._internal.brotli.codec.encode.Histogram_functions.*;
import haxe.ds.Vector;
import crossbyte._internal.brotli.codec.encode.histogram.Histogram;

/**
 * ...
 * @author 
 */
class MetaBlockSplit
{

	public var literal_split:BlockSplit=new BlockSplit();
  public var command_split:BlockSplit=new BlockSplit();
  public var distance_split:BlockSplit=new BlockSplit();
  public var literal_context_map:Vector<Int>=new Vector(0);
  public var distance_context_map:Vector<Int>=new Vector(0);
  public var literal_histograms:Array<Histogram>=new Array();//= HistogramLiteral();
  public var command_histograms:Array<Histogram>=new Array();//=HistogramCommand();
  public var distance_histograms:Array<Histogram>=new Array();//=HistogramDistance();
	public function new() 
	{
		
	}
	
}
