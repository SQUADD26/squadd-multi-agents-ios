## 2026-11-20 06:34 · claude-sandbox · f3fda26d · squadd-multi-agents-ios · ramo: issue/14-approvazioni
Approvazioni Squadd dal telefono (#14): card del companion nello slot di approvazione di Hermex, risposta via respond e always-allow, prova live
+ ApprovalRequestInset: riusato per Squadd con onSkipAll nil, niente stringhe nuove; la card arriva da message.card requestType permission
+ fixture: registrate da openmausbot origin/dev con fake-acp-cli FAKE_ACP_MODE=permission, che apre una card a ogni messaggio
- serveo: senza chiave l'indirizzo dipende solo dall'IP della VPS ed era gia' preso da un'altra sessione (rispondeva un'altra API); con una chiave ssh propria (-i key) l'indirizzo e' unico
- SquaddChatTests: una classe foto con ChatView vuole import SwiftUI, il build della CI e' fallito una volta per questo
