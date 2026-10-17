-- Newberry Build: shared project storage. Run once in the Supabase SQL editor.
-- Each project is identified by a long secret code (the share link). Nobody can read the table directly.
create table if not exists public.build_records(
  code text not null, kind text not null, id text not null,
  data jsonb, deleted boolean not null default false, u bigint not null default 0,
  updated_at timestamptz not null default clock_timestamp(),
  primary key(code,kind,id));
alter table public.build_records enable row level security;
revoke all on public.build_records from anon, authenticated;
create index if not exists build_records_pull on public.build_records(code, updated_at);

create or replace function public.build_upsert(p_code text, p_rows jsonb) returns void
language plpgsql security definer set search_path=public as $$
begin
  if p_code is null or length(p_code)<20 then raise exception 'bad code'; end if;
  insert into public.build_records(code,kind,id,data,deleted,u,updated_at)
  select p_code, r->>'kind', r->>'id', r->'data', coalesce((r->>'deleted')::boolean,false), coalesce((r->>'u')::bigint,0), clock_timestamp()
  from jsonb_array_elements(p_rows) r
  on conflict(code,kind,id) do update
    set data=excluded.data, deleted=excluded.deleted, u=excluded.u, updated_at=excluded.updated_at
    where excluded.u >= public.build_records.u;
end $$;

create or replace function public.build_pull(p_code text, p_since timestamptz, p_lim int default 40)
returns table(kind text,id text,data jsonb,deleted boolean,u bigint,updated_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
  if p_code is null or length(p_code)<20 then raise exception 'bad code'; end if;
  return query select b.kind,b.id,b.data,b.deleted,b.u,b.updated_at from public.build_records b
    where b.code=p_code and (p_since is null or b.updated_at>=p_since)
    order by b.updated_at limit least(coalesce(p_lim,40),100);
end $$;

grant execute on function public.build_upsert(text,jsonb), public.build_pull(text,timestamptz,int) to anon, authenticated;
