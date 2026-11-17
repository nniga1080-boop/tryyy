"use strict";
/* ESST site server.
   - serves index.html + assets (with gzip/etag caching)
   - /auth/v1/*    : real accounts (scrypt passwords, JWT + refresh tokens)
   - /rest/v1/*    : the data API the website already speaks
   - /api/admin/activate : turns the caller into super admin with the secret key
   Database: Railway PostgreSQL (DATABASE_URL). */
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const zlib = require("node:zlib");
const crypto = require("node:crypto");

const db = require("./lib/db");
const auth = require("./lib/auth");
const rest = require("./lib/rest");

const ROOT = __dirname;
const PORT = parseInt(process.env.PORT, 10) || 3000;
const JWT_SECRET =
  process.env.AUTH_SECRET ||
  process.env.JWT_SECRET ||
  crypto.createHash("sha256").update("esst-dev-" + (process.env.DATABASE_URL || "local")).digest("hex");
const ACTIVATION_KEY = (process.env.SUPER_ADMIN_ACTIVATION_KEY || "").trim();

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
};

/* ---------------- tiny helpers ---------------- */
function sendJson(res, status, body, extra = {}) {
  const raw = Buffer.from(JSON.stringify(body ?? null));
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": raw.length,
    "Cache-Control": "no-store",
    ...extra,
  });
  res.end(raw);
}

function readBody(req, limit = 2 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) {
        reject(Object.assign(new Error("Payload too large"), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      if (!text) return resolve({});
      try {
        resolve(JSON.parse(text));
      } catch {
        reject(Object.assign(new Error("Invalid JSON body"), { status: 400 }));
      }
    });
    req.on("error", reject);
  });
}

/* Brute-force guard for password endpoints. */
const attempts = new Map();
function tooManyAttempts(key) {
  const now = Date.now();
  const rec = attempts.get(key);
  if (!rec || now > rec.reset) {
    attempts.set(key, { count: 1, reset: now + 10 * 60 * 1000 });
    return false;
  }
  rec.count += 1;
  return rec.count > 30;
}

function clientIp(req) {
  return String(req.headers["x-forwarded-for"] || "").split(",")[0].trim() || req.socket.remoteAddress || "?";
}

function bearer(req) {
  const raw = String(req.headers.authorization || "");
  if (!/^Bearer\s+/i.test(raw)) return null;
  return raw.replace(/^Bearer\s+/i, "").trim();
}

async function currentUser(req) {
  const token = bearer(req);
  if (!token) return null;
  const claims = auth.verifyJwt(token, JWT_SECRET);
  if (!claims?.sub) return null;
  return { id: claims.sub, email: claims.email || null };
}

/* ---------------- response shapes (GoTrue style) ---------------- */
function publicUser(row) {
  return {
    id: row.id,
    aud: "authenticated",
    role: "authenticated",
    email: row.email,
    email_confirmed_at: row.email_confirmed_at,
    created_at: row.created_at,
    updated_at: row.created_at,
    last_sign_in_at: row.last_sign_in_at,
    app_metadata: { provider: "email", providers: ["email"] },
    user_metadata: row.raw_user_meta_data || {},
    identities: [{ id: row.id, provider: "email", user_id: row.id }],
  };
}

async function issueSession(user) {
  const { token, expiresAt } = auth.signJwt(
    { sub: user.id, email: user.email },
    JWT_SECRET,
    60 * 60
  );
  const refresh = auth.newRefreshToken();
  await db.asUser(
    async (c) =>
      c.query(
        "insert into auth.refresh_tokens (token, user_id, expires_at) values ($1,$2, now() + interval '30 days')",
        [refresh, user.id]
      ),
    { privileged: true }
  );
  return {
    access_token: token,
    token_type: "bearer",
    expires_in: 3600,
    expires_at: expiresAt,
    refresh_token: refresh,
    user: publicUser(user),
  };
}

