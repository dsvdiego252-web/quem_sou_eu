-- Arquivo gerado: 001..003 + seed + 004..009. Para um banco NOVO: cole inteiro no SQL Editor do Supabase e execute uma vez.

create extension if not exists pgcrypto;

create table if not exists public.profiles(
 id uuid primary key references auth.users(id) on delete cascade,
 username text unique not null,
 avatar jsonb not null default '{"emoji":"🙂"}'::jsonb,
 level int not null default 1, xp int not null default 0, wins int not null default 0,
 losses int not null default 0, matches int not null default 0, points int not null default 0,
 best_streak int not null default 0, current_streak int not null default 0,
 online boolean not null default false, last_seen timestamptz not null default now(), created_at timestamptz default now()
);
create table if not exists public.rooms(
 id uuid primary key default gen_random_uuid(), code text unique not null,
 host_id uuid not null references public.profiles(id), status text not null default 'lobby',
 theme text not null default 'ALEATÓRIO', max_players int not null default 4 check(max_players between 2 and 4),
 total_rounds int not null default 5, current_round int not null default 0,
 game_mode text not null default 'FREE', turn_seconds int not null default 0, chat_enabled boolean not null default true,
 created_at timestamptz default now()
);
create table if not exists public.room_players(
 room_id uuid references public.rooms(id) on delete cascade, user_id uuid references public.profiles(id) on delete cascade,
 score int not null default 0, status text not null default 'connected', joined_at timestamptz default now(),
 wrong_guess_available_at timestamptz, primary key(room_id,user_id)
);
create table if not exists public.characters(
 id bigint generated always as identity primary key, theme text not null, name text not null,
 aliases text[] default '{}', active boolean not null default true, unique(theme,name)
);
create table if not exists public.secret_characters(
 room_id uuid references public.rooms(id) on delete cascade, round_no int not null,
 player_id uuid references public.profiles(id) on delete cascade, character_id bigint not null references public.characters(id),
 revealed boolean not null default false, placement int, solved_at timestamptz, wrong_attempts int not null default 0,
 primary key(room_id,round_no,player_id), unique(room_id,round_no,character_id)
);
create table if not exists public.questions(
 id uuid primary key default gen_random_uuid(), room_id uuid references public.rooms(id) on delete cascade,
 round_no int not null, user_id uuid references public.profiles(id), text text not null check(length(text)<=240), created_at timestamptz default now()
);
create table if not exists public.answers(
 question_id uuid references public.questions(id) on delete cascade, user_id uuid references public.profiles(id) on delete cascade,
 answer text not null check(answer in('YES','NO','MAYBE','DONT_KNOW')), note text check(length(note)<=120), created_at timestamptz default now(),
 primary key(question_id,user_id)
);
create table if not exists public.chat_messages(
 id uuid primary key default gen_random_uuid(), room_id uuid references public.rooms(id) on delete cascade,
 user_id uuid references public.profiles(id), text text not null check(length(text)<=300), created_at timestamptz default now()
);
create table if not exists public.friendships(
 requester uuid references public.profiles(id) on delete cascade, addressee uuid references public.profiles(id) on delete cascade,
 status text not null default 'pending', created_at timestamptz default now(), primary key(requester,addressee)
);
create table if not exists public.theme_votes(
 room_id uuid references public.rooms(id) on delete cascade, user_id uuid references public.profiles(id) on delete cascade,
 theme text not null, primary key(room_id,user_id)
);

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,username) values(new.id,coalesce(nullif(new.raw_user_meta_data->>'username',''),split_part(new.email,'@',1)||substr(new.id::text,1,4))) on conflict(id) do nothing;
 return new;
end$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.is_room_member(p_room uuid,p_user uuid default auth.uid()) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.room_players rp where rp.room_id=p_room and rp.user_id=p_user);
$$;

create or replace function public.make_code() returns text language plpgsql volatile security definer set search_path='' as $$
declare c text;begin loop c:=upper(substr(encode(gen_random_bytes(6),'hex'),1,5)); exit when not exists(select 1 from public.rooms where code=c); end loop; return c;end$$;

create or replace function public.create_room(p_theme text,p_rounds int,p_game_mode text,p_turn_seconds int)
returns uuid language plpgsql security definer set search_path='' as $$
declare rid uuid;begin
 insert into public.rooms(code,host_id,theme,total_rounds,game_mode,turn_seconds) values(public.make_code(),auth.uid(),p_theme,p_rounds,p_game_mode,p_turn_seconds) returning id into rid;
 insert into public.room_players(room_id,user_id) values(rid,auth.uid()); return rid;end$$;

create or replace function public.join_room(p_code text) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.rooms; n int;begin
 select * into r from public.rooms where code=upper(trim(p_code)) and status='lobby'; if r.id is null then raise exception 'Sala não encontrada ou já iniciada';end if;
 select count(*) into n from public.room_players where room_id=r.id; if n>=r.max_players then raise exception 'Sala lotada';end if;
 insert into public.room_players(room_id,user_id) values(r.id,auth.uid()) on conflict do update set status='connected'; return r.id;end$$;

create or replace function public.assign_round(p_room uuid,p_round int) returns void language plpgsql security definer set search_path='' as $$
declare r public.rooms; p record; ch bigint; used bigint[]:='{}';begin
 select * into r from public.rooms where id=p_room;
 for p in select user_id from public.room_players where room_id=p_room and status<>'left' order by joined_at loop
   select c.id into ch from public.characters c where c.active and c.id<>all(used) and (r.theme in('ALEATÓRIO','TUDO MISTURADO') or c.theme=r.theme) order by random() limit 1;
   if ch is null then select c.id into ch from public.characters c where c.active and c.id<>all(used) order by random() limit 1; end if;
   if ch is null then raise exception 'Banco de personagens insuficiente';end if;
   insert into public.secret_characters(room_id,round_no,player_id,character_id) values(p_room,p_round,p.user_id,ch);
   used:=array_append(used,ch);
 end loop;
end$$;

