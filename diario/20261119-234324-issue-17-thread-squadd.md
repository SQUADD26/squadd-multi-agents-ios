## 2026-11-19 23:43 · claude-sandbox · 71a4dc73 · squadd-multi-agents-ios · ramo: issue/17-thread-squadd
Thread Squadd sul telefono (#17), secondo giro: merge di dev con #22, righe rosse in un job a parte, registro rifatto pulito
+ righe rosse: in un job separato con un solo build-for-testing e timeout 240; il primo giro morì a 90 minuti senza artefatto
- test dell'ordine: la riga rossa «fissati in cima» restava verde perché nella fixture il fissato era anche il più recente; ora si sposta il fissaggio sul thread più vecchio
- registro17: il primo registro aveva un thread avanzato da un giro precedente; ora un passo setup lo toglie e il desktop si legge anche subito dopo le azioni
+ merge con #22: header agente con nome che apre l'editor e bottone nuovo thread accanto, client con entrambi gli helper (JSONSerialization per i null, Encodable per i bot)
? scratchpad: i worktree dei rami foto spariscono (pulizia); crearli e usarli nella stessa chiamata
