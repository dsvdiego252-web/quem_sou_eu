-- 009: detecção de jogador offline.
-- Cada aparelho chama heartbeat(room) a cada ~15 s enquanto está numa sala. A tabela
-- room_presence fica fora da publicação Realtime para não redesenhar as telas a cada sinal.
-- heartbeat também retira quem está sem sinal há mais de 2 minutos, aplicando as mesmas
-- regras de "sair" (passa o host, passa a vez, encerra se sobrar 1 jogador).

create table if not exists public.room_presence(
 room_id uuid references public.rooms(id) on delete cascade,
 user_id uuid references public.profiles(id) on delete cascade,
 last_seen timestamptz not null default now(),
 primary key(room_id,user_id)
);
alter table public.room_presence enable row level security;
do $$ begin
 create policy presence_member_read on public.room_presence for select to authenticated using(public.is_room_member(room_id));
exception when duplicate_object then null; end $$;
revoke all on public.room_presence from anon, authenticated;
grant select on public.room_presence to authenticated;
create index if not exists room_presence_user_idx on public.room_presence(user_id);

-- Lógica de saída para qualquer jogador (usada por leave_room e pela limpeza de offline).
create or replace function public.remove_player(p_room_id uuid,p_user uuid) returns void language plpgsql security definer set search_path='' as $$
declare r public.rooms; nh uuid; n int;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or r.status='finished' then return;end if;
 update public.room_players set status='left' where room_id=p_room_id and user_id=p_user and status<>'left';
 if not found then return;end if;
 select count(*) into n from public.room_players where room_id=p_room_id and status<>'left';
 if r.status in('playing','round_result') and n<2 then
   update public.rooms set status='finished',end_reason='abandoned',turn_user_id=null,turn_question_id=null where id=p_room_id;
   update public.room_players set status='left' where room_id=p_room_id and status<>'left';
   return;
 end if;
 if r.host_id=p_user then
   select user_id into nh from public.room_players where room_id=p_room_id and status<>'left' order by joined_at limit 1;
   if nh is not null then update public.rooms set host_id=nh where id=p_room_id;
   elsif r.status='lobby' then update public.rooms set status='finished',end_reason='abandoned' where id=p_room_id;end if;
 end if;
 if r.status='playing' then perform public.check_round_end(p_room_id,r.current_round);end if;
end$$;

create or replace function public.leave_room(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.rooms where id=p_room_id) then return false;end if;
 perform public.remove_player(p_room_id,auth.uid());
 return true;end$$;

create or replace function public.heartbeat(p_room_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare x record;begin
 if not exists(select 1 from public.room_players where room_id=p_room_id and user_id=auth.uid() and status<>'left') then return;end if;
 insert into public.room_presence(room_id,user_id,last_seen) values(p_room_id,auth.uid(),now())
  on conflict(room_id,user_id) do update set last_seen=now();
 -- retira quem está sem sinal há mais de 2 minutos (ou nunca mandou sinal e entrou há mais de 2 minutos)
 for x in select rp.user_id from public.room_players rp
   left join public.room_presence pr on pr.room_id=rp.room_id and pr.user_id=rp.user_id
   where rp.room_id=p_room_id and rp.status<>'left' and rp.user_id<>auth.uid()
     and coalesce(pr.last_seen,rp.joined_at)<now()-interval '2 minutes' loop
   perform public.remove_player(p_room_id,x.user_id);
 end loop;
end$$;

revoke execute on function public.remove_player(uuid,uuid) from public, anon, authenticated;
revoke execute on function public.leave_room(uuid),public.heartbeat(uuid) from public, anon;
grant execute on function public.leave_room(uuid),public.heartbeat(uuid) to authenticated;

-- Entrar (ou voltar) para a sala já conta como sinal de vida.
create or replace function public.room_players_touch_presence() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status<>'left' then
   insert into public.room_presence(room_id,user_id,last_seen) values(new.room_id,new.user_id,now())
    on conflict(room_id,user_id) do update set last_seen=now();
 end if;
 return null;end$$;
revoke execute on function public.room_players_touch_presence() from public, anon, authenticated;
create or replace trigger room_players_touch_presence after insert or update of status on public.room_players
 for each row execute function public.room_players_touch_presence();

-- Salas em andamento no momento da migration: todos começam "vistos agora".
insert into public.room_presence(room_id,user_id,last_seen)
 select rp.room_id,rp.user_id,now() from public.room_players rp join public.rooms r on r.id=rp.room_id
 where r.status<>'finished' and rp.status<>'left'
on conflict(room_id,user_id) do update set last_seen=now();
