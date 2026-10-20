# A Statement made from a pooled connection cannot outlive the lock on it.
# expect: is part of the value locked by 'lease' and cannot outlive the lock
import sqlite;

main(): int {
    var pool = sqlite.Pool.open("unused.db", 1).value();
    var saved = Array<sqlite.Statement>();
    with (var lease = pool.connection()) {
        with (var db = lease.lock()) {
            saved.append(db.prepare("SELECT 1").value());
        }
    }
    return 0;
}
