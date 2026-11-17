-- =====================================================================
--  ESST Football Tournament — Supabase database setup
--  How to run: Supabase dashboard -> SQL Editor -> New query ->
--  paste this whole file -> Run.  (Safe to run on an EMPTY project.)
--  Creates: tables, security rules (RLS), server functions, signup trigger.
--  Creates NO fake data: no teams, no players, no matches.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

create table public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  email              text,
  display_name       text,
  full_name          text,
  nickname           text,
  birth_year         int  check (birth_year between 1940 and 2020),
  main_position      text check (main_position in ('goalkeeper','defender','midfielder','forward')),
  secondary_position text check (secondary_position in ('goalkeeper','defender','midfielder','forward')),
  preferred_foot     text check (preferred_foot in ('right','left','both')),
  height_cm          numeric(5,1) check (height_cm between 100 and 250),
  weight_kg          numeric(5,1) check (weight_kg between 30 and 200),
  photo_url          text,
  profile_complete   boolean not null default false,
  role               text not null default 'member'
                     check (role in ('pending','member','score_manager','super_admin')),
  ovr                int  not null default 60 check (ovr between 50 and 99),
  created_at         timestamptz not null default now()
);

create table public.tournament_settings (
  id                      int primary key default 1 check (id = 1),
  tournament_name         text not null default 'ESST Football Tournament',
  season_label            text not null default '2026 / 2027',
  timezone                text not null default 'Africa/Algiers',
  points_for_win          int  not null default 3,
  points_for_draw         int  not null default 1,
  points_for_loss         int  not null default 0,
  substitutions_per_match int  not null default 5,
  updated_at              timestamptz not null default now()
);

create table public.teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(trim(name)) between 2 and 60),
  short_name  text not null check (char_length(trim(short_name)) between 2 and 6),
  logo_url    text,
  description text,
  archived    boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index teams_name_unique  on public.teams (lower(trim(name)));
create unique index teams_short_unique on public.teams (upper(trim(short_name)));

create table public.matches (
  id           uuid primary key default gen_random_uuid(),
  home_team_id uuid not null references public.teams(id) on delete cascade,
  away_team_id uuid not null references public.teams(id) on delete cascade,
  home_score   int check (home_score >= 0),
  away_score   int check (away_score >= 0),
  kickoff_at   timestamptz not null,
  venue        text,
  round_name   text,
  status       text not null default 'scheduled'
               check (status in ('scheduled','live','finished','postponed','cancelled')),
  updated_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (home_team_id <> away_team_id)
);
create index matches_kickoff_idx on public.matches (kickoff_at);

create table public.match_audit_logs (
  id             uuid primary key default gen_random_uuid(),
  match_id       uuid references public.matches(id) on delete cascade,
  old_home_score int, new_home_score int,
  old_away_score int, new_away_score int,
  old_status     text, new_status text,
  changed_by     uuid references public.profiles(id) on delete set null,
  changed_at     timestamptz not null default now()
);

create table public.team_memberships (
  id             uuid primary key default gen_random_uuid(),
  team_id        uuid not null references public.teams(id) on delete cascade,
  player_id      uuid not null references public.profiles(id) on delete cascade,
  status         text not null default 'active' check (status in ('active','transferred_out','left')),
  role_in_team   text not null default 'player' check (role_in_team in ('player','captain')),
  jersey_number  int check (jersey_number between 1 and 99),
  joined_at      timestamptz not null default now(),
  left_at        timestamptz,
  transferred_to uuid references public.teams(id) on delete set null
);
-- a player can be active in only ONE team; jersey numbers are unique inside a team
create unique index memberships_one_active_team on public.team_memberships (player_id) where status = 'active';
create unique index memberships_unique_jersey   on public.team_memberships (team_id, jersey_number)
  where status = 'active' and jersey_number is not null;
create index memberships_team_idx on public.team_memberships (team_id);

create table public.team_join_requests (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references public.teams(id) on delete cascade,
  player_id   uuid not null references public.profiles(id) on delete cascade,
  message     text,
  status      text not null default 'pending' check (status in ('pending','accepted','rejected','cancelled')),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at  timestamptz not null default now()
);
create unique index join_requests_one_pending on public.team_join_requests (team_id, player_id) where status = 'pending';

create table public.team_creation_requests (
  id               uuid primary key default gen_random_uuid(),
  requester_id     uuid not null references public.profiles(id) on delete cascade,
  proposed_name    text not null,
  short_name       text not null,
  description      text,
  logo_url         text,
  status           text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by      uuid references auth.users(id) on delete set null,
  reviewed_at      timestamptz,
  approved_team_id uuid references public.teams(id) on delete set null,
  created_at       timestamptz not null default now()
);
create unique index creation_requests_one_pending on public.team_creation_requests (requester_id) where status = 'pending';

create table public.team_transfer_requests (
  id                   uuid primary key default gen_random_uuid(),
  player_id            uuid not null references public.profiles(id) on delete cascade,
  from_team_id         uuid not null references public.teams(id) on delete cascade,
  to_team_id           uuid not null references public.teams(id) on delete cascade,
  reason               text,
  status               text not null default 'pending'
                       check (status in ('pending','captain_approved','approved','rejected')),
  captain_reviewed_by  uuid references auth.users(id) on delete set null,
  captain_reviewed_at  timestamptz,
  final_approved_by    uuid references auth.users(id) on delete set null,
  final_approved_at    timestamptz,
  created_at           timestamptz not null default now()
);

create table public.staff_access_requests (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles(id) on delete cascade,
  requested_task text not null,
  description    text,
  status         text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by    uuid references auth.users(id) on delete set null,
  reviewed_at    timestamptz,
  assigned_role  text,
  created_at     timestamptz not null default now()
);

