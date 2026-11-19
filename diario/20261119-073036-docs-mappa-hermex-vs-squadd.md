## 2026-11-19 07:30 · claude-sandbox · c89fbb94 · squadd-multi-agents-ios · ramo: docs/mappa-hermex-vs-squadd
Mappa Hermex contro Squadd Multi-Agents in docs/mappa-hermex-vs-squadd.md, con protocollo, Android e PR CI su main e dev
+ companion/src/routes.ts: la whitelist alle righe 82-258 è il contratto del telefono, ogni chiamata di Hermex si confronta lì
+ openmausbot: letto da git archive di origin/dev nella scratchpad, il checkout locale era su un altro commit
+ pr-ci.yml: xcode-27 è un'immagine ospitata da GitHub, si cambiano solo i trigger
- Android: hermex-android-port-hermes è codice Swift per iOS nonostante il nome, va controllato il contenuto e non la descrizione
