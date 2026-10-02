-- 012: lista de temas vinda do banco (temas criados pelo admin aparecem no jogo).
create or replace function public.list_themes() returns table(theme text,total bigint) language sql stable security definer set search_path='' as $$
 select theme,count(*) from public.characters where active group by theme having count(*)>=4 order by theme;
$$;
revoke execute on function public.list_themes() from public;
grant execute on function public.list_themes() to anon, authenticated;
