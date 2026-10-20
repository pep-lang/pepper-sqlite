# A Database moves to another thread only while nothing else, such as a
# Statement prepared on it, still shares it.
# expect: 'db' cannot be moved: 'query' also references its value
import async;
import sqlite;

main(): int {
    var connections = async.Channel<sqlite.Database>();
    var db = sqlite.Database.open_in_memory().value();
    var query = db.prepare("SELECT 1").value();
    connections.send(move(db));
    query.step();
    return 0;
}
