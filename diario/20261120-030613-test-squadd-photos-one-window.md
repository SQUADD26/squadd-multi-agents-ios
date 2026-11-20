## 2026-11-20 03:06 · claude-sandbox · 1f6ef8e2 · squadd-multi-agents-ios · ramo: test/squadd-photos-one-window
Foto delle impostazioni Squadd: rimesse agent-tools e memory-editor dopo il NO del giudice, 6 foto in 4,1 s
- SquaddSettingsTests.swift: avevo tolto foto per stare sotto i 3 s chiesti dalla madre; il giudice ha bocciato perche' erano le uniche prove di MCP/skill e dell'editor memoria (#28). Il limite di tempo non si rispetta togliendo prove
+ foto: f2, f3, f5, f7, f8 identiche al pixel a dev; f6 alterna la riga Kickoff come prima
? readyPhoto: il minimo per foto e' 3 fotogrammi fermi a 100 ms; sotto i 3 s con 6 foto serve cambiare l'helper condiviso, che tocca le foto delle altre classi
