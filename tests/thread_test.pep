import async;
import io;
import sqlite;

# A fresh folder for one test's database files (the database, and the
# write-ahead log's -wal and -shm). Each test runs in its own process, so
# the name keeps parallel tests apart.
_folder(name: String): io.Path {
    var folder = io.Directory.temp().join_str($"pepper-sqlite-{name}");
    io.Directory.remove_all(folder);
    io.Directory.create_all(folder).value();
    return folder;
}

# The first column of the first row of `sql`, read through the pool.
_long(pool: sqlite.Pool, sql: String): long {
    long result = 0;
    with (var lease = pool.connection()) {
        with (var db = lease.lock()) {
            var query = db.prepare(sql).value();
            query.step().value();
            result = query.column_long(0).value();
        }
    }
    return result;
}

_text(pool: sqlite.Pool, sql: String): String {
    var result = "";
    with (var lease = pool.connection()) {
        with (var db = lease.lock()) {
            var query = db.prepare(sql).value();
            query.step().value();
            result = copy(query.column_text(0).value());
        }
    }
    return result;
}

_execute(pool: sqlite.Pool, sql: String): sqlite.SqliteResult<void> {
    with (var lease = pool.connection()) {
        with (var db = lease.lock()) {
            return db.execute(sql);
        }
    }
    return sqlite.SqliteResult<void>.ok();
}

[Test]
a_pool_serves_writers_on_many_threads() {
    var folder = _folder("pool-writers");
    var pool = sqlite.Pool.open(folder.join_str("data.db").to_string(), 3).value();
    expect_equal(pool.size, 3 as ulong);
    _execute(pool, "CREATE TABLE t (thread INTEGER, n INTEGER)").value();

    # More threads than connections, so some wait for one.
    var threads = Array<async.Thread>();
    for (var t in 0..8) {
        var thread_index = t as long;
        threads.append(
            async.Thread.spawn(
                () => {
                    for (var n in 0..50) {
                        with (var lease = pool.connection()) {
                            with (var db = lease.lock()) {
                                db.execute(
                                    "INSERT INTO t VALUES (?, ?)",
                                    [sqlite.Value.Integer(thread_index), sqlite.Value.Integer(n as long)]
                                ).value();
                            }
                        }
                    }
                }
            )
        );
    }
    for (var thread in threads) {
        thread.join();
    }
    expect_equal(_long(pool, "SELECT count(*) FROM t"), 400 as long);
    expect_equal(_long(pool, "SELECT count(DISTINCT thread) FROM t"), 8 as long);
    io.Directory.remove_all(folder);
}

[Test]
a_pool_runs_transactions_on_many_threads() {
    var folder = _folder("pool-transactions");
    var pool = sqlite.Pool.open(folder.join_str("data.db").to_string(), 4).value();
    _execute(
        pool, "CREATE TABLE t (n INTEGER); CREATE TABLE total (sum INTEGER); INSERT INTO total VALUES (0);"
    ).value();

    var threads = Array<async.Thread>();
    for (var t in 0..4) {
        threads.append(
            async.Thread.spawn(
                () => {
                    for (var n in 0..25) {
                        # A read-then-write in one transaction: with IMMEDIATE, two
                        # threads never both read the old sum.
                        with (var lease = pool.connection()) {
                            with (var db = lease.lock()) {
                                db.execute("BEGIN IMMEDIATE").value();
                                db.execute("UPDATE total SET sum = sum + 1").value();
                                db.execute("INSERT INTO t VALUES (1)").value();
                                db.commit().value();
                            }
                        }
                    }
                }
            )
        );
    }
    for (var thread in threads) {
        thread.join();
    }
    expect_equal(_long(pool, "SELECT count(*) FROM t"), 100 as long);
    expect_equal(_long(pool, "SELECT sum FROM total"), 100 as long);
    io.Directory.remove_all(folder);
}

[Test]
an_error_gives_the_connection_back() {
    var folder = _folder("pool-error");
    var pool = sqlite.Pool.open(folder.join_str("data.db").to_string(), 1).value();
    # `_execute` returns from inside both blocks.
    expect_equal(_execute(pool, "SELECT * FROM nowhere").error().message, "no such table: nowhere");
    # With one connection, this would wait forever had the return kept it.
    _execute(pool, "CREATE TABLE t (n INTEGER)").value();
    expect_equal(_long(pool, "SELECT count(*) FROM t"), 0 as long);
    io.Directory.remove_all(folder);
}