create table public.match_lineups (
  id              uuid primary key default gen_random_uuid(),
  match_id        uuid not null references public.matches(id) on delete cascade,
  team_id         uuid not null references public.teams(id) on delete cascade,
  formation       text not null,
  captain_id      uuid references public.profiles(id) on delete set null,
  vice_captain_id uuid references public.profiles(id) on delete set null,
  tactics         text,
  is_locked       boolean not null default false,
  is_public       boolean not null default false,
  created_by      uuid references auth.users(id) on delete set null,
  updated_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (match_id, team_id)
);

create table public.lineup_players (
  id              uuid primary key default gen_random_uuid(),
  lineup_id       uuid not null references public.match_lineups(id) on delete cascade,
  player_id       uuid not null references public.profiles(id) on delete cascade,
  jersey_number   int,
  match_position  text,
  is_starter      boolean not null default false,
  is_captain      boolean not null default false,
  is_vice_captain boolean not null default false,
  created_at      timestamptz not null default now()
);
create index lineup_players_lineup_idx on public.lineup_players (lineup_id);

create table public.match_events (
  id                uuid primary key default gen_random_uuid(),
  match_id          uuid not null references public.matches(id) on delete cascade,
  sequence          int  not null,
  event_type        text not null check (event_type in ('goal','yellow','red','sub')),
  detail            text check (detail in ('normal','penalty','own_goal')),
  minute            int  not null check (minute between 0 and 130),
  extra_minute      int  check (extra_minute between 0 and 15),
  team_id           uuid not null references public.teams(id) on delete cascade,
  player_id         uuid not null references public.profiles(id) on delete cascade,
  related_player_id uuid references public.profiles(id) on delete set null,
  created_by        uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now()
);
create index match_events_match_idx on public.match_events (match_id);

create table public.match_reports (
  id                 uuid primary key default gen_random_uuid(),
  match_id           uuid not null unique references public.matches(id) on delete cascade,
  summary            text,
  referee_score_home int,
  referee_score_away int,
  status             text not null default 'published' check (status in ('published','corrected')),
  submitted_by       uuid references auth.users(id) on delete set null,
  submitted_at       timestamptz,
  corrected_by       uuid references auth.users(id) on delete set null,
  corrected_at       timestamptz,
  correction_note    text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table public.player_match_appearances (
  id             uuid primary key default gen_random_uuid(),
  match_id       uuid not null references public.matches(id) on delete cascade,
  player_id      uuid not null references public.profiles(id) on delete cascade,
  team_id        uuid not null references public.teams(id) on delete cascade,
  match_position text,
  is_starter     boolean not null default false,
  entry_minute   int,
  exit_minute    int,
  minutes_played int,
  created_at     timestamptz not null default now()
);
create index appearances_player_idx on public.player_match_appearances (player_id);
create index appearances_match_idx  on public.player_match_appearances (match_id);

create table public.player_ovr_ledger (
  id         uuid primary key default gen_random_uuid(),
  player_id  uuid not null references public.profiles(id) on delete cascade,
  match_id   uuid not null references public.matches(id) on delete cascade,
  reason     text not null,
  delta      int  not null,
  meta       jsonb,
  created_at timestamptz not null default now()
);
create index ovr_ledger_player_idx on public.player_ovr_ledger (player_id);

create table public.player_suspensions (
  id                    uuid primary key default gen_random_uuid(),
  player_id             uuid not null references public.profiles(id) on delete cascade,
  team_id               uuid not null references public.teams(id) on delete cascade,
  red_card_match_id     uuid references public.matches(id) on delete cascade,
  suspended_for_match_id uuid references public.matches(id) on delete set null,
  status                text not null default 'pending' check (status in ('pending','served')),
  created_at            timestamptz not null default now(),
  served_at             timestamptz
);
create index suspensions_player_idx on public.player_suspensions (player_id);

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  type       text,
  title      text,
  body       text,
  link       text,
  read       boolean not null default false,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id);

create table public.team_posts (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid not null references public.teams(id) on delete cascade,
  author_id  uuid not null references public.profiles(id) on delete cascade,
  title      text,
  body       text not null,
  post_type  text not null default 'post',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index team_posts_team_idx on public.team_posts (team_id);

-- the single settings row (editable later in Admin -> Settings)
insert into public.tournament_settings (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2. HELPER FUNCTIONS (used by the security rules)
-- ---------------------------------------------------------------------

create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.role = 'super_admin' from public.profiles p where p.id = auth.uid()), false)
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select p.role in ('score_manager','super_admin') from public.profiles p where p.id = auth.uid()), false)
$$;

create or replace function public.is_team_member(p_team uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.team_memberships m
                 where m.team_id = p_team and m.player_id = auth.uid() and m.status = 'active')
$$;

create or replace function public.is_team_captain(p_team uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.team_memberships m
                 where m.team_id = p_team and m.player_id = auth.uid()
                   and m.status = 'active' and m.role_in_team = 'captain')
$$;

create or replace function public.try_uuid(p_text text) returns uuid
language plpgsql immutable as $$
begin
  return p_text::uuid;
exception when others then
  return null;
end $$;

-- ---------------------------------------------------------------------
-- 3. TRIGGERS
-- ---------------------------------------------------------------------

-- 3a. Every new sign-up automatically gets a profile (role = member).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  meta   jsonb;
  v_full text;
  v_name text;
  v_year int;
  v_pos  text;
  v_foot text;
begin
  meta   := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_full := nullif(trim(meta->>'full_name'), '');
  v_name := coalesce(nullif(trim(meta->>'display_name'), ''), v_full, split_part(new.email, '@', 1));
  v_year := case when (meta->>'birth_year') ~ '^[0-9]{4}$' then (meta->>'birth_year')::int else null end;
  if v_year is not null and (v_year < 1940 or v_year > 2020) then v_year := null; end if;
  v_pos  := case when (meta->>'main_position') in ('goalkeeper','defender','midfielder','forward')
                 then meta->>'main_position' else null end;
  v_foot := case when (meta->>'preferred_foot') in ('right','left','both')
                 then meta->>'preferred_foot' else null end;

  insert into public.profiles
    (id, email, display_name, full_name, nickname, birth_year, main_position, preferred_foot, profile_complete)
  values
    (new.id, new.email, v_name, v_full, nullif(trim(meta->>'nickname'), ''), v_year, v_pos, v_foot,
     (v_full is not null and v_year is not null and v_pos is not null and v_foot is not null))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 3b. Users can edit their own profile, but NEVER their role / OVR / email.
