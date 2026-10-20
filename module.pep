## SQLite bindings: open a database, run SQL, prepare statements with bound
## parameters, read typed rows or decode them into structs, and run
## transactions.
##
## Bring it in with `import sqlite`. It links the system's SQLite:
## `libsqlite3` on Linux (`apt install libsqlite3-dev`) and macOS, and
## `winsqlite3`, part of Windows 10 and later, on Windows. Every call that
## can fail returns a `SqliteResult<T>`, whose error holds SQLite's result
## code and message.
##
## - `Database`: a connection: `open`, `execute`, `prepare`, `query<T>`,
##   `begin`/`commit`/`rollback` and `transaction`
## - `Statement`: a prepared statement: `bind`, `step`, the `column_`
##   readers, `read<T>`, `reset`, `finalize`
## - `Value`: one value of any of SQLite's storage classes
## - `SqliteError`, `SqliteResult<T>`: errors
## - `OPEN_READ_ONLY` and the other `OPEN_` flags, `version`
##
## @example
##     import sqlite;
##
##     struct Book {
##         var title: String;
##         var year: int;
##     }
##
##     main(): int {
##         var db = sqlite.Database.open_in_memory().value();
##         db.execute("CREATE TABLE books (title TEXT NOT NULL, year INTEGER)").value();
##         var insert = db.prepare("INSERT INTO books VALUES (:title, :year)").value();
##         insert.bind(":title", "Dune").value();
##         insert.bind(":year", 1965).value();
##         insert.step().value();
##         for (var book in db.query<Book>("SELECT title, year FROM books").value()) {
##             print($"{book.title} ({book.year})");   # Dune (1965)
##         }
##         return 0;
##     }

# This file only gathers the module's public API from its other files.

import "database";
import "error";
import "statement";
import "value";

export Database;
export Statement;
export Value;
export SqliteError;
export SqliteResult;
export OPEN_READ_ONLY;
export OPEN_READ_WRITE;
export OPEN_CREATE;
export OPEN_URI;
export OPEN_MEMORY;
export version;
