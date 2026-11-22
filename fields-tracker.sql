-- Newberry Fields: shared copy for the team, people and access by area.
-- APPLIED to Supabase on 2026-11-22 with the user's yes.
-- Same pattern as Newberry Build 3 (build3-tracker.sql): each project has a secret code, each person a personal secret key,
-- and the server decides what every key may read and write, so money is never sent to phones that may not see it.
--
-- Areas and levels (perm.areas): 0 = no access (not sent), 1 = see only, 2 = can change.
--   tasks  tasks and the contractors list (phases and field settings: Project Lead only)      log   site log, snags
--   diary  daily diary                           mats  materials, deliveries
--   docs   plans and documents                   money budget, contractors' payments, bills, expenses, quotes, slips
--   upd    updates (1 = receive, 2 = send)
-- perm.manage = Project Lead: everything, plus people and access.

create table if not exists public.fields_records(
  code text not null, kind text not null, id text not null,
  data jsonb, deleted boolean not null default false, u bigint not null default 0,
  updated_at timestamptz not null default clock_timestamp(),
  primary key(code,kind,id));
alter table public.fields_records enable row level security;
revoke all on public.fields_records from anon, authenticated;
create index if not exists fields_records_pull on public.fields_records(code, updated_at);

create table if not exists public.fields_people(
  code text not null, pid text not null, name text not null, role text not null default 'other',
  perm jsonb not null, key text not null unique, active boolean not null default true,
  phone text not null default '', last_seen timestamptz, created_at timestamptz not null default now(),
  primary key(code,pid));
alter table public.fields_people enable row level security;
revoke all on public.fields_people from anon, authenticated;