create or replace function public.protect_profile_columns() returns trigger
language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    if new.id is distinct from old.id
       or new.role is distinct from old.role
       or new.ovr is distinct from old.ovr
       or new.email is distinct from old.email
       or new.created_at is distinct from old.created_at then
      raise exception 'FORBIDDEN_PROFILE_FIELDS';
    end if;
  end if;
  return new;
end $$;

create trigger profiles_protect before update on public.profiles
  for each row execute function public.protect_profile_columns();

-- 3c. updated_at / updated_by bookkeeping
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger teams_touch    before update on public.teams               for each row execute function public.touch_updated_at();
create trigger settings_touch before update on public.tournament_settings for each row execute function public.touch_updated_at();
create trigger posts_touch    before update on public.team_posts           for each row execute function public.touch_updated_at();

create or replace function public.matches_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
create trigger matches_touch_trg before insert or update on public.matches
  for each row execute function public.matches_touch();

-- 3d. Audit log: every score/status change on a match is recorded.
create or replace function public.matches_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.home_score is distinct from old.home_score
     or new.away_score is distinct from old.away_score
     or new.status     is distinct from old.status then
    insert into public.match_audit_logs
      (match_id, old_home_score, new_home_score, old_away_score, new_away_score, old_status, new_status, changed_by)
    values
      (new.id, old.home_score, new.home_score, old.away_score, new.away_score, old.status, new.status,
       (select p.id from public.profiles p where p.id = auth.uid()));
  end if;
  return new;
end $$;
create trigger matches_audit_trg after update on public.matches
  for each row execute function public.matches_audit();

-- 3e. A team post's author is always the logged-in user.
create or replace function public.team_posts_set_author() returns trigger
language plpgsql as $$
begin
  if new.author_id is null then
    new.author_id := auth.uid();
  end if;
  return new;
end $$;
create trigger team_posts_author before insert on public.team_posts
  for each row execute function public.team_posts_set_author();

-- ---------------------------------------------------------------------
-- 4. SECURITY RULES (Row Level Security)
-- ---------------------------------------------------------------------

alter table public.profiles                 enable row level security;
alter table public.tournament_settings      enable row level security;
alter table public.teams                    enable row level security;
alter table public.matches                  enable row level security;
alter table public.match_audit_logs         enable row level security;
alter table public.team_memberships         enable row level security;
alter table public.team_join_requests       enable row level security;
alter table public.team_creation_requests   enable row level security;
alter table public.team_transfer_requests   enable row level security;
alter table public.staff_access_requests    enable row level security;
alter table public.match_lineups            enable row level security;
alter table public.lineup_players           enable row level security;
alter table public.match_events             enable row level security;
alter table public.match_reports            enable row level security;
alter table public.player_match_appearances enable row level security;
alter table public.player_ovr_ledger        enable row level security;
alter table public.player_suspensions       enable row level security;
alter table public.notifications            enable row level security;
alter table public.team_posts               enable row level security;

-- profiles: logged-in users can read profiles; each user edits only their own row
create policy profiles_select on public.profiles for select to authenticated using (true);
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- public tournament data (readable by everyone, even visitors who are not logged in)
create policy settings_select on public.tournament_settings for select to anon, authenticated using (true);
create policy settings_update on public.tournament_settings for update to authenticated
  using (public.is_super_admin()) with check (public.is_super_admin());

create policy teams_select on public.teams for select to anon, authenticated using (true);
create policy teams_insert on public.teams for insert to authenticated with check (public.is_super_admin());
create policy teams_update on public.teams for update to authenticated
  using (public.is_super_admin()) with check (public.is_super_admin());
create policy teams_delete on public.teams for delete to authenticated using (public.is_super_admin());

create policy matches_select on public.matches for select to anon, authenticated using (true);
create policy matches_insert on public.matches for insert to authenticated with check (public.is_staff());
create policy matches_update on public.matches for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy matches_delete on public.matches for delete to authenticated using (public.is_super_admin());

create policy audit_select on public.match_audit_logs for select to authenticated using (public.is_staff());

create policy memberships_select on public.team_memberships for select to anon, authenticated using (true);

create policy events_select       on public.match_events             for select to anon, authenticated using (true);
create policy reports_select      on public.match_reports            for select to anon, authenticated using (true);
create policy appearances_select  on public.player_match_appearances for select to anon, authenticated using (true);
create policy ledger_select       on public.player_ovr_ledger        for select to anon, authenticated using (true);
create policy suspensions_select  on public.player_suspensions       for select to anon, authenticated using (true);

-- lineups: public once the match is live, otherwise only the team and staff
create policy lineups_select on public.match_lineups for select to anon, authenticated
  using (is_public or public.is_staff() or public.is_team_member(team_id));
create policy lineup_players_select on public.lineup_players for select to anon, authenticated
  using (exists (select 1 from public.match_lineups l
                 where l.id = lineup_id
                   and (l.is_public or public.is_staff() or public.is_team_member(l.team_id))));

-- requests: you see your own; captains see their team's; super admin sees all
create policy join_requests_select on public.team_join_requests for select to authenticated
  using (player_id = auth.uid() or public.is_team_captain(team_id) or public.is_super_admin());
create policy creation_requests_select on public.team_creation_requests for select to authenticated
  using (requester_id = auth.uid() or public.is_super_admin());
