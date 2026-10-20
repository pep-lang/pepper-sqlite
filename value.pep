## `Value`: one SQLite value of any storage class.

## A value as SQLite stores it: `NULL`, an integer, a floating-point
## number, text or a blob. `Statement.column` reads one, `Statement.bind`
## binds one, and `Database.execute` takes them as parameters.
##
## @example
##     import sqlite;
##
##     var parameters = [sqlite.Value.Integer(1), sqlite.Value.Text("Ada"), sqlite.Value.Null];
export enum Value {
    ## SQL `NULL`.
    Null,
    ## A 64-bit signed integer.
    ##
    ## @param value the integer
    Integer(value: long),
    ## An 8-byte IEEE floating-point number.
    ##
    ## @param value the number
    Real(value: double),
    ## Text, stored as UTF-8.
    ##
    ## @param value the text
    Text(value: String),
    ## Bytes, stored exactly as given.
    ##
    ## @param bytes the bytes
    Blob(bytes: u8[]),
}
