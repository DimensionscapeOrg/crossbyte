package crossbyte.db.sql._internal;

import crossbyte.errors.SQLError;
import crossbyte.events.SQLEvent;
import haxe.ds.StringMap;

/**
	A statement's rows made instances of its `itemClass`, as AIR's
	`SQLStatement.itemClass` makes them: each created with no arguments,
	which runs its constructor, and each field set from the column of its
	name. The class needs a field, or a property with a setter, for every
	column; a column it has none for is an error, as in AIR. Only runs when
	a statement has an `itemClass`, so rows that need none cost nothing more.

	Fields are set by reflection, so under `-dce full` keep the class
	(`@:keep`) or its fields are removed as unused.

	What is the same for every row is worked out once a page: which columns
	the class takes, and -- for an SQL result, whose rows all have the same
	columns -- the columns themselves. Each row asked for its field names, and
	each name was looked for along the class's field list, and again with
	"set_" put in front, which cost more than the rest of the page's reading
	(+300-500 ns a row of 8 columns, the audit's SqlitePerf).
**/
@:noCompletion
class ItemRows {
	/**
		`rows`, each made an instance of `itemClass`; `rows` themselves when
		it is null.

		@param uniform Whether every row has the first row's fields, as the
		rows of one SQL result do; a document store's need not.
		@throws SQLError When a column has no field in `itemClass` to go to.
	**/
	public static function make(rows:Array<Dynamic>, itemClass:Null<Class<Dynamic>>, uniform:Bool = false):Array<Dynamic> {
		if (itemClass == null || rows == null || rows.length == 0) {
			return rows;
		}

		// Asked once a page, not once a row.
		var fields:StringMap<Bool> = new StringMap();

		for (field in Type.getInstanceFields(itemClass)) {
			fields.set(field, true);
		}

		var taken:StringMap<Bool> = new StringMap();
		var noArguments:Array<Dynamic> = [];
		var columns:Array<String> = null;
		var items:Array<Dynamic> = [];

		for (row in rows) {
			var item:Dynamic = Type.createInstance(itemClass, noArguments);
			var names:Array<String> = uniform && columns != null ? columns : Reflect.fields(row);

			if (columns == null) {
				columns = names;
			}

			for (column in names) {
				if (!taken.exists(column)) {
					// A property with accessors may not be a field at run time;
					// its setter is.
					if (!fields.exists(column) && !fields.exists("set_" + column)) {
						var detail:String = 'column "$column" has no field in ${Type.getClassName(itemClass)}';
						throw new SQLError(SQLEvent.RESULT, detail, "Execution failed: " + detail);
					}

					taken.set(column, true);
				}

				Reflect.setProperty(item, column, Reflect.field(row, column));
			}

			items.push(item);
		}

		return items;
	}
}
