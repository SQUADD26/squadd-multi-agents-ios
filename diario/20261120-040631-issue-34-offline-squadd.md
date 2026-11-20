## 2026-11-20 04:06 · claude-sandbox · 71a4dc73 · squadd-multi-agents-ios · ramo: issue/34-offline-squadd
Cache offline di Squadd (#34): home e chat dei thread salvate per server nella cache SwiftData di Hermes, banner offline, aggiornamento al ritorno della rete
+ Persistence/CacheStore+Squadd.swift: home come una riga JSON di /api/bots e transcript sotto scope squadd|..., nella tabella dei messaggi: clearCache, TTL e cap valgono già, niente schema nuovo
+ SquaddHTTPFixture e SquaddChatFixture: status 0 e .offline fanno fallire con URLError, così i test offline non hanno attese
- registro Linux: SquaddEndpoint e SquaddChat non compilano senza Network e ChatMessage; build.sh li salta o toglie l'import, e una finta AuthManager sta nel file del registro
? SquaddRouteFinder: la home si aggiorna da sola solo se cambia la rotta (nil -> trovata); un computer che si riaccende sulla stessa rete aspetta il pull o un cambio di rete
