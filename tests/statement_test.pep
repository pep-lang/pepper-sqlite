import sqlite;

_table(): sqlite.Database {
    var db = sqlite.Database.open_in_memory().value();
    db.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB)").value();
    return db;
}

_bytes(values: int[]): u8[] {
    var bytes = Array<u8>();
    for (var value in values) {
        bytes.append(value as u8);
    }
    return bytes;
}

[Test]
binds_and_reads_every_type() {
    var db = _table();
    var insert = db.prepare("INSERT INTO t VALUES (?, ?, ?, ?)").value();
    expect_equal(insert.parameter_count(), 4);
    insert.bind(1, 9007199254740993).value();
    insert.bind(2, 2.5).value();
    insert.bind(3, "héllo").value();
    insert.bind(4, _bytes([0, 1, 255])).value();
    expect_false(insert.step().value());

    var query = db.prepare("SELECT i, r, s, b FROM t").value();
    expect_equal(query.column_count(), 4);
    expect_equal(query.column_name(2), "s");
    expect_true(query.step().value());
    expect_equal(query.column_long(0).value(), 9007199254740993 as long);
    expect_equal(query.column_double(1).value(), 2.5);
    expect_equal(query.column_text(2).value(), "héllo");
    expect_true(query.column_blob(3).value() == _bytes([0, 1, 255]));
    expect_false(query.step().value());
}

[Test]
null_reads_as_none() {
    var db = _table();
    var insert = db.prepare("INSERT INTO t VALUES (?, ?, ?, ?)").value();
    for (var index in 1..5) {
        insert.bind_null(index).value();
    }
    insert.step().value();

    var query = db.prepare("SELECT i, r, s, b FROM t").value();
    expect_true(query.step().value());
    expect_true(query.column_is_null(0));
    expect_true(query.column_int(0).is_empty());
    expect_true(query.column_long(0).is_empty());
    expect_true(query.column_double(1).is_empty());
    expect_true(query.column_text(2).is_empty());
    expect_true(query.column_blob(3).is_empty());
    expect_true(query.column(3) is Null);
}

[Test]
empty_text_and_blobs_are_not_null() {
    var db = _table();
    var insert = db.prepare("INSERT INTO t (s, b) VALUES (?, ?)").value();
    insert.bind(1, "").value();
    insert.bind(2, Array<u8>()).value();
    insert.step().value();

    var query = db.prepare("SELECT s, b, typeof(s), typeof(b) FROM t").value();
    expect_true(query.step().value());
    expect_equal(query.column_text(0).value(), "");
    expect_equal(query.column_blob(1).value().count, 0 as ulong);
    expect_equal(query.column_text(2).value(), "text");
    expect_equal(query.column_text(3).value(), "blob");
}

[Test]
text_with_nul_bytes_round_trips() {
    var db = _table();
    var insert = db.prepare("INSERT INTO t (s) VALUES (?)").value();
    var text = "a\0b";
    insert.bind(1, text).value();
    insert.step().value();
    var query = db.prepare("SELECT s, length(CAST(s AS BLOB)) FROM t").value();
    query.step().value();
    # Against `text`: a literal compares only up to its NUL.
    expect_equal(query.column_text(0).value(), text);
    expect_equal(query.column_long(1).value(), 3 as long);
}

[Test]
column_reads_the_storage_class() {
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT 1, 1.5, 'x', x'00ff', NULL").value();
    query.step().value();
    expect_true(query.column(0) is Integer(1));
    expect_equal(query.column_double(1).value(), 1.5);
    expect_true(query.column(1) is Real(_));
    expect_true(query.column(2) is Text("x"));
    var blob = query.column(3);
    if (blob is Blob(bytes)) {
        expect_true(bytes == _bytes([0, 255]));
    } else {
        panic("expected a blob");
    }
    expect_true(query.column(4) is Null);
}

[Test]
columns_convert_as_sqlite_does() {
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT '42', 3.9, 7, 4294967297").value();
    query.step().value();
    expect_equal(query.column_long(0).value(), 42 as long);
    expect_equal(query.column_long(1).value(), 3 as long);
    expect_equal(query.column_text(2).value(), "7");
    expect_equal(query.column_double(2).value(), 7.0);
    expect_equal(query.column_int(3).value(), 1);  # the low 32 bits
}

