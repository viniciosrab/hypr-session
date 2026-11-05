# hypr-session — remember the Super + P size

Each app remembers the last size its window had in pseudotile (Super + P) and opens again in pseudotile at that size, behind a panel switch. Branch `feat/remember-pseudo-size`.

## Specs

- S1 (user, verbatim): "O que a gente tá falando aqui é somente lembrar o último tamanho da janela, só isso, entendeu?" — While a window is pseudotiled, the plugin keeps its size for its window class. The last window of a class seen before it closed decides: pseudotiled → its size is remembered; not pseudotiled → the class is forgotten. One size per class.
- S2 When an app opens a new tiled window whose class has a remembered size, the plugin turns pseudotile on for that window and applies the remembered size (clamped by Hyprland to the tile). Floating windows and windows opened by a session restore are left alone.
- S3 (user, verbatim): "com a funcao de chave ne" — A panel switch turns the feature on or off; setting `rememberPseudoSize`, default on, persisted with the other settings and settable via `omarchy-shell hypr-session set rememberPseudoSize false`. Off: nothing is remembered or applied.
- S4 The remembered sizes survive a shell restart and a reboot: `~/.local/state/hypr-session.sizes.json` (next to the session file), mode 600.
- S6 (user chose L7) Super + P still pseudotiles at once in Hyprland and also tells the plugin which window it flipped (`omarchy-shell -q hypr-session pseudo <address>`); with the shell down, Super + P works as before. Only windows flipped by Super + P or opened pseudotiled by the plugin are tracked; one gone untracked changes nothing.
- S5 Tests (node unit for the pure rules; Quickshell integration with the fake hyprctl) and README cover it.

## Tasks

- T1 S1-S6 Model rules + Service tracking/apply + IPC `pseudo` + panel switch + i18n + tests + README — inline — commit: pending
- T2 S6 Super + P in ~/.config/hypr/bindings.lua (outside this repo) — inline — no commit (user config)

## Log

- L1 (user, verbatim): "uma coisa, uma pergunta. quando eu uso o Super, o atalho Super mais P, que aí consigo redimensionar a janela, né? aí, por exemplo, eu fecho essa janela do aplicativo e ele abre novo. ele não salva. como que eu vou falar? ele não salva o tamanho que eu deixei, entendeu? ele volta em tela cheia, sabe? como é que pode ser resolvido isso? tem alguma configuração aqui no o omachy?"
- L2 (user, verbatim): "Como assim abrir flutuante? Não, ele vai abrir normal, como eu deixei em Tilingue, né? O que eu tô falando é que eu quero que o aplicativo lembre o último qualquer aplicativo que lembre o último tamanho que eu deixei. É que geralmente, quando eu quero redimensionar, ele usa as teclas de atalho do Super mais P, né? Daí consigo redimensionar, entendeu? É indiferente se é flutuante. O que isso aí é indiferente, entendeu? O que a gente tá falando aqui é somente lembrar o último tamanho da janela, só isso, entendeu?"
- L3 (user, verbatim): "tá, e não dá pra implementar esse, no caso, essa função aí, em vez de usar um script solto, né? que a gente já tem um plugin ativo do Omarchy, que é Hypr-session, que ele já é relacionado, né?"
- L4 (user, verbatim): "com a funcao de chave ne"
- L5 Evidence (Hyprland 0.56.2 source): `persistent_size` only stores the size of floating windows on close (Window.cpp:2577); pseudo size lives on the layout target only (Target.hpp:84) and is lost on close; resizing a pseudotiled window changes its pseudo size by the delta, clamped to the tile (LayoutManager.cpp:61-76).
- L6 Evidence (Hyprland 0.56.2 source): no runtime API exposes whether a window is pseudotiled. `hyprctl clients -j` has no pseudo field (HyprCtl.cpp:389-424; `size` is the shrunken box), the Lua window object has none (LuaWindow.cpp:70-245), and no IPC event fires on a pseudo toggle or resize (Target.cpp:80-101). Applying works: `hl.dsp.window.pseudo({ action = "enable", window = "address:..." })` then a resize, or a runtime `hl.window_rule{ name, match, pseudo = true, size }`. Open question to the user: how the plugin learns of Super + P.
- L7 (user choice): "Super + P passa pelo plugin (recomendado)" over guessing from the window shape.
