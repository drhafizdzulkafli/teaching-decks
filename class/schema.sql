-- ============================================================================
--  Class portal database (Supabase / PostgreSQL)
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run again: it updates functions and policies without deleting data.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- code generators -------------------------------------------------
create or replace function public.gen_code(n int) returns text
language plpgsql volatile as $$
declare
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';   -- no 0/O, 1/I/L
  result text := '';
begin
  for i in 1..n loop
    result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return result;
end $$;

create or replace function public.gen_class_code() returns text
language sql volatile as $$ select public.gen_code(4) || '-' || public.gen_code(4) $$;

-- ---------- tables -----------------------------------------------------------
create table if not exists public.classes (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  code        text not null unique default public.gen_class_code(),
  active      boolean not null default true,      -- false = no new sign-ups with this code
  created_at  timestamptz not null default now()
);

create table if not exists public.modules (
  id                 uuid primary key default gen_random_uuid(),
  title              text not null,
  category           text,
  description        text,
  deck_url           text,                         -- e.g. decks/Triage/xyz.html
  questions_per_quiz int  not null default 10 check (questions_per_quiz between 1 and 100),
  pass_mark          int  not null default 80 check (pass_mark between 0 and 100),
  show_answers       boolean not null default true, -- show correct answers after submitting
  created_at         timestamptz not null default now()
);

create table if not exists public.class_modules (
  class_id  uuid not null references public.classes(id) on delete cascade,
  module_id uuid not null references public.modules(id) on delete cascade,
  position  int  not null default 0,
  primary key (class_id, module_id)
);

create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null,
  matric      text,
  category    text,
  institution text,
  email       text,
  is_admin    boolean not null default false,
  consent_at  timestamptz,
  created_at  timestamptz not null default now()
);

create table if not exists public.enrollments (
  user_id   uuid not null references public.profiles(id) on delete cascade,
  class_id  uuid not null references public.classes(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (user_id, class_id)
);

create table if not exists public.questions (
  id          uuid primary key default gen_random_uuid(),
  module_id   uuid not null references public.modules(id) on delete cascade,
  stem        text not null,
  options     jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 8),
  answer      int  not null check (answer >= 0),     -- 0 = first option
  explanation text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.attempts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  module_id    uuid not null references public.modules(id) on delete cascade,
  question_ids uuid[] not null,
  answers      jsonb,
  score        int,
  total        int not null,
  passed       boolean,
  started_at   timestamptz not null default now(),
  submitted_at timestamptz
);
create index if not exists attempts_user_idx on public.attempts(user_id, module_id);

create table if not exists public.certificates (
  id        text primary key default public.gen_code(10),
  user_id   uuid not null references public.profiles(id) on delete cascade,
  class_id  uuid not null references public.classes(id) on delete cascade,
  issued_at timestamptz not null default now(),
  unique (user_id, class_id)
);

create table if not exists public.activity (
  id      bigserial primary key,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  path    text not null check (length(path) < 500),
  title   text check (length(title) < 300),
  at      timestamptz not null default now()
);
create index if not exists activity_user_idx on public.activity(user_id, at desc);

-- ---------- Data API access (rows are still filtered by the policies below) ---
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
revoke all on all tables in schema public from anon;   -- visitors use only the two public functions

-- ---------- helper: am I an admin? -------------------------------------------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- ---------- row-level security ----------------------------------------------
alter table public.classes       enable row level security;
alter table public.modules       enable row level security;
alter table public.class_modules enable row level security;
alter table public.profiles      enable row level security;
alter table public.enrollments   enable row level security;
alter table public.questions     enable row level security;
alter table public.attempts      enable row level security;
alter table public.certificates  enable row level security;
alter table public.activity      enable row level security;

drop policy if exists classes_read   on public.classes;
drop policy if exists classes_admin  on public.classes;
create policy classes_read  on public.classes for select to authenticated
  using (public.is_admin() or exists (select 1 from public.enrollments e where e.class_id = classes.id and e.user_id = auth.uid()));
create policy classes_admin on public.classes for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists modules_read  on public.modules;
drop policy if exists modules_admin on public.modules;
create policy modules_read  on public.modules for select to authenticated using (true);
create policy modules_admin on public.modules for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists cm_read  on public.class_modules;
drop policy if exists cm_admin on public.class_modules;
create policy cm_read  on public.class_modules for select to authenticated using (true);
create policy cm_admin on public.class_modules for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists profiles_read   on public.profiles;
drop policy if exists profiles_update on public.profiles;
drop policy if exists profiles_delete on public.profiles;
create policy profiles_read   on public.profiles for select to authenticated using (id = auth.uid() or public.is_admin());
create policy profiles_update on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy profiles_delete on public.profiles for delete to authenticated using (public.is_admin());

