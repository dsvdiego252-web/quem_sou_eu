const names=['Luna Bot','Max Bot','Nina Bot'];const ids=['Michael Jordan','Neymar','Batman'];
export function botDemoState(user){return {code:'BOTS1',theme:'ESPORTE',round:1,totalRounds:3,players:[{id:'me',name:user||'Você',emoji:'😎',identity:null,self:true,score:0},{id:'b1',name:names[0],emoji:'🤖',identity:ids[0],score:0},{id:'b2',name:names[1],emoji:'👾',identity:ids[1],score:0},{id:'b3',name:names[2],emoji:'🦾',identity:ids[2],score:0}],messages:[]}}
export function botReply(){return ['SIM','NÃO','TALVEZ','NÃO SEI'][Math.floor(Math.random()*4)]}
