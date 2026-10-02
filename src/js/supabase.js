import { createClient } from '@supabase/supabase-js'
const url=import.meta.env.VITE_SUPABASE_URL
const key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
// Link de "esqueci minha senha": o Supabase volta com #...type=recovery (lido antes de o cliente limpar a URL).
export const recoveryFromUrl=/type=recovery/.test(location.hash+location.search)
export const configured=Boolean(url&&key&&!url.includes('SEU-PROJETO'))
export const supabase=configured?createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true}}):null

// Ao fechar a página (pagehide) não dá para esperar uma chamada normal: usa fetch com keepalive e o
// token salvo pelo supabase-js no localStorage. Avisa o servidor que o jogador saiu (mark_away).
export function markAwayBeacon(roomId){try{if(!configured||!roomId)return;const ref=new URL(url).hostname.split('.')[0];const token=JSON.parse(localStorage.getItem(`sb-${ref}-auth-token`)||'null')?.access_token;if(!token)return;fetch(`${url}/rest/v1/rpc/mark_away`,{method:'POST',keepalive:true,headers:{apikey:key,Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify({p_room_id:roomId})}).catch(()=>{})}catch{}}
