# A lease on a pooled connection lives only as a with block's scope.
# expect: 'PooledConnection' can only be the scope of a 'with' block
import sqlite;

main(): int {
    var pool = sqlite.Pool.open("unused.db", 1).value();
    var lease = pool.connection();
    return 0;
}
