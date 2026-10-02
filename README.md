# QUEM SOU EU? — Multiplayer Online

Projeto web multiplayer em HTML/CSS/JavaScript com Vite + Supabase (Auth, Postgres, RLS e Realtime) e PWA.

## O que já funciona

- Cadastro/login por e-mail e senha.
- Perfil e avatar simples persistido no banco.
- Criação de sala privada com código de 5 caracteres.
- Entrada por código, host e lobby de 2 a 4 jogadores.
- Configuração de tema, rodadas, modo e cronômetro.
- Sorteio server-side de personagens sem repetição na rodada.
- Regra anti-trapaça: o jogador não tem SELECT da própria identidade antes da revelação.
- Perguntas em tempo real, respostas SIM/NÃO/TALVEZ/NÃO SEI e chat.
- Tentativa de adivinhação validada no banco por RPC; o cliente recebe apenas correto/errado.
- Cooldown de 10 segundos após erro.
- Pontuação 4 jogadores: 100/70/40/0; 3: 100/50/0; 2: 100/0; bônus +30 até 3 perguntas e +15 até 5.
- Resultado da rodada, próxima rodada e pódio final.
- Realtime via Supabase Postgres Changes.
- PWA instalável.
- Modo “Testar com Bots” sem configuração externa.
- Ranking global básico e perfil.
- Estruturas de `friendships` e `theme_votes` já criadas para expansão da UI de amigos/votação.

## 1. Instalar

```bash
npm install
cp .env.example .env
npm run dev
```

Sem `.env` configurado, a aplicação entra automaticamente em modo demonstração e o botão **TESTAR COM BOTS** funciona.

## 2. Criar o projeto no Supabase

1. Crie um projeto em https://supabase.com.
2. Em **SQL Editor**, cole e execute `supabase/setup_completo.sql` **ou** execute os arquivos separadamente:
   - `supabase/migrations/001_schema.sql`
   - `supabase/migrations/002_security_and_fixes.sql` (obrigatório: corrige criação de sala, permissões e regras do jogo).
   - `supabase/migrations/003_turns.sql` (perguntas em turnos)
   - `supabase/seed.sql`
3. Em **Authentication > Providers > Email**, mantenha Email habilitado.
4. Em **Authentication > URL Configuration**, coloque a URL da Vercel em *Site URL* e em *Redirect URLs* (para o link de confirmação de e-mail voltar ao jogo).
5. Copie a URL do projeto e a chave pública/publishable para `.env`:

```env
VITE_SUPABASE_URL=https://xxxxx.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_xxxxx
```

Nunca coloque `service_role` no navegador.

## 3. Segurança da identidade secreta

A tabela `secret_characters` tem RLS. A policy permite SELECT quando:

- o registro pertence a outro jogador da mesma sala; ou
- a identidade já foi revelada.

A própria identidade permanece no PostgreSQL. O cliente chama `submit_guess(...)`, uma função `SECURITY DEFINER` com `search_path=''`, que compara o palpite no servidor e retorna somente `correct: true/false`. Ao acertar, ela libera a identidade e calcula colocação/pontos.

Isso é deliberadamente diferente de esconder a identidade com CSS ou mantê-la em um objeto JavaScript.

## 4. Realtime

A migration adiciona estas tabelas à publicação `supabase_realtime`:

- rooms
- room_players
- secret_characters
- questions
- answers
- chat_messages

O frontend assina mudanças dessas tabelas e redesenha a sala automaticamente.

## 5. Banco de personagens

`supabase/seed.sql` contém 600+ itens iniciais. Categorias escaláveis como ANIMAIS, PAÍSES, PROFISSÕES, OBJETOS e COMIDAS já possuem aproximadamente 100 itens cada; temas de cultura pop vêm com um conjunto inicial curado e podem ser ampliados apenas adicionando linhas em `characters`.

## 6. Build de produção

```bash
npm run build
npm run preview
```

A pasta final é `dist/`.

## 7. Publicar gratuitamente

### Vercel
- Importe o repositório (Framework: Vite — `vercel.json` já define build `npm run build` e saída `dist`).
- Cadastre `VITE_SUPABASE_URL` e `VITE_SUPABASE_PUBLISHABLE_KEY` em **Settings > Environment Variables** (Production e Preview). Como são variáveis `VITE_*`, elas entram no build: depois de alterá-las, faça um novo deploy.
- Em **Settings > Deployment Protection**, deixe a *Vercel Authentication* apenas para Preview; senão seus amigos caem numa tela de login da Vercel ao abrir o link de produção.
- `vercel.json` já contém fallback SPA, cache longo para `/assets` e `no-cache` para o service worker.

### Netlify
- Build command: `npm run build`
- Publish directory: `dist`
- Cadastre as duas variáveis de ambiente.
- `netlify.toml` já contém redirect SPA.

### Firebase Hosting
Você também pode servir apenas os arquivos de `dist/` no Firebase Hosting. O backend continuará sendo Supabase.

## 8. PWA no celular

Depois de publicado em HTTPS, abra no Chrome/Edge/Safari compatível e escolha **Adicionar à tela inicial / Instalar aplicativo**. `manifest.webmanifest` e `sw.js` já estão inclusos.

## 9. Estrutura

```text
/index.html
/src/css/style.css
/src/js/app.js
/src/js/supabase.js
/src/js/realtime.js
/src/js/avatar.js
/src/js/bots.js
/src/data/themes.js
/public/manifest.webmanifest
/public/sw.js
/public/icons/icon.svg
/supabase/migrations/001_schema.sql
/supabase/migrations/002_security_and_fixes.sql
/supabase/migrations/003_turns.sql
/supabase/seed.sql
/vercel.json
/netlify.toml
```

## Próximas extensões já modeladas

A base está pronta para evoluir a interface de matchmaking público, votação de temas e amigos usando as tabelas existentes. Para produção maior, prefira Supabase Broadcast para escalar eventos de sala; para salas de 2–4 jogadores, Postgres Changes é simples e adequado.
