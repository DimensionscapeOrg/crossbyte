import crossbyte.ds.IdList;
#if !no_sparse
import crossbyte.ds.SparseSpatialGrid;
#end
import crossbyte.ds.SpatialGrid;
import haxe.ds.Vector;

/**
	The arena sample's index upkeep, grown: N entities wandering at NPC speed
	(40 units a second at 20 Hz), the world grown with N so each view of
	radius 300 holds the same crowd as the sample's (300 in 2,000 by 2,000,
	about 21 a view), and 16 observers asking for their view every step.
	Cells the size of a view, as the sample's.

	Per entity per step: `set` for every entity (`moveNs`); per query:
	`queryCircleIds` into a list (`queryNs`); per entity, the first `set`
	into an empty grid (`insertNs`). The dense `SpatialGrid` over the world's
	rectangle, and `SparseSpatialGrid` with no bounds, on the same moves.

	`--spread` puts the same crowds in 16 towns a hundred million units
	apart, which no dense grid can hold (its cells would pass `MAX_CELLS`),
	for the sparse grid alone.

	Prints a JSON line per grid and count. Built with `-D no_sparse` for a
	tree from before the sparse grid.

	```
	haxe tests/perf/spatial/spatial.hxml
	export/spatial/native/SpatialBench.exe [--counts 10000,100000,250000] [--steps 100] [--spread]
	```
**/
class SpatialBench {
	static inline final VIEW:Float = 300;
	static inline final SPEED:Float = 40;
	static inline final STEP:Float = 1 / 20;
	// The sample's crowd: 300 in a square of 2,000.
	static inline final DENSITY:Float = 300 / (2000.0 * 2000.0);
	static inline final OBSERVERS:Int = 16;
	static inline final TOWN_GAP:Float = 1e8;

	static function main():Void {
		final args:Array<String> = #if sys Sys.args() #else [] #end;
		final counts:Array<Int> = [for (c in stringArg(args, "--counts", "10000,100000,250000").split(",")) Std.parseInt(c)];
		final steps:Int = Std.parseInt(stringArg(args, "--steps", "100"));
		final spread:Bool = args.indexOf("--spread") >= 0;
		final grids:Array<String> = stringArg(args, "--grids", #if no_sparse "dense" #else "dense,sparse" #end).split(",");
		for (count in counts) {
			for (grid in grids) {
				if (spread && grid == "dense") {
					continue;
				}
				run(grid, count, steps, spread);
			}
		}
	}

	static function run(kind:String, count:Int, steps:Int, spread:Bool):Void {
		final world:Float = spread ? Math.sqrt(count / 16 / DENSITY) : Math.sqrt(count / DENSITY);
		final xs = new Vector<Float>(count);
		final ys = new Vector<Float>(count);
		final vxs = new Vector<Float>(count);
		final vys = new Vector<Float>(count);
		var seed:Int = 0x2545F491;
		inline function next():Float {
			seed ^= seed << 13;
			seed ^= seed >>> 17;
			seed ^= seed << 5;
			return (seed & 0x7FFFFFFF) / 2147483648.0;
		}
		for (i in 0...count) {
			// In a town of its own when spread: sixteen, a long way apart.
			final town:Int = spread ? i % 16 : 0;
			xs[i] = next() * world + (town % 4) * TOWN_GAP;
			ys[i] = next() * world + Std.int(town / 4) * TOWN_GAP;
			final angle:Float = next() * Math.PI * 2;
			vxs[i] = Math.cos(angle) * SPEED;
			vys[i] = Math.sin(angle) * SPEED;
		}
		final found = new IdList(256);
		var dense:Null<SpatialGrid> = null;
		#if !no_sparse
		var sparse:Null<SparseSpatialGrid> = null;
		#end

		// Insert: every entity into an empty grid.
		final a:Float = haxe.Timer.stamp();
		if (kind == "dense") {
			final grid = new SpatialGrid(0, 0, world, world, VIEW, count);
			for (i in 0...count) {
				grid.set(i, xs[i], ys[i]);
			}
			dense = grid;
		} else {
			#if !no_sparse
			final grid = new SparseSpatialGrid(VIEW, count);
			for (i in 0...count) {
				grid.set(i, xs[i], ys[i]);
			}
			sparse = grid;
			#end
		}
		final insert:Float = haxe.Timer.stamp() - a;

		var move:Float = 0.0;
		var query:Float = 0.0;
		var seen:Float = 0.0;
		final warm:Int = 20;
		for (step in 0...warm + steps) {
			for (i in 0...count) {
				var x:Float = xs[i] + vxs[i] * STEP;
				var y:Float = ys[i] + vys[i] * STEP;
				final town:Int = spread ? i % 16 : 0;
				final left:Float = (town % 4) * TOWN_GAP;
				final top:Float = Std.int(town / 4) * TOWN_GAP;
				if (x < left || x >= left + world) {
					vxs[i] = -vxs[i];
					x = xs[i];
				}
				if (y < top || y >= top + world) {
					vys[i] = -vys[i];
					y = ys[i];
				}
				xs[i] = x;
				ys[i] = y;
			}
			final b:Float = haxe.Timer.stamp();
			if (dense != null) {
				final grid:SpatialGrid = dense;
				for (i in 0...count) {
					grid.set(i, xs[i], ys[i]);
				}
			}
			#if !no_sparse
			if (sparse != null) {
				final grid:SparseSpatialGrid = sparse;
				for (i in 0...count) {
					grid.set(i, xs[i], ys[i]);
				}
			}
			#end
			final c:Float = haxe.Timer.stamp();
			var hits:Int = 0;
			for (o in 0...OBSERVERS) {
				final at:Int = Std.int(o * (count / OBSERVERS));
				found.clear();
				if (dense != null) {
					dense.queryCircleIds(xs[at], ys[at], VIEW, found);
				}
				#if !no_sparse
				if (sparse != null) {
					sparse.queryCircleIds(xs[at], ys[at], VIEW, found);
				}
				#end
				hits += found.length;
			}
			final d:Float = haxe.Timer.stamp();
			if (step >= warm) {
				move += c - b;
				query += d - c;
				seen += hits;
			}
		}
		Sys.println(haxe.Json.stringify({
			grid: kind,
			target: #if cpp "native" #elseif jvm "jvm" #else "other" #end,
			count: count,
			spread: spread,
			world: Math.round(world),
			insertNs: insert / count * 1e9,
			moveNs: move / (steps * 1.0 * count) * 1e9,
			moveMsPerStep: move / steps * 1e3,
			queryNs: query / (steps * 1.0 * OBSERVERS) * 1e9,
			foundPerQuery: seen / (steps * 1.0 * OBSERVERS)
		}));
	}

	static function stringArg(args:Array<String>, name:String, fallback:String):String {
		final at:Int = args.indexOf(name);
		return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
	}
}
