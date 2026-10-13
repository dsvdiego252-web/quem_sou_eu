// Modo treino com bots: cada bot tem uma identidade secreta, responde às suas perguntas de
// verdade (pelas características do personagem), faz perguntas sobre si mesmo e vai eliminando
// candidatos até arriscar um palpite.
import {BOT_CHARS,BOT_THEMES} from '../data/botChars.js'
export {BOT_THEMES}

export const norm=s=>' '+String(s??'').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g,'').replace(/[^a-z0-9]+/g,' ').trim()+' '
const has=(c,t)=>c.tags.some(x=>norm(x)===norm(t))
const shuffle=a=>{a=[...a];for(let i=a.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[a[i],a[j]]=[a[j],a[i]]}return a}
const pick=a=>a[Math.floor(Math.random()*a.length)]

// Palavras da pergunta → característica. A pergunta vira SIM só se todas as características citadas baterem.
const T=t=>c=>has(c,t)
const RULES=[
 [/ (homem|menino|masculino|garoto|macho|rapaz|senhor) /,c=>c.g==='m'],
 [/ (mulher|menina|feminin\w*|garota|moca|senhora|dama) /,c=>c.g==='f'],
 [/ (real|existo|existe|de verdade|pessoa real|da vida real) /,c=>c.real],
 [/ (ficticio|ficticia|ficcao|inventad\w*|imaginari\w*|personagem) /,c=>!c.real],
 [/ (brasileir\w*|do brasil|no brasil) /,c=>c.br],
 [/ (estrangeir\w*|gringo|gringa|de fora do brasil) /,c=>c.real&&!c.br],
 [/ (argentin\w*) /,c=>c.pais==='argentina'],[/ (portugu\w*|portugal) /,c=>c.pais==='portugal'],
 [/ (american\w*|eua|estados unidos) /,c=>c.pais==='eua'],[/ (frances\w*|franca) /,c=>c.pais==='franca'],
 [/ (ingles\w*|inglaterra) /,c=>c.pais==='inglaterra'],[/ (alema\w*|alemanha) /,c=>c.pais==='alemanha'],
 [/ (canad\w*) /,c=>c.pais==='canada'],[/ (jamaic\w*) /,c=>c.pais==='jamaica'],[/ (japon\w*|japao) /,T('japones')],
 [/ (vivo|viva|estou vivo|ainda vive) /,c=>c.vivo],
 [/ (morto|morta|morri|morreu|falecid\w*|ja morri) /,c=>!c.vivo],
 [/ (futebol|jogador\w*|boleiro|craque) /,T('futebol')],
 [/ (atleta|esport\w*|olimpi\w*) /,c=>has(c,'atleta')||has(c,'esporte')],
 [/ (cant\w*|music\w*|banda) /,T('cantor')],
 [/ (filme|filmes|cinema) /,T('filme')],
 [/ (desenho|desenhos|animacao|cartoon) /,T('desenho')],
 [/ (quadrinho\w*|gibi|hq) /,T('quadrinhos')],
 [/ (anime|animes|manga) /,T('anime')],
 [/ (game|games|videogame|video game|jogo eletronico|de jogo|de jogos|jogos) /,T('game')],
 [/ (heroi|herois|super heroi|heroina) /,T('heroi')],
 [/ (vilao|vila|malvad\w*|do mal) /,T('vilao')],
 [/ (poder|poderes|superpoder\w*|magia|magico) /,T('poderes')],
 [/ (animal|bicho) /,T('animal')],
 [/ (apresentador\w*|apresento|televisao|tv) /,c=>has(c,'apresentador')||has(c,'tv')],
 [/ (youtuber|internet|influencer|influenciador\w*) /,c=>has(c,'youtuber')||has(c,'internet')],
 [/ (realeza|coroa|rei|rainha|princesa|principe|nobre) /,c=>['realeza','rei','rainha','princesa','principe'].some(t=>has(c,t))],
 [/ (rico|rica|milionari\w*|bilionari\w*|dinheiro) /,T('rico')],
 [/ (loiro|loira) /,T('loiro')],[/ (cabelo comprido|cabelo longo) /,T('cabelo comprido')],[/ (cabelo branco|grisalho) /,T('cabelo branco')],
 [/ (engracad\w*|humorista|comedi\w*|piada\w*) /,c=>has(c,'engracado')||has(c,'humorista')],
 [/ (rapido|rapida|veloz|corro) /,T('rapido')],[/ (voo|voa|voar|voando) /,T('voa')],
 [/ (forte|musculos\w*|fortao) /,T('forte')],
 [/ (crianca|criancas|pequeno|pequena) /,T('crianca')],
 [/ (copa do mundo|campeao do mundo|campea do mundo|mundial) /,T('campeao do mundo')],
 [/ (piloto|formula 1|corrida|carro de corrida) /,T('piloto')],
 [/ (vermelh\w*) /,T('vermelho')],[/ (azul) /,T('azul')],[/ (verde) /,T('verde')],[/ (amarel\w*) /,T('amarelo')],
 [/ (rosa) /,T('rosa')],[/ (roxo|roxa) /,T('roxo')],[/ (laranja) /,T('laranja')],[/ (preto|preta) /,T('preto')],
 [/ (cinza) /,T('cinza')],[/ (marrom) /,T('marrom')],
 [/ (chapeu|bone) /,c=>has(c,'chapeu')||has(c,'bone')],[/ (oculos) /,T('oculos')],
 [/ (pai|mae) /,T('pai')],[/ (dente\w*|dentuc\w*) /,T('dentuco')],
]
// Qualquer característica do personagem citada pelo nome também vale (ex.: "tenho barba?", "sou da Marvel?").
const ALL_TAGS=[...new Set(BOT_CHARS.flatMap(c=>c.tags.map(norm)))].filter(t=>t.trim().length>=2)
const NAME_PRE=[' sou ',' sou o ',' sou a ',' sou um ',' sou uma ',' e o ',' e a ',' seria o ',' seria a ',' eu sou o ',' eu sou a ']
const NAMES=BOT_CHARS.flatMap(c=>[c.n,...c.a].map(x=>({c,k:norm(x)})))

