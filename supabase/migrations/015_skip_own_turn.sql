-- 015: quem está na vez pode pular a própria vez (o botão só aparece para essa pessoa).
-- Os demais continuam podendo pular apenas quando o tempo da vez acabou; o host mantém o poder.
create or replace function public.skip_turn(p_room_id uuid,p_turn_started_at timestamptz) returns boolean
language plpgsql security definer set search_path='' as $$
declare r public.rooms;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 if r.status<>'playing' then return false;end if;
 if r.turn_started_at is distinct from p_turn_started_at then return false;end if;
 if r.turn_user_id is distinct from auth.uid() and r.host_id<>auth.uid()
    and not (r.turn_seconds>0 and now()>=r.turn_started_at+make_interval(secs=>r.turn_seconds)) then
   raise exception 'Só quem está na vez pode pular antes do tempo acabar';end if;
 perform public.advance_turn(p_room_id); return true;end$$;
revoke execute on function public.skip_turn(uuid,timestamptz) from public, anon;
grant execute on function public.skip_turn(uuid,timestamptz) to authenticated;
