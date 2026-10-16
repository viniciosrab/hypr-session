# hypr-session

Plugin nativo do Omarchy que salva e restaura a sessão do Hyprland entre reboots, sem mostrar nada na tela durante a restauração.

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

## Instalação

```sh
omarchy plugin add https://github.com/viniciosrab/hypr-session.git --enable
```

Funciona sem configurar nada: o plugin salva a sessão e a restaura sozinho no próximo boot. Os apps abertos hoje só precisam estar abertos quando o plugin for ativado.

Dependências: `hyprland` (0.56+, configuração em Lua), `sqlite3` (só para retomar o Codex).

Para ver o ícone na barra: `omarchy bar put vinicios.hypr-session --section right`.

## Painel

O ícone da barra mostra a hora do último save. Clicar abre o painel:

- **Último save** e **última restauração**, com o resultado (janelas encontradas e se o layout bateu).
- **Salvar agora** e **Restaurar agora**.
- Quatro opções, todas ligadas por padrão:

| Opção | Desligada |
|---|---|
| Restaurar ao iniciar | Nada é reaberto no boot. O save continua. |
| Salvar automaticamente | A sessão salva não é mais atualizada. |
| Remontar layout | Os apps voltam nos workspaces certos, sem remontar o dwindle. |
| Retomar agentes nos terminais | Claude, Codex e pi voltam na pasta certa, mas sem reabrir a conversa. |

- **Não salvar estes apps**: lista dos apps abertos. Os marcados não são salvos nem restaurados (por exemplo, um app que o seu `autostart.lua` já abre).

As opções ficam em `~/.local/state/omarchy/settings/hypr-session.json`, então valem mesmo sem o ícone na barra.

## IPC

```sh
omarchy-shell hypr-session save
omarchy-shell hypr-session restore
omarchy-shell hypr-session status                       # JSON
omarchy-shell hypr-session set autoSave false           # restoreOnStart | autoSave | rearrangeLayout | resumeAgents
omarchy-shell hypr-session ignore <classe>
omarchy-shell hypr-session unignore <classe>
```

## Como funciona

- O plugin é um serviço que roda dentro do `omarchy-shell`. Ele salva o estado a cada evento de janela (abrir e mover esperam 1s, fechar espera 5s) e a cada 15s, e só regrava o arquivo quando algo muda.
- Quando o Omarchy desliga, reinicia ou faz logout, ele fecha todas as janelas antes. O plugin detecta isso e para de salvar, para não gravar um desktop pela metade.
- A restauração roda uma vez por sessão do Hyprland, cerca de 3s depois que o shell sobe. Reiniciar o shell ou recarregar o plugin nunca reabre os apps.
- Para evitar que janelas apareçam no workspace errado, a restauração usa regras de janela temporárias por app, desativadas no final. Isso importa nos web apps e no Chrome, que abrem pela instância que já está rodando.
- Depois de remontar o layout, o plugin confere cada janela com o que foi salvo e tenta de novo (até 3 vezes) se algo não bater.

A lógica de decidir o que salvar e como montar o layout fica em `Model.js`, sem I/O, e é testada com node. O `Service.qml` lê o `/proc`, chama o `hyprctl` e espera.

## Arquivos de estado

| Arquivo | Conteúdo |
|---|---|
| `~/.local/state/hypr-session.json` | Estado salvo atual |
| `~/.local/state/hypr-session.restored.json` | O que foi restaurado no último boot |
| `~/.local/state/hypr-session.log` | Log de saves, da restauração e da remontagem do layout |

O formato é o mesmo da versão em script: um estado salvo por ela restaura normalmente pelo plugin.

## Testes

```sh
tests/run.sh
```

Roda os testes de unidade do `Model.js` (node) e os cenários de integração dentro do Quickshell, com um `hyprctl` falso e um `HOME` temporário. Nada toca o compositor, o shell em uso nem a sua sessão salva. Os cenários de integração precisam de uma sessão Wayland.

## Migração da versão em script

Se você usava o `hypr-session` em bash: remova os links `~/.local/bin/hypr-session` e `~/.config/omarchy/hooks/post-boot.d/restore-session`, pare o `hypr-session watch` que estiver rodando e instale o plugin. Com os dois ativos ao mesmo tempo, a sessão seria restaurada duas vezes.

## Limitações

- Codex e pi só criam a sessão depois da primeira mensagem. Um Codex ou pi aberto e nunca usado volta sem sessão.
- Com dois Codex abertos na mesma pasta, os dois podem voltar na mesma conversa, a mais recente.
- Layouts que não são do dwindle ficam como abriram (fica registrado no log).
- Se o shell reiniciar no meio de uma restauração, ela não recomeça: use **Restaurar agora**.
