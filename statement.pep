## `Statement`: a prepared SQL statement, its parameters and its rows.

import json;
import "error";
import "sqlite3";
import "value";

## A prepared SQL statement, made by `Database.prepare`.
##
## Bind its parameters with `bind`, then call `step` until it returns
## false: each true is a row, read with the `column_` methods or decoded
## into a struct with `read<T>()`. `reset` runs it again, keeping the
## bindings; `clear_bindings` sets every parameter back to `NULL`.
##
## Parameters are numbered from 1, as SQLite numbers them (`?`, `?1`), or
## named (`:name`, `@name`, `$name`, with the prefix in the name you
## bind). Columns are numbered from 0.
##
## The statement keeps its database open. It is finalized when the last
## reference to it goes away, or earlier with `finalize()`.
##
## @example
##     import sqlite;
##
##     var db = sqlite.Database.open_in_memory().value();
##     db.execute("CREATE TABLE t (n INTEGER, name TEXT)").value();
##     var insert = db.prepare("INSERT INTO t VALUES (?, :name)").value();
##     insert.bind(1, 7).value();
##     insert.bind(":name", "seven").value();
##     insert.step().value();
##     var query = db.prepare("SELECT n, name FROM t").value();
##     while (query.step().value()) {
##         print($"{query.column_long(0).value()} {query.column_text(1).value()}");
##     }
export struct Statement {
    var _handle: Handle<__ptr<void>>;
    # Keeps the connection open while the statement lives.
    var _database: Handle<__ptr<void>>;
    var _has_row: bool;

    ## Wraps a statement `Database.prepare` made; use that instead.
    ##
    ## @param handle the `sqlite3_stmt*`, which the statement takes over
    ## @param database the connection's handle, kept open while the
    ##   statement lives
    construct(handle: __ptr<void>, database: Handle<__ptr<void>>) {
        _handle = Handle<__ptr<void>>(handle, (statement) => {
            sqlite3_finalize(statement);
        });
        _database = database;
    }

    ## Reports whether the statement is still usable: false after
    ## `finalize()`.
    ##
    ## @returns true until the statement is finalized
    is_open(): bool {
        return _handle.is_owned();
    }

    ## Frees the statement now rather than when the last reference to it
    ## goes away. Calling it again does nothing.
    finalize() {
        _handle.release();
        _has_row = false;
    }

    _raw(): __ptr<void> {
        assert(_handle.is_owned(), "sqlite: the statement is finalized");
        return _handle.value;
    }

    _db(): __ptr<void> {
        return _database.value;
    }

    # Parameters

    ## Returns the number of parameters: the largest parameter index.
    ##
    ## @returns the parameter count
    ## @panics if the statement is finalized
    parameter_count(): int {
        return sqlite3_bind_parameter_count(_raw());
    }

    ## Returns the index of the parameter named `name`, prefix included
    ## (`:id`).
    ##
    ## @param name the parameter's name, with its `:`, `@` or `$`
    ## @returns the index, from 1, or none when no parameter has that name
    ## @panics if the statement is finalized
    parameter_index(name: String): int? {
        var index = sqlite3_bind_parameter_index(_raw(), name.c_str());
        if (index == 0) {
            return Optional<int>.Empty;
        }
        return Optional<int>.Value(index);
    }

    _index(name: String): SqliteResult<int> {
        var index = parameter_index(name);
        if (index is Value(found)) {
            return SqliteResult<int>.ok(found);
        }
        return SqliteResult<int>.err(SqliteError(SQLITE_RANGE, $"no parameter named '{name}'"));
    }

    ## Binds an integer to the parameter at `index`.
    ##
    ## @param index the parameter's index, from 1
    ## @param value the integer
    ## @returns nothing, or the error (`SQLITE_RANGE` for a bad index)
    ## @panics if the statement is finalized
    bind(index: int, value: long): SqliteResult<void> {
        return _check(_db(), sqlite3_bind_int64(_raw(), index, value));
    }

    ## Binds a floating-point number to the parameter at `index`.
    ##
    ## @param index the parameter's index, from 1
    ## @param value the number
    ## @returns nothing, or the error (`SQLITE_RANGE` for a bad index)
    ## @panics if the statement is finalized
    bind(index: int, value: double): SqliteResult<void> {
        return _check(_db(), sqlite3_bind_double(_raw(), index, value));
    }

