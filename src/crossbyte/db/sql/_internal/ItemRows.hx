package crossbyte.db.sql._internal;

import crossbyte.errors.SQLError;
import crossbyte.events.SQLEvent;

/**
	A statement's rows made instances of its `itemClass`, as AIR's
	`SQLStatement.itemClass` makes them: each created with no arguments,
	which runs its constructor, and each field set from the column of its
	name. The class needs a field, or a property with a setter, for every
	column; a column it has none for is an error, as in AIR. Only runs when
	a statement has an `itemClass`, so rows that need none cost nothing more.

	Fields are set by reflection, so under `-dce full` keep the class
	(`@:keep`) or its fields are removed as unused.
**/
@:noCompletion
class ItemRows {
	/**
		`rows`, each made an instance of `itemClass`; `rows` themselves when
		it is null.

		@throws SQLError When a column has no field in `itemClass` to go to.
	**/
	public static function make(rows:Array<Dynamic>, itemClass:Null<Class<Dynamic>>):Array<Dynamic> {
		if (itemClass == null || rows == null || rows.length == 0) {
			return rows;
		}

		// Asked once a page, not once a row.
		var fields:Array<String> = Type.getInstanceFields(itemClass);
		var items:Array<Dynamic> = [];

		for (row in rows) {
			var item:Dynamic = Type.createInstance(itemClass, []);

			for (column in Reflect.fields(row)) {
				// A property with accessors may not be a field at run time;
				// its setter is.
				if (fields.indexOf(column) < 0 && fields.indexOf("set_" + column) < 0) {
					var detail:String = 'column "$column" has no field in ${Type.getClassName(itemClass)}';
					throw new SQLError(SQLEvent.RESULT, detail, "Execution failed: " + detail);
				}

				Reflect.setProperty(item, column, Reflect.field(row, column));
			}

			items.push(item);
		}

		return items;
	}
}
