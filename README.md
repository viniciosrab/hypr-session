# hypr-session

Salva e restaura a sessão do Hyprland (Omarchy) entre reboots, sem mostrar nada na tela durante a restauração.

## O que volta

- **Apps nos workspaces certos**, incluindo workspaces especiais como o scratchpad (`Super+S`).
- **Layout exato do dwindle**: posição, tamanho e divisões de cada janela, além das janelas flutuantes. O layout é remontado nos workspaces escondidos sem focar nenhuma janela nem trocar de workspace.
- **Terminais com o programa que estava rodando**, na mesma pasta:
  - Claude Code: `claude --resume <sessão>`, a mesma conversa.
  - Codex: `codex resume <sessão>`.
  - pi: `pi --session <sessão>`.
  - herdr, nvim, vim, btop, htop, lazygit, lazydocker e yazi abrem de novo.
- **Chrome com as abas da última sessão** (`--restore-last-session`).
- **Web apps** (`omarchy-launch-webapp`) como web apps, cada um no seu workspace.

## Como funciona

- `hypr-session watch` roda desde o boot. Ele salva o estado a cada evento de janela e a cada 15s, e só regrava o arquivo quando algo muda.
- Quando o Omarchy desliga, reinicia ou faz logout, ele fecha todas as janelas antes. O script detecta isso e para de salvar, para não gravar um desktop pela metade.
- No boot, o hook `post-boot` roda `hypr-session restore` e depois `watch`.
- Para evitar que janelas apareçam no workspace errado, a restauração usa regras de janela temporárias por app, desativadas no final. Isso importa nos web apps e no Chrome, que abrem pela instância que já está rodando.
- Depois de remontar o layout, o script confere cada janela com o que foi salvo e tenta de novo (até 3 vezes) se algo não bater.

## Instalação

```sh
gh repo clone viniciosrab/hypr-session ~/Projects/hypr-session
~/Projects/hypr-session/install.sh
```

O `install.sh` cria links em `~/.local/bin/hypr-session` e `~/.config/omarchy/hooks/post-boot.d/restore-session`, então as edições no repositório valem na hora.

Dependências: `hyprland` (0.56+, configuração em Lua), `jq`, `socat`, `python3` e `sqlite3` (este só para retomar o Codex).

## Arquivos de estado

| Arquivo | Conteúdo |
|---|---|
| `~/.local/state/hypr-session.json` | Estado salvo atual |
| `~/.local/state/hypr-session.restored.json` | O que foi restaurado no último boot |
| `~/.local/state/hypr-session.log` | Log de saves, da restauração e da remontagem do layout |

## Limitações

- Codex e pi só criam a sessão depois da primeira mensagem. Um Codex ou pi aberto e nunca usado volta sem sessão.
- Com dois Codex abertos na mesma pasta, os dois podem voltar na mesma conversa, a mais recente.
- Layouts que não são do dwindle ficam como abriram (fica registrado no log).