/* ---------------- auth endpoints ---------------- */
async function handleAuth(req, res, url) {
  const route = url.pathname.replace(/^\/auth\/v1/, "");
  const method = req.method;

  /* POST /auth/v1/signup */
  if (route === "/signup" && method === "POST") {
    const body = await readBody(req);
    const email = String(body.email || "").trim().toLowerCase();
    const password = String(body.password || "");
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return sendJson(res, 400, { code: 400, msg: "Unable to validate email address: invalid format", error_code: "email_address_invalid" });
    }
    if (password.length < 6) {
      return sendJson(res, 422, { code: 422, msg: "Password should be at least 6 characters", error_code: "weak_password" });
    }
    const meta = body.data && typeof body.data === "object" ? body.data : {};
    try {
      const row = await db.asUser(
        async (client) => {
          const { rows } = await client.query(
            `insert into auth.users (email, encrypted_password, raw_user_meta_data)
             values ($1,$2,$3)
             returning id, email, raw_user_meta_data, email_confirmed_at, created_at, last_sign_in_at`,
            [email, auth.hashPassword(password), JSON.stringify(meta)]
          );
          return rows[0];
        },
        { privileged: true }
      );
      const session = await issueSession(row);
      return sendJson(res, 200, session);
    } catch (e) {
      if (e && e.code === "23505") {
        return sendJson(res, 422, { code: 422, msg: "User already registered", error_code: "user_already_exists" });
      }
      throw e;
    }
  }

  /* POST /auth/v1/token?grant_type=password|refresh_token */
  if (route === "/token" && method === "POST") {
    const grant = url.searchParams.get("grant_type") || "password";
    const body = await readBody(req);
    if (grant === "password") {
      if (tooManyAttempts("pw:" + clientIp(req))) {
        return sendJson(res, 429, { code: 429, msg: "Too many attempts. Try again later.", error_code: "over_request_rate_limit" });
      }
      const email = String(body.email || "").trim().toLowerCase();
      const password = String(body.password || "");
      const row = await db.asUser(
        async (client) => {
          const { rows } = await client.query(
            "select id, email, encrypted_password, raw_user_meta_data, email_confirmed_at, created_at, last_sign_in_at from auth.users where lower(email)=$1",
            [email]
          );
          return rows[0] || null;
        },
        { privileged: true }
      );
      if (!row || !auth.verifyPassword(password, row.encrypted_password)) {
        return sendJson(res, 400, { code: 400, msg: "Invalid login credentials", error_code: "invalid_credentials" });
      }
      await db.asUser(
        async (c) => c.query("update auth.users set last_sign_in_at = now() where id=$1", [row.id]),
        { privileged: true }
      );
      const session = await issueSession(row);
      return sendJson(res, 200, session);
    }
    if (grant === "refresh_token") {
      const token = String(body.refresh_token || "");
      const found = await db.asUser(
        async (client) => {
          const { rows } = await client.query(
            `select u.id, u.email, u.raw_user_meta_data, u.email_confirmed_at, u.created_at, u.last_sign_in_at
               from auth.refresh_tokens t join auth.users u on u.id = t.user_id
              where t.token = $1 and not t.revoked and t.expires_at > now()`,
            [token]
          );
          if (!rows.length) return null;
          await client.query("update auth.refresh_tokens set revoked = true where token = $1", [token]);
          return rows[0];
        },
        { privileged: true }
      );
      if (!found) {
        return sendJson(res, 400, { code: 400, msg: "Invalid Refresh Token: Refresh Token Not Found", error_code: "refresh_token_not_found" });
      }
      return sendJson(res, 200, await issueSession(found));
    }
    return sendJson(res, 400, { code: 400, msg: "Unsupported grant type", error_code: "unsupported_grant_type" });
  }

  /* GET /auth/v1/user */
  if (route === "/user" && method === "GET") {
    const user = await currentUser(req);
    if (!user) return sendJson(res, 401, { code: 401, msg: "invalid claim: missing sub claim", error_code: "bad_jwt" });
    const row = await db.asUser(
      async (client) => {
        const { rows } = await client.query(
          "select id, email, raw_user_meta_data, email_confirmed_at, created_at, last_sign_in_at from auth.users where id=$1",
          [user.id]
        );
        return rows[0] || null;
      },
      { privileged: true }
    );
    if (!row) return sendJson(res, 401, { code: 401, msg: "user not found", error_code: "user_not_found" });
    return sendJson(res, 200, publicUser(row));
  }

  /* POST /auth/v1/logout */
  if (route === "/logout") {
    const user = await currentUser(req);
    if (user) {
      await db.asUser(
        async (c) => c.query("update auth.refresh_tokens set revoked = true where user_id=$1 and not revoked", [user.id]),
        { privileged: true }
      );
    }
    res.writeHead(204, { "Cache-Control": "no-store" });
    return res.end();
  }

  return sendJson(res, 404, { code: 404, msg: "Not found" });
}

