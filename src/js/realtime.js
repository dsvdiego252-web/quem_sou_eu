import { supabase } from './supabase.js'
let channel=null,timer,seq=0
// Agrupa rajadas de eventos (ex.: fim de rodada altera várias linhas) em um único redesenho.
// A cada (re)conexão chama onChange de novo, para recuperar eventos perdidos enquanto
// a conexão estava caída (ex.: tela do celular apagada).
export async function subscribeRoom(roomId,onChange){const my=++seq;await removeCurrent();if(my!==seq)return;const fire=()=>{clearTimeout(timer);timer=setTimeout(onChange,120)};const t='public';const ch=supabase.channel(`room:${roomId}`)
 .on('postgres_changes',{event:'*',schema:t,table:'room_players',filter:`room_id=eq.${roomId}`},fire)
 .on('postgres_changes',{event:'*',schema:t,table:'questions',filter:`room_id=eq.${roomId}`},fire)
 .on('postgres_changes',{event:'*',schema:t,table:'answers'},fire)
 .on('postgres_changes',{event:'*',schema:t,table:'chat_messages',filter:`room_id=eq.${roomId}`},fire)
 .on('postgres_changes',{event:'*',schema:t,table:'secret_characters',filter:`room_id=eq.${roomId}`},fire)
 .on('postgres_changes',{event:'*',schema:t,table:'rooms',filter:`id=eq.${roomId}`},fire)
 channel=ch;ch.subscribe(status=>{if(channel!==ch)return;if(status==='SUBSCRIBED')fire();else if(status==='CHANNEL_ERROR'||status==='TIMED_OUT')setTimeout(()=>{if(channel===ch)subscribeRoom(roomId,onChange)},2000)})}
async function removeCurrent(){clearTimeout(timer);const ch=channel;channel=null;if(ch)await supabase.removeChannel(ch).catch(()=>{})}
export function unsubscribe(){seq++;return removeCurrent()}
