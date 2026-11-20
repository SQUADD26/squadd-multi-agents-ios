## 2026-11-20 06:18 · claude-sandbox · 411cc745 · squadd-multi-agents-ios · ramo: issue/20-undo-exchange
Undo #20, giro 1 del giudice: i test leggono la lista che la riga passa al menu, rosso rosso/20-u-menu
- SquaddUndoTests.swift: i test chiamavano squaddUndo da soli, togliere la voce da extraItems non li faceva cadere; ora la riga compone il menu con squaddRowItems e i test leggono quello
