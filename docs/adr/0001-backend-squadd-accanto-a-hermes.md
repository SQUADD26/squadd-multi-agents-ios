---
status: accepted
---

# Un terzo backend, `Networking/Squadd/`, che parla con il companion

L'app eredita da Hermex due protocolli: Hermes (REST e JSON-RPC su WebSocket) e hermes-webui (REST e SSE). Squadd Multi-Agents ne parla un terzo, quello del companion di `openmausbot`: le route `/api/bots/...` della whitelist (`companion/src/routes.ts`) e lo stream SSE `/api/events`, con i frame descritti in `packages/phone-protocol`. Decidiamo di aggiungere un terzo tipo di server accanto ai due (`ServerKind` guadagna il caso Squadd) e un backend `HermesMobile/Networking/Squadd/` che traduce il contratto del companion nei modelli che i view model usano già. Le schermate di Hermex (lista, chat, approvazioni, stanze, impostazioni) restano e chiamano il nuovo backend attraverso le stesse estensioni e gli stessi modelli tolleranti.

La strada opposta, far parlare Hermes al companion, avrebbe portato sul server di Squadd concetti che non ha (profili Hermes, checkpoint, rewind, gateway RPC) e un adattatore da mantenere in un'altra repo. Il prezzo della nostra scelta: il backend Squadd è il terzo da tenere allineato al suo contratto, e ogni funzione di Hermex che non ha una route nel companion va nascosta o aggiunta alla whitelist in `openmausbot`.

## Conseguenze

- Ogni chiamata nuova verso il companion si verifica sul codice di `companion/src/routes.ts` e di `packages/phone-protocol` al commit indicato nella PR, mai inventata.
- La riga «Protocollo» di `docs/mappa-hermex-vs-squadd.md` è l'elenco di partenza delle chiamate da tradurre.
- Lo stato per server (cache, bozze, credenziali) segue `docs/agents/multi-server-state-isolation.md` anche per i server Squadd.