[Test]
binds_by_name() {
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT :a, @b, $c, :d, :e, :f").value();
    expect_equal(query.parameter_index("@b").value(), 2);
    expect_true(query.parameter_index("b").is_empty());
    query.bind(":a", 1).value();
    query.bind("@b", 0.5).value();
    query.bind("$c", "c").value();
    query.bind(":d", _bytes([7])).value();
    query.bind(":e", sqlite.Value.Integer(5)).value();
    query.bind_null(":f").value();
    query.step().value();
    expect_equal(query.column_long(0).value(), 1 as long);
    expect_equal(query.column_double(1).value(), 0.5);
    expect_equal(query.column_text(2).value(), "c");
    expect_true(query.column_blob(3).value() == _bytes([7]));
    expect_equal(query.column_long(4).value(), 5 as long);
    expect_true(query.column_is_null(5));
}

[Test]
an_unknown_name_or_index_is_a_range_error() {
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT ?").value();
    var by_name = query.bind(":nope", 1);
    expect_equal(by_name.error().code, 25);
    expect_equal(by_name.error().message, "no parameter named ':nope'");
    expect_equal(query.bind(2, 1).error().code, 25);
    expect_equal(query.bind(0, "x").error().code, 25);
}

[Test]
reset_reruns_with_the_same_bindings() {
    var db = _table();
    var insert = db.prepare("INSERT INTO t (i) VALUES (?)").value();
    insert.bind(1, 1).value();
    insert.step().value();
    insert.reset();
    insert.step().value();
    insert.reset();
    insert.clear_bindings();
    insert.step().value();

    var query = db.prepare("SELECT count(i), count(*) FROM t").value();
    query.step().value();
    expect_equal(query.column_long(0).value(), 2 as long);
    expect_equal(query.column_long(1).value(), 3 as long);
}

[Test]
a_failed_step_returns_the_error() {
    var db = sqlite.Database.open_in_memory().value();
    db.execute("CREATE TABLE u (n INTEGER NOT NULL)").value();
    var insert = db.prepare("INSERT INTO u VALUES (?)").value();
    var failed = insert.step();
    expect_equal(failed.error().code, 1299);  # SQLITE_CONSTRAINT_NOTNULL
    expect_equal(failed.error().message, "NOT NULL constraint failed: u.n");
    # The statement is reset and runs again.
    insert.bind(1, 1).value();
    expect_false(insert.step().value());
}

[Test]
prepare_reports_syntax_errors_and_empty_sql() {
    var db = sqlite.Database.open_in_memory().value();
    var bad = db.prepare("SELEC 1");
    expect_equal(bad.error().code, 1);
    expect_equal(bad.error().message, "near \"SELEC\": syntax error");
    expect_equal(db.prepare("").error().code, 21);
    expect_equal(db.prepare("  -- nothing").error().code, 21);
}

[Test]
finalize_frees_the_statement_and_keeps_the_database() {
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT 1").value();
    expect_true(query.is_open());
    query.finalize();
    expect_false(query.is_open());
    query.finalize();  # a second finalize does nothing
    expect_true(db.execute("SELECT 1").is_ok());
}

[Test]
a_statement_outlives_a_closed_database() {
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT 5").value();
    db.close();
    expect_true(query.step().value());
    expect_equal(query.column_long(0).value(), 5 as long);
}

[Test]
[ShouldPanic("the statement is finalized")]
stepping_a_finalized_statement_panics() {
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT 1").value();
    query.finalize();
    query.step();
}

[Test]
[ShouldPanic("no row to read")]
reading_before_a_row_panics() {
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT 1").value();
    query.column_long(0);
}

[Test]
[ShouldPanic("no row to read")]
reading_after_the_last_row_panics() {
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT 1").value();
    query.step().value();
    query.step().value();
    query.column_long(0);
}

[Test]
[ShouldPanic("column 1 out of range")]
reading_past_the_last_column_panics() {
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT 1").value();
    query.step().value();
    query.column_long(1);
}
