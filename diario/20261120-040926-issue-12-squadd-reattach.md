## 2026-11-20 04:09 · claude-sandbox · 9730c008 · squadd-multi-agents-ios · ramo: issue/12-squadd-reattach
Ripresa dello stream Squadd dopo background e cambio di rete (#12): cursore, frame doppi, ricarica su ripresa persa, provati con frame registrati e dal vivo
+ SquaddChatTurnCoordinator.swift: sul hello ripreso si tiene il proprio cursore, il server manda lastSeq ma la replay riparte da since+1
+ SquaddChatTests.swift mock: senza Content-Type URLSession trattiene 512 byte per indovinarlo, un frame piccolo non arriva mai; costato 3 giri di CI
- SquaddChatTests.swift: prima ipotesi sul rosso (lettura iniziale in ritardo) dedotta dal codice e sbagliata; leggere prima cosa resta a schermo
+ foto dal vivo: il tunnel serveo può restare su un URL che dà 502; riavviare il ciclo prima del run
