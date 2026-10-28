## `Database`: a connection to an SQLite database, and its transactions.

import "error";
import "sqlite3";
import "statement";
import "value";

## Opens the database for reading only; it must exist.
export const OPEN_READ_ONLY = 0x1;
## Opens the database for reading and writing.
export const OPEN_READ_WRITE = 0x2;
## With `OPEN_READ_WRITE`, creates the database when it does not exist.
export const OPEN_CREATE = 0x4;
## Reads the path as a URI (`file:data.db?mode=ro`).
export const OPEN_URI = 0x40;
## Opens an in-memory database, whatever the path says.
export const OPEN_MEMORY = 0x80;
## Leaves out the connection's own lock: a connection used by one thread
## at a time needs none.
export const OPEN_NO_MUTEX = 0x8000;
## Serializes every call on the connection with its own lock, whatever
## SQLite's default threading mode is.
export const OPEN_FULL_MUTEX = 0x10000;

## A connection to an SQLite database.
##
## Open one with `open` (a file) or `open_in_memory`. `execute` runs SQL
## that returns no rows; `prepare` makes a `Statement` for SQL with
## parameters or rows; `query<T>` runs a query and decodes every row into a
## struct. `transaction` runs a function inside a transaction that it
## commits, or rolls back when the function fails.
##
## The connection is closed when the last reference to it, and to every
## statement prepared on it, goes away, or earlier with `close()`. It
## belongs to one thread at a time: hand it to another thread whole with
## `Channel.send(move(db))`, or share connections through a `Pool`.
##
## @example
##     import sqlite;
##
##     struct User {
##         var id: long;
##         var name: String;
##     }
##
##     main(): int {
##         var db = sqlite.Database.open("app.db").value();
##         db.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT)").value();
##         db.execute("INSERT INTO users (name) VALUES (?)", [sqlite.Value.Text("Ada")]).value();
##         for (var user in db.query<User>("SELECT id, name FROM users").value()) {
##             print($"{user.id}: {user.name}");
##         }
##         return 0;
##     }
export struct Database {
    var _handle: Handle<__ptr<void>>;

    ## Wraps a connection `open` made; use `open` instead.
    ##
    ## @param handle the `sqlite3*`, which the database takes over
    construct(handle: __ptr<void>) {
        # close_v2 waits for the connection's statements to be finalized.
        _handle = Handle<__ptr<void>>(handle, (db) => {
            sqlite3_close_v2(db);
        });
    }

    ## Opens (by default, creating) the database file at `path`.
    ##
    ## `":memory:"` and an empty path open a private in-memory database,
    ## and a temporary on-disk one, as SQLite documents.
    ##
    ## @param path the database file
    ## @param flags `OPEN_READ_ONLY`, or `OPEN_READ_WRITE` with or without
    ##   `OPEN_CREATE`, plus `OPEN_URI` or `OPEN_MEMORY`
    ## @returns the connection, or the error (`SQLITE_CANTOPEN`, 14, when
    ##   the file cannot be opened)
    static open(path: String, flags: int = OPEN_READ_WRITE | OPEN_CREATE): SqliteResult<Database> {
        __ptr<__ptr<void>> slot = malloc(sizeof<__ptr<void>>()) as __ptr<__ptr<void>>;
        slot[0] = __null;
        __ptr<char> name = _c_text(path);
        var code = sqlite3_open_v2(name, slot, flags, __null);
        var handle = slot[0];
        free(slot as __ptr<void>);
        if (handle == __null) {
            # SQLite could not even allocate the connection.
            return SqliteResult<Database>.err(SqliteError(code, String(sqlite3_errstr(code))));
        }
        var database = Database(handle);
        if (code != SQLITE_OK) {
            return SqliteResult<Database>.err(_error(handle, code));
        }
        sqlite3_extended_result_codes(handle, 1);
        return SqliteResult<Database>.ok(database);
    }

    ## Opens a new, private in-memory database, gone when it is closed.
    ##
    ## @returns the connection, or the error
    static open_in_memory(): SqliteResult<Database> {
        return open(":memory:");
    }

