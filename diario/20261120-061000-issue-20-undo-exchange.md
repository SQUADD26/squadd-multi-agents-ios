## 2026-11-20 06:10 · claude-sandbox · 411cc745 · squadd-multi-agents-ios · ramo: issue/20-undo-exchange
Undo dell'ultimo scambio in un thread Squadd #20: menu dell'ultimo scambio e /undo chiamano undo-exchange di openmausbot #113, spento alla radice, giro dal vivo verde 44685139894
+ SquaddChatTurnCoordinator.swift: canUndo e righe dell'ultimo scambio calcolati in updateMarks dal ramo attivo; il 409 nothing_to_undo non arriva mai al telefono
- unione dopo il merge a squash di #99: git merge di dev confliggeva in 8 file; cherry-pick dei due commit di undo su un ramo nuovo da dev, un solo conflitto nel catalogo
- giro dal vivo: due giri persi per il test, non per l'app; il thread Prima parola non era piu' alla radice perche' il giro del fork ci aveva scritto
? SquaddVersionsTests.swift: rosso una volta su sei a riga 72 in un run di mutazione; ipotesi gara tra lo stream del coordinatore e quello del modello, da verificare