export function answerFor(c,question){const q=norm(question);
 // Pergunta direta pelo nome ("Sou o Neymar?"): vale o nome mais longo citado.
 const named=NAMES.filter(x=>NAME_PRE.some(p=>q.includes(p+x.k.trim()+' '))).sort((a,b)=>b.k.length-a.k.length)[0];if(named)return named.c===c?'SIM':'NÃO'
 const m=q.match(/ comec\w* com (a )?(letra )?([a-z]) /);if(m)return norm(c.n).trim()[0]===m[3]?'SIM':'NÃO'
 if(/ (nome composto|duas palavras|sobrenome) /.test(q))return c.n.trim().includes(' ')?'SIM':'NÃO'
 const checks=RULES.filter(([re])=>re.test(q)).map(([,f])=>f)
 ALL_TAGS.forEach(t=>{if(q.includes(t)&&!RULES.some(([re])=>re.test(t)))checks.push(c=>c.tags.some(x=>norm(x)===t))})
 const theme=BOT_THEMES.find(t=>q.includes(norm(t)));if(theme&&!checks.length)checks.push(c=>c.t===theme)
 if(!checks.length)return 'NÃO SEI'
 return checks.every(f=>f(c))?'SIM':'NÃO'}

// Perguntas que os bots fazem sobre a própria identidade.
const BQ=[
 ['Eu sou homem?',c=>c.g==='m'],['Eu sou uma pessoa de verdade?',c=>c.real],['Eu sou do Brasil?',c=>c.br],
 ['Eu já morri?',c=>c.real&&!c.vivo],['Eu jogo futebol?',T('futebol')],['Eu sou cantor(a)?',T('cantor')],
 ['Eu sou de desenho animado?',T('desenho')],['Eu sou um super-herói?',T('heroi')],['Eu sou um vilão?',T('vilao')],
 ['Eu tenho poderes?',T('poderes')],['Eu sou um animal?',T('animal')],['Eu sou de videogame?',T('game')],
 ['Eu sou de anime?',T('anime')],['Eu apresento programa de TV?',T('apresentador')],['Eu sou da Marvel?',T('marvel')],
 ['Eu sou da DC?',T('dc')],['Eu sou loiro(a)?',T('loiro')],['Eu sou careca?',T('careca')],['Eu tenho barba?',T('barba')],
 ['Eu tenho bigode?',T('bigode')],['Eu uso máscara?',T('mascara')],['Eu uso capa?',T('capa')],['Eu sou rico(a)?',T('rico')],
 ['Eu já fui campeão do mundo?',T('campeao do mundo')],['Eu sou da Nintendo?',T('nintendo')],['Eu sou dos Estados Unidos?',c=>c.pais==='eua'],
 ['Eu sou argentino?',c=>c.pais==='argentina'],['Eu uso roupa vermelha?',T('vermelho')],['Eu sou azul ou uso azul?',T('azul')],
 ['Eu sou verde ou uso verde?',T('verde')],['Eu sou amarelo?',T('amarelo')],['Eu sou engraçado(a)?',T('engracado')],
 ['Eu sou muito forte?',T('forte')],['Eu sou de quadrinhos?',T('quadrinhos')],['Eu canto sertanejo?',T('sertanejo')],
 ['Eu canto pop?',T('pop')],['Eu sou atleta?',c=>has(c,'atleta')],['Eu sou criança?',T('crianca')],['Eu luto?',T('luta')],
 ['Eu uso espada?',T('espada')],['Eu sou ninja?',T('ninja')],['Eu tenho cabelo comprido?',T('cabelo comprido')],
 ['Eu sou da realeza?',c=>['realeza','rei','rainha','princesa','principe'].some(t=>has(c,t))],['Eu tenho tatuagem?',T('tatuagem')],
 ['Eu sou de Dragon Ball?',T('dragon ball')],['Eu sou rápido(a)?',T('rapido')],['Eu sou de filme?',T('filme')],
]