/* ---------------- data endpoints ---------------- */
function pgError(e) {
  const message = String(e.message || "DATABASE_ERROR");
  const code = e.code || "P0001";
  const status =
    code === "42501" ? 403
      : code === "23505" ? 409
      : code === "23503" ? 409
      : code === "23514" ? 400
      : code === "22P02" ? 400
      : (code === "P0001" || code === "P0002") ? 400
      : 500;
  return { status, body: { code, message, details: e.detail || null, hint: e.hint || null } };
}

async function handleRest(req, res, url) {
  const user = await currentUser(req);
  const pathname = url.pathname.replace(/^\/rest\/v1\/?/, "");
  const parts = pathname.split("/").filter(Boolean);
  const method = req.method;
  const single = String(req.headers.accept || "").includes("application/vnd.pgrst.object+json");

  try {
    if (!db.isConfigured()) {
      return sendJson(res, 503, { code: "DB_NOT_CONFIGURED", message: "The database is not connected yet." });
    }

    const result = await db.asUser(
      async (client) => {
        if (parts[0] === "rpc" && parts[1]) {
          if (method !== "POST") throw new rest.ApiError("Use POST for rpc", 405);
          const body = await readBody(req);
          return rest.callRpc(client, parts[1], body);
        }
        const table = parts[0];
        if (!table) throw new rest.ApiError("Missing table", 400);
        if (method === "GET" || method === "HEAD") return rest.selectRows(client, table, url.searchParams);
        if (method === "POST") return rest.insertRows(client, table, await readBody(req), url.searchParams);
        if (method === "PATCH") return rest.updateRows(client, table, await readBody(req), url.searchParams);
        if (method === "DELETE") return rest.deleteRows(client, table, url.searchParams);
        throw new rest.ApiError("Method not allowed", 405);
      },
      { userId: user?.id || null }
    );

    if (single) {
      const row = Array.isArray(result) ? (result.length === 1 ? result[0] : null) : result;
      if (!row) {
        return sendJson(res, 406, {
          code: "PGRST116",
          message: "JSON object requested, multiple (or no) rows returned",
          details: "The result contains 0 rows",
          hint: null,
        });
      }
      return sendJson(res, 200, row);
    }
    if (method === "HEAD") {
      res.writeHead(200, { "Content-Type": "application/json" });
      return res.end();
    }
    return sendJson(res, method === "POST" ? 201 : 200, result ?? []);
  } catch (e) {
    if (e instanceof rest.ApiError) {
      return sendJson(res, e.status, { code: e.code, message: e.message, details: e.details, hint: null });
    }
    const { status, body } = pgError(e);
    if (status >= 500) console.error("[ESST] data error:", e);
    return sendJson(res, status, body);
  }
}

/* ---------------- admin access requests ---------------- */
async function handleAdminRequest(req, res) {
  const user = await currentUser(req);
  if (!user) return sendJson(res, 401, { code: "NOT_AUTHENTICATED", message: "Sign in first." });

  if (req.method === "GET") {
    const state = await db.asUser(
      async (client) => {
        const { rows: me } = await client.query(
          "select role, display_name, email from public.profiles where id = $1",
          [user.id]
        );
        const { rows: reqs } = await client.query(
          "select id, status, requested_task, description, created_at, assigned_role from public.staff_access_requests where user_id = $1 order by created_at desc limit 5",
          [user.id]
        );
        return { profile: me[0] || null, requests: reqs };
      },
      { userId: user.id }
    );
    return sendJson(res, 200, state);
  }

  if (req.method === "POST") {
    const body = await readBody(req);
    const task = String(body.task || "Match day: scores, lineups and reports").trim().slice(0, 200);
    const description = String(body.description || "").trim().slice(0, 500) || null;
    try {
      const request = await db.asUser(
        (client) => rest.callRpc(client, "submit_staff_request", { p_task: task, p_description: description }),
        { userId: user.id }
      );
      return sendJson(res, 200, { ok: true, request });
    } catch (e) {
      if (e && e.code === "P0001") {
        return sendJson(res, 400, { code: "REQUEST_FAILED", message: e.message });
      }
      throw e;
    }
  }
  return sendJson(res, 405, { message: "GET or POST only" });
}

