-- 002: correções de segurança, regras de jogo e desempenho.
-- Idempotente: pode ser executado depois do 001 em um banco que já está em uso.

-- ---------------------------------------------------------------------------
-- 1. Funções SECURITY DEFINER: por padrão o Postgres concede EXECUTE a PUBLIC,
--    o que permitia a qualquer visitante (anon) chamar assign_round/make_code
--    diretamente e inserir identidades em salas de outras pessoas.
-- ---------------------------------------------------------------------------
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.make_code() from public, anon, authenticated;
revoke execute on function public.assign_round(uuid,int) from public, anon, authenticated;
revoke execute on function public.is_room_member(uuid,uuid) from public, anon;
grant execute on function public.is_room_member(uuid,uuid) to authenticated;
revoke execute on function public.create_room(text,int,text,int),public.join_room(text),public.start_match(uuid),
  public.submit_guess(uuid,int,bigint),public.next_round(uuid),public.leave_room(uuid) from public, anon;

-- make_code usava gen_random_bytes (pgcrypto) com search_path='' sem qualificar o
-- schema; no Supabase o pgcrypto fica em "extensions", então criar sala falhava.
-- Agora usa só funções nativas e um alfabeto sem caracteres ambíguos (0/O, 1/I).
create or replace function public.make_code() returns text language plpgsql volatile security definer set search_path='' as $$
declare alphabet constant text:='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text;begin
 loop
   select string_agg(substr(alphabet,1+floor(random()*length(alphabet))::int,1),'') into c from generate_series(1,5);
   exit when not exists(select 1 from public.rooms where code=c);
 end loop;
 return c;end$$;
revoke execute on function public.make_code() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Perfis: o usuário só pode alterar nome e avatar (antes podia editar
--    points/wins/level e fraudar o ranking).
-- ---------------------------------------------------------------------------
revoke update on public.profiles from authenticated;
grant update(username, avatar) on public.profiles to authenticated;
do $$ begin
  alter table public.profiles add constraint profiles_username_len check (char_length(username) between 3 and 24);
exception when duplicate_object then null; when check_violation then null; end $$;

-- Cadastro não falha mais quando o nome de usuário já existe.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path='' as $$
declare base text; candidate text;
begin
 base:=left(coalesce(nullif(trim(new.raw_user_meta_data->>'username'),''),split_part(new.email,'@',1)),18);
 if char_length(base)<3 then base:=base||'jogador'; end if;
 candidate:=base;
 if exists(select 1 from public.profiles where username=candidate) then candidate:=base||'_'||substr(replace(new.id::text,'-',''),1,5); end if;
 insert into public.profiles(id,username) values(new.id,candidate) on conflict(id) do nothing;
 return new;
end$$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Regras de jogo validadas no servidor
-- ---------------------------------------------------------------------------
create or replace function public.create_room(p_theme text,p_rounds int,p_game_mode text,p_turn_seconds int)
returns uuid language plpgsql security definer set search_path='' as $$
declare rid uuid;begin
 if auth.uid() is null then raise exception 'Faça login';end if;
 if p_rounds not between 1 and 10 then raise exception 'Número de rodadas inválido';end if;
 if p_game_mode not in('FREE','TURNS') then raise exception 'Modo inválido';end if;
 if p_turn_seconds not between 0 and 300 then raise exception 'Tempo inválido';end if;
 if p_theme not in('ALEATÓRIO','TUDO MISTURADO') and not exists(select 1 from public.characters where theme=p_theme and active) then raise exception 'Tema sem personagens';end if;
 insert into public.rooms(code,host_id,theme,total_rounds,game_mode,turn_seconds) values(public.make_code(),auth.uid(),p_theme,p_rounds,p_game_mode,p_turn_seconds) returning id into rid;
 insert into public.room_players(room_id,user_id) values(rid,auth.uid()); return rid;end$$;

create or replace function public.join_room(p_code text) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.rooms; n int;begin
 if auth.uid() is null then raise exception 'Faça login';end if;
 select * into r from public.rooms where code=upper(trim(p_code)) for update;
 if r.id is null then raise exception 'Sala não encontrada';end if;
 -- quem já está na sala pode voltar mesmo com o jogo em andamento
 if exists(select 1 from public.room_players where room_id=r.id and user_id=auth.uid() and status<>'left') then return r.id;end if;
 if r.status<>'lobby' then raise exception 'Esta partida já começou';end if;
 select count(*) into n from public.room_players where room_id=r.id and status<>'left'; if n>=r.max_players then raise exception 'Sala lotada';end if;
 insert into public.room_players(room_id,user_id) values(r.id,auth.uid()) on conflict(room_id,user_id) do update set status='connected'; return r.id;end$$;

