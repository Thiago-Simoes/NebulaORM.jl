# Transactions & Connection Management

OrionORM provides both **high-level** and **low-level** APIs for executing database operations, giving you fine-grained control over transactions and connection lifecycles.

---

## 1. Connection Pooling

* **`dbConnection()`**: checks out a connection from the pool (auto-initializes if empty).
* **`releaseConnection(conn)`**: returns a connection to the pool or closes it if the pool is full.
* **Pool health**: connections are validated (`SELECT 1`) before use; dropped ones are reconnected.

---

## 2. `executeQuery` APIs

### 2.1 High-Level (One-Shot)

```julia
# Opens and closes the connection automatically.
result = executeQuery(
  "SELECT * FROM users WHERE active = ?", [true]
)
```

* **Signature**: `executeQuery(sql::String, params::Vector{Any}=Any[]; useTransaction::Bool=true)`
* **Behavior**:

  1. Checks out a connection (`dbConnection()`).
  2. Prepares, executes, closes statement.
  3. Commits or rolls back DML if `useTransaction=true`.
  4. Releases connection (`releaseConnection`).

### 2.2 Low-Level (Conn-Aware)

```julia
conn = dbConnection()
DBInterface.transaction(conn) do
  executeQuery(conn, "UPDATE accounts SET balance = balance - ? WHERE id = ?", [100,1]; useTransaction=false)
  executeQuery(conn, "UPDATE accounts SET balance = balance + ? WHERE id = ?", [100,2]; useTransaction=false)
end
releaseConnection(conn)
```

* **Signature**: `executeQuery(conn::DBInterface.Connection, sql::String, params::Vector{Any}=Any[]; useTransaction::Bool=true)`
* **Behavior**:

  * Uses your provided `conn` without closing it.
  * If `useTransaction=true`, wraps the single statement in its own transaction; otherwise executes raw.
  * Always closes the prepared statement in a `finally` block.

---

## 3. Best Practices

* **One-shot queries**: prefer the high-level API for isolated operations (`SELECT`, single `INSERT`, etc.).
* **Batch updates/inserts**: open a connection once, wrap multiple `executeQuery(conn, ...; useTransaction=false)` calls inside `DBInterface.transaction`, then release the connection.
* **Do not nest transactions**: avoid `useTransaction=true` inside `DBInterface.transaction` blocks—most drivers don’t support nested transactions.
* **Release in `finally`**: always pair `dbConnection()` with `releaseConnection(conn)` in a `try`/`finally`.

---

## 4. Example: Atomic Transfer

```julia
function transfer_funds(from_id::Int, to_id::Int, amount::Float64)
  conn = dbConnection()
  try
    DBInterface.transaction(conn) do
      executeQuery(conn,
        "UPDATE accounts SET balance = balance - ? WHERE id = ?", [amount, from_id];
        useTransaction=false
      )
      executeQuery(conn,
        "UPDATE accounts SET balance = balance + ? WHERE id = ?", [amount, to_id];
        useTransaction=false
      )
    end
  finally
    releaseConnection(conn)
  end
end
```

* All updates occur in a single transaction; on error, changes are rolled back.

---

## 5. Troubleshooting

* **`Commands out of sync`**: ensure prepared statements are closed and connections are released promptly.
* **Zombie connections**: monitor pool size and logs; improper `releaseConnection` usage can exhaust the pool.
* **Transaction deadlocks**: use retries or reduced transaction scope if needed.
