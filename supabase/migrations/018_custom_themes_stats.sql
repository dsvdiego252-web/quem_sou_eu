-- 018: temas criados pelos jogadores ("Temas da galera") e estatísticas por tema no perfil.
-- Um tema da galera é um conjunto de personagens com dono (characters.owner_id). O nome do tema
-- sempre começa com "★ " e é único; só o dono e os amigos dele podem jogar com o tema.
-- Esses personagens nunca entram nos temas oficiais, no ALEATÓRIO nem no sorteio.

alter table public.characters add column if not exists owner_id uuid references public.profiles(id) on delete cascade;
create index if not exists characters_owner_idx on public.characters(owner_id) where owner_id is not null;

create or replace function public.are_friends(p_a uuid,p_b uuid) returns boolean language sql stable security definer set search_path='' as $$
 select p_a=p_b or exists(select 1 from public.friendships f where f.status='accepted'
   and ((f.requester=p_a and f.addressee=p_b) or (f.requester=p_b and f.addressee=p_a)));
$$;

-- Personagens com dono só aparecem para o dono, os amigos dele e quem jogou com eles numa sala.
alter policy chars_read on public.characters using(
 active and (owner_id is null or public.are_friends(owner_id,(select auth.uid()))
   or exists(select 1 from public.secret_characters s where s.character_id=characters.id and public.is_room_member(s.room_id))));

-- Temas oficiais (sem dono).
create or replace function public.list_themes() returns table(theme text,total bigint) language sql stable security definer set search_path='' as $$
 select theme,count(*) from public.characters where active and owner_id is null group by theme having count(*)>=4 order by theme;
$$;
create or replace function public.random_theme(p_min int default 4) returns text language sql volatile set search_path='' as $$
 select theme from public.characters where active and owner_id is null group by theme having count(*)>=p_min order by random() limit 1;
$$;

-- Pode jogar com o tema? Oficiais: sim. Da galera: dono ou amigo do dono, com pelo menos 4 personagens.
create or replace function public.can_use_theme(p_theme text,p_user uuid default auth.uid()) returns boolean language sql stable security definer set search_path='' as $$
 select p_theme in('ALEATÓRIO','TUDO MISTURADO')
  or exists(select 1 from public.characters where theme=p_theme and active and owner_id is null)
  or (select count(*)>=4 and bool_and(public.are_friends(owner_id,p_user)) from public.characters where theme=p_theme and active and owner_id is not null);
$$;

-- Temas da galera que eu posso usar: os meus e os dos meus amigos.
create or replace function public.my_custom_themes() returns table(theme text,owner_name text,mine boolean,total bigint) language sql stable security definer set search_path='' as $$
 select c.theme,p.username,c.owner_id=auth.uid(),count(*) filter(where c.active)
 from public.characters c join public.profiles p on p.id=c.owner_id
 where c.owner_id is not null and public.are_friends(c.owner_id,auth.uid())
 group by c.theme,p.username,c.owner_id having count(*) filter(where c.active)>0
 order by c.owner_id=auth.uid() desc,c.theme;
$$;

-- Adiciona (ou reativa) um personagem num tema meu. O primeiro personagem cria o tema.
create or replace function public.save_custom_character(p_theme text,p_name text,p_aliases text[] default '{}') returns bigint language plpgsql security definer set search_path='' as $$
declare base text:=regexp_replace(trim(regexp_replace(coalesce(p_theme,''),'^★\s*','')),'\s+',' ','g'); t text; cur text;
 n text:=regexp_replace(trim(coalesce(p_name,'')),'\s+',' ','g'); al text[]; cid bigint;begin
 if auth.uid() is null then raise exception 'Faça login';end if;
 if char_length(base) not between 3 and 30 then raise exception 'O nome do tema precisa ter de 3 a 30 caracteres';end if;
 if char_length(n) not between 2 and 40 then raise exception 'O nome do personagem precisa ter de 2 a 40 caracteres';end if;
 t:='★ '||base;
 if exists(select 1 from public.characters where lower(theme)=lower(t) and owner_id is distinct from auth.uid()) then raise exception 'Já existe um tema com esse nome. Escolha outro.';end if;
 select theme into cur from public.characters where lower(theme)=lower(t) and owner_id=auth.uid() limit 1;
 if cur is not null then t:=cur;
 elsif (select count(distinct theme) from public.characters where owner_id=auth.uid() and active)>=10 then raise exception 'Você pode ter até 10 temas';end if;
 if (select count(*) from public.characters where theme=t and active)>=60 then raise exception 'Um tema pode ter até 60 personagens';end if;
 select coalesce(array_agg(x),'{}') into al from (select distinct left(trim(a),40) x from unnest(coalesce(p_aliases,'{}'::text[])) a where char_length(trim(a))>=2 limit 5) s;
 select id into cid from public.characters where theme=t and lower(name)=lower(n);
 if cid is not null then
   update public.characters set active=true,name=n,aliases=al where id=cid;
 else
   insert into public.characters(theme,name,aliases,owner_id) values(t,n,al,auth.uid()) returning id into cid;
 end if;
 return cid;end$$;

-- Remover personagem (ou o tema inteiro): só desativa, porque partidas antigas apontam para ele.
create or replace function public.remove_custom_character(p_id bigint) returns void language plpgsql security definer set search_path='' as $$
begin
 update public.characters set active=false where id=p_id and owner_id=auth.uid();
 if not found then raise exception 'Personagem não encontrado';end if;
end$$;
create or replace function public.remove_custom_theme(p_theme text) returns void language plpgsql security definer set search_path='' as $$
begin
 update public.characters set active=false where theme=p_theme and owner_id=auth.uid();
 if not found then raise exception 'Tema não encontrado';end if;
