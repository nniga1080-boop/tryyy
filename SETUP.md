# ESST site — going live with real accounts (about 10 minutes)

The site no longer contains any fake data. It needs a **Supabase** project (free) to store real
accounts, teams and matches. Until you connect one, visitors see a "not configured" page.

## 1. Create the database (Supabase)
1. Go to supabase.com → **New project** (pick any name/password/region near Algeria, e.g. Frankfurt).
2. Open **SQL Editor → New query**, paste the whole file `supabase/schema.sql`, click **Run**.
   It must finish with "Success". It creates tables and security rules and **no fake data**.
3. **Authentication → Providers → Email**: decide on "Confirm email".
   - OFF = people can use the site right after registering (easiest for a university tournament).
   - ON  = they must click a link in their email first (the site handles both).
4. **Project Settings → API** (or "API Keys"): copy
   - the **Project URL** (https://xxxx.supabase.co)
   - the **anon / publishable key**.  ⚠ Never use the `service_role` / `secret` key — the server refuses it.

## 2. Connect Railway
Railway → your service → **Variables** → add:
```
SUPABASE_URL              = https://xxxx.supabase.co
SUPABASE_PUBLISHABLE_KEY  = (the anon / publishable key)
```
Upload/redeploy this folder. Check `https://your-site/health` returns `{"ok":true}`.

## 3. Make yourself the first super admin
1. On your site click **Créer un compte** and register with your own email.
2. Supabase → SQL Editor → run (use your email):
```sql
update public.profiles set role = 'super_admin' where email = 'YOUR-EMAIL@example.com';
```
3. Log out and in. Open the account menu → **Tableau de bord**.

## How it works for your users
- **Visitor** → registers (name, birth year, position, foot) → lands on **Mon équipe**.
- **Create a team**: the player fills the form → it appears in *Dashboard → Demandes* → you **approve** →
  the player becomes **captain**.
- **Join a team**: on any team page (or in *Mon équipe*) a player presses **Demander à rejoindre** →
  the captain accepts/rejects in *Mon équipe*.
- You (super admin) create matches in *Dashboard → Matchs*; promote score managers in *Dashboard → Gestionnaires*.
- A player can belong to only one team. Max 45 players per team.

## Things to know
- The season label defaults to "2026 / 2027" — change it in *Dashboard → Paramètres*.
- Logged-in members can read other members' profile fields (name, email, birth year…). Public visitors cannot.
- Team approval by you is on purpose (stops spam teams). To let anyone create a team instantly, ask me.

## Performance update
Run `supabase/performance_indexes.sql` once in the SQL Editor (optional, safe to re-run). See CHANGES.md.
