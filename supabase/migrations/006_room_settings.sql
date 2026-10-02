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