create or replace function public.start_match(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rooms; n int;begin
 select * into r from public.rooms where id=p_room_id for update; if r.host_id<>auth.uid() then raise exception 'Somente o host pode iniciar';end if;
 select count(*) into n from public.room_players where room_id=p_room_id and status<>'left'; if n<2 then raise exception 'São necessários pelo menos 2 jogadores';end if;
 update public.rooms set status='playing',current_round=1 where id=p_room_id; perform public.assign_round(p_room_id,1); return true;end$$;

create or replace function public.submit_guess(p_room_id uuid,p_round_no int,p_character_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.secret_characters; rp public.room_players; total int; place int; qcount int; base int:=0; bonus int:=0; cname text; remain int;begin
 if not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 select * into rp from public.room_players where room_id=p_room_id and user_id=auth.uid() for update;
 if rp.wrong_guess_available_at is not null and rp.wrong_guess_available_at>now() then raise exception 'Aguarde alguns segundos para tentar novamente';end if;
 select * into s from public.secret_characters where room_id=p_room_id and round_no=p_round_no and player_id=auth.uid() for update;
 if s.revealed then select name into cname from public.characters where id=s.character_id; return jsonb_build_object('correct',true,'character_name',cname,'already',true);end if;
 if s.character_id<>p_character_id then update public.secret_characters set wrong_attempts=wrong_attempts+1 where room_id=p_room_id and round_no=p_round_no and player_id=auth.uid(); update public.room_players set wrong_guess_available_at=now()+interval '10 seconds' where room_id=p_room_id and user_id=auth.uid(); return jsonb_build_object('correct',false);end if;
 select count(*) into total from public.room_players where room_id=p_room_id and status<>'left';
 select count(*)+1 into place from public.secret_characters where room_id=p_room_id and round_no=p_round_no and revealed;
 select count(*) into qcount from public.questions where room_id=p_room_id and round_no=p_round_no and user_id=auth.uid();
 base:=case when total=4 then case place when 1 then 100 when 2 then 70 when 3 then 40 else 0 end when total=3 then case place when 1 then 100 when 2 then 50 else 0 end else case place when 1 then 100 else 0 end end;
 bonus:=case when qcount<=3 then 30 when qcount<=5 then 15 else 0 end;
 update public.secret_characters set revealed=true,placement=place,solved_at=now() where room_id=p_room_id and round_no=p_round_no and player_id=auth.uid();
 update public.room_players set score=score+base+bonus,wrong_guess_available_at=null where room_id=p_room_id and user_id=auth.uid();
 select name into cname from public.characters where id=s.character_id;
 select count(*) into remain from public.secret_characters where room_id=p_room_id and round_no=p_round_no and not revealed;
 if remain=1 then
   update public.secret_characters set revealed=true,placement=total,solved_at=now() where room_id=p_room_id and round_no=p_round_no and not revealed;
   update public.rooms set status='round_result' where id=p_room_id;
 end if;
 return jsonb_build_object('correct',true,'character_name',cname,'placement',place,'points',base+bonus);end$$;

create or replace function public.next_round(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rooms;begin select * into r from public.rooms where id=p_room_id for update; if r.host_id<>auth.uid() then raise exception 'Somente host';end if;
 if r.current_round>=r.total_rounds then update public.rooms set status='finished' where id=p_room_id; update public.profiles p set matches=matches+1,points=points+coalesce(x.score,0) from public.room_players x where x.room_id=p_room_id and x.user_id=p.id; return true;end if;
 update public.rooms set current_round=current_round+1,status='playing' where id=p_room_id; perform public.assign_round(p_room_id,r.current_round+1); return true;end$$;

create or replace function public.leave_room(p_room_id uuid) returns boolean language plpgsql security definer set search_path='' as $$ begin update public.room_players set status='left' where room_id=p_room_id and user_id=auth.uid();return true;end$$;

alter table public.profiles enable row level security;alter table public.rooms enable row level security;alter table public.room_players enable row level security;alter table public.characters enable row level security;alter table public.secret_characters enable row level security;alter table public.questions enable row level security;alter table public.answers enable row level security;alter table public.chat_messages enable row level security;alter table public.friendships enable row level security;alter table public.theme_votes enable row level security;

create policy profiles_read on public.profiles for select to authenticated using(true);create policy profile_self_update on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
create policy rooms_member_read on public.rooms for select to authenticated using(public.is_room_member(id));
create policy rp_member_read on public.room_players for select to authenticated using(public.is_room_member(room_id));
create policy chars_read on public.characters for select to authenticated using(active);
create policy secrets_opponents_only on public.secret_characters for select to authenticated using(public.is_room_member(room_id) and (player_id<>auth.uid() or revealed));
create policy q_read on public.questions for select to authenticated using(public.is_room_member(room_id));create policy q_insert on public.questions for insert to authenticated with check(user_id=auth.uid() and public.is_room_member(room_id));
create policy a_read on public.answers for select to authenticated using(exists(select 1 from public.questions q where q.id=question_id and public.is_room_member(q.room_id)));create policy a_write on public.answers for insert to authenticated with check(user_id=auth.uid());create policy a_update on public.answers for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy chat_read on public.chat_messages for select to authenticated using(public.is_room_member(room_id));create policy chat_write on public.chat_messages for insert to authenticated with check(user_id=auth.uid() and public.is_room_member(room_id));
create policy friends_read on public.friendships for select to authenticated using(requester=auth.uid() or addressee=auth.uid());create policy friends_write on public.friendships for all to authenticated using(requester=auth.uid() or addressee=auth.uid()) with check(requester=auth.uid() or addressee=auth.uid());
create policy votes_all on public.theme_votes for all to authenticated using(public.is_room_member(room_id)) with check(user_id=auth.uid() and public.is_room_member(room_id));

grant select on public.profiles,public.rooms,public.room_players,public.characters,public.secret_characters,public.questions,public.answers,public.chat_messages,public.friendships,public.theme_votes to authenticated;
grant insert on public.questions,public.answers,public.chat_messages,public.friendships,public.theme_votes to authenticated;grant update on public.profiles,public.answers,public.friendships,public.theme_votes to authenticated;
revoke all on public.secret_characters from anon;revoke insert,update,delete on public.secret_characters from authenticated;
grant execute on function public.create_room(text,int,text,int),public.join_room(text),public.start_match(uuid),public.submit_guess(uuid,int,bigint),public.next_round(uuid),public.leave_room(uuid) to authenticated;

alter publication supabase_realtime add table public.rooms;alter publication supabase_realtime add table public.room_players;alter publication supabase_realtime add table public.secret_characters;alter publication supabase_realtime add table public.questions;alter publication supabase_realtime add table public.answers;alter publication supabase_realtime add table public.chat_messages;

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
create or replace function public.handle_new_user_row(p_id uuid,p_email text,p_meta jsonb) returns void language plpgsql security definer set search_path='' as $$
declare base text; candidate text;
begin
 base:=left(coalesce(nullif(trim(p_meta->>'username'),''),split_part(p_email,'@',1)),18);
 if char_length(base)<3 then base:=base||'jogador'; end if;
 candidate:=base;
 if exists(select 1 from public.profiles where username=candidate) then candidate:=base||'_'||substr(replace(p_id::text,'-',''),1,5); end if;
 insert into public.profiles(id,username) values(p_id,candidate) on conflict(id) do nothing;
end$$;
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path='' as $$
begin perform public.handle_new_user_row(new.id,new.email,new.raw_user_meta_data); return new; end$$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.handle_new_user_row(uuid,text,jsonb) from public, anon, authenticated;

-- Contas criadas antes desta migration (ou por outro app no mesmo projeto Supabase)
-- não passaram pelo trigger; o cliente chama isto ao logar para criar o perfil.
create or replace function public.ensure_profile() returns void language plpgsql security definer set search_path='' as $$
declare u auth.users;begin
 if auth.uid() is null or exists(select 1 from public.profiles where id=auth.uid()) then return;end if;
 select * into u from auth.users where id=auth.uid();
 perform public.handle_new_user_row(u.id,u.email,u.raw_user_meta_data);
end$$;

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
revoke execute on function public.ensure_profile() from public, anon;
grant execute on function public.ensure_profile() to authenticated;

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

-- Dados iniciais. Pode rodar várias vezes: ON CONFLICT evita duplicidade.
insert into public.characters(theme,name) values
  ('ESPORTE','Lionel Messi'),
  ('ESPORTE','Cristiano Ronaldo'),
  ('ESPORTE','Neymar'),
  ('ESPORTE','Michael Jordan'),
  ('ESPORTE','LeBron James'),
  ('ESPORTE','Ayrton Senna'),
  ('ESPORTE','Lewis Hamilton'),
  ('ESPORTE','Usain Bolt'),
  ('ESPORTE','Pelé'),
  ('ESPORTE','Ronaldo Fenômeno'),
  ('ESPORTE','Ronaldinho Gaúcho'),
  ('ESPORTE','Galvão Bueno'),
  ('ESPORTE','Marta'),
  ('ESPORTE','Vinícius Júnior'),
  ('ESPORTE','Kylian Mbappé'),
  ('ESPORTE','Novak Djokovic'),
  ('ESPORTE','Rafael Nadal'),
  ('ESPORTE','Roger Federer'),
  ('ESPORTE','Serena Williams'),
  ('ESPORTE','Simone Biles'),
  ('ESPORTE','Max Verstappen'),
  ('ESPORTE','Gabriel Medina'),
  ('ESPORTE','Rebeca Andrade'),
  ('ESPORTE','Gustavo Kuerten'),
  ('ESPORTE','Oscar Schmidt'),
  ('ESPORTE','Anderson Silva'),
  ('ESPORTE','José Aldo'),
  ('ESPORTE','Mike Tyson'),
  ('ESPORTE','Muhammad Ali'),
  ('ESPORTE','Tom Brady'),
  ('ESPORTE','Stephen Curry'),
  ('ESPORTE','Kobe Bryant'),
  ('ESPORTE','Shaquille O’Neal'),
  ('ESPORTE','Magic Johnson'),
  ('ESPORTE','Larry Bird'),
  ('ESPORTE','Giannis Antetokounmpo'),
  ('ESPORTE','Luka Dončić'),
  ('ESPORTE','Kevin Durant'),
  ('ESPORTE','Tiger Woods'),
  ('ESPORTE','Michael Phelps')
on conflict(theme,name) do nothing;

insert into public.characters(theme,name) values
  ('FILMES','Harry Potter'),
  ('FILMES','Homem-Aranha'),
  ('FILMES','Batman'),
  ('FILMES','Superman'),
  ('FILMES','Homem de Ferro'),
  ('FILMES','Jack Sparrow'),
  ('FILMES','Rocky Balboa'),
  ('FILMES','Darth Vader'),
  ('FILMES','Hulk'),
  ('FILMES','Thanos'),
  ('FILMES','Capitão América'),
  ('FILMES','Thor'),
  ('FILMES','Viúva Negra'),
  ('FILMES','Pantera Negra'),
  ('FILMES','Wolverine'),
  ('FILMES','Deadpool'),
  ('FILMES','Indiana Jones'),
  ('FILMES','Forrest Gump'),
  ('FILMES','Neo'),
  ('FILMES','John Wick'),
  ('FILMES','Shrek'),
  ('FILMES','Elsa'),
  ('FILMES','Woody'),
  ('FILMES','Buzz Lightyear'),
  ('FILMES','Simba'),
  ('FILMES','Aladdin'),
  ('FILMES','Mulan'),
  ('FILMES','Moana'),
  ('FILMES','Marty McFly'),
  ('FILMES','ET')
on conflict(theme,name) do nothing;

insert into public.characters(theme,name) values
  ('GAMES','Mario'),
  ('GAMES','Luigi'),
  ('GAMES','Sonic'),
  ('GAMES','Link'),
  ('GAMES','Zelda'),
  ('GAMES','Kratos'),
  ('GAMES','Master Chief'),
  ('GAMES','Lara Croft'),
  ('GAMES','Pac-Man'),
  ('GAMES','Pikachu'),
  ('GAMES','Donkey Kong'),
  ('GAMES','Kirby'),
  ('GAMES','Crash Bandicoot'),
  ('GAMES','Spyro'),
  ('GAMES','Samus Aran'),
  ('GAMES','Mega Man'),
  ('GAMES','Ryu'),
  ('GAMES','Ken Masters'),
  ('GAMES','Sub-Zero'),
  ('GAMES','Scorpion'),
  ('GAMES','Chun-Li'),
  ('GAMES','Cloud Strife'),
  ('GAMES','Sephiroth'),
  ('GAMES','Steve Minecraft'),
  ('GAMES','Creeper'),
  ('GAMES','Geralt de Rívia'),
  ('GAMES','Ezio Auditore'),
  ('GAMES','Nathan Drake'),
  ('GAMES','Joel Miller'),
  ('GAMES','Ellie Williams')
on conflict(theme,name) do nothing;

insert into public.characters(theme,name) values
  ('ANIMAIS','Cachorro'),
  ('ANIMAIS','Gato'),
  ('ANIMAIS','Leão'),
  ('ANIMAIS','Tigre'),
  ('ANIMAIS','Elefante'),
  ('ANIMAIS','Girafa'),
  ('ANIMAIS','Zebra'),
  ('ANIMAIS','Macaco'),
  ('ANIMAIS','Gorila'),
  ('ANIMAIS','Chimpanzé'),
  ('ANIMAIS','Urso-pardo'),
  ('ANIMAIS','Urso-polar'),
  ('ANIMAIS','Panda'),
  ('ANIMAIS','Lobo'),
  ('ANIMAIS','Raposa'),
  ('ANIMAIS','Hiena'),
  ('ANIMAIS','Rinoceronte'),
  ('ANIMAIS','Hipopótamo'),
  ('ANIMAIS','Cavalo'),
  ('ANIMAIS','Burro'),
  ('ANIMAIS','Jumento'),
  ('ANIMAIS','Vaca'),
  ('ANIMAIS','Touro'),
  ('ANIMAIS','Búfalo'),
  ('ANIMAIS','Bode'),
  ('ANIMAIS','Cabra'),
  ('ANIMAIS','Ovelha'),
  ('ANIMAIS','Porco'),
  ('ANIMAIS','Coelho'),
  ('ANIMAIS','Lebre'),
  ('ANIMAIS','Rato'),
  ('ANIMAIS','Hamster'),
  ('ANIMAIS','Esquilo'),
  ('ANIMAIS','Capivara'),
  ('ANIMAIS','Tamanduá'),
  ('ANIMAIS','Tatu'),
  ('ANIMAIS','Preguiça'),
  ('ANIMAIS','Canguru'),
  ('ANIMAIS','Coala'),
  ('ANIMAIS','Ornitorrinco'),
  ('ANIMAIS','Golfinho'),
  ('ANIMAIS','Baleia'),
  ('ANIMAIS','Orca'),
  ('ANIMAIS','Tubarão'),
  ('ANIMAIS','Arraia'),
  ('ANIMAIS','Polvo'),
  ('ANIMAIS','Lula'),
  ('ANIMAIS','Caranguejo'),
  ('ANIMAIS','Lagosta'),
  ('ANIMAIS','Camarão'),
  ('ANIMAIS','Pinguim'),
  ('ANIMAIS','Avestruz'),
  ('ANIMAIS','Águia'),
  ('ANIMAIS','Falcão'),
  ('ANIMAIS','Coruja'),
  ('ANIMAIS','Papagaio'),
  ('ANIMAIS','Arara'),
  ('ANIMAIS','Tucano'),
  ('ANIMAIS','Pombo'),
  ('ANIMAIS','Galinha'),
  ('ANIMAIS','Galo'),
  ('ANIMAIS','Pato'),
  ('ANIMAIS','Ganso'),
  ('ANIMAIS','Cisne'),
  ('ANIMAIS','Flamingo'),
  ('ANIMAIS','Pavão'),
  ('ANIMAIS','Beija-flor'),
  ('ANIMAIS','Pica-pau'),
  ('ANIMAIS','Canário'),
  ('ANIMAIS','Sabiá'),
  ('ANIMAIS','Jacaré'),
  ('ANIMAIS','Crocodilo'),
  ('ANIMAIS','Iguana'),
  ('ANIMAIS','Camaleão'),
  ('ANIMAIS','Lagarto'),
  ('ANIMAIS','Cobra'),
  ('ANIMAIS','Jiboia'),
  ('ANIMAIS','Sucuri'),
  ('ANIMAIS','Cascavel'),
  ('ANIMAIS','Tartaruga'),
  ('ANIMAIS','Jabuti'),
  ('ANIMAIS','Sapo'),
  ('ANIMAIS','Rã'),
  ('ANIMAIS','Salamandra'),
  ('ANIMAIS','Borboleta'),
  ('ANIMAIS','Abelha'),
  ('ANIMAIS','Formiga'),
  ('ANIMAIS','Mosquito'),
  ('ANIMAIS','Besouro'),
  ('ANIMAIS','Joaninha'),
  ('ANIMAIS','Libélula'),
  ('ANIMAIS','Gafanhoto'),
  ('ANIMAIS','Grilo'),
  ('ANIMAIS','Aranha'),
  ('ANIMAIS','Escorpião'),
  ('ANIMAIS','Minhoca'),
  ('ANIMAIS','Caracol'),
  ('ANIMAIS','Lesma'),
  ('ANIMAIS','Estrela-do-mar'),
  ('ANIMAIS','Cavalo-marinho')
on conflict(theme,name) do nothing;

insert into public.characters(theme,name) values
  ('PAÍSES','Brasil'),
  ('PAÍSES','Argentina'),
  ('PAÍSES','Uruguai'),
  ('PAÍSES','Paraguai'),
  ('PAÍSES','Chile'),
  ('PAÍSES','Peru'),
  ('PAÍSES','Bolívia'),
  ('PAÍSES','Colômbia'),
  ('PAÍSES','Venezuela'),
  ('PAÍSES','Equador'),
  ('PAÍSES','México'),
  ('PAÍSES','Canadá'),
  ('PAÍSES','Estados Unidos'),
  ('PAÍSES','Portugal'),
  ('PAÍSES','Espanha'),
  ('PAÍSES','França'),
  ('PAÍSES','Alemanha'),
  ('PAÍSES','Itália'),
  ('PAÍSES','Reino Unido'),
  ('PAÍSES','Irlanda'),
  ('PAÍSES','Países Baixos'),
  ('PAÍSES','Bélgica'),
  ('PAÍSES','Suíça'),
  ('PAÍSES','Áustria'),
  ('PAÍSES','Polônia'),
  ('PAÍSES','República Tcheca'),
  ('PAÍSES','Eslováquia'),
  ('PAÍSES','Hungria'),
  ('PAÍSES','Romênia'),
  ('PAÍSES','Bulgária'),
  ('PAÍSES','Grécia'),
  ('PAÍSES','Croácia'),
  ('PAÍSES','Sérvia'),
  ('PAÍSES','Eslovênia'),
  ('PAÍSES','Bósnia e Herzegovina'),
  ('PAÍSES','Albânia'),
  ('PAÍSES','Macedônia do Norte'),
  ('PAÍSES','Noruega'),
  ('PAÍSES','Suécia'),
  ('PAÍSES','Finlândia'),
  ('PAÍSES','Dinamarca'),
  ('PAÍSES','Islândia'),
  ('PAÍSES','Estônia'),
  ('PAÍSES','Letônia'),
  ('PAÍSES','Lituânia'),
  ('PAÍSES','Ucrânia'),
  ('PAÍSES','Moldávia'),
  ('PAÍSES','Geórgia'),
  ('PAÍSES','Armênia'),
  ('PAÍSES','Azerbaijão'),
  ('PAÍSES','Turquia'),
  ('PAÍSES','Rússia'),
  ('PAÍSES','China'),
  ('PAÍSES','Japão'),
  ('PAÍSES','Coreia do Sul'),
  ('PAÍSES','Coreia do Norte'),
  ('PAÍSES','Índia'),
  ('PAÍSES','Paquistão'),
  ('PAÍSES','Bangladesh'),
  ('PAÍSES','Nepal'),
  ('PAÍSES','Butão'),
  ('PAÍSES','Sri Lanka'),
  ('PAÍSES','Maldivas'),
  ('PAÍSES','Tailândia'),
  ('PAÍSES','Vietnã'),
  ('PAÍSES','Laos'),
  ('PAÍSES','Camboja'),
  ('PAÍSES','Malásia'),
  ('PAÍSES','Singapura'),
  ('PAÍSES','Indonésia'),
  ('PAÍSES','Filipinas'),
  ('PAÍSES','Mongólia'),
  ('PAÍSES','Cazaquistão'),
  ('PAÍSES','Uzbequistão'),
  ('PAÍSES','Israel'),
  ('PAÍSES','Jordânia'),
  ('PAÍSES','Líbano'),
  ('PAÍSES','Arábia Saudita'),
  ('PAÍSES','Emirados Árabes Unidos'),
  ('PAÍSES','Catar'),
  ('PAÍSES','Kuwait'),
  ('PAÍSES','Egito'),
  ('PAÍSES','Marrocos'),
  ('PAÍSES','Argélia'),
  ('PAÍSES','Tunísia'),
  ('PAÍSES','África do Sul'),
  ('PAÍSES','Nigéria'),
  ('PAÍSES','Gana'),
  ('PAÍSES','Quênia'),
  ('PAÍSES','Etiópia'),
  ('PAÍSES','Angola'),
  ('PAÍSES','Moçambique'),
  ('PAÍSES','Madagascar'),
  ('PAÍSES','Austrália'),
  ('PAÍSES','Nova Zelândia'),
  ('PAÍSES','Fiji'),
  ('PAÍSES','Cuba'),
  ('PAÍSES','Jamaica'),
  ('PAÍSES','Haiti'),
  ('PAÍSES','Panamá'),
  ('PAÍSES','Costa Rica')
on conflict(theme,name) do nothing;

insert into public.characters(theme,name) values
  ('PROFISSÕES','Médico'),
  ('PROFISSÕES','Enfermeiro'),
  ('PROFISSÕES','Dentista'),
  ('PROFISSÕES','Veterinário'),
  ('PROFISSÕES','Psicólogo'),
  ('PROFISSÕES','Fisioterapeuta'),
  ('PROFISSÕES','Nutricionista'),
  ('PROFISSÕES','Farmacêutico'),
  ('PROFISSÕES','Professor'),
  ('PROFISSÕES','Pedagogo'),
  ('PROFISSÕES','Advogado'),
  ('PROFISSÕES','Juiz'),
  ('PROFISSÕES','Promotor'),
  ('PROFISSÕES','Policial'),
  ('PROFISSÕES','Bombeiro'),
  ('PROFISSÕES','Militar'),
  ('PROFISSÕES','Engenheiro civil'),
  ('PROFISSÕES','Engenheiro mecânico'),
  ('PROFISSÕES','Engenheiro elétrico'),
  ('PROFISSÕES','Arquiteto'),
  ('PROFISSÕES','Designer'),
  ('PROFISSÕES','Programador'),
  ('PROFISSÕES','Analista de sistemas'),
  ('PROFISSÕES','Cientista de dados'),
  ('PROFISSÕES','Contador'),
  ('PROFISSÕES','Administrador'),
  ('PROFISSÕES','Economista'),
  ('PROFISSÕES','Bancário'),
  ('PROFISSÕES','Corretor de imóveis'),
  ('PROFISSÕES','Vendedor'),
  ('PROFISSÕES','Caixa'),
  ('PROFISSÕES','Atendente'),
  ('PROFISSÕES','Garçom'),
  ('PROFISSÕES','Cozinheiro'),
  ('PROFISSÕES','Chef de cozinha'),
  ('PROFISSÕES','Padeiro'),
  ('PROFISSÕES','Confeiteiro'),
  ('PROFISSÕES','Açougueiro'),
  ('PROFISSÕES','Motorista'),
  ('PROFISSÕES','Caminhoneiro'),
  ('PROFISSÕES','Motoboy'),
  ('PROFISSÕES','Piloto de avião'),
  ('PROFISSÕES','Comissário de bordo'),
  ('PROFISSÕES','Mecânico'),
  ('PROFISSÕES','Eletricista'),
  ('PROFISSÕES','Encanador'),
  ('PROFISSÕES','Pedreiro'),
  ('PROFISSÕES','Pintor'),
  ('PROFISSÕES','Marceneiro'),
  ('PROFISSÕES','Serralheiro'),
  ('PROFISSÕES','Soldador'),
  ('PROFISSÕES','Jardineiro'),
  ('PROFISSÕES','Agricultor'),
  ('PROFISSÕES','Pecuarista'),
  ('PROFISSÕES','Biólogo'),
  ('PROFISSÕES','Químico'),
  ('PROFISSÕES','Físico'),
  ('PROFISSÕES','Astrônomo'),
  ('PROFISSÕES','Geólogo'),
  ('PROFISSÕES','Arqueólogo'),
  ('PROFISSÕES','Jornalista'),
  ('PROFISSÕES','Fotógrafo'),
  ('PROFISSÕES','Cinegrafista'),
  ('PROFISSÕES','Editor de vídeo'),
  ('PROFISSÕES','Ator'),
  ('PROFISSÕES','Atriz'),
  ('PROFISSÕES','Cantor'),
  ('PROFISSÕES','Músico'),
  ('PROFISSÕES','Dançarino'),
  ('PROFISSÕES','DJ'),
  ('PROFISSÕES','Escritor'),
  ('PROFISSÕES','Poeta'),
  ('PROFISSÕES','Tradutor'),
  ('PROFISSÕES','Intérprete'),
  ('PROFISSÕES','Publicitário'),
  ('PROFISSÕES','Influenciador'),
  ('PROFISSÕES','Youtuber'),
  ('PROFISSÕES','Streamer'),
  ('PROFISSÕES','Jogador de futebol'),
  ('PROFISSÕES','Jogador de basquete'),
  ('PROFISSÕES','Árbitro'),
  ('PROFISSÕES','Personal trainer'),
  ('PROFISSÕES','Cabeleireiro'),
  ('PROFISSÕES','Barbeiro'),
  ('PROFISSÕES','Maquiador'),
  ('PROFISSÕES','Manicure'),
  ('PROFISSÕES','Costureiro'),
  ('PROFISSÕES','Estilista'),
  ('PROFISSÕES','Joalheiro'),
  ('PROFISSÕES','Relojoeiro'),
  ('PROFISSÕES','Carteiro'),
  ('PROFISSÕES','Bibliotecário'),
  ('PROFISSÕES','Recepcionista'),
  ('PROFISSÕES','Secretário'),
  ('PROFISSÕES','Segurança'),
  ('PROFISSÕES','Vigilante'),
  ('PROFISSÕES','Faxineiro'),
  ('PROFISSÕES','Lixeiro'),
  ('PROFISSÕES','Guia turístico'),
  ('PROFISSÕES','Cientista')
on conflict(theme,name) do nothing;

insert into public.characters(theme,name) values
  ('OBJETOS','Celular'),
  ('OBJETOS','Notebook'),
  ('OBJETOS','Computador'),
  ('OBJETOS','Televisão'),
  ('OBJETOS','Controle remoto'),
  ('OBJETOS','Fone de ouvido'),
  ('OBJETOS','Caixa de som'),
  ('OBJETOS','Relógio'),
  ('OBJETOS','Óculos'),
  ('OBJETOS','Boné'),
  ('OBJETOS','Chapéu'),
  ('OBJETOS','Camiseta'),
  ('OBJETOS','Calça'),
  ('OBJETOS','Tênis'),
  ('OBJETOS','Sapato'),
  ('OBJETOS','Chinelo'),
  ('OBJETOS','Meia'),
  ('OBJETOS','Mochila'),
  ('OBJETOS','Mala'),
  ('OBJETOS','Carteira'),
  ('OBJETOS','Chave'),
  ('OBJETOS','Cadeado'),
  ('OBJETOS','Tesoura'),
  ('OBJETOS','Faca'),
  ('OBJETOS','Garfo'),
  ('OBJETOS','Colher'),
  ('OBJETOS','Prato'),
  ('OBJETOS','Copo'),
  ('OBJETOS','Caneca'),
  ('OBJETOS','Garrafa'),
  ('OBJETOS','Panela'),
  ('OBJETOS','Frigideira'),
  ('OBJETOS','Liquidificador'),
  ('OBJETOS','Batedeira'),
  ('OBJETOS','Geladeira'),
  ('OBJETOS','Fogão'),
  ('OBJETOS','Micro-ondas'),
  ('OBJETOS','Torradeira'),
  ('OBJETOS','Cafeteira'),
  ('OBJETOS','Ventilador'),
  ('OBJETOS','Ar-condicionado'),
  ('OBJETOS','Sofá'),
  ('OBJETOS','Cadeira'),
  ('OBJETOS','Mesa'),
  ('OBJETOS','Cama'),
  ('OBJETOS','Travesseiro'),
  ('OBJETOS','Cobertor'),
  ('OBJETOS','Toalha'),
  ('OBJETOS','Espelho'),
  ('OBJETOS','Escova de dentes'),
  ('OBJETOS','Pasta de dente'),
  ('OBJETOS','Sabonete'),
  ('OBJETOS','Shampoo'),
  ('OBJETOS','Pente'),
  ('OBJETOS','Escova de cabelo'),
  ('OBJETOS','Livro'),
  ('OBJETOS','Caderno'),
  ('OBJETOS','Caneta'),
  ('OBJETOS','Lápis'),
  ('OBJETOS','Borracha'),
  ('OBJETOS','Régua'),
  ('OBJETOS','Apontador'),
  ('OBJETOS','Calculadora'),
  ('OBJETOS','Grampeador'),
  ('OBJETOS','Clipe'),
  ('OBJETOS','Papel'),
  ('OBJETOS','Envelope'),
  ('OBJETOS','Caixa'),
  ('OBJETOS','Martelo'),
  ('OBJETOS','Chave de fenda'),
  ('OBJETOS','Alicate'),
  ('OBJETOS','Furadeira'),
  ('OBJETOS','Serrote'),
  ('OBJETOS','Escada'),
  ('OBJETOS','Vassoura'),
  ('OBJETOS','Rodo'),
  ('OBJETOS','Balde'),
  ('OBJETOS','Mangueira'),
  ('OBJETOS','Guarda-chuva'),
  ('OBJETOS','Bicicleta'),
  ('OBJETOS','Patinete'),
  ('OBJETOS','Skate'),
  ('OBJETOS','Bola'),
  ('OBJETOS','Raquete'),
  ('OBJETOS','Violão'),
  ('OBJETOS','Guitarra'),
  ('OBJETOS','Piano'),
  ('OBJETOS','Microfone'),
  ('OBJETOS','Câmera'),
  ('OBJETOS','Tripé'),
  ('OBJETOS','Lanterna'),
  ('OBJETOS','Vela'),
  ('OBJETOS','Isqueiro'),
  ('OBJETOS','Brinquedo'),
  ('OBJETOS','Boneca'),
  ('OBJETOS','Quebra-cabeça'),
  ('OBJETOS','Dado'),
  ('OBJETOS','Baralho'),
  ('OBJETOS','Capacete'),
  ('OBJETOS','Extintor')
on conflict(theme,name) do nothing;

insert into public.characters(theme,name) values
  ('COMIDAS','Pizza'),
  ('COMIDAS','Hambúrguer'),
  ('COMIDAS','Cachorro-quente'),
  ('COMIDAS','Lasanha'),
  ('COMIDAS','Macarrão'),
  ('COMIDAS','Arroz'),
  ('COMIDAS','Feijão'),
  ('COMIDAS','Bife'),
  ('COMIDAS','Frango assado'),
  ('COMIDAS','Peixe'),
  ('COMIDAS','Sushi'),
  ('COMIDAS','Temaki'),
  ('COMIDAS','Pastel'),
  ('COMIDAS','Coxinha'),
  ('COMIDAS','Kibe'),
  ('COMIDAS','Esfiha'),
  ('COMIDAS','Pão de queijo'),
  ('COMIDAS','Pão francês'),
  ('COMIDAS','Tapioca'),
  ('COMIDAS','Cuscuz'),
  ('COMIDAS','Feijoada'),
  ('COMIDAS','Churrasco'),
  ('COMIDAS','Strogonoff'),
  ('COMIDAS','Risoto'),
  ('COMIDAS','Nhoque'),
  ('COMIDAS','Panqueca'),
  ('COMIDAS','Omelete'),
  ('COMIDAS','Salada'),
  ('COMIDAS','Sopa'),
  ('COMIDAS','Caldo'),
  ('COMIDAS','Batata frita'),
  ('COMIDAS','Purê de batata'),
  ('COMIDAS','Mandioca frita'),
  ('COMIDAS','Polenta'),
  ('COMIDAS','Milho cozido'),
  ('COMIDAS','Pipoca'),
  ('COMIDAS','Brigadeiro'),
  ('COMIDAS','Beijinho'),
  ('COMIDAS','Pudim'),
  ('COMIDAS','Bolo de chocolate'),
  ('COMIDAS','Bolo de cenoura'),
  ('COMIDAS','Sorvete'),
  ('COMIDAS','Açaí'),
  ('COMIDAS','Chocolate'),
  ('COMIDAS','Paçoca'),
  ('COMIDAS','Pé de moleque'),
  ('COMIDAS','Doce de leite'),
  ('COMIDAS','Goiabada'),
  ('COMIDAS','Romeu e Julieta'),
  ('COMIDAS','Mousse'),
  ('COMIDAS','Gelatina'),
  ('COMIDAS','Churros'),
  ('COMIDAS','Donut'),
  ('COMIDAS','Cookie'),
  ('COMIDAS','Brownie'),
  ('COMIDAS','Croissant'),
  ('COMIDAS','Waffle'),
  ('COMIDAS','Cereal'),
  ('COMIDAS','Iogurte'),
  ('COMIDAS','Queijo'),
  ('COMIDAS','Presunto'),
  ('COMIDAS','Salame'),
  ('COMIDAS','Ovo'),
  ('COMIDAS','Bacon'),
  ('COMIDAS','Linguiça'),
  ('COMIDAS','Salsicha'),
  ('COMIDAS','Alface'),
  ('COMIDAS','Tomate'),
  ('COMIDAS','Cenoura'),
  ('COMIDAS','Beterraba'),
  ('COMIDAS','Abóbora'),
  ('COMIDAS','Abobrinha'),
  ('COMIDAS','Berinjela'),
  ('COMIDAS','Brócolis'),
  ('COMIDAS','Couve-flor'),
  ('COMIDAS','Espinafre'),
  ('COMIDAS','Banana'),
  ('COMIDAS','Maçã'),
  ('COMIDAS','Laranja'),
  ('COMIDAS','Uva'),
  ('COMIDAS','Morango'),
  ('COMIDAS','Manga'),
  ('COMIDAS','Abacaxi'),
  ('COMIDAS','Melancia'),
  ('COMIDAS','Melão'),
  ('COMIDAS','Mamão'),
  ('COMIDAS','Pera'),
  ('COMIDAS','Pêssego'),
  ('COMIDAS','Kiwi'),
  ('COMIDAS','Limão'),
  ('COMIDAS','Coco'),
  ('COMIDAS','Maracujá'),
  ('COMIDAS','Goiaba'),
  ('COMIDAS','Ameixa'),
  ('COMIDAS','Cereja'),
  ('COMIDAS','Jabuticaba'),
  ('COMIDAS','Acerola'),
  ('COMIDAS','Castanha'),
  ('COMIDAS','Amendoim'),
  ('COMIDAS','Granola')
on conflict(theme,name) do nothing;

-- 004: palpite digitado (sem lista de nomes), troca/sorteio de tema entre
-- rodadas e ranking que soma os pontos a cada acerto.

-- Normaliza nomes para comparar palpites: sem acentos, minúsculo, só letras/números.
create or replace function public.norm_name(p text) returns text language sql immutable set search_path='' as $$
 select trim(regexp_replace(regexp_replace(lower(translate(coalesce(p,''),
   'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
   'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN')),'[^a-z0-9 ]',' ','g'),'\s+',' ','g'));
$$;

-- Sorteia um tema que tenha personagens suficientes para a sala.
create or replace function public.random_theme(p_min int default 4) returns text language sql volatile set search_path='' as $$
 select theme from public.characters where active group by theme having count(*)>=p_min order by random() limit 1;
$$;

-- Palpite digitado: o servidor compara com o nome (e apelidos) da identidade secreta.
create or replace function public.submit_guess_text(p_room_id uuid,p_round_no int,p_guess text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare cid bigint; ok boolean;begin
 if char_length(trim(coalesce(p_guess,'')))=0 then raise exception 'Digite um nome';end if;
 select s.character_id into cid from public.secret_characters s where s.room_id=p_room_id and s.round_no=p_round_no and s.player_id=auth.uid();
 select exists(select 1 from public.characters c where c.id=cid and (public.norm_name(c.name)=public.norm_name(p_guess)
   or exists(select 1 from unnest(c.aliases) a where public.norm_name(a)=public.norm_name(p_guess)))) into ok;
 return public.submit_guess(p_room_id,p_round_no,case when ok then cid else -1 end);
end$$;

-- Pontos entram no perfil (ranking) no momento do acerto; o fim da partida soma
-- apenas partidas/vitórias/derrotas.
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
 update public.profiles set points=points+base+bonus,xp=xp+base+bonus,level=1+(xp+base+bonus)/500 where id=auth.uid();
 perform public.check_round_end(p_room_id,p_round_no);
 return jsonb_build_object('correct',true,'character_name',cname,'placement',place,'points',base+bonus);end$$;

-- Próxima rodada com tema opcional: null = mantém, 'SORTEADO' = sorteia um tema.
create or replace function public.next_round(p_room_id uuid,p_theme text) returns boolean language plpgsql security definer set search_path='' as $$
declare r public.rooms; top int; nt text;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or r.host_id<>auth.uid() then raise exception 'Somente o host';end if;
 if r.status<>'round_result' then raise exception 'A rodada ainda não terminou';end if;
 if r.current_round>=r.total_rounds then
   update public.rooms set status='finished',turn_user_id=null,turn_question_id=null where id=p_room_id;
   select max(score) into top from public.room_players where room_id=p_room_id and status<>'left';
   update public.profiles p set
     matches=matches+1,
     wins=wins+case when x.score=top then 1 else 0 end,
     losses=losses+case when x.score=top then 0 else 1 end,
     current_streak=case when x.score=top then current_streak+1 else 0 end,
     best_streak=greatest(best_streak,case when x.score=top then current_streak+1 else 0 end)
   from public.room_players x where x.room_id=p_room_id and x.user_id=p.id and x.status<>'left';
   return true;
 end if;
 nt:=nullif(trim(coalesce(p_theme,'')),'');
 if nt='SORTEADO' then nt:=public.random_theme();
 elsif nt is not null and nt not in('ALEATÓRIO','TUDO MISTURADO') and not exists(select 1 from public.characters where theme=nt and active) then raise exception 'Tema sem personagens';end if;
 update public.rooms set current_round=current_round+1,status='playing',theme=coalesce(nt,theme) where id=p_room_id;
 perform public.assign_round(p_room_id,r.current_round+1); perform public.advance_turn(p_room_id); return true;end$$;

create or replace function public.next_round(p_room_id uuid) returns boolean language sql security definer set search_path='' as $$
 select public.next_round(p_room_id,null::text);
$$;

-- Criar sala com tema sorteado.
create or replace function public.create_room(p_theme text,p_rounds int,p_game_mode text,p_turn_seconds int)
returns uuid language plpgsql security definer set search_path='' as $$
declare rid uuid; t text:=p_theme;begin
 if auth.uid() is null then raise exception 'Faça login';end if;
 if p_rounds not between 1 and 10 then raise exception 'Número de rodadas inválido';end if;
 if p_game_mode not in('FREE','TURNS') then raise exception 'Modo inválido';end if;
 if p_turn_seconds not between 0 and 300 then raise exception 'Tempo inválido';end if;
 if t='SORTEADO' then t:=public.random_theme();end if;
 if t not in('ALEATÓRIO','TUDO MISTURADO') and not exists(select 1 from public.characters where theme=t and active) then raise exception 'Tema sem personagens';end if;
 insert into public.rooms(code,host_id,theme,total_rounds,game_mode,turn_seconds) values(public.make_code(),auth.uid(),t,p_rounds,p_game_mode,p_turn_seconds) returning id into rid;
 insert into public.room_players(room_id,user_id) values(rid,auth.uid()); return rid;end$$;

revoke execute on function public.random_theme(int) from public, anon, authenticated;
revoke execute on function public.submit_guess_text(uuid,int,text),public.submit_guess(uuid,int,bigint),public.next_round(uuid,text),public.next_round(uuid),public.create_room(text,int,text,int) from public, anon;
grant execute on function public.submit_guess_text(uuid,int,text),public.submit_guess(uuid,int,bigint),public.next_round(uuid,text),public.next_round(uuid),public.create_room(text,int,text,int) to authenticated;

-- Pontos de partidas em andamento (antes desta migration iam só no final).
update public.profiles p set points=p.points+x.s,xp=p.xp+x.s,level=1+(p.xp+x.s)/500
from (select user_id,sum(score) s from public.room_players rp join public.rooms r on r.id=rp.room_id where r.status<>'finished' group by user_id) x
where x.user_id=p.id and x.s>0;

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

-- 006: host altera tema, rodadas e tempo por vez enquanto a sala está no lobby.
create or replace function public.update_room_settings(p_room_id uuid,p_theme text,p_rounds int,p_turn_seconds int)
returns text language plpgsql security definer set search_path='' as $$
declare r public.rooms; t text:=p_theme;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or r.host_id<>auth.uid() then raise exception 'Somente o host pode alterar a sala';end if;
 if r.status<>'lobby' then raise exception 'A partida já começou';end if;
 if p_rounds not between 1 and 10 then raise exception 'Número de rodadas inválido';end if;
 if p_turn_seconds not between 0 and 300 then raise exception 'Tempo inválido';end if;
 if t='SORTEADO' then t:=public.random_theme();end if;
 if t not in('ALEATÓRIO','TUDO MISTURADO') and not exists(select 1 from public.characters where theme=t and active) then raise exception 'Tema sem personagens';end if;
 update public.rooms set theme=t,total_rounds=p_rounds,turn_seconds=p_turn_seconds where id=p_room_id;
 return t;end$$;
revoke execute on function public.update_room_settings(uuid,text,int,int) from public, anon;
grant execute on function public.update_room_settings(uuid,text,int,int) to authenticated;

-- 007: pular a vez é idempotente. Quando o tempo acaba, vários aparelhos pedem
-- para pular; antes, um pedido atrasado (principalmente do host, que não passava
-- pela checagem de tempo) pulava de novo e a vez voltava para quem perguntou.
-- Agora o pedido informa qual vez quer pular (turn_started_at) e é ignorado
-- se essa vez já terminou.
create or replace function public.skip_turn(p_room_id uuid,p_turn_started_at timestamptz) returns boolean
language plpgsql security definer set search_path='' as $$
declare r public.rooms;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 if r.status<>'playing' then return false;end if;
 if r.turn_started_at is distinct from p_turn_started_at then return false;end if;
 if r.host_id<>auth.uid() and not (r.turn_seconds>0 and now()>=r.turn_started_at+make_interval(secs=>r.turn_seconds)) then
   raise exception 'Somente o host pode pular a vez antes do tempo acabar';end if;
 perform public.advance_turn(p_room_id); return true;end$$;
revoke execute on function public.skip_turn(uuid,timestamptz) from public, anon;
grant execute on function public.skip_turn(uuid,timestamptz) to authenticated;

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