[Test]
open_switches_to_the_write_ahead_log() {
    var folder = _folder("pool-wal");
    var path = folder.join_str("data.db").to_string();
    var pool = sqlite.Pool.open(path, 2).value();
    expect_equal(_text(pool, "PRAGMA journal_mode"), "wal");

    var plain = sqlite.Pool.open(folder.join_str("plain.db").to_string(), 1, write_ahead_log = false).value();
    expect_equal(_text(plain, "PRAGMA journal_mode"), "delete");
    io.Directory.remove_all(folder);
}

[Test]
a_read_only_pool_reads_on_many_threads() {
    var folder = _folder("pool-read-only");
    var path = folder.join_str("data.db").to_string();
    var setup = sqlite.Database.open(path).value();
    setup.execute("CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (1), (2), (3);").value();
    setup.close();

    var pool = sqlite.Pool.open(path, 2, sqlite.OPEN_READ_ONLY).value();
    var total = async.Atomic<long>(0);
    var threads = Array<async.Thread>();
    for (var t in 0..4) {
        threads.append(async.Thread.spawn(() => {
            total.fetch_add(_long(pool, "SELECT sum(n) FROM t"));
        }));
    }
    for (var thread in threads) {
        thread.join();
    }
    expect_equal(total.load(), 24 as long);
    expect_equal(_execute(pool, "DELETE FROM t").error().primary_code(), 8);  # SQLITE_READONLY
    io.Directory.remove_all(folder);
}

[Test]
opening_a_pool_reports_the_error() {
    var opened = sqlite.Pool.open("no/such/folder/x.db", 2, sqlite.OPEN_READ_ONLY);
    expect_equal(opened.error().primary_code(), 14);  # SQLITE_CANTOPEN
}

[Test]
[ShouldPanic("at least one connection")]
a_pool_of_no_connections_panics() {
    sqlite.Pool.open("unused.db", 0);
}

[Test]
one_connection_per_thread() {
    var folder = _folder("per-thread");
    var path = folder.join_str("data.db").to_string();
    var setup = sqlite.Database.open(path).value();
    setup.execute("PRAGMA journal_mode=WAL; CREATE TABLE t (n INTEGER);").value();
    setup.close();

    # A thread body captures only thread-safe values, so each thread gets
    # the path through a channel and opens its own connection.
    var paths = async.Channel<String>();
    var threads = Array<async.Thread>();
    for (var t in 0..4) {
        paths.send(copy(path));
        threads.append(
            async.Thread.spawn(
                () => {
                    var db = sqlite.Database.open(
                        paths.receive().value(), sqlite.OPEN_READ_WRITE | sqlite.OPEN_NO_MUTEX
                    ).value();
                    db.set_busy_timeout(5000);
                    for (var n in 0..25) {
                        db.execute("INSERT INTO t VALUES (?)", [sqlite.Value.Integer(n as long)]).value();
                    }
                }
            )
        );
    }
    for (var thread in threads) {
        thread.join();
    }

    var check = sqlite.Database.open(path, sqlite.OPEN_READ_ONLY | sqlite.OPEN_FULL_MUTEX).value();
    var query = check.prepare("SELECT count(*) FROM t").value();
    query.step().value();
    expect_equal(query.column_long(0).value(), 100 as long);
    query.finalize();
    check.close();
    io.Directory.remove_all(folder);
}

[Test]
a_database_moves_to_another_thread() {
    var connections = async.Channel<sqlite.Database>();
    var db = sqlite.Database.open_in_memory().value();
    db.execute("CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (7);").value();
    # Nothing else shares `db`, so it can be handed over whole.
    connections.send(move(db));
    var seen = async.Atomic<long>(0);
    async.Thread.spawn(() => {
        var moved = connections.receive().value();
        var query = moved.prepare("SELECT n FROM t").value();
        query.step().value();
        seen.store(query.column_long(0).value());
    }).join();
    expect_equal(seen.load(), 7 as long);
}
