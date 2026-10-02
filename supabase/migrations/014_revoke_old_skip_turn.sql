-- 014: a versão antiga skip_turn(uuid) (sem informar a vez) podia pular duas vezes;
-- o app usa skip_turn(uuid, timestamptz) desde a 007.
revoke execute on function public.skip_turn(uuid) from public, anon, authenticated;