create policy transfer_requests_select on public.team_transfer_requests for select to authenticated
  using (player_id = auth.uid() or public.is_team_captain(from_team_id)
         or public.is_team_captain(to_team_id) or public.is_super_admin());
create policy staff_requests_select on public.staff_access_requests for select to authenticated
  using (user_id = auth.uid() or public.is_super_admin());

-- notifications: private to their owner
create policy notifications_select on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notifications_update on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- team space (posts): team members only
create policy posts_select on public.team_posts for select to authenticated
  using (public.is_team_member(team_id) or public.is_super_admin());
create policy posts_insert on public.team_posts for insert to authenticated
  with check (author_id = auth.uid() and (public.is_team_member(team_id) or public.is_super_admin()));
create policy posts_update on public.team_posts for update to authenticated
  using (author_id = auth.uid() or public.is_team_captain(team_id) or public.is_super_admin())
  with check (author_id = auth.uid() or public.is_team_captain(team_id) or public.is_super_admin());

-- ---------------------------------------------------------------------
-- 5. SERVER FUNCTIONS (called by the website through supabase.rpc)
--    Every error is raised as a short code (e.g. TEAM_FULL) that the
--    website translates for the user.
-- ---------------------------------------------------------------------

-- ===== Teams: users request, super admin approves =====

create or replace function public.request_team_creation(
  p_name text, p_short text, p_description text default null, p_logo_url text default null)
returns public.team_creation_requests
language plpgsql security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_name  text := trim(coalesce(p_name, ''));
  v_short text := upper(trim(coalesce(p_short, '')));
  v_logo  text := nullif(trim(coalesce(p_logo_url, '')), '');
  v_req   public.team_creation_requests;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60
     or char_length(v_short) < 2 or char_length(v_short) > 6 then
    raise exception 'INVALID_TEAM';
  end if;
  if v_logo is not null and v_logo !~* '^https?://.+' then raise exception 'INVALID_TEAM'; end if;
  if exists (select 1 from public.team_memberships where player_id = v_uid and status = 'active') then
    raise exception 'ALREADY_IN_A_TEAM';
  end if;
  if exists (select 1 from public.team_creation_requests where requester_id = v_uid and status = 'pending') then
    raise exception 'REQUEST_ALREADY_PENDING';
  end if;
  if exists (select 1 from public.teams where lower(trim(name)) = lower(v_name) or upper(trim(short_name)) = v_short)
     or exists (select 1 from public.team_creation_requests
                 where status = 'pending' and (lower(trim(proposed_name)) = lower(v_name) or upper(trim(short_name)) = v_short)) then
    raise exception 'DUPLICATE_TEAM';
  end if;
  insert into public.team_creation_requests (requester_id, proposed_name, short_name, description, logo_url)
  values (v_uid, v_name, v_short, nullif(trim(coalesce(p_description, '')), ''), v_logo)
  returning * into v_req;
  return v_req;
end $$;

create or replace function public.approve_team_creation(p_request_id uuid, p_approve boolean)
returns public.team_creation_requests
language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_req     public.team_creation_requests;
  v_team_id uuid;
begin
  if not public.is_super_admin() then raise exception 'FORBIDDEN'; end if;
  select * into v_req from public.team_creation_requests where id = p_request_id for update;
  if not found or v_req.status <> 'pending' then raise exception 'REQUEST_NOT_FOUND'; end if;

  if p_approve then
    if exists (select 1 from public.team_memberships where player_id = v_req.requester_id and status = 'active') then
      raise exception 'ALREADY_IN_A_TEAM';
    end if;
    begin
      insert into public.teams (name, short_name, logo_url, description)
      values (v_req.proposed_name, v_req.short_name, v_req.logo_url, v_req.description)
      returning id into v_team_id;
    exception when unique_violation then
      raise exception 'DUPLICATE_TEAM';
    end;
    insert into public.team_memberships (team_id, player_id, status, role_in_team)
    values (v_team_id, v_req.requester_id, 'active', 'captain');
    update public.team_creation_requests
       set status = 'approved', reviewed_by = v_uid, reviewed_at = now(), approved_team_id = v_team_id
     where id = p_request_id returning * into v_req;
    -- the new captain no longer needs other pending join requests
    update public.team_join_requests set status = 'cancelled', reviewed_at = now()
     where player_id = v_req.requester_id and status = 'pending';
  else
    update public.team_creation_requests
       set status = 'rejected', reviewed_by = v_uid, reviewed_at = now()
     where id = p_request_id returning * into v_req;
  end if;
  return v_req;
end $$;

-- ===== Joining a team =====

create or replace function public.request_join_team(p_team_id uuid, p_message text default null)
returns public.team_join_requests
language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_team public.teams;
  v_req  public.team_join_requests;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select * into v_team from public.teams where id = p_team_id;
  if not found or v_team.archived then raise exception 'TEAM_NOT_FOUND'; end if;
  if exists (select 1 from public.team_memberships where player_id = v_uid and status = 'active') then
    raise exception 'ALREADY_IN_A_TEAM';
  end if;
  if exists (select 1 from public.team_join_requests
              where player_id = v_uid and team_id = p_team_id and status = 'pending') then
    raise exception 'REQUEST_ALREADY_PENDING';
  end if;
  insert into public.team_join_requests (team_id, player_id, message)
  values (p_team_id, v_uid, nullif(trim(coalesce(p_message, '')), ''))
  returning * into v_req;
  return v_req;
end $$;

create or replace function public.decide_join_request(
  p_request_id uuid, p_accept boolean, p_jersey_number int default null)
