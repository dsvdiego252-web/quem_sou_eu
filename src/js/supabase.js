import { createClient } from '@supabase/supabase-js'
const url=import.meta.env.VITE_SUPABASE_URL
const key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
// Link de "esqueci minha senha": o Supabase volta com #...type=recovery (lido antes de o cliente limpar a URL).
export const recoveryFromUrl=/type=recovery/.test(location.hash+location.search)
export const configured=Boolean(url&&key&&!url.includes('SEU-PROJETO'))
export const supabase=configured?createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true}}):null
