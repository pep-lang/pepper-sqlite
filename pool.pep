## `Pool`: connections to one database that any thread may use.

import async;
import "database";
import "error";
import "sqlite3";

## A fixed set of connections to one database, shared between threads.
##
## A `Database` belongs to one thread, so threads that use one database
## either open a connection each or share a `Pool`. The pool is `[Shared]`:
## a closure passed to `async.Thread.spawn` may capture it.
## `connection()` lends one connection to one thread at a time, and waits
## while every connection is in use. Each connection sits in an
## `async.Mutex`, so the compiler checks the block that locks it as it
## checks any `with` over a lock: nothing made from the `Database`, such as
## a `Statement`, can outlive the block.
##
## Every connection waits up to `busy_timeout` milliseconds for a lock
## another connection holds. For a file database, the write-ahead log
## (`PRAGMA journal_mode=WAL`, which `open` sets unless asked not to) lets
## readers run alongside one writer. An in-memory database (`":memory:"`)
## is private to each connection, so a pool of them is a set of separate
## databases; use a file.
##
## @example
##     import async;
##     import sqlite;
##
##     main(): int {
##         var pool = sqlite.Pool.open("app.db", 4).value();
##         with (var lease = pool.connection()) {
##             with (var db = lease.lock()) {
##                 db.execute("CREATE TABLE IF NOT EXISTS hits (n INTEGER)").value();
##             }
##         }
##         var workers = Array<async.Thread>();
##         for (var i in 0..4) {
##             workers.append(async.Thread.spawn(() => {
##                 with (var lease = pool.connection()) {
##                     with (var db = lease.lock()) {
##                         db.execute("INSERT INTO hits VALUES (1)").value();
##                     }
##                 }
##             }));
##         }
##         for (var worker in workers) {
##             worker.join();
##         }
##         return 0;
##     }
[Shared]
export struct Pool {
    const _idle: async.Channel<async.Mutex<Database>>;
    ## The number of connections.
    const size: ulong;

    ## Wraps connections `open` made; use `open` instead.
    ##
    ## @param idle a channel holding every connection, each in its own lock
    ## @param size the number of connections in `idle`
    construct(idle: async.Channel<async.Mutex<Database>>, size: ulong) {
        _idle = idle;
        this.size = size;
    }

    ## Opens `size` connections to the database at `path`.
    ##
    ## @param path the database file
    ## @param size the number of connections, at least 1
    ## @param flags the flags each connection opens with, as for
    ##   `Database.open`
    ## @param busy_timeout how long, in milliseconds, a statement waits for
    ##   a lock another connection holds before it fails with `SQLITE_BUSY`
    ## @param write_ahead_log whether to switch the database to the
    ##   write-ahead log, so readers do not wait for a writer; a read-only
    ##   pool leaves the file as it is
    ## @returns the pool, or the first error; `SQLITE_MISUSE` (21) when the
    ##   SQLite library was built without thread support
    ## @panics if `size` is 0
    static open(
        path: String,
        size: ulong,
        flags: int = OPEN_READ_WRITE | OPEN_CREATE,
        busy_timeout: int = 5000,
        write_ahead_log: bool = true
    ): SqliteResult<Pool> {
        assert(size > 0, "sqlite: a pool needs at least one connection");
        if (sqlite3_threadsafe() == 0) {
            return SqliteResult<Pool>.err(
                SqliteError(SQLITE_MISUSE, "this SQLite library was built without thread support")
            );
        }
        var idle = async.Channel<async.Mutex<Database>>();
        for (var i in 0..size) {
            var db = Database.open(path, flags)?;
            db.set_busy_timeout(busy_timeout);
            # The journal mode is the file's, so one connection sets it; a
            # read-only connection cannot.
            if (i == 0 && write_ahead_log && (flags & OPEN_READ_WRITE) != 0) {
                db.execute("PRAGMA journal_mode=WAL")?;
            }
            idle.send(async.Mutex<Database>(move(db)));
        }
        return SqliteResult<Pool>.ok(Pool(idle, size));
    }

    ## Takes a connection no other thread is using, waiting while all are
    ## in use, for a `with` header. The block's binding is the connection's
    ## lock; lock it with an inner `with` to reach the `Database`. The
    ## connection goes back to the pool when the outer block ends, by any
    ## path.
    ##
    ## @returns the lease on one connection
    ## @panics if the pool's connections are gone, which cannot happen while
    ##   the pool is alive
    ## @example
    ##     with (var lease = pool.connection()) {
    ##         with (var db = lease.lock()) {
    ##             db.execute("DELETE FROM sessions WHERE expired").value();
    ##         }
    ##     }   # the connection is back in the pool
    connection(): PooledConnection {
        return PooledConnection(_idle, _idle.receive().value());
    }
}

## One connection of a `Pool`, lent to the thread that took it with
## `Pool.connection()`, which a `with` block holds.
##
## `enter()` hands the block the connection's `async.Mutex<Database>`;
## destroying the lease gives the connection back to the pool. It is
## `[Isolated]`: it can only be the scope of a `with` header, so it cannot
## be kept past the block.
[Isolated]
export struct PooledConnection {
    const _idle: async.Channel<async.Mutex<Database>>;
    const _connection: async.Mutex<Database>;
    # True until the connection goes back to the pool.
    var _held: bool;

    ## Takes over a connection `Pool.connection()` received; use that
    ## instead.
    ##
    ## @param idle the pool's channel, which gets the connection back
    ## @param connection the connection lent
    construct(idle: async.Channel<async.Mutex<Database>>, connection: async.Mutex<Database>) {
        _idle = idle;
        _connection = connection;
        _held = true;
    }

    destruct {
        this.exit();
    }

    ## Returns the connection, for the `with` header to bind; lock it to
    ## reach the `Database`.
    ##
    ## @returns the connection's lock
    enter(): async.Mutex<Database> {
        return _connection;
    }

    ## Gives the connection back to the pool. The destructor calls it;
    ## calling it again does nothing.
    exit() {
        if (_held) {
            _held = false;
            _idle.send(_connection);
        }
    }
}