drop policy if exists enr_read  on public.enrollments;
drop policy if exists enr_admin on public.enrollments;
create policy enr_read  on public.enrollments for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy enr_admin on public.enrollments for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists q_admin on public.questions;          -- students never read questions directly
create policy q_admin on public.questions for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists att_read  on public.attempts;
drop policy if exists att_admin on public.attempts;
create policy att_read  on public.attempts for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy att_admin on public.attempts for delete to authenticated using (public.is_admin());

drop policy if exists cert_read  on public.certificates;
drop policy if exists cert_admin on public.certificates;
create policy cert_read  on public.certificates for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy cert_admin on public.certificates for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists act_insert on public.activity;
drop policy if exists act_read   on public.activity;
create policy act_insert on public.activity for insert to authenticated with check (user_id = auth.uid());
create policy act_read   on public.activity for select to authenticated using (public.is_admin());

-- ---------- sign-up: validate class code, create profile + enrolment --------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  c uuid;
begin
  select id into c from public.classes
   where upper(code) = upper(trim(m->>'class_code')) and active;
  if c is null then
    raise exception 'Invalid or closed class code';
  end if;
  if coalesce((m->>'consent')::boolean, false) is not true then
    raise exception 'Consent is required';
  end if;
  insert into public.profiles (id, full_name, matric, category, institution, email, consent_at)
  values (new.id, left(trim(m->>'full_name'), 120), nullif(left(trim(m->>'matric'), 40), ''),
          left(m->>'category', 80), left(m->>'institution', 120), new.email, now());
  insert into public.enrollments (user_id, class_id) values (new.id, c);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- functions the web pages call ------------------------------------
-- Look up a class code before registering (returns the class name, or null)
create or replace function public.check_class_code(p_code text) returns text
language sql stable security definer set search_path = public as $$
  select name from public.classes where upper(code) = upper(trim(p_code)) and active
$$;