    ## Binds text to the parameter at `index`. SQLite copies it.
    ##
    ## @param index the parameter's index, from 1
    ## @param value the text; empty text binds `''`, not `NULL`
    ## @returns nothing, or the error (`SQLITE_RANGE` for a bad index,
    ##   `SQLITE_TOOBIG` for text of 2 GiB or more)
    ## @panics if the statement is finalized
    bind(index: int, value: String): SqliteResult<void> {
        if (value.size > 0x7fffffff) {
            return SqliteResult<void>.err(_error(__null, SQLITE_TOOBIG));
        }
        __ptr<char> text = _c_text(value);
        return _check(_db(), sqlite3_bind_text(_raw(), index, text, value.size as int, _transient()));
    }

    ## Binds a blob to the parameter at `index`. SQLite copies it.
    ##
    ## @param index the parameter's index, from 1
    ## @param bytes the bytes; an empty array binds an empty blob, not
    ##   `NULL`
    ## @returns nothing, or the error (`SQLITE_RANGE` for a bad index,
    ##   `SQLITE_TOOBIG` for 2 GiB or more)
    ## @panics if the statement is finalized
    bind(index: int, bytes: u8[]): SqliteResult<void> {
        if (bytes.count > 0x7fffffff) {
            return SqliteResult<void>.err(_error(__null, SQLITE_TOOBIG));
        }
        if (bytes.count == 0) {
            return _check(_db(), sqlite3_bind_zeroblob(_raw(), index, 0));
        }
        # The runtime gives no pointer to an array's elements, so the bytes go
        # through a C buffer.
        __ptr<u8> buffer = malloc(bytes.count) as __ptr<u8>;
        for (var i in 0..bytes.count) {
            buffer[i] = bytes[i];
        }
        var code = sqlite3_bind_blob(_raw(), index, buffer as __ptr<void>, bytes.count as int, _transient());
        free(buffer as __ptr<void>);
        return _check(_db(), code);
    }

    ## Binds any `Value` to the parameter at `index`.
    ##
    ## @param index the parameter's index, from 1
    ## @param value the value
    ## @returns nothing, or the error, as the `bind` for its type
    ## @panics if the statement is finalized
    bind(index: int, value: Value): SqliteResult<void> {
        return match (value) {
            Null => this.bind_null(index),
            Integer(n) => this.bind(index, n),
            Real(x) => this.bind(index, x),
            Text(text) => this.bind(index, text),
            Blob(bytes) => this.bind(index, bytes),
        };
    }

    ## Binds `NULL` to the parameter at `index`.
    ##
    ## @param index the parameter's index, from 1
    ## @returns nothing, or the error (`SQLITE_RANGE` for a bad index)
    ## @panics if the statement is finalized
    bind_null(index: int): SqliteResult<void> {
        return _check(_db(), sqlite3_bind_null(_raw(), index));
    }

    ## Binds an integer to the parameter named `name`.
    ##
    ## @param name the parameter's name, with its prefix (`:id`)
    ## @param value the integer
    ## @returns nothing, or the error (`SQLITE_RANGE` for an unknown name)
    ## @panics if the statement is finalized
    bind(name: String, value: long): SqliteResult<void> {
        return this.bind(_index(name)?, value);
    }

    ## Binds a floating-point number to the parameter named `name`.
    ##
    ## @param name the parameter's name, with its prefix (`:id`)
    ## @param value the number
    ## @returns nothing, or the error (`SQLITE_RANGE` for an unknown name)
    ## @panics if the statement is finalized
    bind(name: String, value: double): SqliteResult<void> {
        return this.bind(_index(name)?, value);
    }

    ## Binds text to the parameter named `name`.
    ##
    ## @param name the parameter's name, with its prefix (`:id`)
    ## @param value the text
    ## @returns nothing, or the error (`SQLITE_RANGE` for an unknown name)
    ## @panics if the statement is finalized
    bind(name: String, value: String): SqliteResult<void> {
        return this.bind(_index(name)?, value);
    }

    ## Binds a blob to the parameter named `name`.
    ##
    ## @param name the parameter's name, with its prefix (`:id`)
    ## @param bytes the bytes
    ## @returns nothing, or the error (`SQLITE_RANGE` for an unknown name)
    ## @panics if the statement is finalized
    bind(name: String, bytes: u8[]): SqliteResult<void> {
        return this.bind(_index(name)?, bytes);
    }

