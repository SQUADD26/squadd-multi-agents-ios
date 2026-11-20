## 2026-11-20 02:03 · claude-sandbox · 411cc745 · squadd-multi-agents-ios · ramo: fix/pr-state-cancelled
CI PR iOS di squadd-multi-agents-ios: pr_state.py regge un run annullato a metà del cambio di stato
+ ci/pr_state.py: se lo stato del ramo corrente è già parcheggiato, quello che resta nel workspace va via invece di bloccare il rename (Errno 66 su entrambi i runner)
- rami rosso/9: annullarne uno o lasciarlo scadere a metà dello script ha bloccato i runner per tutte le figlie; non annullare run iOS in corsa
+ ci/test_pr_state.py: il caso annullato gira anche su Linux, il resto della classe chiede libc.dylib e cade fuori dal Mac
