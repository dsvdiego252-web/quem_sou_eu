// Vercel Function: envia a notificação push de convite.
// Recebe o token do usuário que convida; o banco (push_targets_for_invite) confere se ele está
// na sala e aplica limite de envio, e devolve as inscrições do convidado.
import webpush from 'web-push'

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method not allowed' })
  const auth = req.headers.authorization || ''
  const { to, code } = req.body || {}
  if (!auth.startsWith('Bearer ') || typeof to !== 'string' || typeof code !== 'string') return res.status(400).json({ error: 'bad request' })
  const url = process.env.VITE_SUPABASE_URL, key = process.env.VITE_SUPABASE_PUBLISHABLE_KEY
  const pub = process.env.VITE_VAPID_PUBLIC_KEY, priv = process.env.VAPID_PRIVATE_KEY
  if (!url || !key || !pub || !priv) return res.status(500).json({ error: 'push not configured' })
  const rpc = (fn, body) => fetch(`${url}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: key, Authorization: auth, 'Content-Type': 'application/json' }, body: JSON.stringify(body) })

  const r = await rpc('push_targets_for_invite', { p_to: to, p_code: code })
  if (!r.ok) return res.status(403).json({ error: (await r.json().catch(() => ({}))).message || 'forbidden' })
  const { from_name, subs = [] } = await r.json()

  webpush.setVapidDetails('https://quem-sou-eu-gamma.vercel.app', pub, priv)
  const payload = JSON.stringify({
    title: '🎮 Convite para jogar!',
    body: `${from_name} te chamou para uma partida de Quem Sou Eu?`,
    url: `/?room=${encodeURIComponent(code)}`,
    tag: `invite-${code}`,
  })
  const gone = []
  let sent = 0
  await Promise.all(subs.map(s => webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 300, urgency: 'high' })
    .then(() => { sent++ })
    .catch(e => { if (e.statusCode === 404 || e.statusCode === 410) gone.push(s.endpoint) })))
  if (gone.length) await rpc('mark_push_gone', { p_endpoints: gone }).catch(() => {})
  return res.status(200).json({ sent, devices: subs.length })
}
