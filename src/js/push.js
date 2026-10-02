import { supabase } from './supabase.js'
// Notificações push de convite: inscrição do aparelho e envio via /api/invite-push.
const PUBLIC_KEY=import.meta.env.VITE_VAPID_PUBLIC_KEY
export const pushSupported=()=>!!(PUBLIC_KEY&&'serviceWorker'in navigator&&'PushManager'in window&&'Notification'in window)
export const pushPermission=()=>('Notification'in window)?Notification.permission:'unsupported'
function keyBytes(b64){const p='='.repeat((4-b64.length%4)%4),s=atob((b64+p).replace(/-/g,'+').replace(/_/g,'/'));return Uint8Array.from(s,c=>c.charCodeAt(0))}
async function save(sub){const j=sub.toJSON();const {error}=await supabase.rpc('register_push',{p_endpoint:j.endpoint,p_p256dh:j.keys.p256dh,p_auth:j.keys.auth});if(error)throw error}
export async function enablePush(){if(!pushSupported())throw new Error(/iPhone|iPad/.test(navigator.userAgent)?'No iPhone, primeiro adicione o jogo à Tela de Início (Compartilhar → Adicionar à Tela de Início) e abra por lá.':'Este navegador não suporta notificações.')
 const perm=await Notification.requestPermission();if(perm!=='granted')throw new Error('Permissão negada. Libere as notificações do site nas configurações do navegador.')
 const reg=await navigator.serviceWorker.ready;const sub=await reg.pushManager.getSubscription()||await reg.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:keyBytes(PUBLIC_KEY)});await save(sub);return true}
// Ao entrar: se já tem permissão, garante que a inscrição deste aparelho está salva para este usuário.
export async function refreshPush(){try{if(!pushSupported()||Notification.permission!=='granted')return;const reg=await navigator.serviceWorker.ready;const sub=await reg.pushManager.getSubscription();if(sub)await save(sub)}catch{}}
export async function sendInvitePush(to,code){try{const {data:{session}}=await supabase.auth.getSession();if(!session)return;await fetch('/api/invite-push',{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${session.access_token}`},body:JSON.stringify({to,code})})}catch{}}
