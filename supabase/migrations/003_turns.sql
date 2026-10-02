-- 003: perguntas em turnos.
-- Um jogador por vez faz UMA pergunta; quando todos os outros jogadores ativos
-- respondem, a vez passa automaticamente para o próximo (na ordem de entrada),
-- pulando quem já descobriu a identidade. O host pode pular a vez; se a sala
-- tiver tempo por vez (turn_seconds > 0), qualquer jogador pode pular quando
-- o tempo acabar.

alter table public.rooms add column if not exists turn_user_id uuid references public.profiles(id);
alter table public.rooms add column if not exists turn_question_id uuid references public.questions(id) on delete set null;
alter table public.rooms add column if not exists turn_started_at timestamptz;

-- Passa a vez para o próximo jogador ativo que ainda não descobriu quem é.
create or replace function public.advance_turn(p_room_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare r public.rooms; cur_j timestamptz; nxt uuid;begin
 select * into r from public.rooms where id=p_room_id;
 select joined_at into cur_j from public.room_players where room_id=p_room_id and user_id=r.turn_user_id;
 select rp.user_id into nxt from public.room_players rp
  left join public.secret_characters s on s.room_id=rp.room_id and s.player_id=rp.user_id and s.round_no=r.current_round
  where rp.room_id=p_room_id and rp.status<>'left' and not coalesce(s.revealed,false)
  order by (cur_j is not null and rp.joined_at<=cur_j), rp.joined_at limit 1;
 update public.rooms set turn_user_id=nxt,turn_question_id=null,turn_started_at=now() where id=p_room_id;
end$$;

-- Verifica se a vez atual terminou (todos responderam, ou o dono da vez saiu/acertou).
create or replace function public.check_turn(p_room_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare r public.rooms; asker_ok boolean; pending int;begin
 select * into r from public.rooms where id=p_room_id;
 if r.status<>'playing' then return;end if;
 select exists(select 1 from public.room_players rp
   left join public.secret_characters s on s.room_id=rp.room_id and s.player_id=rp.user_id and s.round_no=r.current_round
   where rp.room_id=p_room_id and rp.user_id=r.turn_user_id and rp.status<>'left' and not coalesce(s.revealed,false)) into asker_ok;
 if not asker_ok then perform public.advance_turn(p_room_id); return;end if;
 if r.turn_question_id is null then return;end if;
 select count(*) into pending from public.room_players rp
  where rp.room_id=p_room_id and rp.status<>'left' and rp.user_id<>r.turn_user_id
    and not exists(select 1 from public.answers a where a.question_id=r.turn_question_id and a.user_id=rp.user_id);
 if pending=0 then perform public.advance_turn(p_room_id);end if;
end$$;

create or replace function public.ask_question(p_room_id uuid,p_text text) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.rooms; qid uuid; t text:=trim(p_text);begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 if r.status<>'playing' then raise exception 'A rodada não está em andamento';end if;
 if r.turn_user_id is distinct from auth.uid() then raise exception 'Não é a sua vez de perguntar';end if;
 if r.turn_question_id is not null then raise exception 'Aguarde todos responderem sua pergunta';end if;
 if char_length(t) not between 1 and 240 then raise exception 'Pergunta deve ter de 1 a 240 caracteres';end if;
 insert into public.questions(room_id,round_no,user_id,text) values(p_room_id,r.current_round,auth.uid(),t) returning id into qid;
 update public.rooms set turn_question_id=qid where id=p_room_id;
 return qid;end$$;

create or replace function public.skip_turn(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rooms;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 if r.status<>'playing' then return false;end if;
 if r.host_id<>auth.uid() and not (r.turn_seconds>0 and now()>=r.turn_started_at+make_interval(secs=>r.turn_seconds)) then
   raise exception 'Somente o host pode pular a vez antes do tempo acabar';end if;
 perform public.advance_turn(p_room_id); return true;end$$;

-- Toda resposta pode encerrar a vez.
create or replace function public.answers_check_turn() returns trigger language plpgsql security definer set search_path='' as $$
declare rid uuid;begin
 select room_id into rid from public.questions where id=new.question_id;
 perform public.check_turn(rid); return null;end$$;
drop trigger if exists answers_check_turn on public.answers;
create trigger answers_check_turn after insert or update on public.answers for each row execute function public.answers_check_turn();

-- Início de partida/rodada define a vez; acerto e saída reavaliam a vez.
create or replace function public.start_match(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rooms; n int;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or r.host_id<>auth.uid() then raise exception 'Somente o host pode iniciar';end if;
 if r.status<>'lobby' then raise exception 'A partida já começou';end if;
 select count(*) into n from public.room_players where room_id=p_room_id and status<>'left'; if n<2 then raise exception 'São necessários pelo menos 2 jogadores';end if;
 update public.rooms set status='playing',current_round=1 where id=p_room_id;
 perform public.assign_round(p_room_id,1); perform public.advance_turn(p_room_id); return true;end$$;

create or replace function public.next_round(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rooms; top int;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or r.host_id<>auth.uid() then raise exception 'Somente o host';end if;
 if r.status<>'round_result' then raise exception 'A rodada ainda não terminou';end if;
 if r.current_round>=r.total_rounds then
   update public.rooms set status='finished',turn_user_id=null,turn_question_id=null where id=p_room_id;
   select max(score) into top from public.room_players where room_id=p_room_id and status<>'left';
   update public.profiles p set
     matches=matches+1,
     points=points+coalesce(x.score,0),
     xp=xp+coalesce(x.score,0),
     level=1+(xp+coalesce(x.score,0))/500,
     wins=wins+case when x.score=top then 1 else 0 end,
     losses=losses+case when x.score=top then 0 else 1 end,
     current_streak=case when x.score=top then current_streak+1 else 0 end,
     best_streak=greatest(best_streak,case when x.score=top then current_streak+1 else 0 end)
   from public.room_players x where x.room_id=p_room_id and x.user_id=p.id and x.status<>'left';
   return true;
 end if;
 update public.rooms set current_round=current_round+1,status='playing' where id=p_room_id;
 perform public.assign_round(p_room_id,r.current_round+1); perform public.advance_turn(p_room_id); return true;end$$;

-- Envolve submit_guess/leave_room (definidos no 002) para reavaliar a vez.
create or replace function public.check_round_end(p_room_id uuid,p_round int) returns void language plpgsql security definer set search_path='' as $$
declare total int; remain int;begin
 select count(*) into total from public.room_players where room_id=p_room_id and status<>'left';
 select count(*) into remain from public.secret_characters s join public.room_players rp on rp.room_id=s.room_id and rp.user_id=s.player_id
  where s.room_id=p_room_id and s.round_no=p_round and not s.revealed and rp.status<>'left';
 if remain<=1 then
   update public.secret_characters set revealed=true,placement=coalesce(placement,total),solved_at=coalesce(solved_at,now()) where room_id=p_room_id and round_no=p_round and not revealed;
   update public.rooms set status='round_result',turn_question_id=null where id=p_room_id and status='playing';
 else
   perform public.check_turn(p_room_id);
 end if;
end$$;

revoke execute on function public.advance_turn(uuid),public.check_turn(uuid),public.answers_check_turn(),public.check_round_end(uuid,int) from public, anon, authenticated;
revoke execute on function public.ask_question(uuid,text),public.skip_turn(uuid),public.start_match(uuid),public.next_round(uuid) from public, anon;
grant execute on function public.ask_question(uuid,text),public.skip_turn(uuid),public.start_match(uuid),public.next_round(uuid) to authenticated;

-- Perguntas só via ask_question; respostas só para a pergunta da vez atual.
drop policy if exists q_insert on public.questions;
revoke insert on public.questions from authenticated;
drop policy if exists a_write on public.answers;
create policy a_write on public.answers for insert to authenticated with check(
  user_id=(select auth.uid()) and exists(select 1 from public.questions q join public.rooms r on r.turn_question_id=q.id
    where q.id=question_id and q.user_id<>(select auth.uid()) and public.is_room_member(q.room_id)));
drop policy if exists a_update on public.answers;
create policy a_update on public.answers for update to authenticated using(user_id=(select auth.uid())) with check(
  user_id=(select auth.uid()) and exists(select 1 from public.questions q join public.rooms r on r.turn_question_id=q.id
    where q.id=question_id and q.user_id<>(select auth.uid()) and public.is_room_member(q.room_id)));

-- Partidas que já estavam em andamento ganham uma vez.
do $$ declare x record; begin
 for x in select id from public.rooms where status='playing' and turn_user_id is null loop perform public.advance_turn(x.id); end loop;
end $$;
