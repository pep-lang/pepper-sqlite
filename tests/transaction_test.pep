import sqlite;

_accounts(): sqlite.Database {
    var db = sqlite.Database.open_in_memory().value();
    db.execute(
        "CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER CHECK (balance >= 0));"
            + "INSERT INTO accounts VALUES (1, 100), (2, 0);"
    ).value();
    return db;
}

_balance(db: sqlite.Database, id: long): long {
    var query = db.prepare("SELECT balance FROM accounts WHERE id = ?").value();
    query.bind(1, id).value();
    query.step().value();
    return query.column_long(0).value();
}

_move(db: sqlite.Database, amount: long): sqlite.SqliteResult<void> {
    db.execute("UPDATE accounts SET balance = balance + ? WHERE id = 2", [sqlite.Value.Integer(amount)])?;
    db.execute("UPDATE accounts SET balance = balance - ? WHERE id = 1", [sqlite.Value.Integer(amount)])?;
    return sqlite.SqliteResult<void>.ok();
}

[Test]
begin_and_commit() {
    var db = _accounts();
    expect_false(db.in_transaction());
    db.begin().value();
    expect_true(db.in_transaction());
    _move(db, 30).value();
    db.commit().value();
    expect_false(db.in_transaction());
    expect_equal(_balance(db, 1), 70 as long);
}

[Test]
begin_and_rollback() {
    var db = _accounts();
    db.begin().value();
    _move(db, 30).value();
    db.rollback().value();
    expect_false(db.in_transaction());
    expect_equal(_balance(db, 1), 100 as long);
    expect_equal(_balance(db, 2), 0 as long);
}

[Test]
transactions_do_not_nest() {
    var db = _accounts();
    db.begin().value();
    expect_equal(db.begin().error().message, "cannot start a transaction within a transaction");
    db.rollback().value();
    expect_equal(db.commit().error().message, "cannot commit - no transaction is active");
    expect_equal(db.rollback().error().message, "cannot rollback - no transaction is active");
}

[Test]
transaction_commits_on_ok() {
    var db = _accounts();
    var moved = db.transaction<long>((): sqlite.SqliteResult<long> => {
        _move(db, 40)?;
        return sqlite.SqliteResult<long>.ok(db.changes());
    });
    expect_equal(moved.value(), 1 as long);
    expect_false(db.in_transaction());
    expect_equal(_balance(db, 1), 60 as long);
    expect_equal(_balance(db, 2), 40 as long);
}

[Test]
transaction_rolls_back_on_error() {
    var db = _accounts();
    # The second update breaks the CHECK after the first has run.
    var moved = db.transaction<void>((): sqlite.SqliteResult<void> => _move(db, 150));
    expect_equal(moved.error().code, 275);  # SQLITE_CONSTRAINT_CHECK
    expect_false(db.in_transaction());
    expect_equal(_balance(db, 2), 0 as long);
}

[Test]
transaction_rolls_back_on_an_error_of_its_own() {
    var db = _accounts();
    var moved = db.transaction<void>((): sqlite.SqliteResult<void> => {
        _move(db, 10)?;
        return sqlite.SqliteResult<void>.err(sqlite.SqliteError(1, "changed my mind"));
    });
    expect_equal(moved.error().message, "changed my mind");
    expect_equal(_balance(db, 1), 100 as long);
}

[Test]
transaction_inside_a_transaction_fails_without_running() {
    var db = _accounts();
    db.begin().value();
    var ran = Array<bool>();
    var inner = db.transaction<void>((): sqlite.SqliteResult<void> => {
        ran.append(true);
        return sqlite.SqliteResult<void>.ok();
    });
    expect_true(inner.is_err());
    expect_equal(ran.count, 0 as ulong);
    expect_true(db.in_transaction());  # the outer one is untouched
    db.rollback().value();
}
