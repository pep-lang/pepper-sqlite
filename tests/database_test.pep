import io;
import sqlite;

_memory(): sqlite.Database {
    return sqlite.Database.open_in_memory().value();
}

[Test]
reports_the_library_version() {
    expect_true(sqlite.version().starts_with("3."));
}

[Test]
opens_and_closes_an_in_memory_database() {
    var db = _memory();
    expect_true(db.is_open());
    db.close();
    expect_false(db.is_open());
    db.close();  # a second close does nothing
}

[Test]
[ShouldPanic("the database is closed")]
using_a_closed_database_panics() {
    var db = _memory();
    db.close();
    db.execute("SELECT 1");
}

[Test]
opens_a_file_and_reopens_it() {
    # Each test runs in its own process; the name keeps parallel runs apart.
    var dir = io.Directory.temp().join_str("pepper-sqlite-reopen-test");
    io.Directory.remove_all(dir);
    io.Directory.create_all(dir).value();
    var path = dir.join_str("data.db").to_string();
    var db = sqlite.Database.open(path).value();
    db.execute("CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (42);").value();
    db.close();

    var again = sqlite.Database.open(path, sqlite.OPEN_READ_ONLY).value();
    var rows = again.prepare("SELECT n FROM t").value();
    expect_true(rows.step().value());
    expect_equal(rows.column_long(0).value(), 42 as long);
    var write = again.execute("INSERT INTO t VALUES (1)");
    expect_equal(write.error().primary_code(), 8);  # SQLITE_READONLY
    rows.finalize();
    again.close();
    io.Directory.remove_all(dir).value();
}

[Test]
opening_a_missing_file_read_only_fails() {
    var opened = sqlite.Database.open("no/such/folder/x.db", sqlite.OPEN_READ_ONLY);
    expect_true(opened.is_err());
    expect_equal(opened.error().primary_code(), 14);  # SQLITE_CANTOPEN
}

[Test]
execute_reports_the_failing_statement() {
    var db = _memory();
    var result = db.execute("CREATE TABLE t (n INTEGER); INSERT INTO nope VALUES (1);");
    expect_equal(result.error().code, 1);
    expect_equal(result.error().message, "no such table: nope");
    # The statement before the failing one ran.
    expect_true(db.execute("INSERT INTO t VALUES (1)").is_ok());
}

[Test]
execute_with_parameters_counts_changes() {
    var db = _memory();
    db.execute("CREATE TABLE t (n INTEGER, s TEXT)").value();
    expect_equal(
        db.execute("INSERT INTO t VALUES (?, ?)", [sqlite.Value.Integer(1), sqlite.Value.Text("a")]).value(), 1 as long
    );
    expect_equal(db.last_insert_rowid(), 1 as long);
    db.execute("INSERT INTO t VALUES (2, 'b'), (3, 'c')").value();
    expect_equal(
        db.execute("UPDATE t SET s = ? WHERE n > ?", [sqlite.Value.Text("z"), sqlite.Value.Integer(1)]).value(),
        2 as long
    );
    expect_equal(db.changes(), 2 as long);
}

[Test]
too_many_parameters_is_a_range_error() {
    var db = _memory();
    var result = db.execute("SELECT ?", [sqlite.Value.Integer(1), sqlite.Value.Integer(2)]);
    expect_equal(result.error().primary_code(), 25);  # SQLITE_RANGE
}

[Test]
a_constraint_failure_has_the_extended_code() {
    var db = _memory();
    db.execute("CREATE TABLE users (name TEXT UNIQUE)").value();
    db.execute("INSERT INTO users VALUES ('ada')").value();
    var again = db.execute("INSERT INTO users VALUES (?)", [sqlite.Value.Text("ada")]);
    expect_equal(again.error().code, 2067);  # SQLITE_CONSTRAINT_UNIQUE
    expect_equal(again.error().primary_code(), 19);
    expect_equal(again.error().message, "UNIQUE constraint failed: users.name");
    expect_equal(again.error().to_string(), "UNIQUE constraint failed: users.name (code 2067)");
}
