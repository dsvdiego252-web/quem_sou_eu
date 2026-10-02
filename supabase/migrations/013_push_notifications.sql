-- 013: notificações push de convite (mesmo com o app fechado).
-- O envio é feito pela função da Vercel /api/invite-push, que assina com a chave VAPID
-- privada (variável de ambiente). Sem essa chave, os dados de inscrição não servem para enviar nada.

create table if not exists public.push_subscriptions(
 endpoint text primary key,
 user_id uuid not null references public.profiles(id) on delete cascade,
 p256dh text not null,
 auth text not null,
 created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;
create index if not exists push_subscriptions_user_idx on public.push_subscriptions(user_id);

create table if not exists public.push_log(
 sender uuid not null,
 target uuid not null,
 sent_at timestamptz not null default now()
);
alter table public.push_log enable row level security;
revoke all on public.push_log from anon, authenticated;
create index if not exists push_log_idx on public.push_log(sender,target,sent_at);

create or replace function public.register_push(p_endpoint text,p_p256dh text,p_auth text) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Faça login';end if;
 if char_length(p_endpoint)>1000 or p_endpoint not like 'https://%' then raise exception 'Inscrição inválida';end if;
 insert into public.push_subscriptions(endpoint,user_id,p256dh,auth) values(p_endpoint,auth.uid(),p_p256dh,p_auth)
  on conflict(endpoint) do update set user_id=auth.uid(),p256dh=excluded.p256dh,auth=excluded.auth,created_at=now();
end$$;

create or replace function public.unregister_push(p_endpoint text) returns void language plpgsql security definer set search_path='' as $$
begin
 update public.push_subscriptions set p256dh='',auth='' where endpoint=p_endpoint and user_id=auth.uid();
end$$;

-- Usada pela função /api/invite-push com o token de quem convida: confere que ele está numa
-- sala aberta com esse código, aplica limite de 1 convite por pessoa a cada 20 s e devolve
-- as inscrições do convidado.
create or replace function public.push_targets_for_invite(p_to uuid,p_code text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.rooms; n text;begin
 if auth.uid() is null or p_to=auth.uid() then raise exception 'Convite inválido';end if;
 select * into r from public.rooms where code=upper(trim(p_code));
 if r.id is null or r.status<>'lobby' or not exists(select 1 from public.room_players where room_id=r.id and user_id=auth.uid() and status<>'left') then raise exception 'Sala inválida';end if;
 if exists(select 1 from public.push_log where sender=auth.uid() and target=p_to and sent_at>now()-interval '20 seconds') then raise exception 'Aguarde para convidar de novo';end if;
 insert into public.push_log(sender,target) values(auth.uid(),p_to);
 select username into n from public.profiles where id=auth.uid();
 return jsonb_build_object('from_name',n,'subs',coalesce((select jsonb_agg(jsonb_build_object('endpoint',endpoint,'p256dh',p256dh,'auth',auth))
   from public.push_subscriptions where user_id=p_to and p256dh<>''),'[]'::jsonb));
end$$;

-- Inscrições que o serviço de push informou como expiradas (404/410).
create or replace function public.mark_push_gone(p_endpoints text[]) returns void language sql security definer set search_path='' as $$
 update public.push_subscriptions set p256dh='',auth='' where endpoint=any(p_endpoints);
$$;

revoke execute on function public.register_push(text,text,text),public.unregister_push(text),public.push_targets_for_invite(uuid,text),public.mark_push_gone(text[]) from public, anon;
grant execute on function public.register_push(text,text,text),public.unregister_push(text),public.push_targets_for_invite(uuid,text),public.mark_push_gone(text[]) to authenticated;
