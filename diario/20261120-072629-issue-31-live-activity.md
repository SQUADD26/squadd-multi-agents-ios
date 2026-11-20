## 2026-11-20 07:26 · claude-sandbox · 96334640 · squadd-multi-agents-ios · ramo: issue/31-live-activity
Giro 3 di #31: la card finisce quando il thread riletto dopo un resume perso mostra il turno chiuso
+ SquaddChatTurnCoordinator: dopo il reload, una risposta con turnTerminal dopo l'ultimo messaggio della persona chiude la card; il residuo «Working per 15 minuti» del giro 2 non c'è più
- residuo dichiarato invece che chiuso: il giudice lo boccia se l'app ha già il segnale (qui turnTerminal nel transcript)
