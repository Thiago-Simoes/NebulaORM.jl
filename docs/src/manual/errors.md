# Error Handling & Troubleshooting

This guide covers the common exceptions, error messages, and debugging techniques in OrionORM. Proper error handling ensures robust applications and simplifies troubleshooting.

---

## 1. Debugging SQL

1. **Enable Info Logging**:

   ```julia
   ENV["ORIONORM_LOG_LEVEL"] = "info"
   ```

2. **Check Logs**: Every call to `executeQuery` logs:

   * `sql`: the prepared SQL string
   * `args`: the parameter vector

3. **Reproduce in MySQL client**:

   * Copy the logged SQL, replace `?` with actual values, and run in `mysql` CLI or GUI.

4. **Inspect Generated Query**:

   ```julia
   b = buildSelectQuery(User, qdict)
   println(b.sql, "\nParams:", b.params)
   ```

---

## 2. Handling `commands out of sync`

This error arises when statements remain open or connections are reused improperly. To resolve:

* Ensure **every** `DBInterface.prepare` is paired with `DBInterface.close!(stmt)` in a `finally` block.
* Use the unified `executeQuery` which guarantees closing statements.
* Do not call raw `DBInterface.execute` on a connection with unclosed statements.

---

## 3. Transaction Rollback

Within a `DBInterface.transaction(conn)` block, any uncaught exception triggers a rollback:

```julia
conn = dbConnection()
try
  DBInterface.transaction(conn) do
    executeQuery(conn, sql1, params1; useTransaction=false)
    error("trigger rollback")
  end
catch e
  @info "Transaction rolled back due to: $e"
finally
  releaseConnection(conn)
end
```
