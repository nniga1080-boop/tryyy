"use strict";
/* Accounts: password hashing (scrypt), JWT access tokens and refresh tokens.
   Nothing here trusts the browser; a wrong password can never log you in. */
const crypto = require("node:crypto");

function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString("hex");
  const hash = crypto.scryptSync(String(password), salt, 64).toString("hex");
  return `s1$${salt}$${hash}`;
}

function verifyPassword(password, stored) {
  if (typeof stored !== "string") return false;
  const [tag, salt, hash] = stored.split("$");
  if (tag !== "s1" || !salt || !hash) return false;
  const expected = Buffer.from(hash, "hex");
  const actual = crypto.scryptSync(String(password), salt, 64);
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

const b64url = (buf) => Buffer.from(buf).toString("base64url");

function signJwt(payload, secret, seconds = 3600) {
  const now = Math.floor(Date.now() / 1000);
  const body = { ...payload, iat: now, exp: now + seconds, role: "authenticated" };
  const head = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const data = `${head}.${b64url(JSON.stringify(body))}`;
  const sig = crypto.createHmac("sha256", secret).update(data).digest("base64url");
  return { token: `${data}.${sig}`, expiresAt: body.exp };
}

function verifyJwt(token, secret) {
  if (typeof token !== "string" || token.split(".").length !== 3) return null;
  const [head, body, sig] = token.split(".");
  const expected = crypto.createHmac("sha256", secret).update(`${head}.${body}`).digest("base64url");
  const a = Buffer.from(sig);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const claims = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
    if (!claims.exp || claims.exp < Math.floor(Date.now() / 1000)) return null;
    return claims;
  } catch {
    return null;
  }
}

const newRefreshToken = () => crypto.randomBytes(32).toString("hex");

module.exports = { hashPassword, verifyPassword, signJwt, verifyJwt, newRefreshToken };
