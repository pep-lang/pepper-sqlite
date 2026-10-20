# A Database is not thread-safe: another thread cannot capture it.
# expect: captures 'db' of type 'Database', which is not thread-safe
import async;
import sqlite;

main(): int {
    var db = sqlite.Database.open_in_memory().value();
    async.Thread.spawn(() => {
        db.execute("SELECT 1");
    }).join();
    return 0;
}
