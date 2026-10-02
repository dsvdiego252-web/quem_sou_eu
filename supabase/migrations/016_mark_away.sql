-- 016: aviso de saída ao fechar o app/aba ou apertar "voltar" (pagehide).
-- Em vez de sair na hora (um recarregar de página também dispara o evento), o último sinal
-- de vida é recuado para 100 s atrás: se o jogador não voltar, os outros o retiram em ~20 s
-- (regra de 2 minutos do heartbeat); se voltar (ex.: recarregou), o próximo sinal o mantém.
create or replace function public.mark_away(p_room_id uuid) returns void language sql security definer set search_path='' as $$
 update public.room_presence set last_seen=least(last_seen,now()-interval '100 seconds')
 where room_id=p_room_id and user_id=auth.uid();
$$;
revoke execute on function public.mark_away(uuid) from public, anon;
grant execute on function public.mark_away(uuid) to authenticated;