-- A logged-in student joins another class
create or replace function public.join_class(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare c public.classes;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select * into c from public.classes where upper(code) = upper(trim(p_code)) and active;
  if not found then raise exception 'Invalid or closed class code'; end if;
  insert into public.enrollments (user_id, class_id) values (auth.uid(), c.id) on conflict do nothing;
  return c.name;
end $$;

-- Start a quiz: random questions from the bank, without the answers
create or replace function public.start_quiz(p_module uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  m    public.modules;
  qids uuid[];
  aid  uuid;
begin
  if auth.uid() is null then raise exception 'Please log in'; end if;
  select * into m from public.modules where id = p_module;
  if not found then raise exception 'Module not found'; end if;
  if not public.is_admin() and not exists (
       select 1 from public.enrollments e
       join public.class_modules cm on cm.class_id = e.class_id
       where e.user_id = auth.uid() and cm.module_id = p_module) then
    raise exception 'This module is not part of your class';
  end if;
  select array_agg(id) into qids from (
    select id from public.questions
     where module_id = p_module and active
     order by random() limit m.questions_per_quiz) s;
  if qids is null then raise exception 'This quiz has no questions yet'; end if;

  insert into public.attempts (user_id, module_id, question_ids, total)
  values (auth.uid(), p_module, qids, array_length(qids, 1)) returning id into aid;

  return json_build_object(
    'attempt_id', aid,
    'module', json_build_object('id', m.id, 'title', m.title, 'pass_mark', m.pass_mark),
    'questions', (select json_agg(json_build_object('id', q.id, 'stem', q.stem, 'options', q.options)
                                  order by array_position(qids, q.id))
                    from public.questions q where q.id = any(qids)));
end $$;

-- Submit answers ({"question-id": chosen_index, ...}); grades on the server
create or replace function public.submit_quiz(p_attempt uuid, p_answers jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  a      public.attempts;
  m      public.modules;
  sc     int;
  ok     boolean;
  review json;
begin
  select * into a from public.attempts where id = p_attempt and user_id = auth.uid() for update;
  if not found then raise exception 'Attempt not found'; end if;
  if a.submitted_at is not null then raise exception 'This attempt was already submitted'; end if;
  select * into m from public.modules where id = a.module_id;

  select count(*) into sc from public.questions q
   where q.id = any(a.question_ids)
     and (p_answers->>(q.id::text)) ~ '^\d+$'
     and (p_answers->>(q.id::text))::int = q.answer;
  ok := sc * 100 >= m.pass_mark * a.total;

  update public.attempts set answers = p_answers, score = sc, passed = ok, submitted_at = now()
   where id = a.id;

  select json_agg(json_build_object(
           'id', q.id,
           'correct', (p_answers->>(q.id::text)) = q.answer::text,
           'answer', case when m.show_answers then q.answer end,
           'explanation', case when m.show_answers then q.explanation end)
         order by array_position(a.question_ids, q.id))
    into review
    from public.questions q where q.id = any(a.question_ids);

  -- Issue a certificate for every class whose modules are now all passed
  insert into public.certificates (user_id, class_id)
  select e.user_id, e.class_id from public.enrollments e
   where e.user_id = auth.uid()
     and exists (select 1 from public.class_modules cm where cm.class_id = e.class_id)
     and not exists (
       select 1 from public.class_modules cm
        where cm.class_id = e.class_id
          and not exists (select 1 from public.attempts t
                           where t.user_id = e.user_id and t.module_id = cm.module_id and t.passed))
  on conflict (user_id, class_id) do nothing;

  return json_build_object('score', sc, 'total', a.total, 'passed', ok,
                           'pass_mark', m.pass_mark, 'review', review);
end $$;

-- Public certificate check (used by the QR code)
create or replace function public.verify_certificate(p_id text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', c.id, 'full_name', p.full_name, 'matric', p.matric, 'institution', p.institution,
    'class_name', k.name, 'issued_at', c.issued_at,
    'modules', (select json_agg(mo.title order by cm.position, mo.title)
                  from public.class_modules cm join public.modules mo on mo.id = cm.module_id
                 where cm.class_id = k.id))
  from public.certificates c
  join public.profiles p on p.id = c.user_id
  join public.classes  k on k.id = c.class_id
  where c.id = upper(trim(p_id))
$$;

-- Admin: set a temporary password for a student who forgot theirs
create or replace function public.admin_set_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if length(p_password) < 8 then raise exception 'Password must be at least 8 characters'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
                        updated_at = now()
   where id = p_user;
end $$;

-- Admin: remove a participant completely (account + all their records)
create or replace function public.admin_delete_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if p_user = auth.uid() then raise exception 'You cannot delete your own account here'; end if;
  delete from auth.users where id = p_user;
end $$;

revoke execute on function public.admin_set_password(uuid, text) from anon, public;
revoke execute on function public.admin_delete_user(uuid)        from anon, public;
revoke execute on function public.start_quiz(uuid)               from anon, public;
revoke execute on function public.submit_quiz(uuid, jsonb)       from anon, public;
revoke execute on function public.join_class(text)               from anon, public;
grant  execute on function public.admin_set_password(uuid, text) to authenticated;
grant  execute on function public.admin_delete_user(uuid)        to authenticated;
grant  execute on function public.start_quiz(uuid)               to authenticated;
grant  execute on function public.submit_quiz(uuid, jsonb)       to authenticated;
grant  execute on function public.join_class(text)               to authenticated;
grant  execute on function public.check_class_code(text)         to anon, authenticated;
grant  execute on function public.verify_certificate(text)       to anon, authenticated;

-- ---------- starter data (only added once) -----------------------------------
insert into public.classes (name)
select 'Staff & facilitators'
where not exists (select 1 from public.classes);

with m as (
  insert into public.modules (title, category, description, deck_url, questions_per_quiz, pass_mark)
  select 'Sepsis Early Recognition (sample)', 'Resuscitation',
         'Sample module to try the system. Replace with your own.',
         'decks/Resuscitation/Sepsis-Early-Recognition.html', 5, 80
  where not exists (select 1 from public.modules)
  returning id
), q as (
  insert into public.questions (module_id, stem, options, answer, explanation)
  select m.id, v.stem, v.options::jsonb, v.answer, v.expl from m, (values
    ('Which qSOFA criterion uses a respiratory rate threshold?', '["RR ≥ 18","RR ≥ 20","RR ≥ 22","RR ≥ 30"]', 2, 'qSOFA: RR ≥ 22, altered mentation, SBP ≤ 100 mmHg.'),
    ('Initial crystalloid volume suggested for sepsis-induced hypotension is:', '["10 mL/kg","20 mL/kg","30 mL/kg","50 mL/kg"]', 2, 'Surviving Sepsis Campaign suggests at least 30 mL/kg within the first 3 hours.'),
    ('A lactate level above which value suggests tissue hypoperfusion in sepsis?', '["1 mmol/L","2 mmol/L","4 mmol/L","6 mmol/L"]', 1, 'Lactate > 2 mmol/L is abnormal; ≥ 4 mmol/L indicates high risk.'),
    ('First-line vasopressor in septic shock is:', '["Dopamine","Adrenaline","Noradrenaline","Phenylephrine"]', 2, 'Noradrenaline is first-line; target MAP ≥ 65 mmHg.'),
    ('Antibiotics for suspected septic shock should be given within:', '["1 hour","3 hours","6 hours","12 hours"]', 0, 'Give within 1 hour of recognition when shock is likely.')
  ) as v(stem, options, answer, expl)
  returning module_id
)
insert into public.class_modules (class_id, module_id)
select (select id from public.classes order by created_at limit 1), module_id from q group by module_id;

-- Show the starter class code (use it to register your own account)
select name, code from public.classes order by created_at;
