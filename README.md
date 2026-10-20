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
  returns how many rows it changed.
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

## Which SQLite

The package links the system's SQLite rather than building its own copy:

- **Linux:** `libsqlite3.so`, from the distribution's development package
  (`apt install libsqlite3-dev`, `dnf install sqlite-devel`).
- **macOS:** `libsqlite3.dylib`, which the macOS SDK provides.
- **Windows:** `winsqlite3.dll`, which Windows 10 and later ship, through
  `winsqlite3.lib` from the Windows SDK that Pepper already links with.

`sqlite.version()` says which version the program runs against.

## Limits

- No user-defined SQL functions, collations, hooks or the backup and blob
  I/O APIs.
- Transactions do not nest (`begin` inside a transaction fails); use
  `SAVEPOINT` through `execute` for nested work.
- A connection and its statements belong to one thread at a time.
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

Without a project, put a folder named `sqlite` that holds (or links to)
this repository on the import path: `pepper build -I packages main.pep`.

## Tests

```sh
tests/run.sh path/to/pepper
```

runs the `[Test]` functions in `tests/` with `pepper test`: opening,
closing and errors (`database_test.pep`), binding and reading every type,
`NULL`, names and misuse (`statement_test.pep`), decoding rows into structs
(`read_test.pep`), and transactions (`transaction_test.pep`).

## Releasing

CI (`.github/workflows/ci.yml`) runs the tests on Linux, macOS and
Windows for every push to `main` and every pull request. To release, set
`version` in `pep.toml`, merge, then push the matching tag
(`git tag v1.0.0 && git push origin v1.0.0`): CI tests the tag and
publishes a GitHub release for it. `pepper package add` and `pepper
package update` find versions by their tags.

## License

Apache-2.0; see [LICENSE](LICENSE). SQLite itself is in the public domain
and is not part of this repository.