const BOTS=[['Luna Bot','🤖'],['Max Bot','👾'],['Nina Bot','🦾'],['Teco Bot','🐙']]
const MINQ={facil:9,normal:7,dificil:5}
export const DIFFS={facil:'Fácil',normal:'Normal',dificil:'Difícil'}

// Nova partida de treino: tema (ou TUDO MISTURADO), dificuldade e quantidade de bots.
export function newBotGame(user,theme='TUDO MISTURADO',diff='normal',nBots=3){
 const pool=theme==='TUDO MISTURADO'?BOT_CHARS:BOT_CHARS.filter(c=>c.t===theme)
 const ids=shuffle(pool).slice(0,nBots+1)
 const players=[{id:'me',name:user.name||'Você',emoji:user.emoji||'😎',self:true,char:ids[0]},...BOTS.slice(0,nBots).map(([name,emoji],i)=>({id:'b'+i,name,emoji,char:ids[i+1]}))]
 players.forEach(p=>Object.assign(p,{solved:false,place:null,q:0,wrong:0,asked:new Set()}))
 // Cada bot vê as identidades dos outros, então elas saem da lista de candidatos dele.
 players.filter(p=>!p.self).forEach(b=>b.cands=pool.filter(c=>!players.some(o=>o!==b&&o.char===c)))
 return {theme,diff,pool,players,turn:0,log:[],pending:null,places:0,hints:0,over:false}}

export const current=g=>g.players[g.turn]
export function nextTurn(g){const n=g.players.length;for(let i=1;i<=n;i++){const j=(g.turn+i)%n;if(!g.players[j].solved){g.turn=j;return}}}
export function checkOver(g){const me=g.players[0],left=g.players.filter(p=>!p.solved);if(me.solved||left.length<=1)g.over=true;return g.over}
export const prize=(g,place)=>g.players.length>=4?[100,70,40][place-1]||0:g.players.length===3?[100,50][place-1]||0:place===1?100:0

export function solve(g,p){p.solved=true;p.place=++g.places;p.points=prize(g,p.place)+(p.q<=3?30:p.q<=5?15:0)}

// Pergunta do jogador: os bots respondem com base na identidade dele.
export function humanAsk(g,text){const me=g.players[0];me.q++;const answers=g.players.filter(p=>!p.self).map(p=>({name:p.name,emoji:p.emoji,ans:answerFor(me.char,text)}));g.log.push({who:me,text,answers});nextTurn(g)}

// Palpite tolerante: nome/apelido sem acento, sobrenome ou um errinho de digitação.
function lev(a,b){const d=Array.from({length:a.length+1},(_,i)=>[i]);for(let j=1;j<=b.length;j++)d[0][j]=j;for(let i=1;i<=a.length;i++)for(let j=1;j<=b.length;j++)d[i][j]=Math.min(d[i-1][j]+1,d[i][j-1]+1,d[i-1][j-1]+(a[i-1]===b[j-1]?0:1));return d[a.length][b.length]}
export function guessMatches(c,guess){const g=norm(guess).trim();if(!g)return false;const names=[c.n,...c.a].map(x=>norm(x).trim());if(names.includes(g))return true;const n=names[0],last=n.split(' ').pop();if(n.includes(' ')&&g.length>=3&&g===last)return true;const tol=n.length>=10?2:n.length>=5?1:0;return tol>0&&lev(g,n)<=tol}
export function humanGuess(g,text){const me=g.players[0];const ok=guessMatches(me.char,text);g.log.push({who:me,text:`💡 Eu sou ${text}!`,result:ok?'✅ ACERTOU!':'❌ Errou'});if(ok)solve(g,me);else me.wrong++;nextTurn(g);checkOver(g);return ok}

