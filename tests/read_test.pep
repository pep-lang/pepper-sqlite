import sqlite;

struct Person {
    var id: long;
    var name: String;
    [Name("years")]
    var age: int;
    var email: String?;
    var score: double;
    var avatar: u8[];
}

struct Strict {
    [Required]
    var id: long;
    [Required]
    var missing: String;
}

_people(): sqlite.Database {
    var db = sqlite.Database.open_in_memory().value();
    db.execute(
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, years INTEGER, email TEXT, score REAL, avatar BLOB, extra TEXT);"
            + "INSERT INTO people VALUES (1, 'Ada', 36, 'ada@example.com', 9.5, x'0102', 'x');"
            + "INSERT INTO people VALUES (2, 'Alan', 41, NULL, 7, NULL, NULL);"
    ).value();
    return db;
}

[Test]
query_decodes_rows_into_structs() {
    var db = _people();
    var people = db.query<Person>("SELECT * FROM people ORDER BY id").value();
    expect_equal(people.count, 2 as ulong);
    expect_equal(people[0].id, 1 as long);
    expect_equal(people[0].name, "Ada");
    expect_equal(people[0].age, 36);
    expect_equal(people[0].email.value(), "ada@example.com");
    expect_equal(people[0].score, 9.5);
    expect_equal(people[0].avatar.count, 2 as ulong);
    expect_equal(people[0].avatar[1], 2 as u8);
    expect_true(people[1].email.is_empty());
    expect_equal(people[1].score, 7.0);  # an INTEGER fills a double
}

[Test]
query_binds_parameters() {
    var db = _people();
    var people = db.query<Person>("SELECT * FROM people WHERE years > ?", [sqlite.Value.Integer(40)]).value();
    expect_equal(people.count, 1 as ulong);
    expect_equal(people[0].name, "Alan");
}

[Test]
query_with_no_rows_is_empty() {
    var db = _people();
    expect_equal(db.query<Person>("SELECT * FROM people WHERE id = 99").value().count, 0 as ulong);
}

[Test]
read_decodes_the_current_row() {
    var db = _people();
    var query = db.prepare("SELECT id, name FROM people WHERE id = ?").value();
    query.bind(1, 2).value();
    expect_true(query.step().value());
    var person = query.read<Person>().value();
    expect_equal(person.name, "Alan");
    expect_equal(person.age, 0);  # no column: the default
}

[Test]
a_type_mismatch_is_an_error() {
    var db = _people();
    var result = db.query<Person>("SELECT 'old' AS years");
    expect_equal(result.error().code, 20);  # SQLITE_MISMATCH
    expect_true(result.error().message.starts_with("$.years:"));
}

[Test]
a_missing_required_column_is_an_error() {
    var db = _people();
    var result = db.query<Strict>("SELECT id FROM people");
    expect_equal(result.error().code, 20);
    expect_true(result.error().message.contains("missing"));
}

[Test]
query_reports_sql_errors() {
    var db = _people();
    expect_equal(db.query<Person>("SELECT * FROM nobody").error().message, "no such table: nobody");
}