    ## Binds any `Value` to the parameter named `name`.
    ##
    ## @param name the parameter's name, with its prefix (`:id`)
    ## @param value the value
    ## @returns nothing, or the error (`SQLITE_RANGE` for an unknown name)
    ## @panics if the statement is finalized
    bind(name: String, value: Value): SqliteResult<void> {
        return this.bind(_index(name)?, value);
    }

    ## Binds `NULL` to the parameter named `name`.
    ##
    ## @param name the parameter's name, with its prefix (`:id`)
    ## @returns nothing, or the error (`SQLITE_RANGE` for an unknown name)
    ## @panics if the statement is finalized
    bind_null(name: String): SqliteResult<void> {
        return this.bind_null(_index(name)?);
    }

    ## Binds `values` to the parameters 1, 2, ... in order.
    ##
    ## @param values one value per parameter
    ## @returns nothing, or the first error (`SQLITE_RANGE` when there are
    ##   more values than parameters)
    ## @panics if the statement is finalized
    bind_all(values: Value[]): SqliteResult<void> {
        for (var i in 0..values.count) {
            var value = values[i];
            this.bind((i + 1) as int, value)?;
        }
        return SqliteResult<void>.ok();
    }

    ## Sets every parameter back to `NULL`.
    ##
    ## @panics if the statement is finalized
    clear_bindings() {
        sqlite3_clear_bindings(_raw());
    }

    # Running

    ## Runs the statement to its next row.
    ##
    ## @returns true when a row is ready to read, false when the statement
    ##   is done, or the error; after false or an error, `reset` runs it
    ##   again
    ## @panics if the statement is finalized
    step(): SqliteResult<bool> {
        var code = sqlite3_step(_raw());
        _has_row = code == SQLITE_ROW;
        if (code == SQLITE_ROW || code == SQLITE_DONE) {
            return SqliteResult<bool>.ok(_has_row);
        }
        # The step's error is on the connection; reset returns the same code.
        sqlite3_reset(_raw());
        return SqliteResult<bool>.err(_error(_db(), code));
    }

    ## Sets the statement back to its start, to run it again. The bindings
    ## stay.
    ##
    ## @panics if the statement is finalized
    reset() {
        # Its code repeats the last step's error, which step already returned.
        sqlite3_reset(_raw());
        _has_row = false;
    }

    # Columns

    ## Returns the number of columns in the statement's rows.
    ##
    ## @returns the column count, 0 for a statement that returns no rows
    ## @panics if the statement is finalized
    column_count(): int {
        return sqlite3_column_count(_raw());
    }

    ## Returns the name of a column: its `AS` name, or SQLite's.
    ##
    ## @param index the column's index, from 0
    ## @returns the name
    ## @panics if the statement is finalized or `index` is out of range
    column_name(index: int): String {
        _column(index);
        return String(sqlite3_column_name(_raw(), index));
    }

    _column(index: int) {
        var count = column_count();
        assert(index >= 0 && index < count, $"sqlite: column {index} out of range (the statement has {count})");
    }

    _row_column(index: int): bool {
        assert(_has_row, "sqlite: no row to read; step() did not return true");
        _column(index);
        return sqlite3_column_type(_raw(), index) != SQLITE_NULL;
    }

    ## Reports whether a column of the current row is `NULL`.
    ##
    ## @param index the column's index, from 0
    ## @returns true for `NULL`
    ## @panics if there is no current row or `index` is out of range
    column_is_null(index: int): bool {
        return !_row_column(index);
    }

    ## Reads a column of the current row as an `int`, converting as SQLite
    ## does (text is parsed, a real truncated) and keeping the low 32 bits.
    ##
    ## @param index the column's index, from 0
    ## @returns the integer, or none for `NULL`
    ## @panics if there is no current row or `index` is out of range
    column_int(index: int): int? {
        if (!_row_column(index)) {
            return Optional<int>.Empty;
        }
        return Optional<int>.Value(sqlite3_column_int64(_raw(), index) as int);
    }

    ## Reads a column of the current row as a `long`, converting as SQLite
    ## does (text is parsed, a real truncated).
    ##
    ## @param index the column's index, from 0
    ## @returns the integer, or none for `NULL`
    ## @panics if there is no current row or `index` is out of range
    column_long(index: int): long? {
        if (!_row_column(index)) {
            return Optional<long>.Empty;
        }
        return Optional<long>.Value(sqlite3_column_int64(_raw(), index));
    }