/* ---------------- activation endpoint ---------------- */
async function handleActivate(req, res) {
  if (req.method !== "POST") return sendJson(res, 405, { message: "POST only" });
  const user = await currentUser(req);
  if (!user) {
    return sendJson(res, 401, { code: "NOT_AUTHENTICATED", message: "Sign in with your account first." });
  }
  if (tooManyAttempts("act:" + clientIp(req))) {
    return sendJson(res, 429, { code: "TOO_MANY_ATTEMPTS", message: "Too many attempts. Try again in 10 minutes." });
  }
  const body = await readBody(req);
  const given = String(body.key || "");
  if (!ACTIVATION_KEY) {
    return sendJson(res, 503, {
      code: "ACTIVATION_DISABLED",
      message: "The server has no SUPER_ADMIN_ACTIVATION_KEY set, so activation is disabled.",
    });
  }
  const a = Buffer.from(given);
  const b = Buffer.from(ACTIVATION_KEY);
  const ok = a.length === b.length && crypto.timingSafeEqual(a, b);
  if (!ok) return sendJson(res, 403, { code: "WRONG_KEY", message: "Wrong activation key." });

  const email = await db.asUser(
    async (client) => {
      const { rows } = await client.query(
        "update public.profiles set role = 'super_admin' where id = $1 returning email",
        [user.id]
      );
      return rows[0]?.email || user.email;
    },
    { privileged: true }
  );
  console.log("[ESST] super admin activated:", email, "at", new Date().toISOString());
  return sendJson(res, 200, { ok: true, role: "super_admin", email });
}

/* ---------------- pages ---------------- */
const TOKEN_HELPER = `<script>
function esstToken(){
  var cands=[];
  try{var raw=localStorage.getItem('sb-esst-auth-token')||localStorage.getItem('esst-auth-token');if(raw)cands.push(raw);}catch(e){}
  try{Object.keys(localStorage).forEach(function(k){if(/auth-token$/.test(k))cands.push(localStorage.getItem(k));});}catch(e){}
  for(var i=0;i<cands.length;i++){
    try{var v=JSON.parse(cands[i]);
      if(v&&v.access_token)return v.access_token;
      if(v&&v.currentSession&&v.currentSession.access_token)return v.currentSession.access_token;
      if(v&&v.session&&v.session.access_token)return v.session.access_token;
    }catch(e){}
  }
  return null;
}
</script>`;

