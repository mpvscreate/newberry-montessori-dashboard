-- Newberry Build 3: the final (green) tick on a task belongs to the Project Lead. Replaces build3_upsert from build3-tracker.sql. Applied to Supabase.
create or replace function public.build3_upsert(p_code text, p_key text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare w public.build3_people; r jsonb; k text; i text; d jsonb; nd jsonb; del boolean; uu bigint; old public.build3_records; rej jsonb:='[]'::jsonb; hasmoney boolean; isl boolean;
begin
  w:=public.b3_who(p_code,p_key);
  isl:=coalesce((w.perm->>'manage')::boolean,false);
  hasmoney:=isl or w.perm->>'money'='edit';
  for r in select * from jsonb_array_elements(p_rows) loop
    k:=r->>'kind'; i:=r->>'id'; d:=r->'data'; if jsonb_typeof(d)='null' then d:=null; end if;
    del:=coalesce((r->>'deleted')::boolean,false); uu:=coalesce((r->>'u')::bigint,0);
    select * into old from public.build3_records where code=p_code and kind=k and id=i;
    if not public.b3_can_write(w,k,coalesce(d,old.data)) or (old.data is not null and not public.b3_can_write(w,k,old.data)) then
      rej:=rej||to_jsonb(k||'|'||i); continue;
    end if;
    -- the final (green) tick belongs to the Project Lead
    if k='tasks' and not isl and d is not null then
      if (d->>'status')='done' and coalesce(old.data->>'status','')<>'done' then rej:=rej||to_jsonb(k||'|'||i); continue; end if;
      if coalesce(old.data->>'status','')='done' and (d->>'status')<>'done' then rej:=rej||to_jsonb(k||'|'||i); continue; end if;
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
