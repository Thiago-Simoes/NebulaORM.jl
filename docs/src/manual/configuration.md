# Configuration & Best Practices

This guide covers environment setup, logging, and security considerations when using OrionORM in production.

---

## 1. Environment Variables

OrionORM uses **DotEnv.jl** to load database credentials and pool settings. Create a `.env` file at your project root:

```
DB_HOST=localhost
DB_USER=root
DB_PASSWORD=supersecret
DB_NAME=myapp_db
DB_PORT=3306
POOL_SIZE=10              # default is 5
ORIONORM_LOG_LEVEL=info   # error, warn, info, debug
```

Load variables at startup:

```julia
using DotEnv; DotEnv.load!()
using OrionORM
```

---

## 2. Logging

* Set `ORIONORM_LOG_LEVEL` to control verbosity:

  * `error`: only SQL errors
  * `warn`: warnings and errors
  * `info`: queries + warnings
  * `debug`: detailed internal logs

Customize globally:

```julia
ENV["ORIONORM_LOG_LEVEL"] = "debug"
initLogger()
```

Remember: logging takes time and storage.

---

## 3. Connection Pool Tuning

* `POOL_SIZE`: number of live connections to maintain. Increase for high concurrency.
* Monitor active vs. idle connections:

  ```julia
  @info "Pool available: $(Pool.connection_pool.n_avail_items)"
  ```

Avoid exhausting the pool:

* Always call `releaseConnection(conn)` in a `finally` block.
* For short-lived apps or scripts, consider lowering `POOL_SIZE`.

---

## 4. Security & Secrets Management

* **Don’t commit `.env`** to your repo. Use a secrets manager (e.g., Vault) in production. **(!!!)**
* **Encrypt credentials** at rest and load them via environment injection pipelines.
* Rotate database credentials regularly and leverage connection string parameters for SSL/TLS.

---

## 5. SQL Injection Prevention

* **Always** use `executeQuery` with parameters (never string interpolation).
* The QueryBuilder escapes identifiers and sanitizes literals before binding.

Bad (vulnerable):

```julia
sql = "SELECT * FROM users WHERE name = ‘$(user_input)’"
DBInterface.execute(conn, sql)
```

Good (safe):

```julia
executeQuery(conn,
    "SELECT * FROM users WHERE name = ?",
    [user_input]
)
```

---

With this configuration guide, you can securely and efficiently run OrionORM in development, staging, and production environments.
