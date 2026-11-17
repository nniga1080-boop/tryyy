"use strict";
/* Database access for the ESST site on Railway Postgres.
   Every request runs inside a transaction with `set local role` + the user id,
   so the Row Level Security rules in supabase/schema.sql do the permission checks. */
const fs = require("node:fs");
const path = require("node:path");
const { Pool } = require("pg");

const ROOT = path.resolve(__dirname, "..");
const connectionString =
  process.env.DATABASE_URL ||
  process.env.DATABASE_PRIVATE_URL ||
  process.env.POSTGRES_URL ||
  "";

const pool = new Pool({
  connectionString: connectionString || undefined,
  max: Number(process.env.DB_POOL_SIZE || 10),
  ssl: /sslmode=(require|verify)/.test(connectionString) || process.env.PGSSL === "1"
    ? { rejectUnauthorized: false }
    : undefined,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 15_000,
});

pool.on("error", (e) => console.error("[ESST] idle database connection error:", e.message));

let readyPromise = null;

async function runFile(client, file) {
  const sql = fs.readFileSync(path.join(ROOT, file), "utf8");
  await client.query(sql);
}

async function bootstrap() {
  const client = await pool.connect();
  try {
    await client.query("begin");
    await runFile(client, "db/00-auth.sql");
    const { rows } = await client.query(
      "select to_regclass('public.profiles') is not null as has_app"
    );
    if (!rows[0].has_app) {
      console.log("[ESST] creating the application tables…");
      await runFile(client, "supabase/schema.sql");
    }
    await runFile(client, "supabase/performance_indexes.sql");
    await client.query("commit");
    console.log("[ESST] database ready");
  } catch (e) {
    await client.query("rollback").catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

/* Runs fn(client) in a transaction as `authenticated` (or `anon`).
   With `privileged` the request runs as the database owner: used only by
   /api/admin/activate, which is protected by the secret key instead. */
async function asUser(fn, { userId = null, privileged = false } = {}) {
  if (!connectionString && !process.env.PGHOST) throw new Error("DATABASE_URL is not set");
  if (!readyPromise) readyPromise = bootstrap();
  await readyPromise;

  const client = await pool.connect();
  try {
    await client.query("begin");
    if (privileged) {
      // stay as the database owner: the secret key already authorised this request
      await client.query("set local role none");
    } else {
      await client.query("set local role " + (userId ? "authenticated" : "anon"));
    }
    await client.query("select set_config('request.jwt.claim.sub', $1, true)", [
      userId || "",
    ]);
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (e) {
    await client.query("rollback").catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

module.exports = { pool, asUser, isConfigured: () => Boolean(connectionString || process.env.PGHOST) };