returns public.team_join_requests
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_req public.team_join_requests;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select * into v_req from public.team_join_requests where id = p_request_id for update;
  if not found or v_req.status <> 'pending' then raise exception 'REQUEST_NOT_FOUND'; end if;
  if not (public.is_team_captain(v_req.team_id) or public.is_super_admin()) then
    raise exception 'FORBIDDEN';
  end if;

  if p_accept then
    if (select count(*) from public.team_memberships where team_id = v_req.team_id and status = 'active') >= 45 then
      raise exception 'TEAM_FULL';
    end if;
    if exists (select 1 from public.team_memberships where player_id = v_req.player_id and status = 'active') then
      raise exception 'ALREADY_IN_A_TEAM';
    end if;
    insert into public.team_memberships (team_id, player_id, status, role_in_team, jersey_number)
    values (v_req.team_id, v_req.player_id, 'active', 'player', p_jersey_number);
    update public.team_join_requests
       set status = 'accepted', reviewed_by = v_uid, reviewed_at = now()
     where id = p_request_id returning * into v_req;
    update public.team_join_requests set status = 'cancelled', reviewed_at = now()
     where player_id = v_req.player_id and status = 'pending' and id <> p_request_id;
  else
    update public.team_join_requests
       set status = 'rejected', reviewed_by = v_uid, reviewed_at = now()
     where id = p_request_id returning * into v_req;
  end if;
  return v_req;
end $$;

-- ===== Transfers between teams =====

create or replace function public.request_transfer(p_from_team uuid, p_to_team uuid, p_reason text default null)
returns public.team_transfer_requests
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_m   public.team_memberships;
  v_req public.team_transfer_requests;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if p_from_team = p_to_team then raise exception 'INVALID_TRANSFER'; end if;
  select * into v_m from public.team_memberships
   where player_id = v_uid and team_id = p_from_team and status = 'active';
  if not found then raise exception 'FORBIDDEN'; end if;
  if v_m.role_in_team = 'captain' then raise exception 'CAPTAIN_CANNOT_TRANSFER'; end if;
  if not exists (select 1 from public.teams where id = p_to_team and not archived) then
    raise exception 'TEAM_NOT_FOUND';
  end if;
  if exists (select 1 from public.team_transfer_requests
              where player_id = v_uid and status in ('pending','captain_approved')) then
    raise exception 'REQUEST_ALREADY_PENDING';
  end if;
  insert into public.team_transfer_requests (player_id, from_team_id, to_team_id, reason)
  values (v_uid, p_from_team, p_to_team, nullif(trim(coalesce(p_reason, '')), ''))
  returning * into v_req;
  return v_req;
end $$;

create or replace function public.captain_approve_transfer(p_request_id uuid, p_accept boolean)
returns public.team_transfer_requests
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_req public.team_transfer_requests;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  select * into v_req from public.team_transfer_requests where id = p_request_id for update;
  if not found or v_req.status <> 'pending' then raise exception 'REQUEST_NOT_FOUND'; end if;
  if not (public.is_team_captain(v_req.to_team_id) or public.is_super_admin()) then
    raise exception 'FORBIDDEN';
  end if;
  update public.team_transfer_requests
     set status = case when p_accept then 'captain_approved' else 'rejected' end,
         captain_reviewed_by = v_uid, captain_reviewed_at = now()
   where id = p_request_id returning * into v_req;
  return v_req;
end $$;

create or replace function public.finalize_transfer(p_request_id uuid, p_approve boolean)
returns public.team_transfer_requests
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_req public.team_transfer_requests;
begin
  if not public.is_super_admin() then raise exception 'FORBIDDEN'; end if;
  select * into v_req from public.team_transfer_requests where id = p_request_id for update;
  if not found or v_req.status not in ('pending','captain_approved') then raise exception 'REQUEST_NOT_FOUND'; end if;

  if p_approve then
    if (select count(*) from public.team_memberships where team_id = v_req.to_team_id and status = 'active') >= 45 then
      raise exception 'TEAM_FULL';
    end if;
    update public.team_memberships
       set status = 'transferred_out', left_at = now(), transferred_to = v_req.to_team_id
     where player_id = v_req.player_id and team_id = v_req.from_team_id and status = 'active';
    insert into public.team_memberships (team_id, player_id, status, role_in_team)
    values (v_req.to_team_id, v_req.player_id, 'active', 'player');
    update public.team_transfer_requests
       set status = 'approved', final_approved_by = v_uid, final_approved_at = now()
     where id = p_request_id returning * into v_req;
  else
    update public.team_transfer_requests
       set status = 'rejected', final_approved_by = v_uid, final_approved_at = now()
     where id = p_request_id returning * into v_req;
  end if;
  return v_req;
end $$;

-- ===== Staff access (score managers) and roles =====

create or replace function public.submit_staff_request(p_task text, p_description text default null)
returns public.staff_access_requests
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_req public.staff_access_requests;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if nullif(trim(coalesce(p_task, '')), '') is null then raise exception 'INVALID_REQUEST'; end if;
  if exists (select 1 from public.staff_access_requests where user_id = v_uid and status = 'pending') then
    raise exception 'REQUEST_ALREADY_PENDING';
  end if;
  insert into public.staff_access_requests (user_id, requested_task, description)
  values (v_uid, trim(p_task), nullif(trim(coalesce(p_description, '')), ''))
  returning * into v_req;
  return v_req;
end $$;

create or replace function public.review_staff_request(p_request_id uuid, p_approve boolean, p_assigned_role text)
returns public.staff_access_requests
language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_req  public.staff_access_requests;
  v_role text := coalesce(p_assigned_role, 'score_manager');
begin
  if not public.is_super_admin() then raise exception 'FORBIDDEN'; end if;
  select * into v_req from public.staff_access_requests where id = p_request_id for update;
  if not found or v_req.status <> 'pending' then raise exception 'REQUEST_NOT_FOUND'; end if;

  if p_approve then
    if v_role not in ('member','score_manager','super_admin') then raise exception 'INVALID_ROLE'; end if;
    update public.profiles set role = v_role where id = v_req.user_id;
    update public.staff_access_requests
       set status = 'approved', assigned_role = v_role, reviewed_by = v_uid, reviewed_at = now()
     where id = p_request_id returning * into v_req;
  else
    update public.staff_access_requests
       set status = 'rejected', reviewed_by = v_uid, reviewed_at = now()
     where id = p_request_id returning * into v_req;
  end if;
  return v_req;
