# hypr-session

Plugin do Omarchy que salva sua sessão do Hyprland e a restaura depois de um reboot, sem nada piscar na tela.

## O que volta

- Cada app no seu workspace, incluindo os especiais (como o scratchpad).
- O layout exato: tamanho e divisão de cada janela, e as janelas flutuantes.
- Terminais na mesma pasta, rodando o que rodavam: Claude Code, Codex e pi voltam na mesma conversa. Também reabrem herdr, nvim, vim, btop, htop, lazygit, lazydocker e yazi.
- Chrome com as abas da última sessão, e web apps como web apps.

## Instalação

```sh
omarchy plugin add https://github.com/viniciosrab/hypr-session.git --enable
omarchy bar put vinicios.hypr-session --section right   # ícone na barra (opcional)
```

Pronto. A partir daí a sessão é salva sozinha e volta no próximo boot.

Precisa do Hyprland 0.56 ou mais novo. O `sqlite3` só é necessário para retomar o Codex.

## Painel

Clique no ícone da barra para ver quando a sessão foi salva e restaurada pela última vez, e para salvar ou restaurar na hora.

| Opção (todas ligadas por padrão) | Ao desligar |
|---|---|
| Restaurar ao iniciar | Nada reabre no boot. A sessão continua sendo salva. |
| Salvar automaticamente | A sessão salva fica congelada como está. |
| Remontar layout | Os apps voltam no workspace certo, mas sem refazer o layout. |
| Retomar agentes nos terminais | Claude, Codex e pi voltam na pasta, sem reabrir a conversa. |

Em **Não salvar estes apps**, marque o que não deve ser salvo nem reaberto.

## Pelo terminal

```sh
omarchy-shell hypr-session save | restore | status
omarchy-shell hypr-session set autoSave false
omarchy-shell hypr-session ignore <classe>      # ou unignore
```

## Arquivos

- `~/.local/state/hypr-session.json`: a sessão salva
- `~/.local/state/hypr-session.log`: o que foi salvo e restaurado, útil quando algo não volta certo

## Vindo da versão em script

Apague `~/.local/bin/hypr-session` e `~/.config/omarchy/hooks/post-boot.d/restore-session` antes de instalar, senão a sessão é restaurada duas vezes. A sessão já salva continua valendo.

## Limitações

- Um Codex ou pi aberto e nunca usado volta sem conversa.
- Dois Codex na mesma pasta podem voltar na mesma conversa.
- Só o layout dwindle é remontado.
- Se o shell reiniciar no meio de uma restauração, ela não recomeça sozinha. Use **Restaurar agora**.