// Dicas do treino: a cada 4 perguntas libera uma (até 3).
export const hintReady=g=>g.hints<3&&g.players[0].q>=(g.hints+1)*4
export function takeHint(g){const n=g.players[0].char.n,w=n.split(' ');g.hints++;const h=g.hints===1?`${g.theme==='TUDO MISTURADO'?`Seu tema é ${g.players[0].char.t}. `:''}Seu nome tem ${w.length} palavra${w.length>1?'s':''} e ${n.replace(/ /g,'').length} letras.`:g.hints===2?`Seu nome começa com "${n[0].toUpperCase()}" e termina com "${n.slice(-1).toLowerCase()}".`:`Seu nome: ${w.map(x=>[...x].map((ch,i)=>i===0||i%2===0?ch.toUpperCase():'_').join(' ')).join('   ')}`;g.log.push({who:g.players[0],text:`🔎 Dica ${g.hints}: ${h}`,hint:true});return h}

// Vez do bot: decide entre perguntar (melhor divisão dos candidatos) e arriscar um palpite.
export function botMove(g){const b=current(g),c=b.cands
 const sure=c.length===1,risk=g.diff==='dificil'?c.length<=2:g.diff==='normal'?c.length<=2&&b.q>=8:false
 const qs=BQ.filter(([q])=>!b.asked.has(q)).map(([q,f])=>{const y=c.filter(f).length;return {q,f,score:Math.min(y,c.length-y)}})
 const useful=qs.filter(x=>x.score>0)
 // Gente de verdade não acerta em 3 perguntas: o bot só arrisca depois de um mínimo de perguntas.
 const early=b.q<MINQ[g.diff]&&qs.length
 if(!early&&(sure||risk||!useful.length)){const guess=pick(c);b.q++;const ok=guess===b.char;g.log.push({who:b,text:`💡 Eu sou ${guess.n}!`,result:ok?'✅ ACERTOU!':'❌ Errou'});if(ok)solve(g,b);else{b.wrong++;b.cands=c.filter(x=>x!==guess)}nextTurn(g);checkOver(g);return {type:'guess',ok,name:guess.n}}
 let choice
 // Sem pergunta que ajude (ou já tem certeza, mas ainda é cedo para chutar): pergunta algo que combine com os candidatos.
 if(!useful.length||(sure&&early)){const ok=qs.filter(x=>c.some(x.f));choice=pick(ok.length?ok:qs)}
 else if(g.diff==='facil')choice=Math.random()<.35&&qs.length?pick(qs):pick(useful)
 else{const best=[...useful].sort((a,b)=>b.score-a.score);choice=g.diff==='dificil'?best[0]:pick(best.slice(0,Math.min(3,best.length)))}
 b.asked.add(choice.q);b.q++
 const answers=g.players.filter(p=>!p.self&&p!==b).map(p=>({name:p.name,emoji:p.emoji,ans:choice.f(b.char)?'SIM':'NÃO'}))
 g.pending={bot:b,q:choice.q,f:choice.f,answers};g.log.push({who:b,text:choice.q,answers,pending:true});return {type:'ask',q:choice.q}}

// Resposta do jogador à pergunta do bot; o bot confia na maioria (SIM x NÃO) das respostas.
export function humanAnswer(g,ans){const p=g.pending;if(!p)return;const all=[...p.answers.map(a=>a.ans),ans],yes=all.filter(a=>a==='SIM').length,no=all.filter(a=>a==='NÃO').length
 const entry=g.log.findLast(x=>x.pending);if(entry){entry.answers=[{name:g.players[0].name,emoji:g.players[0].emoji,ans},...p.answers];entry.pending=false}
 if(yes!==no){const v=yes>no;const left=p.bot.cands.filter(c=>!!p.f(c)===v);if(left.length)p.bot.cands=left}
 g.pending=null;nextTurn(g)}
