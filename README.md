# pepper-sqlite

[SQLite](https://sqlite.org) bindings for
[Pepper](https://github.com/pep-lang/pepper): open a database, run SQL,
prepare statements with bound parameters, read typed rows or decode them
into structs, and run transactions. Every call that can fail returns a
`SqliteResult<T>`, whose `SqliteError` holds SQLite's result code and
message.

One module, **`sqlite`**:

- **`Database.open(path, flags)`** opens (by default, creating) a database
  file; **`open_in_memory()`** a private in-memory one. **`close()`**
  closes it early; otherwise it closes when the last reference to it, and
  to its statements, goes away.
- **`execute(sql)`** runs SQL that may hold several statements;
  **`execute(sql, parameters)`** runs one statement with parameters and
  returns how many rows it inserted, changed or deleted (0 for a `SELECT`,
  DDL or any other statement that writes no rows).
- **`prepare(sql)`** makes a **`Statement`**: **`bind`** a `long`,
  `double`, `String`, `u8[]` blob or `Value` by index (from 1) or by name
  (`":id"`), **`bind_null`**, then **`step()`** until it returns false.
  Each row reads with **`column_int`**, **`column_long`**,
  **`column_double`**, **`column_text`** and **`column_blob`**, which give
  none for `NULL`, or **`column(i)`**, a `Value` of the column's storage
  class. **`reset`** runs it again, **`clear_bindings`** unbinds, and
  **`finalize`** frees it early.
- **`read<T>()`** decodes the current row into a struct, and
  **`query<T>(sql, parameters)`** decodes every row of a query: each
  column fills the property of its name, through the `serialize`
  attributes `json` uses (`[Name("...")]`, `[Required]`, `[Ignore]`), and
  `NULL` fills an `Optional` property as none.
- **`begin`**, **`commit`** and **`rollback`** run transactions by hand;
  **`transaction<T>(body)`** commits when `body` returns Ok and rolls back
  when it returns an error.
- **`Pool.open(path, size)`** opens connections that any thread may use, one
  thread at a time each (see [Threads](#threads)).

```pepper
import sqlite;

struct Book {
    var title: String;
    var year: int;
    var isbn: String?;
}

main(): int {
    var db = sqlite.Database.open("books.db").value();
    db.execute("CREATE TABLE IF NOT EXISTS books (title TEXT NOT NULL, year INTEGER, isbn TEXT)").value();

    var added = db.transaction<void>((): sqlite.SqliteResult<void> => {
        var insert = db.prepare("INSERT INTO books VALUES (:title, :year, :isbn)")?;
        insert.bind(":title", "Dune")?;
        insert.bind(":year", 1965)?;
        insert.bind_null(":isbn")?;
        insert.step()?;
        return sqlite.SqliteResult<void>.ok();
    });
    if (added is Err(e)) {
        print($"not added: {e}");   # such as: UNIQUE constraint failed: ... (code 2067)
        return 1;
    }

    for (var book in db.query<Book>("SELECT * FROM books WHERE year < ?", [sqlite.Value.Integer(2000)]).value()) {
        print($"{book.title} ({book.year})");   # Dune (1965)
    }
    return 0;
}
```

## Threads

A `Database` and its `Statement`s belong to one thread at a time, and the
compiler holds you to it:

- A thread's closure cannot capture a `Database`: it is not thread-safe.
- `Channel.send(move(db))` hands a whole connection to another thread, and is
  rejected while a `Statement` prepared on it still exists.

For several threads on one database, open a connection per thread, or share
a **`Pool`**, which is `[Shared]`:

```pepper
import async;
import sqlite;

main(): int {
    var pool = sqlite.Pool.open("app.db", 4).value();
    var workers = Array<async.Thread>();
    for (var i in 0..8) {
        workers.append(async.Thread.spawn(() => {
            with (var lease = pool.connection()) {   # waits for a free connection
                with (var db = lease.lock()) {
                    db.execute("INSERT INTO hits VALUES (1)").value();
                }
            }   # the connection goes back to the pool
        }));
    }
    for (var worker in workers) {
        worker.join();
    }
    return 0;
}
```

- `pool.connection()` lends one connection to one thread. The lease can only
  be the scope of a `with` block, so the connection always goes back.
- Each connection sits in an `async.Mutex`, so the compiler checks the inner
  block as it checks any lock: a `Statement` or row made from `db` cannot
  outlive it.
- `Pool.open` gives every connection a busy timeout (5 seconds by default),
  so a write waits for another connection's lock instead of failing with
  `SQLITE_BUSY`. It also switches the database to the write-ahead log, so
  readers do not wait for a writer.
- A read-then-write that must not interleave with other threads runs in
  `BEGIN IMMEDIATE` ... `COMMIT`.
- `OPEN_NO_MUTEX` and `OPEN_FULL_MUTEX` choose SQLite's own locking per
  connection. The pool's lease already keeps each connection to one thread.
- The bindings' calls block their thread. Inside `async.run`, they hold up
  that thread's other tasks.

## Which SQLite

The package bundles SQLite **3.54.1**: the amalgamation (`sqlite3.c` and
`sqlite3.h`, unchanged from sqlite.org) in `native/sqlite/`, whose
`VERSION` file records the download and its hashes. The `[native]` table
in `pep.toml` compiles it into every program that uses the package, on
every system and for every `--target`, so nothing needs installing.

- It is built with `SQLITE_THREADSAFE=1` (serialized, as `Pool` needs),
  `SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_OMIT_DEPRECATED` and
  `SQLITE_DEFAULT_MEMSTATUS=0`, and has FTS5, R*Tree and the SQL math
  functions.
- The first build compiles `sqlite3.c`, which takes a while (about 25
  seconds on a desktop); the object is kept in the project's `.pep/build/`,
  so later builds reuse it.
- `sqlite.version()` says which version the program runs against.

To move to a newer SQLite, replace the two files with those of the new
amalgamation, update `native/sqlite/VERSION`, and the version that
`tests/database_test.pep` expects.

## Limits

- No user-defined SQL functions, collations, hooks or the backup and blob
  I/O APIs.
- Transactions do not nest (`begin` inside a transaction fails); use
  `SAVEPOINT` through `execute` for nested work.
- Text and blobs of 2 GiB or more fail to bind (`SQLITE_TOOBIG`).
- `int` columns keep the low 32 bits of a larger integer; read them with
  `column_long`.

## Using it

This repository is a package: `pep.toml` marks its root, and its root
`module.pep` is the `sqlite` module. Add it to a project under the name
`sqlite`:

```sh
pepper package add pep-lang/pepper-sqlite --name sqlite
```

which writes

```toml
[dependencies]
sqlite = { github = "pep-lang/pepper-sqlite" }
```

It needs Pepper 0.11.0 or later (`minimum_toolchain`), which builds
`[native]` C. Use it as a dependency of a project: a folder passed with
`-I` is only searched for modules, so its SQLite would not be built.

## Tests

```sh
tests/run.sh path/to/pepper
```

runs the `[Test]` functions in `tests/` with `pepper test`: the bundled
SQLite's version and features, opening, closing and errors
(`database_test.pep`), binding and reading every type,
`NULL`, names and misuse (`statement_test.pep`), decoding rows into structs
(`read_test.pep`), transactions (`transaction_test.pep`), and pools and
connections on many threads (`thread_test.pep`). It then builds each program
in `tests/rejected/`, which breaks a threading rule, and checks that the
compiler rejects it with the error that its `# expect:` line names.

## Releasing

CI (`.github/workflows/ci.yml`) runs the tests on Linux, macOS and
Windows for every push to `main` and every pull request. To release, set
`version` in `pep.toml`, merge, then push the matching tag
(`git tag v1.0.0 && git push origin v1.0.0`): CI tests the tag and
publishes a GitHub release for it. `pepper package add` and `pepper
package update` find versions by their tags.

## License

Apache-2.0; see [LICENSE](LICENSE). The bundled SQLite, in
`native/sqlite/`, is in the public domain.
