-- Newberry Build 3: people, roles and role-aware sync. Applied to Supabase.
-- Each project has a secret code. Each person has a personal secret key. The server decides what every key may read and write,
-- so money is never sent to phones that may not see it.

create table if not exists public.build3_records(
  code text not null, kind text not null, id text not null,
  data jsonb, deleted boolean not null default false, u bigint not null default 0,
  updated_at timestamptz not null default clock_timestamp(),
  primary key(code,kind,id));
alter table public.build3_records enable row level security;
revoke all on public.build3_records from anon, authenticated;
create index if not exists build3_records_pull on public.build3_records(code, updated_at);

create table if not exists public.build3_people(
  code text not null, pid text not null, name text not null, role text not null default 'other',
  perm jsonb not null, key text not null unique, active boolean not null default true,
  phone text not null default '', last_seen timestamptz, created_at timestamptz not null default now(),
  primary key(code,pid));
alter table public.build3_people enable row level security;
revoke all on public.build3_people from anon, authenticated;

-- perm = {edit: all|notes|none, money: none|view|edit, send: bool, manage: bool}
create or replace function public.b3_perm(p jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'edit', case when p->>'edit' in ('all','notes') then p->>'edit' else 'none' end,
    'money', case when p->>'money' in ('view','edit') then p->>'money' else 'none' end,
    'send', coalesce((p->>'send')::boolean,false),
    'manage', false) $$;

create or replace function public.b3_who(p_code text, p_key text) returns public.build3_people
language plpgsql security definer set search_path=public as $$
declare w public.build3_people;
begin
  if p_code is null or length(p_code)<20 or p_key is null or length(p_key)<20 then raise exception 'denied'; end if;
  select * into w from public.build3_people where code=p_code and key=p_key and active;
  if not found then raise exception 'denied'; end if;
  return w;
end $$;

create or replace function public.b3_can_write(w public.build3_people, k text, d jsonb) returns boolean
language plpgsql immutable as $$
declare e text:=w.perm->>'edit'; m text:=w.perm->>'money'; mon boolean:=coalesce(d->>'type','') in ('contract','quote','invoice');
begin
  if coalesce((w.perm->>'manage')::boolean,false) and k not in ('msgs','rcpt') then return true; end if;
  if k in ('tasks','mats','sups','plans') then return e='all'; end if;
  if k='settings' then return e='all' or m='edit'; end if;
  if k='logs' then return e in ('all','notes'); end if;
  if k in ('costs','pays') then return m='edit'; end if;
  if k='docs' then if mon then return m='edit'; else return e in ('all','notes') or m='edit'; end if; end if;
  if k in ('acts','media') then if coalesce(d->>'m','0')='1' then return m='edit'; else return e in ('all','notes') or m='edit'; end if; end if;
  if k='msgs' then return coalesce((w.perm->>'send')::boolean,false) and d->>'from'=w.pid; end if;
  if k='rcpt' then return d->>'p'=w.pid; end if;
  return false;
end $$;

