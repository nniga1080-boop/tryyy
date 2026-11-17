-- =====================================================================
--  ESST — performance indexes (review, then run in Supabase -> SQL Editor)
--  Safe to re-run (IF NOT EXISTS). Each index is tied to a real query in
--  the site or to a security rule that runs per row. Nothing here changes data.
-- =====================================================================

-- profiles: Players page + admin Managers list sort by created_at
create index if not exists profiles_created_idx            on public.profiles (created_at);

-- matches: "next match of a team" (submit_match_report) + every team page filter
create index if not exists matches_home_kickoff_idx        on public.matches (home_team_id, kickoff_at);
create index if not exists matches_away_kickoff_idx        on public.matches (away_team_id, kickoff_at);

-- team_memberships: is_team_member()/is_team_captain() run inside security rules
-- for every row; roster list filters team_id + status='active'
create index if not exists memberships_team_player_active_idx on public.team_memberships (team_id, player_id) where status = 'active';

-- requests: "my requests" (player_id/requester_id/user_id), captain inbox (team_id) newest first
create index if not exists join_requests_team_created_idx     on public.team_join_requests (team_id, created_at desc);
create index if not exists join_requests_player_created_idx   on public.team_join_requests (player_id, created_at desc);
create index if not exists creation_requests_requester_idx    on public.team_creation_requests (requester_id, created_at desc);
create index if not exists transfer_requests_player_idx       on public.team_transfer_requests (player_id);
create index if not exists transfer_requests_from_team_idx    on public.team_transfer_requests (from_team_id);
create index if not exists transfer_requests_to_team_idx      on public.team_transfer_requests (to_team_id);
create index if not exists staff_requests_user_idx            on public.staff_access_requests (user_id);

-- match page: events of one match in order (replaces the plain match_id index)
create index if not exists match_events_match_seq_idx      on public.match_events (match_id, sequence);

-- player page: OVR history in order; ledger rows per match (recompute_player_ovr)
create index if not exists ovr_ledger_player_created_idx   on public.player_ovr_ledger (player_id, created_at);
create index if not exists ovr_ledger_match_idx            on public.player_ovr_ledger (match_id);

-- lineup page: pending suspensions for one match; report rewrite deletes by red_card_match_id
create index if not exists suspensions_next_match_idx      on public.player_suspensions (suspended_for_match_id) where status = 'pending';
create index if not exists suspensions_red_match_idx       on public.player_suspensions (red_card_match_id);

-- notifications: my notifications, newest first
create index if not exists notifications_user_created_idx  on public.notifications (user_id, created_at desc);

-- team space: live posts of a team, newest first
create index if not exists team_posts_team_created_idx     on public.team_posts (team_id, created_at desc) where deleted_at is null;

-- admin audit log: newest 200
create index if not exists audit_logs_changed_idx          on public.match_audit_logs (changed_at desc);

-- Left out on purpose: teams, tournament_settings and the admin approval queues'
-- created_at sort (tens of rows: Postgres scans them faster than any index).
-- Older single-column indexes (match_events_match_idx, ovr_ledger_player_idx,
-- notifications_user_idx, team_posts_team_idx) are now redundant; drop later if you like.