end $$;

create or replace function public.change_manager_role(target_user_id uuid, new_role text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_target public.profiles;
begin
  if not public.is_super_admin() then raise exception 'FORBIDDEN'; end if;
  if target_user_id = auth.uid() then raise exception 'You cannot change your own role'; end if;
  if new_role not in ('pending','member','score_manager','super_admin') then raise exception 'INVALID_ROLE'; end if;
  select * into v_target from public.profiles where id = target_user_id;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  if v_target.role = 'super_admin' and new_role <> 'super_admin'
     and (select count(*) from public.profiles where role = 'super_admin') <= 1 then
    raise exception 'LAST_SUPER_ADMIN';
  end if;
  update public.profiles set role = new_role where id = target_user_id;
end $$;

-- ===== Match day: lineups, live, report =====

create or replace function public.save_lineup(
  p_match_id uuid, p_team_id uuid, p_formation text,
  p_captain_id uuid, p_vice_captain_id uuid, p_tactics text, p_players jsonb)
returns public.match_lineups
language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_match   public.matches;
  v_lineup  public.match_lineups;
  v_total   int;
  v_starters int;
  v_distinct int;
  v_bad     int;
  v_locked  boolean;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if not (public.is_team_captain(p_team_id) or public.is_super_admin()) then raise exception 'FORBIDDEN'; end if;
  select * into v_match from public.matches where id = p_match_id;
  if not found then raise exception 'MATCH_NOT_FOUND'; end if;
  if p_team_id not in (v_match.home_team_id, v_match.away_team_id) then raise exception 'INVALID_LINEUP'; end if;
  if v_match.status <> 'scheduled' then raise exception 'LINEUP_LOCKED'; end if;
  if p_formation is null or p_formation not in ('4-3-3','4-4-2','4-2-3-1','3-5-2','5-3-2','3-4-3','4-5-1') then
    raise exception 'INVALID_LINEUP';
  end if;
  if jsonb_typeof(coalesce(p_players, 'null'::jsonb)) <> 'array' then raise exception 'INVALID_LINEUP'; end if;

  select l.is_locked into v_locked from public.match_lineups l
   where l.match_id = p_match_id and l.team_id = p_team_id;
  if coalesce(v_locked, false) then raise exception 'LINEUP_LOCKED'; end if;

  select count(*), count(*) filter (where x.is_starter), count(distinct x.player_id)
    into v_total, v_starters, v_distinct
    from jsonb_to_recordset(p_players) as x(player_id uuid, jersey_number int, match_position text,
                                            is_starter boolean, is_captain boolean, is_vice_captain boolean);
  if v_total = 0 or v_starters <> 11 or (v_total - v_starters) > 7 or v_distinct <> v_total then
    raise exception 'INVALID_LINEUP';
  end if;

  -- every player must be an active member of this team, not suspended for this match,
  -- with a valid position and a jersey number 1..99
  select count(*) into v_bad
    from jsonb_to_recordset(p_players) as x(player_id uuid, jersey_number int, match_position text,
                                            is_starter boolean, is_captain boolean, is_vice_captain boolean)
   where not exists (select 1 from public.team_memberships m
                      where m.team_id = p_team_id and m.player_id = x.player_id and m.status = 'active')
      or exists (select 1 from public.player_suspensions s
                  where s.player_id = x.player_id and s.suspended_for_match_id = p_match_id and s.status = 'pending')
      or x.match_position is null
      or x.match_position not in ('goalkeeper','defender','midfielder','forward')
      or x.jersey_number is null or x.jersey_number < 1 or x.jersey_number > 99;
  if v_bad > 0 then raise exception 'INVALID_LINEUP'; end if;

  if (select count(distinct x.jersey_number) from jsonb_to_recordset(p_players) as x(jersey_number int)) <> v_total then
    raise exception 'INVALID_LINEUP';
  end if;
  if (select count(*) from jsonb_to_recordset(p_players) as x(is_captain boolean) where x.is_captain) <> 1 then
    raise exception 'INVALID_LINEUP';
  end if;

  insert into public.match_lineups (match_id, team_id, formation, captain_id, vice_captain_id, tactics, created_by, updated_by)
  values (p_match_id, p_team_id, p_formation, p_captain_id, p_vice_captain_id, nullif(trim(coalesce(p_tactics, '')), ''), v_uid, v_uid)
  on conflict (match_id, team_id) do update
    set formation = excluded.formation, captain_id = excluded.captain_id,
        vice_captain_id = excluded.vice_captain_id, tactics = excluded.tactics,
        updated_by = v_uid, updated_at = now()
  returning * into v_lineup;

  delete from public.lineup_players where lineup_id = v_lineup.id;
  insert into public.lineup_players
    (lineup_id, player_id, jersey_number, match_position, is_starter, is_captain, is_vice_captain)
  select v_lineup.id, x.player_id, x.jersey_number, x.match_position,
         coalesce(x.is_starter, false), coalesce(x.is_captain, false), coalesce(x.is_vice_captain, false)
    from jsonb_to_recordset(p_players) as x(player_id uuid, jersey_number int, match_position text,
                                            is_starter boolean, is_captain boolean, is_vice_captain boolean);
  return v_lineup;
end $$;

create or replace function public.mark_match_live(p_match_id uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  v_match public.matches;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  select * into v_match from public.matches where id = p_match_id for update;
  if not found or v_match.status <> 'scheduled' then raise exception 'MATCH_NOT_SCHEDULABLE'; end if;
  if not exists (select 1 from public.match_lineups where match_id = p_match_id and team_id = v_match.home_team_id)
     or not exists (select 1 from public.match_lineups where match_id = p_match_id and team_id = v_match.away_team_id) then
    raise exception 'LINEUPS_REQUIRED';
  end if;
  update public.match_lineups set is_locked = true, is_public = true where match_id = p_match_id;
  update public.matches
     set status = 'live', home_score = coalesce(home_score, 0), away_score = coalesce(away_score, 0)
   where id = p_match_id returning * into v_match;
  return v_match;
end $$;

-- OVR = 60 + the sum of all match deltas, applied match by match and kept between 50 and 99.
create or replace function public.recompute_player_ovr(p_player uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_ovr int := 60;
  r     record;
begin
  for r in
    select l.match_id, sum(l.delta)::int as total
      from public.player_ovr_ledger l
      join public.matches m on m.id = l.match_id and m.status = 'finished'
     where l.player_id = p_player
     group by l.match_id, m.kickoff_at
     order by m.kickoff_at, l.match_id
  loop
    v_ovr := least(99, greatest(50, v_ovr + r.total));
  end loop;
  update public.profiles set ovr = v_ovr where id = p_player;
end $$;

create or replace function public.submit_match_report(
  p_match_id uuid, p_events jsonb, p_summary text,
  p_referee_home int, p_referee_away int, p_appearances jsonb, p_ovr_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_match   public.matches;
  v_clean   jsonb := '[]'::jsonb;
  v_keys    text[] := '{}';
  v_home    int := 0;
  v_away    int := 0;
  r         record;
  v_type    text;
  v_detail  text;
  v_min     int;
  v_extra   int;
  v_team    uuid;
  v_player  uuid;
  v_rel     uuid;
  v_key     text;
  v_prev    uuid[];
  v_next    uuid;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  select * into v_match from public.matches where id = p_match_id for update;
  if not found then raise exception 'MATCH_NOT_FOUND'; end if;
  if v_match.status = 'cancelled' then raise exception 'MATCH_CANCELLED'; end if;
  if jsonb_typeof(coalesce(p_events, '[]'::jsonb)) <> 'array' then
    raise exception 'INVALID_EVENTS:events.notList';
  end if;

  -- validate and normalise every event
  for r in select t.e as e, t.idx::int as idx
             from jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) with ordinality as t(e, idx)
  loop
    v_type := r.e->>'event_type';
    if v_type is null or v_type not in ('goal','yellow','red','sub') then
      raise exception 'INVALID_EVENTS:events.badType:#%', r.idx;
    end if;
    if coalesce(r.e->>'minute', '') !~ '^[0-9]+$' or (r.e->>'minute')::int > 130 then
      raise exception 'INVALID_EVENTS:events.badMinute:#%', r.idx;
    end if;
    v_min := (r.e->>'minute')::int;
    if nullif(r.e->>'extra_minute', '') is null then
      v_extra := null;
    else
      if (r.e->>'extra_minute') !~ '^[0-9]+$' or (r.e->>'extra_minute')::int > 15 then
        raise exception 'INVALID_EVENTS:events.badStoppage:#%', r.idx;
      end if;
      v_extra := (r.e->>'extra_minute')::int;
    end if;
    v_team := public.try_uuid(r.e->>'team_id');
    if v_team is null or v_team not in (v_match.home_team_id, v_match.away_team_id) then
      raise exception 'INVALID_EVENTS:events.badTeam:#%', r.idx;
    end if;
    v_player := public.try_uuid(r.e->>'player_id');
    if v_player is null then raise exception 'INVALID_EVENTS:events.missingPlayer:#%', r.idx; end if;
    v_rel := public.try_uuid(r.e->>'related_player_id');
    v_detail := null;

    if v_type = 'goal' then
      v_detail := coalesce(nullif(r.e->>'detail', ''), 'normal');
      if v_detail not in ('normal','penalty','own_goal') then
        raise exception 'INVALID_EVENTS:events.badDetail:#%', r.idx;
      end if;
      if v_detail = 'own_goal' then
        v_rel := null;
      elsif v_rel is not null and v_rel = v_player then
        raise exception 'INVALID_EVENTS:events.selfAssist:#%', r.idx;
      end if;
      if v_team = v_match.home_team_id then v_home := v_home + 1; else v_away := v_away + 1; end if;
    elsif v_type = 'sub' then
      if v_rel is null then raise exception 'INVALID_EVENTS:events.subMissingIn:#%', r.idx; end if;
      if v_rel = v_player then raise exception 'INVALID_EVENTS:events.subSamePlayer:#%', r.idx; end if;
    else
      v_rel := null;
    end if;

    v_key := concat_ws('|', v_type, coalesce(v_detail, ''), v_min, coalesce(v_extra::text, ''), v_team, v_player, coalesce(v_rel::text, ''));
    if v_key = any (v_keys) then raise exception 'INVALID_EVENTS:events.duplicate:#%', r.idx; end if;
    v_keys := v_keys || v_key;

    v_clean := v_clean || jsonb_build_array(jsonb_build_object(
      'idx', r.idx, 'event_type', v_type, 'detail', v_detail, 'minute', v_min, 'extra_minute', v_extra,
      'team_id', v_team, 'player_id', v_player, 'related_player_id', v_rel));
  end loop;

  if p_referee_home is not null and p_referee_home <> v_home then raise exception 'SCORE_MISMATCH'; end if;
  if p_referee_away is not null and p_referee_away <> v_away then raise exception 'SCORE_MISMATCH'; end if;

  -- remember who was affected by a previous version of this report, then wipe it
  select array_agg(distinct l.player_id) into v_prev from public.player_ovr_ledger l where l.match_id = p_match_id;
  delete from public.match_events             where match_id = p_match_id;
  delete from public.player_match_appearances where match_id = p_match_id;
  delete from public.player_ovr_ledger        where match_id = p_match_id;
  delete from public.player_suspensions       where red_card_match_id = p_match_id;

  insert into public.match_events
    (match_id, sequence, event_type, detail, minute, extra_minute, team_id, player_id, related_player_id, created_by)
  select p_match_id,
         row_number() over (order by (c.minute * 100 + coalesce(c.extra_minute, 0)), c.idx),
         c.event_type, c.detail, c.minute, c.extra_minute, c.team_id, c.player_id, c.related_player_id, v_uid
    from jsonb_to_recordset(v_clean) as c(idx int, event_type text, detail text, minute int, extra_minute int,
                                          team_id uuid, player_id uuid, related_player_id uuid);

  insert into public.player_match_appearances
    (match_id, player_id, team_id, match_position, is_starter, entry_minute, exit_minute, minutes_played)
  select p_match_id, a.player_id, a.team_id, a.match_position, coalesce(a.is_starter, false),
         a.entry_minute, a.exit_minute, a.minutes_played
    from jsonb_to_recordset(coalesce(p_appearances, '[]'::jsonb)) as a(player_id uuid, team_id uuid, match_position text,
                                      is_starter boolean, entry_minute int, exit_minute int, minutes_played int)
   where a.player_id is not null and a.team_id in (v_match.home_team_id, v_match.away_team_id);

  insert into public.player_ovr_ledger (player_id, match_id, reason, delta, meta)
  select o.player_id, p_match_id, o.reason, o.delta, o.meta
    from jsonb_to_recordset(coalesce(p_ovr_rows, '[]'::jsonb)) as o(player_id uuid, reason text, delta int, meta jsonb)
   where o.player_id is not null and o.reason is not null and o.delta is not null;

  -- red card => suspended for that team's next match
  for r in select c.player_id, c.team_id
             from jsonb_to_recordset(v_clean) as c(event_type text, player_id uuid, team_id uuid)
            where c.event_type = 'red'
  loop
    select m.id into v_next
      from public.matches m
     where (m.home_team_id = r.team_id or m.away_team_id = r.team_id)
       and m.status <> 'cancelled' and m.id <> p_match_id
       and (m.kickoff_at, m.id) > (v_match.kickoff_at, v_match.id)
     order by m.kickoff_at, m.id
     limit 1;
    insert into public.player_suspensions (player_id, team_id, red_card_match_id, suspended_for_match_id, status)
    values (r.player_id, r.team_id, p_match_id, v_next, 'pending');
  end loop;

  update public.matches
     set status = 'finished', home_score = v_home, away_score = v_away
   where id = p_match_id;

  -- a suspension is "served" once the suspended match is finished without that player
  update public.player_suspensions s
     set status = 'served', served_at = now()
   where s.status = 'pending' and s.suspended_for_match_id is not null
     and exists (select 1 from public.matches m where m.id = s.suspended_for_match_id and m.status = 'finished')
     and not exists (select 1 from public.player_match_appearances a
                      where a.match_id = s.suspended_for_match_id and a.player_id = s.player_id);

  insert into public.match_reports
    (match_id, summary, referee_score_home, referee_score_away, status, submitted_by, submitted_at,
     corrected_by, corrected_at, correction_note, updated_at)
  values
    (p_match_id, nullif(trim(coalesce(p_summary, '')), ''), p_referee_home, p_referee_away, 'published',
     v_uid, now(), null, null, null, now())
  on conflict (match_id) do update
    set summary = excluded.summary, referee_score_home = excluded.referee_score_home,
        referee_score_away = excluded.referee_score_away, status = 'published',
        submitted_by = excluded.submitted_by, submitted_at = excluded.submitted_at,
        corrected_by = null, corrected_at = null, correction_note = null, updated_at = now();

  for r in
    select distinct s.pid
      from (select unnest(coalesce(v_prev, '{}'::uuid[])) as pid
            union
            select l.player_id as pid from public.player_ovr_ledger l where l.match_id = p_match_id) s
  loop
    perform public.recompute_player_ovr(r.pid);
  end loop;

  return jsonb_build_object('homeScore', v_home, 'awayScore', v_away);
end $$;

create or replace function public.correct_match_report(p_match_id uuid, p_note text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_prev uuid[];
  r      record;
begin
  if not public.is_super_admin() then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.matches where id = p_match_id) then raise exception 'MATCH_NOT_FOUND'; end if;
  select array_agg(distinct l.player_id) into v_prev from public.player_ovr_ledger l where l.match_id = p_match_id;
  delete from public.match_events             where match_id = p_match_id;
  delete from public.player_match_appearances where match_id = p_match_id;
  delete from public.player_ovr_ledger        where match_id = p_match_id;
  delete from public.player_suspensions       where red_card_match_id = p_match_id;
  update public.matches set status = 'live' where id = p_match_id;
  update public.match_reports
     set status = 'corrected', corrected_by = auth.uid(), corrected_at = now(),
         correction_note = nullif(trim(coalesce(p_note, '')), ''), updated_at = now()
   where match_id = p_match_id;
  for r in select unnest(coalesce(v_prev, '{}'::uuid[])) as pid loop
    perform public.recompute_player_ovr(r.pid);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 6. PERMISSIONS + LIVE UPDATES
-- ---------------------------------------------------------------------

grant usage on schema public to anon, authenticated;
grant select on all tables in schema public to anon, authenticated;
grant insert, update, delete on all tables in schema public to authenticated;

revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated, service_role;
-- the helper functions are used inside the security rules, so visitors need them too
grant execute on function public.is_super_admin(), public.is_staff(),
                         public.is_team_member(uuid), public.is_team_captain(uuid) to anon;

-- the sign-up trigger must stay runnable by Supabase's auth service
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.handle_new_user() to supabase_auth_admin;
  end if;
end $$;

-- live score updates on the website
do $$
begin
  alter publication supabase_realtime add table public.matches;
exception when duplicate_object then null;
          when undefined_object then null;
end $$;

-- =====================================================================
--  DONE.  Next: create your account on the website, then make yourself
--  the first super admin (see SETUP.md, step 3).
-- =====================================================================