create or replace function public.build3_upsert(p_code text, p_key text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare w public.build3_people; r jsonb; k text; i text; d jsonb; nd jsonb; del boolean; uu bigint; old public.build3_records; rej jsonb:='[]'::jsonb; hasmoney boolean;
begin
  w:=public.b3_who(p_code,p_key);
  hasmoney:=coalesce((w.perm->>'manage')::boolean,false) or w.perm->>'money'='edit';
  for r in select * from jsonb_array_elements(p_rows) loop
    k:=r->>'kind'; i:=r->>'id'; d:=r->'data'; if jsonb_typeof(d)='null' then d:=null; end if;
    del:=coalesce((r->>'deleted')::boolean,false); uu:=coalesce((r->>'u')::bigint,0);
    select * into old from public.build3_records where code=p_code and kind=k and id=i;
    if not public.b3_can_write(w,k,coalesce(d,old.data)) or (old.data is not null and not public.b3_can_write(w,k,old.data)) then
      rej:=rej||to_jsonb(k||'|'||i); continue;
    end if;
    nd:=d;
    if k='settings' and d is not null and not hasmoney then
      nd:=(d-'budget'-'contract')
        ||case when old.data ? 'budget' then jsonb_build_object('budget',old.data->'budget') else '{}'::jsonb end
        ||case when old.data ? 'contract' then jsonb_build_object('contract',old.data->'contract') else '{}'::jsonb end;
    end if;
    insert into public.build3_records(code,kind,id,data,deleted,u,updated_at) values(p_code,k,i,nd,del,uu,clock_timestamp())
    on conflict(code,kind,id) do update set data=excluded.data, deleted=excluded.deleted, u=excluded.u, updated_at=excluded.updated_at
      where excluded.u >= public.build3_records.u;
  end loop;
  return rej;
end $$;

create or replace function public.build3_pull(p_code text, p_key text, p_since timestamptz, p_lim int default 40)
returns table(kind text,id text,data jsonb,deleted boolean,u bigint,updated_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare w public.build3_people; mv text; mg boolean;
begin
  w:=public.b3_who(p_code,p_key); mv:=w.perm->>'money'; mg:=coalesce((w.perm->>'manage')::boolean,false);
  update public.build3_people p set last_seen=now() where p.code=p_code and p.pid=w.pid and (p.last_seen is null or p.last_seen<now()-interval '1 minute');
  return query select b.kind,b.id,
      case when b.kind='settings' and mv='none' and not mg then b.data-'budget'-'contract' else b.data end,
      b.deleted,b.u,b.updated_at
    from public.build3_records b
    where b.code=p_code and (p_since is null or b.updated_at>=p_since)
      and case b.kind
        when 'msgs' then ((b.data->'to') ? w.pid or (b.data->'to') ? 'all' or b.data->>'from'=w.pid)
        when 'rcpt' then (b.data->>'p'=w.pid or b.data->>'from'=w.pid)
        else (mg or case b.kind
          when 'costs' then mv<>'none'
          when 'pays' then mv<>'none'
          when 'docs' then mv<>'none' or coalesce(b.data->>'type','') not in ('contract','quote','invoice')
          when 'acts' then mv<>'none' or coalesce(b.data->>'m','0')<>'1'
          when 'media' then mv<>'none' or coalesce(b.data->>'m','0')<>'1'
          else true end) end
    order by b.updated_at limit least(coalesce(p_lim,40),100);
end $$;

create or replace function public.build3_start(p_code text, p_name text, p_phone text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare k text; v_pid text;
begin
  if p_code is null or length(p_code)<20 then raise exception 'bad code'; end if;
  if exists(select 1 from public.build3_people where code=p_code) then raise exception 'exists'; end if;
  k:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  v_pid:='p'||substr(md5(random()::text||clock_timestamp()::text),1,8);
  insert into public.build3_people(code,pid,name,role,perm,key,phone)
  values(p_code,v_pid,coalesce(nullif(trim(p_name),''),'Project Lead'),'lead',jsonb_build_object('edit','all','money','edit','send',true,'manage',true),k,coalesce(p_phone,''));
  return jsonb_build_object('pid',v_pid,'key',k);
end $$;

create or replace function public.build3_me(p_code text, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare w public.build3_people;
begin
  w:=public.b3_who(p_code,p_key);
  update public.build3_people p set last_seen=now() where p.code=p_code and p.pid=w.pid;
  return jsonb_build_object('pid',w.pid,'name',w.name,'role',w.role,'perm',w.perm);
end $$;

create or replace function public.build3_people_list(p_code text, p_key text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare w public.build3_people; mg boolean;
begin
  w:=public.b3_who(p_code,p_key); mg:=coalesce((w.perm->>'manage')::boolean,false);
  return coalesce((select jsonb_agg(
      case when mg then jsonb_build_object('pid',p.pid,'name',p.name,'role',p.role,'active',p.active,'phone',p.phone,'perm',p.perm,'key',p.key,'seen',p.last_seen)
      else jsonb_build_object('pid',p.pid,'name',p.name,'role',p.role,'active',p.active,'phone',p.phone) end
      order by p.created_at, p.pid)
    from public.build3_people p where p.code=p_code),'[]'::jsonb);
end $$;

create or replace function public.build3_people_set(p_code text, p_key text, p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare w public.build3_people; v_pid text; k text; cur public.build3_people;
begin
  w:=public.b3_who(p_code,p_key);
  if not coalesce((w.perm->>'manage')::boolean,false) then raise exception 'denied'; end if;
  v_pid:=nullif(p->>'pid','');
  if v_pid is null then
    v_pid:='p'||substr(md5(random()::text||clock_timestamp()::text),1,8);
    k:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
    insert into public.build3_people(code,pid,name,role,perm,key,active,phone)
    values(p_code,v_pid,coalesce(nullif(trim(p->>'name'),''),'New person'),coalesce(nullif(p->>'role',''),'other'),public.b3_perm(p->'perm'),k,coalesce((p->>'active')::boolean,true),coalesce(p->>'phone',''));
  else
    select * into cur from public.build3_people where code=p_code and pid=v_pid;
    if not found then raise exception 'unknown person'; end if;
    k:=cur.key;
    if v_pid<>w.pid and coalesce((p->>'regen')::boolean,false) then k:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''); end if;
    update public.build3_people set
      name=coalesce(nullif(trim(p->>'name'),''),name),
      role=case when v_pid=w.pid then role else coalesce(nullif(p->>'role',''),role) end,
      perm=case when v_pid=w.pid or p->'perm' is null then perm else public.b3_perm(p->'perm') end,
      active=case when v_pid=w.pid then true else coalesce((p->>'active')::boolean,active) end,
      phone=coalesce(p->>'phone',phone), key=k
    where code=p_code and pid=v_pid;
  end if;
  return jsonb_build_object('pid',v_pid,'key',k);
end $$;

revoke all on function public.b3_perm(jsonb), public.b3_who(text,text), public.b3_can_write(public.build3_people,text,jsonb) from public, anon, authenticated;
grant execute on function
  public.build3_upsert(text,text,jsonb), public.build3_pull(text,text,timestamptz,int),
  public.build3_start(text,text,text), public.build3_me(text,text),
  public.build3_people_list(text,text), public.build3_people_set(text,text,jsonb)
to anon, authenticated;
