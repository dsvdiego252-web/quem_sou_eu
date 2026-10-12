-- 017: dicas grátis por número de perguntas + dica paga exige saldo.
-- Cada dica (grátis ou paga) revela o próximo nível de uma "escada" de dicas sobre o nome.
-- Grátis: liberam após 10, 15 e 20 perguntas do próprio jogador na rodada; não custam nada
--         na hora, mas descontam 20, 30 e 40 pontos do prêmio quando ele acertar.
-- Paga:   a qualquer momento, até 2 por rodada, custa 80 pontos e exige saldo >= 80.

alter table public.player_hints add column if not exists kind text not null default 'paid';
alter table public.player_hints add column if not exists penalty int not null default 0;

-- Texto da dica de um nível (1..5) da escada.
create or replace function public.hint_text(p_name text,p_theme text,p_mixed boolean,p_level int) returns text language plpgsql immutable set search_path='' as $$
declare n text:=trim(p_name); words text[]:=regexp_split_to_array(trim(p_name),'\s+'); w int:=array_length(regexp_split_to_array(trim(p_name),'\s+'),1);
 masked text:=''; i int; ch text; pos int:=0;begin
 if p_level=1 then
   return case when p_mixed then 'Seu tema é '||p_theme||'. ' else '' end||'Seu nome tem '||w||' palavra'||case when w>1 then 's' else '' end||' e '||char_length(replace(n,' ',''))||' letras.';
 elsif p_level=2 then
   return 'Seu nome começa com "'||upper(left(n,1))||'" e termina com "'||lower(right(n,1))||'".';
 end if;
 -- níveis 3+: nome mascarado; 3 = só iniciais de cada palavra, 4 = letras alternadas, 5 = falta só 1 letra em cada palavra
 for i in 1..char_length(n) loop
   ch:=substr(n,i,1);
   if ch=' ' then masked:=masked||'   ';pos:=0;continue;end if;
   pos:=pos+1;
   if ch !~ '[[:alpha:]0-9]' then masked:=masked||ch;
   elsif pos=1 or (p_level=4 and pos%2=1) or (p_level>=5 and pos<>2) then masked:=masked||upper(ch);
   else masked:=masked||'_';end if;
   masked:=masked||' ';
 end loop;
 return 'Seu nome: '||trim(masked);
end$$;

-- Nível da próxima dica do jogador nesta rodada (grátis e pagas somam na escada).
create or replace function public.next_hint_level(p_room uuid,p_round int,p_user uuid) returns int language sql stable security definer set search_path='' as $$
 select coalesce(max(hint_no),0)+1 from public.player_hints where room_id=p_room and round_no=p_round and user_id=p_user;
$$;

