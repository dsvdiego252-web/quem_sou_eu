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