end$$;

create or replace function public.my_custom_characters(p_theme text) returns table(id bigint,name text,aliases text[]) language sql stable security definer set search_path='' as $$
 select id,name,aliases from public.characters where theme=p_theme and owner_id=auth.uid() and active order by name;
$$;

-- Sorteio de identidades: tema da galera usa só os personagens dele; os demais nunca usam os da galera.
create or replace function public.assign_round(p_room uuid,p_round int) returns void language plpgsql security definer set search_path='' as $$
declare r public.rooms; p record; ch bigint; used bigint[]:='{}'; custom boolean;begin
 select * into r from public.rooms where id=p_room;
 custom:=r.theme like '★ %';
 for p in select user_id from public.room_players where room_id=p_room and status<>'left' order by joined_at loop
   select c.id into ch from public.characters c where c.active and c.id<>all(used)
     and case when custom then c.theme=r.theme else c.owner_id is null and (r.theme in('ALEATÓRIO','TUDO MISTURADO') or c.theme=r.theme) end
     order by random() limit 1;
   if ch is null then select c.id into ch from public.characters c where c.active and c.owner_id is null and c.id<>all(used) order by random() limit 1; end if;
   if ch is null then raise exception 'Banco de personagens insuficiente';end if;
   insert into public.secret_characters(room_id,round_no,player_id,character_id) values(p_room,p_round,p.user_id,ch);
   used:=array_append(used,ch);
 end loop;
end$$;

create or replace function public.create_room(p_theme text,p_rounds int,p_game_mode text,p_turn_seconds int)
returns uuid language plpgsql security definer set search_path='' as $$
declare rid uuid; t text:=p_theme;begin
 if auth.uid() is null then raise exception 'Faça login';end if;
 if p_rounds not between 1 and 10 then raise exception 'Número de rodadas inválido';end if;
 if p_game_mode not in('FREE','TURNS') then raise exception 'Modo inválido';end if;
 if p_turn_seconds not between 0 and 300 then raise exception 'Tempo inválido';end if;
 if t='SORTEADO' then t:=public.random_theme();end if;
 if not public.can_use_theme(t) then raise exception 'Tema sem personagens suficientes ou sem permissão';end if;
 insert into public.rooms(code,host_id,theme,total_rounds,game_mode,turn_seconds) values(public.make_code(),auth.uid(),t,p_rounds,p_game_mode,p_turn_seconds) returning id into rid;
 insert into public.room_players(room_id,user_id) values(rid,auth.uid()); return rid;end$$;

create or replace function public.update_room_settings(p_room_id uuid,p_theme text,p_rounds int,p_turn_seconds int)
returns text language plpgsql security definer set search_path='' as $$
declare r public.rooms; t text:=p_theme;begin
 select * into r from public.rooms where id=p_room_id for update;
 if r.id is null or r.host_id<>auth.uid() then raise exception 'Somente o host pode alterar a sala';end if;
 if r.status<>'lobby' then raise exception 'A partida já começou';end if;
 if p_rounds not between 1 and 10 then raise exception 'Número de rodadas inválido';end if;
 if p_turn_seconds not between 0 and 300 then raise exception 'Tempo inválido';end if;
 if t='SORTEADO' then t:=public.random_theme();end if;
 if t<>r.theme and not public.can_use_theme(t) then raise exception 'Tema sem personagens suficientes ou sem permissão';end if;
 update public.rooms set theme=t,total_rounds=p_rounds,turn_seconds=p_turn_seconds where id=p_room_id;
 return t;end$$;

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
 elsif nt is not null and nt<>r.theme and not public.can_use_theme(nt) then raise exception 'Tema sem personagens suficientes ou sem permissão';end if;
 update public.rooms set current_round=current_round+1,status='playing',theme=coalesce(nt,theme) where id=p_room_id;
 perform public.assign_round(p_room_id,r.current_round+1); perform public.advance_turn(p_room_id); return true;end$$;

-- Estatísticas por tema do jogador: rodadas jogadas, acertos, vezes em 1º e média de perguntas nos acertos.
create or replace function public.my_theme_stats() returns table(theme text,rounds bigint,solved bigint,firsts bigint,avg_questions numeric) language sql stable security definer set search_path='' as $$
 select c.theme,count(*),count(*) filter(where s.revealed),count(*) filter(where s.placement=1),
   round(avg(q.n) filter(where s.revealed),1)
 from public.secret_characters s
 join public.characters c on c.id=s.character_id
 join public.rooms r on r.id=s.room_id and (r.status in('round_result','finished') or r.current_round>s.round_no)
 left join lateral (select count(*) n from public.questions x where x.room_id=s.room_id and x.round_no=s.round_no and x.user_id=s.player_id) q on true
 where s.player_id=auth.uid()
 group by c.theme order by count(*) desc,c.theme;
$$;

-- are_friends é usada na política de leitura, então quem está logado precisa poder executá-la.
revoke execute on function public.are_friends(uuid,uuid) from public, anon;
grant execute on function public.are_friends(uuid,uuid) to authenticated;
revoke execute on function public.can_use_theme(text,uuid),public.random_theme(int) from public, anon, authenticated;
revoke execute on function public.my_custom_themes(),public.save_custom_character(text,text,text[]),public.remove_custom_character(bigint),public.remove_custom_theme(text),public.my_custom_characters(text),public.my_theme_stats() from public, anon;
grant execute on function public.my_custom_themes(),public.save_custom_character(text,text,text[]),public.remove_custom_character(bigint),public.remove_custom_theme(text),public.my_custom_characters(text),public.my_theme_stats() to authenticated;
revoke execute on function public.list_themes() from public;
grant execute on function public.list_themes() to anon, authenticated;