create or replace function public.buy_hint(p_room_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.rooms; s public.secret_characters; c public.characters; used int; lvl int; h text; bal int; cost constant int:=80;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 if r.status<>'playing' then raise exception 'A rodada não está em andamento';end if;
 select * into s from public.secret_characters where room_id=p_room_id and round_no=r.current_round and player_id=auth.uid();
 if not found or s.revealed then raise exception 'Você já descobriu quem é';end if;
 select count(*) into used from public.player_hints where room_id=p_room_id and round_no=r.current_round and user_id=auth.uid() and kind='paid';
 if used>=2 then raise exception 'Você já usou as 2 dicas pagas desta rodada';end if;
 select points into bal from public.profiles where id=auth.uid() for update;
 if coalesce(bal,0)<cost then raise exception 'Saldo insuficiente: a dica paga custa 80 pontos e você tem %',coalesce(bal,0);end if;
 lvl:=public.next_hint_level(p_room_id,r.current_round,auth.uid());
 if lvl>5 then raise exception 'Você já recebeu todas as dicas possíveis';end if;
 select * into c from public.characters where id=s.character_id;
 h:=public.hint_text(c.name,c.theme,r.theme in('ALEATÓRIO','TUDO MISTURADO'),lvl);
 insert into public.player_hints(room_id,round_no,user_id,hint_no,hint,kind,penalty) values(p_room_id,r.current_round,auth.uid(),lvl,h,'paid',0);
 update public.room_players set score=score-cost where room_id=p_room_id and user_id=auth.uid();
 update public.profiles set points=points-cost where id=auth.uid();
 insert into public.score_events(user_id,room_id,points,reason) values(auth.uid(),p_room_id,-cost,'hint');
 return jsonb_build_object('hint',h,'cost',cost);
end$$;

create or replace function public.take_free_hint(p_room_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.rooms; s public.secret_characters; c public.characters; used int; asked int; lvl int; h text;
 need constant int[]:=array[10,15,20]; pen constant int[]:=array[20,30,40];begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 if r.status<>'playing' then raise exception 'A rodada não está em andamento';end if;
 select * into s from public.secret_characters where room_id=p_room_id and round_no=r.current_round and player_id=auth.uid();
 if not found or s.revealed then raise exception 'Você já descobriu quem é';end if;
 select count(*) into used from public.player_hints where room_id=p_room_id and round_no=r.current_round and user_id=auth.uid() and kind='free';
 if used>=3 then raise exception 'Você já usou as 3 dicas grátis desta rodada';end if;
 select count(*) into asked from public.questions where room_id=p_room_id and round_no=r.current_round and user_id=auth.uid();
 if asked<need[used+1] then raise exception 'A próxima dica grátis libera depois da sua pergunta %',need[used+1];end if;
 lvl:=public.next_hint_level(p_room_id,r.current_round,auth.uid());
 if lvl>5 then raise exception 'Você já recebeu todas as dicas possíveis';end if;
 select * into c from public.characters where id=s.character_id;
 h:=public.hint_text(c.name,c.theme,r.theme in('ALEATÓRIO','TUDO MISTURADO'),lvl);
 insert into public.player_hints(room_id,round_no,user_id,hint_no,hint,kind,penalty) values(p_room_id,r.current_round,auth.uid(),lvl,h,'free',pen[used+1]);
 return jsonb_build_object('hint',h,'penalty',pen[used+1]);
end$$;

-- Acerto: desconta do prêmio as penalidades das dicas grátis usadas na rodada (mínimo 0).
create or replace function public.submit_guess(p_room_id uuid,p_round_no int,p_character_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.rooms; s public.secret_characters; rp public.room_players; total int; place int; qcount int; base int:=0; bonus int:=0; pen int:=0; prize int; cname text; gname text; ncorrect int;begin
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
 select coalesce(sum(penalty),0) into pen from public.player_hints where room_id=p_room_id and round_no=p_round_no and user_id=auth.uid() and kind='free';
 base:=case when total>=4 then case place when 1 then 100 when 2 then 70 when 3 then 40 else 0 end when total=3 then case place when 1 then 100 when 2 then 50 else 0 end else case place when 1 then 100 else 0 end end;
 bonus:=case when qcount<=3 then 30 when qcount<=5 then 15 else 0 end;
 prize:=greatest(0,base+bonus-pen);
 update public.secret_characters set revealed=true,placement=place,solved_at=now() where room_id=p_room_id and round_no=p_round_no and player_id=auth.uid();
 update public.room_players set score=score+prize,wrong_guess_available_at=null where room_id=p_room_id and user_id=auth.uid();
 update public.profiles set points=points+prize,xp=xp+prize,level=1+(xp+prize)/500 where id=auth.uid();
 insert into public.score_events(user_id,room_id,points,reason) values(auth.uid(),p_room_id,prize,'guess');
 perform public.award(auth.uid(),'primeiro_acerto');
 if qcount<=1 then perform public.award(auth.uid(),'genio');end if;
 if s.wrong_attempts=0 and place=1 then perform public.award(auth.uid(),'certeiro');end if;
 select count(*) into ncorrect from public.score_events where user_id=auth.uid() and reason='guess';
 if ncorrect>=10 then perform public.award(auth.uid(),'dez_acertos');end if;
 if ncorrect>=50 then perform public.award(auth.uid(),'cinquenta_acertos');end if;
 perform public.check_round_end(p_room_id,p_round_no);
 return jsonb_build_object('correct',true,'character_name',cname,'placement',place,'points',prize,'penalty',pen);end$$;

revoke execute on function public.hint_text(text,text,boolean,int),public.next_hint_level(uuid,int,uuid) from public, anon, authenticated;
revoke execute on function public.buy_hint(uuid),public.take_free_hint(uuid),public.submit_guess(uuid,int,bigint) from public, anon;
grant execute on function public.buy_hint(uuid),public.take_free_hint(uuid),public.submit_guess(uuid,int,bigint) to authenticated;
