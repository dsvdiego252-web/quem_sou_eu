export const defaultAvatar={skin:'🏻',hair:'🟤',shirt:'💜',accessory:'✨'}
export function avatarEmoji(a={}){return a.emoji||'🙂'}
export function avatarEditorHTML(a={}){const cur=avatarEmoji(a);return `<div class="card"><h2>Crie seu avatar</h2><div class="avatar" id="avatarPreview">${cur}</div><div class="row" style="justify-content:center;margin-top:16px">${['🙂','😎','🤠','🥳','🤓','🧑‍🚀','🦸','🧙','👩','👨','🧑','👽'].map(x=>`<button class="btn alt avatarPick" data-e="${x}">${x}</button>`).join('')}</div></div>`}
