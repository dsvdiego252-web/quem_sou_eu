export const defaultAvatar={emoji:'🙂'}
export function avatarEmoji(a={}){return a?.emoji||'🙂'}

// Emojis de pessoas aceitam tom de pele: o modificador entra logo após o primeiro caractere.
const TONES=[['','🟡'],['🏻','🏻'],['🏼','🏼'],['🏽','🏽'],['🏾','🏾'],['🏿','🏿']]
const CATEGORIES=[
 {id:'pessoas',label:'Pessoas',tone:true,items:['🧑','👨','👩','🧒','👦','👧','🧓','👴','👵','👱','👱‍♂️','👱‍♀️','🧔','🧔‍♀️','👨‍🦰','👩‍🦰','👨‍🦱','👩‍🦱','👨‍🦳','👩‍🦳','👨‍🦲','👩‍🦲','🧑‍🦰','🧑‍🦱','👲','👳','👳‍♀️','🧕','🤵','👰','🤰','🙋','🙋‍♂️','🙆‍♀️','💁‍♀️','💁‍♂️','🤷‍♀️','🤷‍♂️']},
 {id:'profissoes',label:'Profissões',tone:true,items:['👮','👮‍♀️','👷','👷‍♀️','💂','🕵️','🕵️‍♀️','🧑‍⚕️','👨‍⚕️','👩‍⚕️','🧑‍🍳','👨‍🍳','👩‍🍳','🧑‍🎤','👨‍🎤','👩‍🎤','🧑‍🎨','👩‍🎨','🧑‍🚀','👨‍🚀','👩‍🚀','🧑‍🚒','👨‍🚒','🧑‍💻','👨‍💻','👩‍💻','🧑‍🏫','👩‍🏫','🧑‍🔬','👩‍🔬','🧑‍🌾','👩‍🌾','🧑‍🔧','👩‍🔧','🧑‍✈️','👩‍✈️','🧑‍⚖️','👩‍⚖️','🧑‍🎓','👩‍🎓']},
 {id:'esporte',label:'Esporte',tone:true,items:['⛹️','⛹️‍♀️','🏃','🏃‍♀️','🚴','🚴‍♀️','🏊','🏊‍♀️','🏄','🏄‍♀️','🤸','🤸‍♀️','🏋️','🏋️‍♀️','🤾','🤾‍♀️','🧗','🧗‍♀️','🤽','🏌️','🏇','🧘','🧘‍♀️','🤺','⛷️','🏂']},
 {id:'fantasia',label:'Fantasia',tone:true,items:['🦸','🦸‍♂️','🦸‍♀️','🦹','🦹‍♂️','🦹‍♀️','🧙','🧙‍♂️','🧙‍♀️','🧚','🧚‍♀️','🧛','🧛‍♀️','🧜','🧜‍♀️','🧝','🧝‍♀️','🥷','🤴','👸','🎅','🤶','👼','🧞','🧟','🧌']},
 {id:'rostos',label:'Rostos',tone:false,items:['🙂','😎','🤠','🥳','🤓','😁','😂','🤣','😇','😍','🤩','😜','🤪','🤔','🤫','😴','🤯','😈','👻','💀','🤖','👽','👾','🤡','🎃','💩']},
 {id:'animais',label:'Animais',tone:false,items:['🐶','🐱','🦊','🐻','🐼','🐨','🐯','🦁','🐮','🐷','🐸','🐵','🐔','🐧','🦉','🦄','🐲','🐙','🦈','🐢','🦖','🐝','🦋','🐺']},
]
const MOD=/[\u{1F3FB}-\u{1F3FF}]/gu
export function withTone(e,tone){const base=e.replace(MOD,'');if(!tone)return base;const [first,...rest]=[...base];if(rest[0]==='️')rest.shift();return first+tone+rest.join('')}
function toneOf(e){return (e.match(MOD)||[''])[0]}

export function avatarEditorHTML(a={}){const cur=avatarEmoji(a);return `<div class="card"><h2>Crie seu avatar</h2><div class="avatar" id="avatarPreview">${cur}</div><div class="row avatar-tabs" style="justify-content:center;margin-top:16px">${CATEGORIES.map((c,i)=>`<button class="btn ${i?'alt':''} small avatarTab" data-c="${c.id}">${c.label}</button>`).join('')}</div><div class="row tone-row" id="toneRow" style="justify-content:center;margin-top:10px">${TONES.map(([t,icon])=>`<button class="btn alt small toneBtn ${t===toneOf(cur)?'picked':''}" data-t="${t}" title="Tom de pele">${icon}</button>`).join('')}</div><div class="avatar-grid" id="avatarGrid"></div></div>`}

// Liga o editor; onPick recebe o emoji final escolhido.
export function bindAvatarEditor(initial,onPick){let chosen=initial,tone=toneOf(initial),cat=CATEGORIES[0];const grid=document.getElementById('avatarGrid'),preview=document.getElementById('avatarPreview'),toneRow=document.getElementById('toneRow');
 const draw=()=>{toneRow.style.display=cat.tone?'':'none';grid.innerHTML=cat.items.map(x=>{const e=cat.tone?withTone(x,tone):x;return `<button class="avatarPick ${e===chosen?'picked':''}" data-e="${e}">${e}</button>`}).join('');grid.querySelectorAll('.avatarPick').forEach(b=>b.onclick=()=>{chosen=b.dataset.e;preview.textContent=chosen;onPick(chosen);draw()})};
 document.querySelectorAll('.avatarTab').forEach(b=>b.onclick=()=>{cat=CATEGORIES.find(c=>c.id===b.dataset.c);document.querySelectorAll('.avatarTab').forEach(x=>x.classList.toggle('alt',x!==b));draw()});
 document.querySelectorAll('.toneBtn').forEach(b=>b.onclick=()=>{tone=b.dataset.t;document.querySelectorAll('.toneBtn').forEach(x=>x.classList.toggle('picked',x===b));if(CATEGORIES.some(c=>c.tone&&c.items.includes(chosen.replace(MOD,'')))){chosen=withTone(chosen,tone);preview.textContent=chosen;onPick(chosen)}draw()});
 draw()}
