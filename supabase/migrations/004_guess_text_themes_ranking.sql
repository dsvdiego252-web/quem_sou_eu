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
