// Foto do personagem: usa image_url cadastrada pelo admin ou busca a miniatura na Wikipédia em
// português (com uma palavra-chave do tema para desambiguar, ex.: "Tom desenho animado").
const HINT={DESENHOS:'desenho animado',ANIME:'anime',NOVELAS:'telenovela personagem',SÉRIES:'série de televisão personagem',GAMES:'jogo eletrônico personagem',FILMES:'filme personagem',YOUTUBERS:'youtuber',CANTORES:'cantor',FUTEBOL:'futebolista',ESPORTE:'atleta',ANIMAIS:'animal',PAÍSES:'bandeira',COMIDAS:'culinária',OBJETOS:'objeto',PROFISSÕES:'profissão',FAMOSOS:''}
let disk={};try{disk=JSON.parse(localStorage.getItem('charimg')||'{}')}catch{}
const pending=new Map()
const keyOf=(name,theme)=>theme+'|'+name
function save(){try{localStorage.setItem('charimg',JSON.stringify(disk))}catch{}}
export function cachedImage(name,theme,url){return url||disk[keyOf(name,theme)]||''}
export function characterImage(name,theme,url){if(url)return Promise.resolve(url);const k=keyOf(name,theme);if(k in disk)return Promise.resolve(disk[k]);if(pending.has(k))return pending.get(k)
 const p=(async()=>{try{const q=`${name} ${HINT[theme]??''}`.trim();const r=await fetch(`https://pt.wikipedia.org/w/api.php?action=query&generator=search&gsrsearch=${encodeURIComponent(q)}&gsrlimit=1&prop=pageimages&piprop=thumbnail&pithumbsize=240&format=json&origin=*`);const j=await r.json();const pg=j?.query?.pages?Object.values(j.query.pages)[0]:null;disk[k]=pg?.thumbnail?.source||'';save();return disk[k]}catch{return ''}finally{pending.delete(k)}})()
 pending.set(k,p);return p}
// Completa as <img data-char> que ainda não têm foto depois de desenhar a tela.
export function hydrateImages(root=document){root.querySelectorAll('img[data-char]').forEach(img=>{if(img.getAttribute('src'))return;characterImage(img.dataset.char,img.dataset.theme,img.dataset.url).then(src=>{if(src&&img.isConnected){img.src=src;img.hidden=false}})})}
export function imgTag(c,cls='char-img'){if(!c?.name)return '';const src=cachedImage(c.name,c.theme,c.image_url);const e=s=>String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]));return `<img class="${cls}" data-char="${e(c.name)}" data-theme="${e(c.theme)}" data-url="${e(c.image_url||'')}" ${src?`src="${e(src)}"`:'hidden'} alt="" loading="lazy" referrerpolicy="no-referrer">`}
