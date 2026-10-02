-- 010: dica paga, palpite tolerante, revanche, partida rápida, conquistas e ranking semanal.
create schema if not exists extensions;
create extension if not exists fuzzystrmatch with schema extensions;

alter table public.rooms add column if not exists is_public boolean not null default false;
alter table public.rooms add column if not exists rematch_room_id uuid references public.rooms(id) on delete set null;
alter table public.characters add column if not exists image_url text;
alter table public.profiles add column if not exists is_admin boolean not null default false;

-- Dicas compradas (visíveis para a sala; os outros já sabem a identidade de quem comprou).
create table if not exists public.player_hints(
 room_id uuid references public.rooms(id) on delete cascade,
 round_no int not null,
 user_id uuid references public.profiles(id) on delete cascade,
 hint_no int not null,
 hint text not null,
 created_at timestamptz not null default now(),
 primary key(room_id,round_no,user_id,hint_no)
);
alter table public.player_hints enable row level security;
do $$ begin create policy hints_member_read on public.player_hints for select to authenticated using(public.is_room_member(room_id));
exception when duplicate_object then null; end $$;
revoke all on public.player_hints from anon, authenticated;
grant select on public.player_hints to authenticated;

-- Histórico de pontos (ranking semanal).
create table if not exists public.score_events(
 id bigint generated always as identity primary key,
 user_id uuid not null references public.profiles(id) on delete cascade,
 room_id uuid references public.rooms(id) on delete set null,
 points int not null,
 reason text not null,
 created_at timestamptz not null default now()
);
alter table public.score_events enable row level security;
revoke all on public.score_events from anon, authenticated;
create index if not exists score_events_created_idx on public.score_events(created_at);
create index if not exists score_events_user_idx on public.score_events(user_id);
create index if not exists score_events_room_idx on public.score_events(room_id);

-- Conquistas.
create table if not exists public.user_achievements(
 user_id uuid references public.profiles(id) on delete cascade,
 code text not null,
 earned_at timestamptz not null default now(),
 primary key(user_id,code)
);
alter table public.user_achievements enable row level security;
do $$ begin create policy achievements_read on public.user_achievements for select to authenticated using(true);
exception when duplicate_object then null; end $$;
revoke all on public.user_achievements from anon, authenticated;
grant select on public.user_achievements to authenticated;

create or replace function public.award(p_user uuid,p_code text) returns void language sql security definer set search_path='' as $$
 insert into public.user_achievements(user_id,code) values(p_user,p_code) on conflict do nothing;
$$;

-- Palpite tolerante: nome/apelido exato (sem acento), sobrenome, ou pequenos erros de digitação.
create or replace function public.guess_matches(p_character_id bigint,p_guess text) returns boolean language plpgsql stable security definer set search_path='' as $$
declare c public.characters; g text:=public.norm_name(p_guess); n text; last text; tol int;begin
 select * into c from public.characters where id=p_character_id;
 if c.id is null or g='' then return false;end if;
 n:=public.norm_name(c.name);
 if g=n or exists(select 1 from unnest(c.aliases) a where public.norm_name(a)=g) then return true;end if;
 -- sobrenome: última palavra ou duas últimas (ex.: "o neal"), com pelo menos 3 letras
 last:=regexp_replace(n,'^.* ','');
 if position(' ' in n)>0 and char_length(replace(g,' ',''))>=3 and (g=last or g=regexp_replace(n,'^(.* )?(\S+ \S+)$','\2')) then return true;end if;
 tol:=case when char_length(n)>=10 then 2 when char_length(n)>=5 then 1 else 0 end;
 return tol>0 and extensions.levenshtein(g,n)<=tol;
end$$;