create or replace function public.start_match(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rooms; n int;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or r.host_id<>auth.uid() then raise exception 'Somente o host pode iniciar';end if;
 if r.status<>'lobby' then raise exception 'A partida já começou';end if;
 select count(*) into n from public.room_players where room_id=p_room_id and status<>'left'; if n<2 then raise exception 'São necessários pelo menos 2 jogadores';end if;
 update public.rooms set status='playing',current_round=1 where id=p_room_id; perform public.assign_round(p_room_id,1); return true;end$$;

-- Fecha a rodada quando resta no máximo 1 jogador ativo sem acertar.
create or replace function public.check_round_end(p_room_id uuid,p_round int) returns void language plpgsql security definer set search_path='' as $$
declare total int; remain int;begin
 select count(*) into total from public.room_players where room_id=p_room_id and status<>'left';
 select count(*) into remain from public.secret_characters s join public.room_players rp on rp.room_id=s.room_id and rp.user_id=s.player_id
  where s.room_id=p_room_id and s.round_no=p_round and not s.revealed and rp.status<>'left';
 if remain<=1 then
   update public.secret_characters set revealed=true,placement=coalesce(placement,total),solved_at=coalesce(solved_at,now()) where room_id=p_room_id and round_no=p_round and not revealed;
   update public.rooms set status='round_result' where id=p_room_id and status='playing';
 end if;
end$$;
revoke execute on function public.check_round_end(uuid,int) from public, anon, authenticated;

-- Correções:
--  * antes, chamar com uma rodada inexistente caía no ramo "acertou" e dava pontos infinitos;
--  * agora só vale na rodada atual com a sala em jogo;
--  * compara pelo NOME do personagem (o mesmo nome existe em mais de um tema, ex. Neymar).
create or replace function public.submit_guess(p_room_id uuid,p_round_no int,p_character_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.rooms; s public.secret_characters; rp public.room_players; total int; place int; qcount int; base int:=0; bonus int:=0; cname text; gname text;begin
 if not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 select * into r from public.rooms where id=p_room_id for update;
 if r.status<>'playing' or r.current_round<>p_round_no then raise exception 'A rodada não está em andamento';end if;
 select * into rp from public.room_players where room_id=p_room_id and user_id=auth.uid() for update;
 if rp.status='left' then raise exception 'Você saiu da sala';end if;
 if rp.wrong_guess_available_at is not null and rp.wrong_guess_available_at>now() then raise exception 'Aguarde alguns segundos para tentar novamente';end if;
 select * into s from public.secret_characters where room_id=p_room_id and round_no=p_round_no and player_id=auth.uid() for update;
 if not found then raise exception 'Você não tem identidade nesta rodada';end if;
 select name into cname from public.characters where id=s.character_id;
 if s.revealed then return jsonb_build_object('correct',true,'character_name',cname,'already',true);end if;
 select name into gname from public.characters where id=p_character_id;
 if gname is null or lower(gname)<>lower(cname) then
   update public.secret_characters set wrong_attempts=wrong_attempts+1 where room_id=p_room_id and round_no=p_round_no and player_id=auth.uid();
   update public.room_players set wrong_guess_available_at=now()+interval '10 seconds' where room_id=p_room_id and user_id=auth.uid();
   return jsonb_build_object('correct',false);
 end if;
 select count(*) into total from public.room_players where room_id=p_room_id and status<>'left';
 select count(*)+1 into place from public.secret_characters where room_id=p_room_id and round_no=p_round_no and revealed;
 select count(*) into qcount from public.questions where room_id=p_room_id and round_no=p_round_no and user_id=auth.uid();
 base:=case when total>=4 then case place when 1 then 100 when 2 then 70 when 3 then 40 else 0 end when total=3 then case place when 1 then 100 when 2 then 50 else 0 end else case place when 1 then 100 else 0 end end;
 bonus:=case when qcount<=3 then 30 when qcount<=5 then 15 else 0 end;
 update public.secret_characters set revealed=true,placement=place,solved_at=now() where room_id=p_room_id and round_no=p_round_no and player_id=auth.uid();
 update public.room_players set score=score+base+bonus,wrong_guess_available_at=null where room_id=p_room_id and user_id=auth.uid();
 perform public.check_round_end(p_room_id,p_round_no);
 return jsonb_build_object('correct',true,'character_name',cname,'placement',place,'points',base+bonus);end$$;

-- Só avança a partir da tela de resultado; ao final atualiza vitórias/derrotas/XP.
create or replace function public.next_round(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rooms; top int;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or r.host_id<>auth.uid() then raise exception 'Somente o host';end if;
 if r.status<>'round_result' then raise exception 'A rodada ainda não terminou';end if;
 if r.current_round>=r.total_rounds then
   update public.rooms set status='finished' where id=p_room_id;
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
 perform public.assign_round(p_room_id,r.current_round+1); return true;end$$;

-- Sair no meio da rodada não trava mais a partida; host sai do lobby => passa o host.
create or replace function public.leave_room(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rooms; nh uuid;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null then return false;end if;
 update public.room_players set status='left' where room_id=p_room_id and user_id=auth.uid();
 if r.host_id=auth.uid() then
   select user_id into nh from public.room_players where room_id=p_room_id and status<>'left' order by joined_at limit 1;
   if nh is not null then update public.rooms set host_id=nh where id=p_room_id;
   elsif r.status in('lobby','playing','round_result') then update public.rooms set status='finished' where id=p_room_id;end if;
 end if;
 if r.status='playing' then perform public.check_round_end(p_room_id,r.current_round);end if;
 return true;end$$;

revoke execute on function public.create_room(text,int,text,int),public.join_room(text),public.start_match(uuid),
  public.submit_guess(uuid,int,bigint),public.next_round(uuid),public.leave_room(uuid) from public, anon;
grant execute on function public.create_room(text,int,text,int),public.join_room(text),public.start_match(uuid),
  public.submit_guess(uuid,int,bigint),public.next_round(uuid),public.leave_room(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Policies mais restritas
-- ---------------------------------------------------------------------------
-- Respostas: só membros da sala, e ninguém responde a própria pergunta.
drop policy if exists a_write on public.answers;
create policy a_write on public.answers for insert to authenticated with check(
  user_id=(select auth.uid()) and exists(select 1 from public.questions q where q.id=question_id and q.user_id<>(select auth.uid()) and public.is_room_member(q.room_id)));
drop policy if exists a_update on public.answers;
create policy a_update on public.answers for update to authenticated using(user_id=(select auth.uid())) with check(
  user_id=(select auth.uid()) and exists(select 1 from public.questions q where q.id=question_id and q.user_id<>(select auth.uid()) and public.is_room_member(q.room_id)));

-- Perguntas: apenas na rodada atual de uma sala em jogo.
drop policy if exists q_insert on public.questions;
create policy q_insert on public.questions for insert to authenticated with check(
  user_id=(select auth.uid()) and public.is_room_member(room_id)
  and exists(select 1 from public.rooms r where r.id=room_id and r.status='playing' and r.current_round=round_no));

-- Amizades: só o solicitante cria; ambos podem ver/aceitar/remover.
drop policy if exists friends_write on public.friendships;
drop policy if exists friends_insert on public.friendships;
drop policy if exists friends_update on public.friendships;
drop policy if exists friends_delete on public.friendships;
create policy friends_insert on public.friendships for insert to authenticated with check(requester=(select auth.uid()) and status='pending');
create policy friends_update on public.friendships for update to authenticated using(addressee=(select auth.uid())) with check(addressee=(select auth.uid()));
create policy friends_delete on public.friendships for delete to authenticated using(requester=(select auth.uid()) or addressee=(select auth.uid()));
grant delete on public.friendships to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Índices para as consultas e políticas usadas pelo app
-- ---------------------------------------------------------------------------
create index if not exists room_players_user_idx on public.room_players(user_id);
create index if not exists rooms_host_idx on public.rooms(host_id);
create index if not exists questions_room_round_idx on public.questions(room_id,round_no,created_at desc);
create index if not exists questions_user_idx on public.questions(user_id);
create index if not exists answers_user_idx on public.answers(user_id);
create index if not exists chat_room_created_idx on public.chat_messages(room_id,created_at desc);
create index if not exists chat_user_idx on public.chat_messages(user_id);
create index if not exists secret_player_idx on public.secret_characters(player_id);
create index if not exists secret_character_idx on public.secret_characters(character_id);
create index if not exists characters_theme_idx on public.characters(theme) where active;
create index if not exists friendships_addressee_idx on public.friendships(addressee);
create index if not exists theme_votes_user_idx on public.theme_votes(user_id);
create index if not exists profiles_points_idx on public.profiles(points desc);
