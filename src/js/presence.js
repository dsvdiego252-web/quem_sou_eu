import { supabase } from './supabase.js'
// Quem está online (Supabase Realtime Presence) e convites diretos entre jogadores (Broadcast).
let ch=null,myId=null,meta={},state={},handlers={}
const listeners=new Set()

export function startPresence(user,profile,h={}){handlers=h;meta={user_id:user.id,username:profile?.username||'Jogador',avatar:profile?.avatar||{},status:meta.status||'menu'};if(ch&&myId===user.id){ch.track(meta);return}stopPresence();myId=user.id
 ch=supabase.channel('online-players',{config:{presence:{key:user.id},broadcast:{self:false}}})
 ch.on('presence',{event:'sync'},()=>{state=ch.presenceState();listeners.forEach(f=>f())})
  .on('broadcast',{event:'invite'},({payload})=>{if(payload?.to===myId)handlers.onInvite?.(payload)})
  .on('broadcast',{event:'invite_reply'},({payload})=>{if(payload?.to===myId)handlers.onReply?.(payload)})
  .subscribe(s=>{if(s==='SUBSCRIBED')ch.track(meta)})}
export function stopPresence(){if(ch){supabase.removeChannel(ch);ch=null}myId=null;state={};listeners.forEach(f=>f())}
export function setStatus(status){if(meta.status===status)return;meta.status=status;ch?.track(meta)}
export function onlinePlayers(){return Object.entries(state).filter(([k])=>k!==myId).map(([,arr])=>arr[arr.length-1]).filter(Boolean).sort((a,b)=>a.username.localeCompare(b.username))}
export function onPresenceChange(f){listeners.add(f);return()=>listeners.delete(f)}
export function sendInvite(to,code){ch?.send({type:'broadcast',event:'invite',payload:{to,code,from_id:myId,from:meta.username,avatar:meta.avatar}})}
export function replyInvite(to,accepted){ch?.send({type:'broadcast',event:'invite_reply',payload:{to,accepted,from:meta.username}})}
