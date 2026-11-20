## 2026-11-20 04:30 · claude-sandbox · 71a4dc73 · squadd-multi-agents-ios · ramo: issue/34-offline-squadd
Cache offline di Squadd (#34), giro live: nell'app vera il thread offline restava vuoto, corretto e riprovato
- SquaddChatTurnCoordinator.swift: ChatView apre la chat con reconnectStreamIfNeeded prima di loadMessages, e la cache arrivava solo da loadMessages; i test unitari chiamavano solo loadMessages e passavano. Ora ogni ingresso con il contesto lo passa, e il test parte come la vista
- serveo: nessun indirizzo con due altri tunnel attivi sulla sandbox (forse un limite per IP); cloudflared quick tunnel va bene per le prove solo REST
+ foto/34-live: workflow_dispatch come chiesto dalla sessione madre; il giro live si lancia una volta, prima di unire