    ## Reads a column of the current row as a `double`, converting as
    ## SQLite does.
    ##
    ## @param index the column's index, from 0
    ## @returns the number, or none for `NULL`
    ## @panics if there is no current row or `index` is out of range
    column_double(index: int): double? {
        if (!_row_column(index)) {
            return Optional<double>.Empty;
        }
        return Optional<double>.Value(sqlite3_column_double(_raw(), index));
    }

    ## Reads a column of the current row as text: a number as SQLite
    ## writes it, a blob's bytes as they are.
    ##
    ## @param index the column's index, from 0
    ## @returns the text, or none for `NULL`
    ## @panics if there is no current row or `index` is out of range
    column_text(index: int): String? {
        if (!_row_column(index)) {
            return Optional<String>.Empty;
        }
        # Text first, then its size, as SQLite asks.
        var text = sqlite3_column_text(_raw(), index);
        var size = sqlite3_column_bytes(_raw(), index) as ulong;
        return Optional<String>.Value(String(text, size));
    }

    ## Reads a column of the current row as bytes: a blob as stored, text
    ## as its UTF-8 bytes.
    ##
    ## @param index the column's index, from 0
    ## @returns the bytes, or none for `NULL`
    ## @panics if there is no current row or `index` is out of range
    column_blob(index: int): u8[]? {
        if (!_row_column(index)) {
            return Optional<u8[]>.Empty;
        }
        __ptr<u8> data = sqlite3_column_blob(_raw(), index) as __ptr<u8>;
        var size = sqlite3_column_bytes(_raw(), index) as ulong;
        var bytes = Array<u8>();
        bytes.reserve(size);
        for (var i in 0..size) {
            bytes.append(data[i]);
        }
        return Optional<u8[]>.Value(bytes);
    }

    ## Reads a column of the current row as the `Value` of its storage
    ## class.
    ##
    ## @param index the column's index, from 0
    ## @returns the value
    ## @panics if there is no current row or `index` is out of range
    column(index: int): Value {
        if (!_row_column(index)) {
            return Value.Null;
        }
        var storage = sqlite3_column_type(_raw(), index);
        if (storage == SQLITE_INTEGER) {
            return Value.Integer(column_long(index).value());
        }
        if (storage == SQLITE_FLOAT) {
            return Value.Real(column_double(index).value());
        }
        if (storage == SQLITE_TEXT) {
            return Value.Text(column_text(index).value());
        }
        return Value.Blob(column_blob(index).value());
    }

    ## Decodes the current row into a `T`, as `json.from_json` decodes an
    ## object whose keys are the column names.
    ##
    ## A column fills the property of its name (or of its
    ## `[Name("...")]`); a `NULL` column is `null`, so it fills an
    ## `Optional` property as none. Integers fill number properties, text
    ## `String`s and blobs `u8[]` properties. A column no property names is
    ## ignored, and a property no column names keeps its default, unless it
    ## is `[Required]`.
    ##
    ## @typeParam T the struct to decode into
    ## @returns the decoded row, or an error with code `SQLITE_MISMATCH`
    ##   (20) whose message is the conversion's (`$.age: expected a
    ##   number, found a string`)
    ## @panics if there is no current row
    read<T>(): SqliteResult<T> {
        assert(_has_row, "sqlite: no row to read; step() did not return true");
        var object = json.JsonValue.object();
        var count = column_count();
        for (var i in 0..count) {
            object[column_name(i)] = _json_of(column(i));
        }
        var decoded = json.from_json<T>(object);
        if (decoded.is_err()) {
            return SqliteResult<T>.err(SqliteError(SQLITE_MISMATCH, decoded.error().message));
        }
        return SqliteResult<T>.ok(decoded.value());
    }
}

_json_of(value: Value): json.JsonValue {
    return match (value) {
        Null => json.JsonValue.Null,
        Integer(n) => json.JsonValue.Integer(n),
        Real(x) => json.JsonValue.Number(x),
        Text(text) => json.JsonValue.String(text),
        Blob(bytes) => _json_bytes(bytes),
    };
}

_json_bytes(bytes: u8[]): json.JsonValue {
    var items = json.JsonValue.array();
    for (var item in bytes) {
        items.append(json.JsonValue.Integer(item as long));
    }
    return items;
}
