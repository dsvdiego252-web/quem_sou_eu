-- 005: palpite ("JÁ SEI QUEM SOU!") só na própria vez; errar passa a vez.
create or replace function public.submit_guess(p_room_id uuid,p_round_no int,p_character_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.rooms; s public.secret_characters; rp public.room_players; total int; place int; qcount int; base int:=0; bonus int:=0; cname text; gname text;begin
 if not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 select * into r from public.rooms where id=p_room_id for update;
 if r.status<>'playing' or r.current_round<>p_round_no then raise exception 'A rodada não está em andamento';end if;
 if r.turn_user_id is distinct from auth.uid() then raise exception 'Você só pode tentar adivinhar na sua vez';end if;
 select * into rp from public.room_players where room_id=p_room_id and user_id=auth.uid() for update;
 if rp.status='left' then raise exception 'Você saiu da sala';end if;
 select * into s from public.secret_characters where room_id=p_room_id and round_no=p_round_no and player_id=auth.uid() for update;
 if not found then raise exception 'Você não tem identidade nesta rodada';end if;
 select name into cname from public.characters where id=s.character_id;
 if s.revealed then return jsonb_build_object('correct',true,'character_name',cname,'already',true);end if;
 select name into gname from public.characters where id=p_character_id;
 if gname is null or lower(gname)<>lower(cname) then
   update public.secret_characters set wrong_attempts=wrong_attempts+1 where room_id=p_room_id and round_no=p_round_no and player_id=auth.uid();
   perform public.advance_turn(p_room_id);
   return jsonb_build_object('correct',false,'turn_passed',true);
 end if;
 select count(*) into total from public.room_players where room_id=p_room_id and status<>'left';
 select count(*)+1 into place from public.secret_characters where room_id=p_room_id and round_no=p_round_no and revealed;
 select count(*) into qcount from public.questions where room_id=p_room_id and round_no=p_round_no and user_id=auth.uid();
 base:=case when total>=4 then case place when 1 then 100 when 2 then 70 when 3 then 40 else 0 end when total=3 then case place when 1 then 100 when 2 then 50 else 0 end else case place when 1 then 100 else 0 end end;
 bonus:=case when qcount<=3 then 30 when qcount<=5 then 15 else 0 end;
 update public.secret_characters set revealed=true,placement=place,solved_at=now() where room_id=p_room_id and round_no=p_round_no and player_id=auth.uid();
 update public.room_players set score=score+base+bonus,wrong_guess_available_at=null where room_id=p_room_id and user_id=auth.uid();
 update public.profiles set points=points+base+bonus,xp=xp+base+bonus,level=1+(xp+base+bonus)/500 where id=auth.uid();
 perform public.check_round_end(p_room_id,p_round_no);
 return jsonb_build_object('correct',true,'character_name',cname,'placement',place,'points',base+bonus);end$$;

revoke execute on function public.submit_guess(uuid,int,bigint) from public, anon;
grant execute on function public.submit_guess(uuid,int,bigint) to authenticated;
