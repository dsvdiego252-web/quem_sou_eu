-- 008: se alguém sai de uma partida em andamento e sobra menos de 2 jogadores,
-- a partida é encerrada (end_reason='abandoned') e quem ficou é retirado da sala.
alter table public.rooms add column if not exists end_reason text;

create or replace function public.leave_room(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rooms; nh uuid; n int;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null then return false;end if;
 update public.room_players set status='left' where room_id=p_room_id and user_id=auth.uid();
 select count(*) into n from public.room_players where room_id=p_room_id and status<>'left';
 if r.status in('playing','round_result') and n<2 then
   update public.rooms set status='finished',end_reason='abandoned',turn_user_id=null,turn_question_id=null where id=p_room_id;
   update public.room_players set status='left' where room_id=p_room_id and status<>'left';
   return true;
 end if;
 if r.host_id=auth.uid() then
   select user_id into nh from public.room_players where room_id=p_room_id and status<>'left' order by joined_at limit 1;
   if nh is not null then update public.rooms set host_id=nh where id=p_room_id;
   elsif r.status='lobby' then update public.rooms set status='finished',end_reason='abandoned' where id=p_room_id;end if;
 end if;
 if r.status='playing' then perform public.check_round_end(p_room_id,r.current_round);end if;
 return true;end$$;
revoke execute on function public.leave_room(uuid) from public, anon;
grant execute on function public.leave_room(uuid) to authenticated;