    ## Reports whether the connection is open: false after `close()`.
    ##
    ## @returns true until the connection is closed
    is_open(): bool {
        return _handle.is_owned();
    }

    ## Closes the connection now rather than when the last reference to it
    ## goes away. Statements prepared on it keep it open until they are
    ## finalized, but no longer through this `Database`. Calling it again
    ## does nothing.
    close() {
        _handle.release();
    }

    _raw(): __ptr<void> {
        assert(_handle.is_owned(), "sqlite: the database is closed");
        return _handle.value;
    }

    ## Runs `sql`, which may hold several statements separated by `;`, and
    ## discards any rows.
    ##
    ## @param sql the SQL
    ## @returns nothing, or the error of the first statement that fails;
    ##   the statements before it have run
    ## @panics if the database is closed
    execute(sql: String): SqliteResult<void> {
        var db = _raw();
        __ptr<__ptr<char>> message = malloc(sizeof<__ptr<char>>()) as __ptr<__ptr<char>>;
        message[0] = __null;
        var code = sqlite3_exec(db, _c_text(sql), __null, __null, message);
        var text = message[0];
        free(message as __ptr<void>);
        if (code == SQLITE_OK) {
            return SqliteResult<void>.ok();
        }
        var error = _error(db, code);
        if (text != __null) {
            error.message = String(text);
            sqlite3_free(text as __ptr<void>);
        }
        return SqliteResult<void>.err(error);
    }

    ## Runs one statement with `parameters` bound to it in order, and
    ## discards any rows.
    ##
    ## @param sql one SQL statement
    ## @param parameters one value per parameter
    ## @returns the number of rows it inserted, changed or deleted (0 for
    ##   any other statement, such as a `SELECT` or `CREATE TABLE`), or the
    ##   error
    ## @panics if the database is closed
    execute(sql: String, parameters: Value[]): SqliteResult<long> {
        var statement = prepare(sql)?;
        statement.bind_all(parameters)?;
        # changes() keeps the last write's count through any other statement;
        # total_changes() moves only when this one writes.
        var db = _raw();
        var before = sqlite3_total_changes(db);
        while (statement.step()?) {}
        statement.finalize();
        if (sqlite3_total_changes(db) == before) {
            return SqliteResult<long>.ok(0);
        }
        return SqliteResult<long>.ok(sqlite3_changes(db) as long);
    }

    ## Compiles the first statement in `sql`.
    ##
    ## @param sql the SQL; anything after its first statement is ignored
    ## @returns the statement, or the error (`SQLITE_ERROR` for a syntax
    ##   error or an unknown table, `SQLITE_MISUSE` for SQL that holds no
    ##   statement)
    ## @panics if the database is closed
    prepare(sql: String): SqliteResult<Statement> {
        var db = _raw();
        if (sql.size > 0x7fffffff) {
            return SqliteResult<Statement>.err(_error(__null, SQLITE_TOOBIG));
        }
        __ptr<__ptr<void>> slot = malloc(sizeof<__ptr<void>>()) as __ptr<__ptr<void>>;
        slot[0] = __null;
        __ptr<char> text = _c_text(sql);
        var code = sqlite3_prepare_v2(db, text, sql.size as int, slot, __null);
        var handle = slot[0];
        free(slot as __ptr<void>);
        if (code != SQLITE_OK) {
            return SqliteResult<Statement>.err(_error(db, code));
        }
        if (handle == __null) {
            # Only whitespace or comments: SQLite makes no statement.
            return SqliteResult<Statement>.err(SqliteError(SQLITE_MISUSE, "no SQL statement to prepare"));
        }
        return SqliteResult<Statement>.ok(Statement(handle, _handle));
    }