-- clean levels; manage is never granted through this (only fields_start makes the Lead)
create or replace function public.fields_perm(p jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object('areas', jsonb_build_object(
    'tasks', least(greatest(coalesce((p->'areas'->>'tasks')::int,1),1),2),
    'log',   least(greatest(coalesce((p->'areas'->>'log')::int,1),0),2),
    'diary', least(greatest(coalesce((p->'areas'->>'diary')::int,1),0),2),
    'mats',  least(greatest(coalesce((p->'areas'->>'mats')::int,1),0),2),
    'docs',  least(greatest(coalesce((p->'areas'->>'docs')::int,1),0),2),
    'money', least(greatest(coalesce((p->'areas'->>'money')::int,0),0),2),
    'upd',   least(greatest(coalesce((p->'areas'->>'upd')::int,1),1),2)),
   'manage', false) $$;

create or replace function public.fields_lvl(w public.fields_people, a text) returns int language sql immutable as $$
  select case when coalesce((w.perm->>'manage')::boolean,false) then 2 else coalesce((w.perm->'areas'->>a)::int,0) end $$;

-- which area a kind of record belongs to
create or replace function public.fields_area(k text, d jsonb) returns text language sql immutable as $$
  select case
    when k in ('field','tasks','cons') then 'tasks'
    when k in ('logs','snags') then 'log'
    when k='diary' then 'diary'
    when k in ('mats','deliv') then 'mats'
    when k='docs' then case when coalesce(d->>'m','0')='1' then 'money' else 'docs' end
    when k in ('mset','mcons','msups','mexps','quotes','slips') then 'money'
    when k in ('media','acts') then case when coalesce(d->>'m','0')='1' then 'money' else 'any' end
    when k in ('msgs','rcpt') then 'upd'
    else 'none' end $$;

create or replace function public.fields_who(p_code text, p_key text) returns public.fields_people
language plpgsql security definer set search_path=public as $$
declare w public.fields_people;
begin
  if p_code is null or length(p_code)<20 or p_key is null or length(p_key)<20 then raise exception 'denied'; end if;
  select * into w from public.fields_people where code=p_code and key=p_key and active;
  if not found then raise exception 'denied'; end if;
  return w;
end $$;

create or replace function public.fields_can_write(w public.fields_people, k text, d jsonb) returns boolean
language plpgsql immutable as $$
declare a text:=public.fields_area(k,d);
begin
  -- a field's name, settings and phases: only the Project Lead (migration fields_tracker_field_lead_only)
  if k='field' then return coalesce((w.perm->>'manage')::boolean,false); end if;
  if k='msgs' then return public.fields_lvl(w,'upd')=2 and d->>'from'=w.pid; end if;
  if k='rcpt' then return d->>'p'=w.pid; end if;
  if a='any' then return coalesce((w.perm->>'manage')::boolean,false)
    or greatest(public.fields_lvl(w,'tasks'),public.fields_lvl(w,'log'),public.fields_lvl(w,'diary'),public.fields_lvl(w,'mats'),public.fields_lvl(w,'docs'))=2; end if;
  if a='none' then return false; end if;
  return public.fields_lvl(w,a)=2;
end $$;

create or replace function public.fields_can_read(w public.fields_people, k text, d jsonb) returns boolean
language plpgsql immutable as $$
declare a text:=public.fields_area(k,d);
begin
  if coalesce((w.perm->>'manage')::boolean,false) and k not in ('msgs','rcpt') then return true; end if;
  if k='msgs' then return (d->'to') ? w.pid or (d->'to') ? 'all' or d->>'from'=w.pid; end if;
  if k='rcpt' then return d->>'p'=w.pid or d->>'from'=w.pid; end if;
  if a='any' then return true; end if;
  if a='none' then return false; end if;
  return public.fields_lvl(w,a)>=1;
end $$;

create or replace function public.fields_upsert(p_code text, p_key text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare w public.fields_people; r jsonb; k text; i text; d jsonb; del boolean; uu bigint; old public.fields_records; rej jsonb:='[]'::jsonb;
begin
  w:=public.fields_who(p_code,p_key);
  for r in select * from jsonb_array_elements(p_rows) loop
    k:=r->>'kind'; i:=r->>'id'; d:=r->'data'; if jsonb_typeof(d)='null' then d:=null; end if;
    del:=coalesce((r->>'deleted')::boolean,false); uu:=coalesce((r->>'u')::bigint,0);
    if k is null or i is null or length(k)>20 or length(i)>80 then rej:=rej||to_jsonb(coalesce(k,'')||'|'||coalesce(i,'')); continue; end if;
    select * into old from public.fields_records where code=p_code and kind=k and id=i;
    if not public.fields_can_write(w,k,coalesce(d,old.data)) or (old.data is not null and not public.fields_can_write(w,k,old.data)) then
      rej:=rej||to_jsonb(k||'|'||i); continue;
    end if;
    insert into public.fields_records(code,kind,id,data,deleted,u,updated_at) values(p_code,k,i,d,del,uu,clock_timestamp())
    on conflict(code,kind,id) do update set data=excluded.data, deleted=excluded.deleted, u=excluded.u, updated_at=excluded.updated_at
      where excluded.u >= public.fields_records.u;
  end loop;
  return rej;
end $$;

create or replace function public.fields_pull(p_code text, p_key text, p_since timestamptz, p_lim int default 60)
returns table(kind text,id text,data jsonb,deleted boolean,u bigint,updated_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare w public.fields_people;
begin
  w:=public.fields_who(p_code,p_key);
  update public.fields_people p set last_seen=now() where p.code=p_code and p.pid=w.pid and (p.last_seen is null or p.last_seen<now()-interval '1 minute');
  return query select b.kind,b.id,b.data,b.deleted,b.u,b.updated_at
    from public.fields_records b
    where b.code=p_code and (p_since is null or b.updated_at>=p_since)
      and public.fields_can_read(w,b.kind,b.data)
    order by b.updated_at limit least(coalesce(p_lim,60),200);
end $$;

-- the Project Lead starts sharing: creates the project and gets the first key
create or replace function public.fields_start(p_code text, p_name text, p_phone text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare k text; v_pid text;
begin
  if p_code is null or length(p_code)<20 then raise exception 'bad code'; end if;
  if exists(select 1 from public.fields_people where code=p_code) then raise exception 'exists'; end if;
  k:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  v_pid:='p'||substr(md5(random()::text||clock_timestamp()::text),1,8);
  insert into public.fields_people(code,pid,name,role,perm,key,phone)
  values(p_code,v_pid,coalesce(nullif(trim(p_name),''),'Project Lead'),'lead',
    jsonb_build_object('areas',jsonb_build_object('tasks',2,'log',2,'diary',2,'mats',2,'docs',2,'money',2,'upd',2),'manage',true),k,coalesce(p_phone,''));
  return jsonb_build_object('pid',v_pid,'key',k);
end $$;

create or replace function public.fields_me(p_code text, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare w public.fields_people;
begin
  w:=public.fields_who(p_code,p_key);
  update public.fields_people p set last_seen=now() where p.code=p_code and p.pid=w.pid;
  return jsonb_build_object('pid',w.pid,'name',w.name,'role',w.role,'perm',w.perm);
end $$;

create or replace function public.fields_people_list(p_code text, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare w public.fields_people; mg boolean;
begin
  w:=public.fields_who(p_code,p_key); mg:=coalesce((w.perm->>'manage')::boolean,false);
  return coalesce((select jsonb_agg(
      case when mg then jsonb_build_object('pid',p.pid,'name',p.name,'role',p.role,'active',p.active,'phone',p.phone,'perm',p.perm,'key',p.key,'seen',p.last_seen)
      else jsonb_build_object('pid',p.pid,'name',p.name,'role',p.role,'active',p.active) end
      order by p.created_at, p.pid)
    from public.fields_people p where p.code=p_code),'[]'::jsonb);
end $$;

create or replace function public.fields_people_set(p_code text, p_key text, p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare w public.fields_people; v_pid text; k text; cur public.fields_people;
begin
  w:=public.fields_who(p_code,p_key);
  if not coalesce((w.perm->>'manage')::boolean,false) then raise exception 'denied'; end if;
  v_pid:=nullif(p->>'pid','');
  if v_pid is null then
    v_pid:='p'||substr(md5(random()::text||clock_timestamp()::text),1,8);
    k:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
    insert into public.fields_people(code,pid,name,role,perm,key,active,phone)
    values(p_code,v_pid,coalesce(nullif(trim(p->>'name'),''),'New person'),coalesce(nullif(p->>'role',''),'other'),public.fields_perm(p->'perm'),k,coalesce((p->>'active')::boolean,true),coalesce(p->>'phone',''));
  else
    select * into cur from public.fields_people where code=p_code and pid=v_pid;
    if not found then raise exception 'unknown person'; end if;
    k:=cur.key;
    if v_pid<>w.pid and coalesce((p->>'regen')::boolean,false) then k:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''); end if;
    update public.fields_people set
      name=coalesce(nullif(trim(p->>'name'),''),name),
      role=case when v_pid=w.pid then role else coalesce(nullif(p->>'role',''),role) end,
      perm=case when v_pid=w.pid or p->'perm' is null then perm else public.fields_perm(p->'perm') end,
      active=case when v_pid=w.pid then true else coalesce((p->>'active')::boolean,active) end,
      phone=coalesce(p->>'phone',phone), key=k
    where code=p_code and pid=v_pid;
  end if;
  return jsonb_build_object('pid',v_pid,'key',k);
end $$;

revoke all on function public.fields_perm(jsonb), public.fields_lvl(public.fields_people,text), public.fields_area(text,jsonb),
  public.fields_who(text,text), public.fields_can_write(public.fields_people,text,jsonb), public.fields_can_read(public.fields_people,text,jsonb)
  from public, anon, authenticated;
grant execute on function
  public.fields_upsert(text,text,jsonb), public.fields_pull(text,text,timestamptz,int),
  public.fields_start(text,text,text), public.fields_me(text,text),
  public.fields_people_list(text,text), public.fields_people_set(text,text,jsonb)
to anon, authenticated;

-- Storage for photos, plans and documents, slips and voice notes: a public bucket whose file names are random, like build-media.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('fields-media','fields-media',true,52428800,
  array['image/jpeg','image/png','image/webp','image/heic','image/gif','video/mp4','video/quicktime','video/webm','audio/webm','audio/mp4','audio/mpeg','audio/ogg','audio/aac','application/pdf','application/octet-stream'])
on conflict(id) do nothing;
create policy "fields-media upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id='fields-media' and length(name)<200);

-- Applied 2026-11-22 as migrations fields_tracker and fields_tracker_search_path (fixed search path on the helper functions):
alter function public.fields_perm(jsonb) set search_path=public;
alter function public.fields_lvl(public.fields_people,text) set search_path=public;
alter function public.fields_area(text,jsonb) set search_path=public;
alter function public.fields_can_write(public.fields_people,text,jsonb) set search_path=public;
alter function public.fields_can_read(public.fields_people,text,jsonb) set search_path=public;
