// Sons sintetizados (Web Audio, sem arquivos) e vibração no celular.
let enabled=(()=>{try{return localStorage.getItem('sound')!=='off'}catch{return true}})()
let ctx=null
export const soundOn=()=>enabled
export function toggleSound(){enabled=!enabled;try{localStorage.setItem('sound',enabled?'on':'off')}catch{}if(enabled)play('click');return enabled}
function ac(){if(!ctx){const C=window.AudioContext||window.webkitAudioContext;if(!C)return null;ctx=new C()}if(ctx.state==='suspended')ctx.resume().catch(()=>{});return ctx}
// navegadores só liberam áudio depois de um toque/tecla
;['pointerdown','keydown'].forEach(ev=>addEventListener(ev,()=>ac(),{once:true}))
function tone(freq,start,dur,type='sine',vol=.14){const c=ac();if(!c)return;const t=c.currentTime+start,o=c.createOscillator(),g=c.createGain();o.type=type;o.frequency.value=freq;g.gain.setValueAtTime(0,t);g.gain.linearRampToValueAtTime(vol,t+.01);g.gain.exponentialRampToValueAtTime(.0001,t+dur);o.connect(g).connect(c.destination);o.start(t);o.stop(t+dur+.05)}
const SOUNDS={
 turn:[[660,0,.14],[880,.15,.28]],
 question:[[520,0,.1],[640,.11,.14]],
 correct:[[523,0,.12],[659,.12,.12],[784,.24,.12],[1047,.36,.4]],
 wrong:[[320,0,.2,'sawtooth',.07],[220,.2,.4,'sawtooth',.07]],
 invite:[[784,0,.12],[988,.14,.12],[784,.28,.12],[988,.42,.22]],
 tick:[[1100,0,.05,'square',.04]],
 click:[[700,0,.05]],
 win:[[392,0,.15],[523,.15,.15],[659,.3,.15],[784,.45,.15],[1047,.6,.5]],
 hint:[[880,0,.08],[660,.09,.08],[440,.18,.18]],
}
const VIB={turn:[120,60,120],question:[50],correct:[80,40,80,40,220],wrong:[300],invite:[200,100,200],win:[100,50,100,50,300]}
export function play(name){if(!enabled)return;(SOUNDS[name]||[]).forEach(([f,s,d,t,v])=>tone(f,s,d,t,v));if(VIB[name]&&navigator.vibrate)try{navigator.vibrate(VIB[name])}catch{}}
