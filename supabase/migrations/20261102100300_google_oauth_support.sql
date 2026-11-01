-- =============================================================================
-- Google OAuth support: who may connect a dentist's Google Calendar?
-- An admin of the clinic, or the dentist themself. Called by the google-oauth
-- Edge Function (as dentpilot_agent) after it has verified the staff JWT.
-- =============================================================================

create or replace function ops.can_connect_calendar(p_user_id uuid, p_professional_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ops, core, pg_temp
as $$
  select exists (
    select 1
      from staff s
      join core.professionals p on p.clinic_id = s.clinic_id
     where s.user_id = p_user_id
       and p.id = p_professional_id
       and (s.role = 'admin' or s.professional_id = p_professional_id)
  )
$$;

grant execute on function ops.can_connect_calendar(uuid, uuid) to dentpilot_agent;
revoke execute on function ops.can_connect_calendar(uuid, uuid) from public;
