alter table public.team_members
  add column invited_at timestamptz,
  add column accepted_at timestamptz,
  add column invited_by uuid references auth.users(id) on delete set null;

update public.team_members
set accepted_at = created_at
where accepted_at is null;

comment on column public.team_members.invited_at is 'When an administrator sent the current account invitation.';
comment on column public.team_members.accepted_at is 'When the invited member completed password setup.';
comment on column public.team_members.invited_by is 'Administrator who created the invitation.';
