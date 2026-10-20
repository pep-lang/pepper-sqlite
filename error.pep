## `SqliteError`, what a failed call returns, and `SqliteResult<T>`.

import "sqlite3";

## An error SQLite reported: its result code and its message.
##
## `code` is SQLite's extended result code, such as 2067
## (`SQLITE_CONSTRAINT_UNIQUE`); `primary_code()` is its low byte, the
## primary code, such as 19 (`SQLITE_CONSTRAINT`). See
## <https://sqlite.org/rescode.html> for the codes.
export struct SqliteError {
    ## SQLite's extended result code.
    var code: int;
    ## What went wrong, as SQLite words it (`UNIQUE constraint failed:
    ## users.name`).
    var message: String;

    ## Creates an error from a result code and a message.
    ##
    ## @param code SQLite's extended result code
    ## @param message what went wrong
    construct(code: int, message: String) {
        this.code = code;
        this.message = message;
    }

    ## Returns the primary result code: the low byte of `code`.
    ##
    ## @returns the primary code, such as 19 for any constraint failure
    primary_code(): int {
        return code & 0xff;
    }

    ## Returns the message and the code, as `message (code N)`.
    ##
    ## @returns the error as text
    to_string(): String {
        return $"{message} (code {code})";
    }
}

## The result of a call that can fail: its value, or a `SqliteError`.
##
## @typeParam T the value on success
export type SqliteResult<T> = Result<T, SqliteError>;

# The error SQLite reported for `code` on `db`: the connection's message
# when it is about this code, else SQLite's generic text for the code
# (a bind error such as SQLITE_RANGE may not set the connection's message).
_error(db: __ptr<void>, code: int): SqliteError {
    if (db != __null && (sqlite3_extended_errcode(db) & 0xff) == (code & 0xff)) {
        return SqliteError(sqlite3_extended_errcode(db), String(sqlite3_errmsg(db)));
    }
    return SqliteError(code, String(sqlite3_errstr(code)));
}

_check(db: __ptr<void>, code: int): SqliteResult<void> {
    if (code != SQLITE_OK) {
        return SqliteResult<void>.err(_error(db, code));
    }
    return SqliteResult<void>.ok();
}