const pageShell = (title, body) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>${title} · ESST</title>
<link rel="icon" type="image/svg+xml" href="/assets/favicon.svg"/>
<style>
  :root{color-scheme:dark}
  body{margin:0;min-height:100vh;display:grid;place-items:center;background:#050605;color:#eef3e8;
       font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;padding:24px}
  .card{width:100%;max-width:460px;background:#101410;border:1px solid #26301f;border-radius:18px;padding:28px}
  h1{font-size:1.35rem;margin:0 0 6px}
  p{color:#a8afa2;line-height:1.5;font-size:.95rem}
  label{display:block;margin:14px 0 6px;font-size:.9rem;color:#cbd5c0}
  input{width:100%;padding:12px;border-radius:10px;border:1px solid #33402a;background:#0a0d09;color:#eef3e8;font-size:1rem}
  button{margin-top:18px;width:100%;padding:12px;border:0;border-radius:10px;background:#a9dc6d;color:#0a0d09;font-weight:700;font-size:1rem;cursor:pointer}
  button:disabled{opacity:.6;cursor:default}
  .msg{margin-top:14px;font-size:.9rem;padding:10px 12px;border-radius:10px;display:none}
  .ok{display:block;background:#12351f;color:#b9f3c8}
  .err{display:block;background:#3a1616;color:#ffc9c9}
  a{color:#a9dc6d}
</style>${TOKEN_HELPER}</head><body><div class="card">${body}</div></body></html>`;

const ACTIVATE_PAGE = pageShell(
  "Activate super admin",
  `<h1>Activate super admin</h1>
   <p>Sign in with the account that should become the organiser, then paste the activation key.
      The key is checked by the server — a wrong key does nothing.</p>
   <div id="who" style="font-size:.9rem;color:#a8afa2"></div>
   <label for="key">Activation key</label>
   <input id="key" type="password" autocomplete="off" spellcheck="false"/>
   <button id="go">Activate my account</button>
   <div id="msg" class="msg"></div>
   <p style="margin-top:18px"><a href="/">Back to the site</a></p>
   <script>
   (function(){
     var msg=document.getElementById('msg'), btn=document.getElementById('go');
     var token=esstToken();
     function show(text,cls){msg.textContent=text;msg.className='msg '+cls;}
     document.getElementById('who').textContent=token?'Signed in ✓':'You are not signed in — log in on the site first.';
     btn.onclick=function(){
       if(!token) return show('Open the site, sign in, then come back to this page.','err');
       btn.disabled=true;show('Checking…','');
       fetch('/api/admin/activate',{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer '+token},
         body:JSON.stringify({key:document.getElementById('key').value})})
       .then(function(r){return r.json().then(function(j){return {status:r.status,j:j}})})
       .then(function(o){
         if(o.status===200){show('Done! This account is now super admin. Open the dashboard from the site menu.','ok');}
         else show(o.j.message||'Activation failed.','err');
         btn.disabled=false;
       }).catch(function(){show('Network error. Try again.','err');btn.disabled=false;});
     };
   })();
   </script>`
);

const REQUEST_PAGE = pageShell(
  "Request admin access",
  `<h1>Request admin access</h1>
   <p>Playing does not need an account request — just sign up and play.
      If you want to help organise (scores, lineups, reports), send a request here.
      A super admin approves it in the dashboard.</p>
   <div id="who" style="font-size:.9rem;color:#a8afa2"></div>
   <div id="status"></div>
   <div id="formwrap" style="display:none">
     <label for="task">What do you want to help with?</label>
     <input id="task" type="text" maxlength="200" value="Match day: scores, lineups and reports"/>
     <label for="desc">Anything else (optional)</label>
     <input id="desc" type="text" maxlength="500" placeholder="e.g. I am the captain of ESST FC"/>
     <button id="go">Send my request</button>
   </div>
   <div id="msg" class="msg"></div>
   <p style="margin-top:18px"><a href="/">Back to the site</a></p>
   <script>
   (function(){
     var token=esstToken(), msg=document.getElementById('msg'), who=document.getElementById('who');
     function show(text,cls){msg.textContent=text;msg.className='msg '+cls;}
     if(!token){who.textContent='You are not signed in.';show('Log in on the site first, then come back here.','err');return;}
     function render(state){
       var p=state.profile||{}, list=state.requests||[];
       who.textContent=(p.display_name||p.email||'Signed in')+' — role: '+(p.role||'member');
       var pending=list.find(function(r){return r.status==='pending';});
       var last=list[0];
       if(p.role==='super_admin'||p.role==='score_manager'){
         document.getElementById('status').innerHTML='<div class="msg ok" style="display:block">You already have the '+p.role.replace('_',' ')+' role. Open the dashboard from the site menu.</div>';
         return;
       }
       if(pending){
         document.getElementById('status').innerHTML='<div class="msg ok" style="display:block">Your request is waiting for a super admin to review it.</div>';
         return;
       }
       if(last&&last.status==='rejected'){
         document.getElementById('status').innerHTML='<div class="msg err" style="display:block">Your last request was declined. You can send a new one.</div>';
       }
       document.getElementById('formwrap').style.display='block';
     }
     function load(){
       fetch('/api/admin/request',{headers:{'Authorization':'Bearer '+token}})
         .then(function(r){return r.json().then(function(j){return {s:r.status,j:j}})})
         .then(function(o){ if(o.s!==200){show(o.j.message||'Could not load your account.','err');return;} render(o.j); })
         .catch(function(){show('Network error.','err');});
     }
     document.getElementById('go').onclick=function(){
       var btn=this;btn.disabled=true;show('Sending…','');
       fetch('/api/admin/request',{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer '+token},
         body:JSON.stringify({task:document.getElementById('task').value,description:document.getElementById('desc').value})})
       .then(function(r){return r.json().then(function(j){return {s:r.status,j:j}})})
       .then(function(o){
         btn.disabled=false;
         if(o.s===200){show('Request sent. A super admin will review it.','ok');load();}
         else show(o.j.message||'Could not send the request.','err');
       }).catch(function(){btn.disabled=false;show('Network error.','err');});
     };
     load();
   })();
   </script>`
);

/* ---------------- static files ---------------- */
const cache = new Map();

function configScript(req) {
  const forwarded = String(req.headers["x-forwarded-proto"] || "").split(",")[0].trim();
  const proto = forwarded || (req.socket.encrypted ? "https" : "http");
  const host = req.headers.host || `localhost:${PORT}`;
  const origin = `${proto}://${host}`;
  const json = JSON.stringify({
    VITE_SUPABASE_URL: origin,
    VITE_SUPABASE_PUBLISHABLE_KEY: "esst-local-anon-key",
  }).replace(/</g, "\\u003c");
  return `<script>window.__ESST_CONFIG__=${json};</script>`;
}

function pageBuffer(file, st, req) {
  const etag = '"' + st.size.toString(36) + "-" + Math.floor(st.mtimeMs).toString(36) + '"';
  const cfg = configScript(req);
  const html = fs.readFileSync(file, "utf8").replace("<!--ESST_CONFIG-->", cfg);
  const raw = Buffer.from(html, "utf8");
  return { etag: etag + "-" + crypto.createHash("md5").update(cfg).digest("hex").slice(0, 8), raw, gz: zlib.gzipSync(raw) };
}

function serveStatic(req, res, pathname) {
  let rel = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
  const allowed = rel === "index.html" || (/^assets\/[\w\-.]+$/.test(rel) && !rel.includes(".."));
  if (!allowed && path.extname(rel)) {
    res.writeHead(404);
    return res.end("Not found");
  }
  const file = path.join(ROOT, allowed ? rel : "index.html");
  fs.stat(file, (e, st) => {
    if (e || !st.isFile()) {
      res.writeHead(404);
      return res.end("Not found");
    }
    const isPage = file.endsWith("index.html");
    const type = TYPES[path.extname(file)] || "application/octet-stream";
    const wantsGzip = /\bgzip\b/.test(req.headers["accept-encoding"] || "");
    const head = req.method === "HEAD";
    if (isPage) {
      const c = pageBuffer(file, st, req);
      const h = {
        "Content-Type": type,
        ETag: c.etag,
        "Cache-Control": "no-cache",
        Vary: "Accept-Encoding",
      };
      if (req.headers["if-none-match"] === c.etag) {
        res.writeHead(304, h);
        return res.end();
      }
      const body = wantsGzip ? c.gz : c.raw;
      if (wantsGzip) h["Content-Encoding"] = "gzip";
      h["Content-Length"] = body.length;
      res.writeHead(200, h);
      return res.end(head ? undefined : body);
    }
    const etag = '"' + st.size.toString(36) + "-" + Math.floor(st.mtimeMs).toString(36) + '"';
    const h = { "Content-Type": type, ETag: etag, "Cache-Control": "public, max-age=86400" };
    if (req.headers["if-none-match"] === etag) {
      res.writeHead(304, h);
      return res.end();
    }
    if (/^(text\/|image\/svg)/.test(type) && wantsGzip) {
      let g = cache.get(file);
      if (!g || g.etag !== etag) {
        g = { etag, buf: zlib.gzipSync(fs.readFileSync(file)) };
        cache.set(file, g);
      }
      res.writeHead(200, Object.assign(h, { "Content-Encoding": "gzip", Vary: "Accept-Encoding", "Content-Length": g.buf.length }));
      return res.end(head ? undefined : g.buf);
    }
    res.writeHead(200, Object.assign(h, { "Content-Length": st.size }));
    if (head) res.end();
    else fs.createReadStream(file).pipe(res);
  });
}

/* ---------------- router ---------------- */
const server = http.createServer(async (req, res) => {
  let url;
  try {
    url = new URL(req.url, "http://x");
  } catch {
    res.writeHead(400);
    return res.end();
  }
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");
  res.setHeader("X-Frame-Options", "SAMEORIGIN");

  try {
    if (url.pathname === "/health") {
      return sendJson(res, 200, { ok: true, database: db.isConfigured() ? "configured" : "missing" });
    }
    if (url.pathname.startsWith("/auth/v1")) return await handleAuth(req, res, url);
    if (url.pathname.startsWith("/rest/v1")) return await handleRest(req, res, url);
    if (url.pathname === "/api/admin/activate") return await handleActivate(req, res);
    if (url.pathname === "/api/admin/request") return await handleAdminRequest(req, res);
    if (url.pathname === "/request-admin") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      return res.end(REQUEST_PAGE);
    }
    if (url.pathname === "/activate-admin") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      return res.end(ACTIVATE_PAGE);
    }
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405);
      return res.end();
    }
    return serveStatic(req, res, url.pathname);
  } catch (e) {
    const status = e.status || 500;
    if (status >= 500) console.error("[ESST] request error:", e);
    if (res.headersSent) return res.end();
    return sendJson(res, status, { code: e.code || "SERVER_ERROR", message: e.message || "Server error" });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[ESST] listening on ${PORT}`);
  if (!ACTIVATION_KEY) console.warn("[ESST] SUPER_ADMIN_ACTIVATION_KEY is not set — activation is disabled.");
  if (!db.isConfigured()) console.warn("[ESST] DATABASE_URL is not set — the site can load but data will fail.");
});
