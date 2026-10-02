import { supabase } from './supabase.js'
// Quem está online (Supabase Realtime Presence) e convites diretos entre jogadores (Broadcast).
let ch=null,myId=null,meta={},state={},handlers={},seq=0
const listeners=new Set()

export async function startPresence(user,profile,h={},force=false){handlers=h;meta={user_id:user.id,username:profile?.username||'Jogador',avatar:profile?.avatar||{},status:meta.status||'menu'};if(ch&&myId===user.id&&!force){ch.track(meta);return}
 const my=++seq;await removeCurrent();if(my!==seq)return;myId=user.id
 const c=supabase.channel('online-players',{config:{presence:{key:user.id},broadcast:{self:false}}});ch=c
 c.on('presence',{event:'sync'},()=>{if(ch!==c)return;state=c.presenceState();listeners.forEach(f=>f())})
  .on('broadcast',{event:'invite'},({payload})=>{if(ch===c&&payload?.to===myId)handlers.onInvite?.(payload)})
  .on('broadcast',{event:'invite_reply'},({payload})=>{if(ch===c&&payload?.to===myId)handlers.onReply?.(payload)})
  .subscribe(s=>{if(ch!==c)return;if(s==='SUBSCRIBED')c.track(meta);else if(s==='CHANNEL_ERROR'||s==='TIMED_OUT')setTimeout(()=>{if(ch===c)startPresence(user,{username:meta.username,avatar:meta.avatar},handlers,true)},3000)})}
async function removeCurrent(){const c=ch;ch=null;myId=null;state={};listeners.forEach(f=>f());if(c)await supabase.removeChannel(c).catch(()=>{})}
export function stopPresence(){seq++;return removeCurrent()}
export function setStatus(status){if(meta.status===status)return;meta.status=status;ch?.track(meta)}
export function onlinePlayers(){return Object.entries(state).filter(([k])=>k!==myId).map(([,arr])=>arr[arr.length-1]).filter(Boolean).sort((a,b)=>a.username.localeCompare(b.username))}
export function onPresenceChange(f){listeners.add(f);return()=>listeners.delete(f)}
export function sendInvite(to,code){ch?.send({type:'broadcast',event:'invite',payload:{to,code,from_id:myId,from:meta.username,avatar:meta.avatar}})}
export function replyInvite(to,accepted){ch?.send({type:'broadcast',event:'invite_reply',payload:{to,accepted,from:meta.username}})}
