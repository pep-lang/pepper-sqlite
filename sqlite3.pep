## The parts of SQLite's C API (`sqlite3.h`) the module calls, private to
## the module. Each declaration is the C function of the same name, with
## C's types: `sqlite3*` and `sqlite3_stmt*` are `void*`, `sqlite3_int64`
## is `long`.
##
## Which library is linked, per platform:
##
## - **Linux:** `libsqlite3.so` (`apt install libsqlite3-dev`).
## - **macOS:** `libsqlite3.dylib`, which the SDK provides.
## - **Windows:** `winsqlite3.dll`, which Windows 10 and later ship in
##   `System32`, through `winsqlite3.lib` from the Windows SDK.

# The [Link] on sqlite3_libversion links the library for every program that
# imports the module.

[Target(OS(Windows))]
[Link("winsqlite3")]
extern char* sqlite3_libversion();

[Target(!OS(Windows))]
[Link("sqlite3")]
extern char* sqlite3_libversion();

extern void* malloc(ulong size);
extern void free(void* p);

extern int sqlite3_open_v2(char* filename, void** db, int flags, char* vfs);
extern int sqlite3_close_v2(void* db);
extern char* sqlite3_errmsg(void* db);
extern char* sqlite3_errstr(int code);
extern int sqlite3_extended_errcode(void* db);
extern int sqlite3_extended_result_codes(void* db, int on);
extern int sqlite3_exec(void* db, char* sql, void* callback, void* argument, char** error);
extern void sqlite3_free(void* p);
extern int sqlite3_changes(void* db);
extern long sqlite3_last_insert_rowid(void* db);
extern int sqlite3_get_autocommit(void* db);
extern int sqlite3_busy_timeout(void* db, int milliseconds);

extern int sqlite3_prepare_v2(void* db, char* sql, int size, void** statement, char** tail);
extern int sqlite3_step(void* statement);
extern int sqlite3_reset(void* statement);
extern int sqlite3_clear_bindings(void* statement);
extern int sqlite3_finalize(void* statement);

extern int sqlite3_bind_parameter_count(void* statement);
extern int sqlite3_bind_parameter_index(void* statement, char* name);
extern int sqlite3_bind_null(void* statement, int index);
extern int sqlite3_bind_int64(void* statement, int index, long value);
extern int sqlite3_bind_double(void* statement, int index, double value);
extern int sqlite3_bind_text(void* statement, int index, char* text, int size, void* destructor);
extern int sqlite3_bind_zeroblob(void* statement, int index, int size);
extern int sqlite3_bind_blob(void* statement, int index, void* data, int size, void* destructor);

extern int sqlite3_column_count(void* statement);
extern char* sqlite3_column_name(void* statement, int index);
extern int sqlite3_column_type(void* statement, int index);
extern long sqlite3_column_int64(void* statement, int index);
extern double sqlite3_column_double(void* statement, int index);
extern char* sqlite3_column_text(void* statement, int index);
extern void* sqlite3_column_blob(void* statement, int index);
extern int sqlite3_column_bytes(void* statement, int index);

const SQLITE_OK = 0;
const SQLITE_TOOBIG = 18;
const SQLITE_MISMATCH = 20;
const SQLITE_MISUSE = 21;
const SQLITE_RANGE = 25;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;

const SQLITE_INTEGER = 1;
const SQLITE_FLOAT = 2;
const SQLITE_TEXT = 3;
const SQLITE_NULL = 5;

# SQLITE_TRANSIENT: SQLite copies the bound bytes before the call returns.
_transient(): __ptr<void> {
    return unsafe_cast<__ptr<void>>(0xffffffffffffffff as ulong);
}

# `text.c_str()`, but "" for empty text: an empty String has no buffer, and
# SQLite reads a null pointer as NULL rather than ''.
_c_text(text: String): __ptr<char> {
    if (text.size == 0) {
        return "";
    }
    return text.c_str();
}