    ## Runs a query with `parameters` bound to it in order, and decodes
    ## each row into a `T` as `Statement.read<T>()` does.
    ##
    ## @typeParam T the struct each row decodes into
    ## @param sql one SQL query
    ## @param parameters one value per parameter
    ## @returns the rows, or the first error
    ## @panics if the database is closed
    query<T>(sql: String, parameters: Value[] = Array<Value>()): SqliteResult<T[]> {
        var statement = prepare(sql)?;
        statement.bind_all(parameters)?;
        var rows = Array<T>();
        while (statement.step()?) {
            rows.append(statement.read<T>()?);
        }
        return SqliteResult<T[]>.ok(rows);
    }

    ## Returns the number of rows the last `INSERT`, `UPDATE` or `DELETE`
    ## changed.
    ##
    ## @returns the row count
    ## @panics if the database is closed
    changes(): long {
        return sqlite3_changes(_raw()) as long;
    }

    ## Returns the rowid of the last row inserted, 0 before any.
    ##
    ## @returns the rowid
    ## @panics if the database is closed
    last_insert_rowid(): long {
        return sqlite3_last_insert_rowid(_raw());
    }

    ## Sets how long a statement waits for a lock another connection holds
    ## before it fails with `SQLITE_BUSY` (5). The default is not to wait.
    ##
    ## @param milliseconds the longest wait; 0 or less turns waiting off
    ## @panics if the database is closed
    set_busy_timeout(milliseconds: int) {
        sqlite3_busy_timeout(_raw(), milliseconds);
    }

    # Transactions

    ## Reports whether a transaction is open.
    ##
    ## @returns true between `begin` and `commit` or `rollback`
    ## @panics if the database is closed
    in_transaction(): bool {
        return sqlite3_get_autocommit(_raw()) == 0;
    }

    ## Starts a transaction (`BEGIN`).
    ##
    ## @returns nothing, or the error (`SQLITE_ERROR` inside a transaction:
    ##   transactions do not nest)
    ## @panics if the database is closed
    begin(): SqliteResult<void> {
        return execute("BEGIN");
    }

    ## Commits the open transaction (`COMMIT`).
    ##
    ## @returns nothing, or the error (`SQLITE_ERROR` with no transaction
    ##   open, `SQLITE_BUSY` when another connection holds a lock, and the
    ##   transaction stays open)
    ## @panics if the database is closed
    commit(): SqliteResult<void> {
        return execute("COMMIT");
    }

    ## Rolls the open transaction back (`ROLLBACK`).
    ##
    ## @returns nothing, or the error (`SQLITE_ERROR` with no transaction
    ##   open)
    ## @panics if the database is closed
    rollback(): SqliteResult<void> {
        return execute("ROLLBACK");
    }

    ## Runs `body` inside a transaction: commits when it returns Ok, and
    ## rolls back when it returns an error or the commit fails.
    ##
    ## @typeParam T what `body` returns on success
    ## @param body the work to do; return its errors (with `?`) to roll back
    ## @returns `body`'s result, or the error of `begin` or `commit`
    ## @panics if the database is closed
    ## @example
    ##     import sqlite;
    ##
    ##     var db = sqlite.Database.open_in_memory().value();
    ##     db.execute("CREATE TABLE accounts (id INTEGER, balance INTEGER)").value();
    ##     var moved = db.transaction<void>((): sqlite.SqliteResult<void> => {
    ##         db.execute("UPDATE accounts SET balance = balance - 10 WHERE id = 1")?;
    ##         db.execute("UPDATE accounts SET balance = balance + 10 WHERE id = 2")?;
    ##         return sqlite.SqliteResult<void>.ok();
    ##     });
    transaction<T>(body: () => SqliteResult<T>): SqliteResult<T> {
        begin()?;
        var result = body();
        if (result.is_err()) {
            # The body's error is the one to report; a failed rollback only
            # means SQLite already rolled back.
            if (in_transaction()) {
                rollback();
            }
            return result;
        }
        if (commit() is Err(e)) {
            rollback();
            return SqliteResult<T>.err(e);
        }
        return result;
    }
}

## Returns the version of the SQLite library the program runs against.
##
## @returns the version, such as `3.54.1`
export version(): String {
    return String(sqlite3_libversion());
}
