"use strict";
/* A small Supabase/PostgREST-compatible layer.
   The website was built against supabase-js, so it sends requests like
   GET /rest/v1/teams?select=*&order=name.asc and POST /rest/v1/rpc/request_join_team.
   This file translates those into parameterised SQL, run as the logged-in user
   so the Row Level Security rules in supabase/schema.sql are enforced. */

const IDENT = /^[a-z_][a-z0-9_]*$/;

/* Postgres array columns may arrive as '{a,b}' text; normalise to a JS array. */
function toArray(value) {
  if (Array.isArray(value)) return value;
  if (typeof value !== "string") return [];
  const inner = value.replace(/^\{/, "").replace(/\}$/, "");
  if (!inner) return [];
  return inner.split(",").map((s) => s.replace(/^"|"$/g, "").trim());
}
const RESERVED = new Set(["select", "order", "limit", "offset", "on_conflict", "columns"]);

class ApiError extends Error {
  constructor(message, status = 400, code = "P0001", details = null) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

/* ---------- select parsing ---------- */
function splitTopLevel(text, sep = ",") {
  const out = [];
  let depth = 0;
  let quote = false;
  let cur = "";
  for (const ch of text) {
    if (ch === '"') quote = !quote;
    if (!quote && ch === "(") depth++;
    if (!quote && ch === ")") depth--;
    if (!quote && depth === 0 && ch === sep) {
      out.push(cur);
      cur = "";
    } else cur += ch;
  }
  if (cur.trim()) out.push(cur);
  return out.map((s) => s.trim()).filter(Boolean);
}

function parseSelect(select) {
  const plain = [];
  const embeds = [];
  let star = false;
  for (const item of splitTopLevel(select || "*")) {
    if (item === "*") {
      star = true;
      continue;
    }
    const paren = item.indexOf("(");
    if (paren > 0 && item.endsWith(")")) {
      const head = item.slice(0, paren);
      const inner = item.slice(paren + 1, -1);
      const [aliasPart, ...hints] = head.split("!");
      const [alias, table] = aliasPart.includes(":")
        ? aliasPart.split(":")
        : [aliasPart, aliasPart];
      const fk = hints.find((h) => h && h !== "inner" && h !== "left") || null;
      const nested = parseSelect(inner);
      embeds.push({
        alias: (alias || table).trim(),
        table: table.trim(),
        fk: fk ? fk.trim() : null,
        star: nested.star || (!nested.plain.length && !nested.embeds.length),
        columns: nested.plain,
        embeds: nested.embeds,
      });
      continue;
    }
    const col = item.split(":")[0].split("!")[0].trim();
    if (col) plain.push(col);
  }
  return { plain, embeds, star };
}

/* ---------- filters ---------- */
function parseFilterValue(raw) {
  if (raw === undefined || raw === null) return null;
  if (raw.startsWith("(") && raw.endsWith(")")) {
    return splitTopLevel(raw.slice(1, -1)).map(unquote);
  }
  return unquote(raw);
}

function unquote(v) {
  const s = String(v).trim();
  if (s.length > 1 && s.startsWith('"') && s.endsWith('"')) return s.slice(1, -1).replace(/\\"/g, '"');
  return s;
}

function buildWhere(params, values) {
  const clauses = [];
  for (const [rawKey, rawValue] of params) {
    if (RESERVED.has(rawKey) || rawKey.includes(".")) continue;
    if (!IDENT.test(rawKey)) throw new ApiError("Bad column " + rawKey, 400);
    const dot = rawValue.indexOf(".");
    if (dot < 0) throw new ApiError("Bad filter", 400);
    const op = rawValue.slice(0, dot);
    const value = parseFilterValue(rawValue.slice(dot + 1));
    const col = `"${rawKey}"`;

    switch (op) {
      case "eq":
        if (value === "null") {
          clauses.push(`${col} is null`);
        } else {
          values.push(value);
          clauses.push(`${col} = $${values.length}`);
        }
        break;
      case "neq":
        values.push(value);
        clauses.push(`${col} <> $${values.length}`);
        break;
      case "in": {
        const list = Array.isArray(value) ? value : [value];
        if (!list.length) {
          clauses.push("false");
          break;
        }
        const marks = list.map((v) => {
          values.push(v);
          return `$${values.length}`;
        });
        clauses.push(`${col} in (${marks.join(", ")})`);
        break;
      }
      case "is":
        if (value === "null") clauses.push(`${col} is null`);
        else if (value === "true" || value === "false") clauses.push(`${col} is ${value}`);
        else throw new ApiError("Bad is filter", 400);
        break;
      case "not":
        if (String(value).startsWith("is.")) {
          clauses.push(`${col} is not null`);
        } else {
          values.push(String(value).replace(/^eq\./, ""));
          clauses.push(`${col} <> $${values.length}`);
        }
        break;
      case "gte":
        values.push(value);
        clauses.push(`${col} >= $${values.length}`);
        break;
      case "lte":
        values.push(value);
        clauses.push(`${col} <= $${values.length}`);
        break;
      case "gt":
        values.push(value);
        clauses.push(`${col} > $${values.length}`);
        break;
      case "lt":
        values.push(value);
        clauses.push(`${col} < $${values.length}`);
        break;
      case "like":
      case "ilike":
        values.push(value);
        clauses.push(`${col} ${op.toUpperCase()} $${values.length}`);
        break;
      default:
        throw new ApiError("Unsupported filter " + op, 400);
    }
  }
  return clauses.length ? " where " + clauses.join(" and ") : "";
}

function buildOrder(params) {
  const raw = params.get("order");
  if (!raw) return "";
  const parts = splitTopLevel(raw).map((item) => {
    const [column, ...rest] = item.split(".");
    if (!IDENT.test(column)) throw new ApiError("Bad order column", 400);
    const dir = rest.includes("desc") ? "desc" : "asc";
    const nulls = rest.includes("nullsfirst")
      ? " nulls first"
      : rest.includes("nullslast")
        ? " nulls last"
        : "";
    return `"${column}" ${dir}${nulls}`;
  });
  return parts.length ? " order by " + parts.join(", ") : "";
}

function limitClause(params) {
  let sql = "";
  const limit = parseInt(params.get("limit"), 10);
  const offset = parseInt(params.get("offset"), 10);
  if (Number.isFinite(limit) && limit >= 0) sql += ` limit ${limit}`;
  if (Number.isFinite(offset) && offset > 0) sql += ` offset ${offset}`;
  return sql;
}

/* ---------- relationship lookup (for embedded selects) ---------- */
async function findRelationship(client, from, to, fkName) {
  if (fkName && IDENT.test(fkName)) {
    const { rows } = await client.query(
      `select c.conname,
              (select array_agg(a.attname order by k.ord)
                 from unnest(c.conkey) with ordinality k(attnum, ord)
                 join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) as local_cols,
              (select array_agg(a.attname order by k.ord)
                 from unnest(c.confkey) with ordinality k(attnum, ord)
                 join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as foreign_cols,
              (select n.nspname||'.'||cl.relname from pg_class cl join pg_namespace n on n.oid=cl.relnamespace where cl.oid=c.conrelid) as local_table
         from pg_constraint c
        where c.conname = $1 and c.contype = 'f'`,
      [fkName]
    );
    if (rows.length) {
      const r = rows[0];
      const local = r.local_table.split(".").pop();
      return {
        many: local !== from,
        localCols: toArray(r.local_cols),
        foreignCols: toArray(r.foreign_cols),
        otherTable: local === from ? to : from,
      };
    }
  }
  const { rows } = await client.query(
    `select c.conname, c.conrelid::regclass::text as local_table,
            (select array_agg(a.attname order by k.ord)
               from unnest(c.conkey) with ordinality k(attnum, ord)
               join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) as local_cols,
            (select array_agg(a.attname order by k.ord)
               from unnest(c.confkey) with ordinality k(attnum, ord)
               join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as foreign_cols
       from pg_constraint c
      where c.contype = 'f'
        and ((c.conrelid::regclass::text = $1 and c.confrelid::regclass::text = $2)
          or (c.conrelid::regclass::text = $2 and c.confrelid::regclass::text = $1))`,
    [from, to]
  );
  if (!rows.length) throw new ApiError(`No relationship between ${from} and ${to}`, 400);
  const direct = rows.find((r) => r.local_table.split(".").pop() === from && toArray(r.local_cols).length === 1);
  const chosen = direct || rows[0];
  const local = chosen.local_table.split(".").pop();
  return {
    many: local !== from, // FK on the child table -> many children
    localCols: toArray(chosen.local_cols),
    foreignCols: toArray(chosen.foreign_cols),
    otherTable: local === from ? to : from,
  };
}

async function attachEmbeds(client, table, rows, embeds) {
  for (const embed of embeds) {
    if (!IDENT.test(embed.table)) throw new ApiError("Bad table", 400);
    const rel = await findRelationship(client, table, embed.table, embed.fk);
    if (!rows.length) {
      for (const row of rows) row[embed.alias] = rel.many ? [] : null;
      continue;
    }
    const keyColumn = rel.many ? rel.foreignCols[0] : rel.localCols[0];
    const targetColumn = rel.many ? rel.localCols[0] : rel.foreignCols[0];
    const keys = [...new Set(rows.map((r) => r[keyColumn]).filter((k) => k !== null && k !== undefined))];
    if (!keys.length) {
      for (const row of rows) row[embed.alias] = rel.many ? [] : null;
      continue;
    }
    const cols = embed.star || !embed.columns.length ? "*" : embed.columns.map((c) => `"${c}"`).join(", ");
    for (const c of embed.columns) if (!IDENT.test(c)) throw new ApiError("Bad column", 400);
    const { rows: children } = await client.query(
      `select ${cols}, "${targetColumn}" as __esst_parent_key from "${embed.table}" where "${targetColumn}" = any($1)`,
      [keys]
    );
    const grouped = new Map();
    for (const child of children) {
      const key = String(child.__esst_parent_key);
      delete child.__esst_parent_key;
      if (!grouped.has(key)) grouped.set(key, []);
      grouped.get(key).push(child);
    }
    for (const row of rows) {
      const key = String(row[keyColumn]);
      const list = grouped.get(key) || [];
      if (rel.many) row[embed.alias] = list;
      else row[embed.alias] = list[0] || null;
    }
    if (embed.embeds && embed.embeds.length) {
      const nested = [];
      for (const row of rows) {
        const value = row[embed.alias];
        if (Array.isArray(value)) nested.push(...value);
        else if (value) nested.push(value);
      }
      if (nested.length) await attachEmbeds(client, embed.table, nested, embed.embeds);
    }
  }
  return rows;
}

function tableName(raw) {
  if (!IDENT.test(raw)) throw new ApiError("Bad table name", 400);
  return raw;
}

/* ---------- query builders ---------- */
async function selectRows(client, table, params) {
  const t = tableName(table);
  const parsed = parseSelect(params.get("select"));
  const cols = parsed.star || !parsed.plain.length ? "*" : parsed.plain.map((c) => `"${c}"`).join(", ");
  for (const c of parsed.plain) if (!IDENT.test(c)) throw new ApiError("Bad column", 400);
  const values = [];
  const where = buildWhere(params, values);
  const sql = `select ${cols} from "${t}"${where}${buildOrder(params)}${limitClause(params)}`;
  const { rows } = await client.query(sql, values);
  if (parsed.embeds.length) await attachEmbeds(client, t, rows, parsed.embeds);
  return rows;
}

async function insertRows(client, table, body, params) {
  const t = tableName(table);
  const list = Array.isArray(body) ? body : [body];
  if (!list.length) return [];
  const columns = Object.keys(list[0]);
  for (const c of columns) if (!IDENT.test(c)) throw new ApiError("Bad column " + c, 400);
  const insertCols = columns.map((c) => `"${c}"`).join(", ");
  const values = [];
  const tuples = list.map((row) => {
    const marks = columns.map((c) => {
      values.push(row[c] === undefined ? null : row[c]);
      return `$${values.length}`;
    });
    return `(${marks.join(", ")})`;
  });
  const parsed = parseSelect(params.get("select"));
  const returning = parsed.star || !parsed.plain.length ? "*" : parsed.plain.map((c) => `"${c}"`).join(", ");
  const { rows } = await client.query(
    `insert into "${t}" (${insertCols}) values ${tuples.join(", ")} returning ${returning}`,
    values
  );
  if (parsed.embeds.length) await attachEmbeds(client, t, rows, parsed.embeds);
  return rows;
}

async function updateRows(client, table, body, params) {
  const t = tableName(table);
  const columns = Object.keys(body || {});
  if (!columns.length) throw new ApiError("Empty update", 400);
  const values = [];
  const sets = columns.map((c) => {
    if (!IDENT.test(c)) throw new ApiError("Bad column " + c, 400);
    values.push(body[c] === undefined ? null : body[c]);
    return `"${c}" = $${values.length}`;
  });
  const where = buildWhere(params, values);
  if (!where) throw new ApiError("Refusing to update every row", 400);
  const parsed = parseSelect(params.get("select"));
  const returning = parsed.star || !parsed.plain.length ? "*" : parsed.plain.map((c) => `"${c}"`).join(", ");
  const { rows } = await client.query(
    `update "${t}" set ${sets.join(", ")}${where} returning ${returning}`,
    values
  );
  if (parsed.embeds.length) await attachEmbeds(client, t, rows, parsed.embeds);
  return rows;
}

async function deleteRows(client, table, params) {
  const t = tableName(table);
  const values = [];
  const where = buildWhere(params, values);
  if (!where) throw new ApiError("Refusing to delete every row", 400);
  const { rows } = await client.query(`delete from "${t}"${where} returning *`, values);
  return rows;
}

async function callRpc(client, name, args) {
  if (!IDENT.test(name)) throw new ApiError("Bad function name", 400);
  const keys = Object.keys(args || {});
  const values = [];
  const call = keys
    .map((k) => {
      if (!IDENT.test(k)) throw new ApiError("Bad argument " + k, 400);
      const v = args[k] === undefined ? null : args[k];
      values.push(typeof v === "object" && v !== null ? JSON.stringify(v) : v);
      const isJson = typeof v === "object" && v !== null;
      return `${k} => $${values.length}${isJson ? "::jsonb" : ""}`;
    })
    .join(", ");
  const { rows } = await client.query(`select to_jsonb(public."${name}"(${call})) as data`, values);
  return rows[0] ? rows[0].data : null;
}

module.exports = { ApiError, selectRows, insertRows, updateRows, deleteRows, callRpc };
module.exports._debug = { parseSelect, findRelationship, attachEmbeds };