create or replace function public.submit_guess_text(p_room_id uuid,p_round_no int,p_guess text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare cid bigint;begin
 if char_length(trim(coalesce(p_guess,'')))=0 then raise exception 'Digite um nome';end if;
 select s.character_id into cid from public.secret_characters s where s.room_id=p_room_id and s.round_no=p_round_no and s.player_id=auth.uid();
 return public.submit_guess(p_room_id,p_round_no,case when public.guess_matches(cid,p_guess) then cid else -1 end);
end$$;

create or replace function public.submit_guess(p_room_id uuid,p_round_no int,p_character_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.rooms; s public.secret_characters; rp public.room_players; total int; place int; qcount int; base int:=0; bonus int:=0; cname text; gname text; ncorrect int;begin
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
 insert into public.score_events(user_id,room_id,points,reason) values(auth.uid(),p_room_id,base+bonus,'guess');
 perform public.award(auth.uid(),'primeiro_acerto');
 if qcount<=1 then perform public.award(auth.uid(),'genio');end if;
 if s.wrong_attempts=0 and place=1 then perform public.award(auth.uid(),'certeiro');end if;
 select count(*) into ncorrect from public.score_events where user_id=auth.uid() and reason='guess';
 if ncorrect>=10 then perform public.award(auth.uid(),'dez_acertos');end if;
 if ncorrect>=50 then perform public.award(auth.uid(),'cinquenta_acertos');end if;
 perform public.check_round_end(p_room_id,p_round_no);
 return jsonb_build_object('correct',true,'character_name',cname,'placement',place,'points',base+bonus);end$$;

-- Dica paga: 80 pontos cada, no máximo 2 por rodada.
create or replace function public.buy_hint(p_room_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.rooms; s public.secret_characters; c public.characters; used int; h text; cost constant int:=80; n text; words int;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 if r.status<>'playing' then raise exception 'A rodada não está em andamento';end if;
 select * into s from public.secret_characters where room_id=p_room_id and round_no=r.current_round and player_id=auth.uid();
 if not found or s.revealed then raise exception 'Você já descobriu quem é';end if;
 select count(*) into used from public.player_hints where room_id=p_room_id and round_no=r.current_round and user_id=auth.uid();
 if used>=2 then raise exception 'Você já usou as 2 dicas desta rodada';end if;
 select * into c from public.characters where id=s.character_id;
 n:=trim(c.name); words:=array_length(regexp_split_to_array(n,'\s+'),1);
 if used=0 then
   h:=case when r.theme in('ALEATÓRIO','TUDO MISTURADO') then 'Seu tema é '||c.theme||'. ' else '' end
     ||'Seu nome tem '||words||' palavra'||case when words>1 then 's' else '' end||' e '||char_length(replace(n,' ',''))||' letras.';
 else
   h:='Seu nome começa com "'||upper(left(n,1))||'" e termina com "'||lower(right(n,1))||'".';
 end if;
 insert into public.player_hints(room_id,round_no,user_id,hint_no,hint) values(p_room_id,r.current_round,auth.uid(),used+1,h);
 update public.room_players set score=score-cost where room_id=p_room_id and user_id=auth.uid();
 update public.profiles set points=greatest(0,points-cost) where id=auth.uid();
 insert into public.score_events(user_id,room_id,points,reason) values(auth.uid(),p_room_id,-cost,'hint');
 return jsonb_build_object('hint',h,'cost',cost,'remaining',1-used);
end$$;

-- Fim de partida: conquistas de vitórias/partidas/sequência.
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
   insert into public.user_achievements(user_id,code)
    select p.id,a.code from public.profiles p join public.room_players x on x.user_id=p.id and x.room_id=p_room_id and x.status<>'left'
    cross join lateral (values
      ('primeira_partida',p.matches>=1),('veterano',p.matches>=10),('primeira_vitoria',p.wins>=1),
      ('dez_vitorias',p.wins>=10),('sequencia_3',p.best_streak>=3),('sequencia_5',p.best_streak>=5)) a(code,ok)
    where a.ok on conflict do nothing;
   return true;
 end if;
 nt:=nullif(trim(coalesce(p_theme,'')),'');
 if nt='SORTEADO' then nt:=public.random_theme();
 elsif nt is not null and nt not in('ALEATÓRIO','TUDO MISTURADO') and not exists(select 1 from public.characters where theme=nt and active) then raise exception 'Tema sem personagens';end if;
 update public.rooms set current_round=current_round+1,status='playing',theme=coalesce(nt,theme) where id=p_room_id;
 perform public.assign_round(p_room_id,r.current_round+1); perform public.advance_turn(p_room_id); return true;end$$;

-- Revanche: o host cria uma sala nova com as mesmas configurações e os mesmos jogadores.
create or replace function public.rematch(p_room_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare r public.rooms; nid uuid;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or not public.is_room_member(p_room_id,auth.uid()) then raise exception 'Sem acesso';end if;
 if r.rematch_room_id is not null then return r.rematch_room_id;end if;
 if r.status<>'finished' or coalesce(r.end_reason,'')='abandoned' then raise exception 'Revanche só ao fim de uma partida';end if;
 if r.host_id<>auth.uid() then raise exception 'Somente o host pode pedir revanche';end if;
 insert into public.rooms(code,host_id,theme,total_rounds,game_mode,turn_seconds,max_players)
  values(public.make_code(),auth.uid(),r.theme,r.total_rounds,r.game_mode,r.turn_seconds,r.max_players) returning id into nid;
 insert into public.room_players(room_id,user_id,joined_at)
  select nid,user_id,joined_at from public.room_players where room_id=p_room_id and status<>'left';
 update public.rooms set rematch_room_id=nid where id=p_room_id;
 return nid;end$$;

-- Partida rápida: entra numa sala pública aberta ou cria uma.
create or replace function public.quick_match() returns uuid language plpgsql security definer set search_path='' as $$
declare rid uuid;begin
 if auth.uid() is null then raise exception 'Faça login';end if;
 select r.id into rid from public.rooms r
  where r.is_public and r.status='lobby' and r.created_at>now()-interval '30 minutes'
    and not exists(select 1 from public.room_players x where x.room_id=r.id and x.user_id=auth.uid())
    and (select count(*) from public.room_players x where x.room_id=r.id and x.status<>'left')<r.max_players
    and exists(select 1 from public.room_players x join public.room_presence pr on pr.room_id=x.room_id and pr.user_id=x.user_id
               where x.room_id=r.id and x.status<>'left' and pr.last_seen>now()-interval '45 seconds')
  order by r.created_at limit 1 for update skip locked;
 if rid is not null then
   insert into public.room_players(room_id,user_id) values(rid,auth.uid()) on conflict(room_id,user_id) do update set status='connected';
   return rid;
 end if;
 insert into public.rooms(code,host_id,theme,total_rounds,game_mode,turn_seconds,is_public)
  values(public.make_code(),auth.uid(),public.random_theme(),5,'TURNS',60,true) returning id into rid;
 insert into public.room_players(room_id,user_id) values(rid,auth.uid());
 return rid;end$$;

-- Ranking da semana (segunda a domingo, horário de Brasília).
create or replace function public.weekly_ranking() returns table(username text,avatar jsonb,points bigint,guesses bigint)
language sql stable security definer set search_path='' as $$
 select p.username,p.avatar,sum(e.points) points,count(*) filter(where e.reason='guess') guesses
 from public.score_events e join public.profiles p on p.id=e.user_id
 where e.created_at>=(date_trunc('week',now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo')
 group by p.id having sum(e.points)>0 order by points desc limit 50;
$$;

-- Admin: cadastro de personagens e temas.
do $$ begin create policy chars_admin_read on public.characters for select to authenticated using(exists(select 1 from public.profiles where id=(select auth.uid()) and is_admin));
exception when duplicate_object then null; end $$;
do $$ begin create policy chars_admin_insert on public.characters for insert to authenticated with check(exists(select 1 from public.profiles where id=(select auth.uid()) and is_admin));
exception when duplicate_object then null; end $$;
do $$ begin create policy chars_admin_update on public.characters for update to authenticated using(exists(select 1 from public.profiles where id=(select auth.uid()) and is_admin)) with check(exists(select 1 from public.profiles where id=(select auth.uid()) and is_admin));
exception when duplicate_object then null; end $$;
grant insert,update on public.characters to authenticated;

revoke execute on function public.award(uuid,text),public.guess_matches(bigint,text) from public, anon, authenticated;
revoke execute on function public.submit_guess_text(uuid,int,text),public.submit_guess(uuid,int,bigint),public.buy_hint(uuid),public.next_round(uuid,text),public.rematch(uuid),public.quick_match(),public.weekly_ranking() from public, anon;
grant execute on function public.submit_guess_text(uuid,int,text),public.submit_guess(uuid,int,bigint),public.buy_hint(uuid),public.next_round(uuid,text),public.rematch(uuid),public.quick_match(),public.weekly_ranking() to authenticated;

-- Pontos já ganhos nesta semana entram no ranking semanal; conquistas retroativas.
insert into public.score_events(user_id,room_id,points,reason,created_at)
 select rp.user_id,rp.room_id,rp.score,'guess',r.created_at from public.room_players rp join public.rooms r on r.id=rp.room_id
 where rp.score>0 and not exists(select 1 from public.score_events e where e.room_id=rp.room_id and e.user_id=rp.user_id);
insert into public.user_achievements(user_id,code) select id,'primeiro_acerto' from public.profiles where points>0 on conflict do nothing;
