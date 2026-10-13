-- 019: tempo garantido para responder.
-- Se a pergunta for feita nos últimos segundos da vez, o relógio é estendido para que os
-- outros jogadores tenham pelo menos 30 s (ou o tempo total da vez, se for menor) para responder.
-- Pergunta enviada depois que o tempo da vez já acabou é recusada.
create or replace function public.ask_question(p_room_id uuid,p_text text) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.rooms; qid uuid; t text:=trim(p_text); keep int;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 if r.status<>'playing' then raise exception 'A rodada não está em andamento';end if;
 if r.turn_user_id is distinct from auth.uid() then raise exception 'Não é a sua vez de perguntar';end if;
 if r.turn_question_id is not null then raise exception 'Aguarde todos responderem sua pergunta';end if;
 if char_length(t) not between 1 and 240 then raise exception 'Pergunta deve ter de 1 a 240 caracteres';end if;
 if r.turn_seconds>0 and now()>=r.turn_started_at+make_interval(secs=>r.turn_seconds) then raise exception 'O tempo da sua vez acabou';end if;
 insert into public.questions(room_id,round_no,user_id,text) values(p_room_id,r.current_round,auth.uid(),t) returning id into qid;
 keep:=least(r.turn_seconds,30);
 update public.rooms set turn_question_id=qid,
   turn_started_at=case when r.turn_seconds>0 then greatest(r.turn_started_at,now()-make_interval(secs=>r.turn_seconds-keep)) else r.turn_started_at end
  where id=p_room_id;
 return qid;end$$;
revoke execute on function public.ask_question(uuid,text) from public, anon;
grant execute on function public.ask_question(uuid,text) to authenticated;
