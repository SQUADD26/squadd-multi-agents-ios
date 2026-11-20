## 2026-11-20 05:13 · claude-sandbox · 9730c008 · squadd-multi-agents-ios · ramo: issue/13-squadd-stop-queue-compact
Squadd #13 nell'app iPhone: Stop, coda (steer e cancella) e compattazione contro il companion, provati con frame veri, 10 rossi e due giri dal vivo
+ contratto followUp: un invio a un agente occupato viene steered di default, va in coda solo con followUp queue; verificato dal vivo prima di scrivere codice
- SquaddChatTests stop: il primo test aspettava activeStreamID nil, vero dentro finish prima della ricarica; il rosso keepstopped passava verde. Ora aspetta la riconnessione dello stream dopo l'ultimo frame
- prova dal vivo: la prima ricaricava dopo Stop e faceva sparire la parziale; si vede solo dalla foto, guardarle sempre
+ conflitto con dev su send: mode dei comandi slash e followUp della coda convivono nello stesso corpo
? log dal vivo: il frame di stop puo' arrivare prima della risposta HTTP di interrupt, quindi still running puo' essere false; non e' un difetto
