## 2026-11-20 07:15 · claude-sandbox · 96334640 · squadd-multi-agents-ios · ramo: issue/31-live-activity
Giro 2 di #31 dopo il NO del giudice: avatar Squadd nel widget, foto di widget e Dynamic Island, card tenuta su resume perso
+ BotWidget.swift nel target app: la foto rende la vista vera del widget, nessuna copia
+ waitUntil: aspetta solo valori @Observable; per un file scritto in un Task si aspetta la closure reloadWidget (expectation con count)
- foto widget: avevo scritto «impossibile» senza provare a mettere il file nel target app; il giudice l'ha bocciato
- scripts/pr-ios-run red: nomi minuscoli (resume-ends=<sha>), con maiuscole esce subito
? card su turno finito a frame persi: resta Working fino alla push di fine o allo stale di 15 minuti
