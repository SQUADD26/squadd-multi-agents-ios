## 2026-11-20 03:02 · claude-sandbox · 1f6ef8e2 · squadd-multi-agents-ios · ramo: test/squadd-photos-one-window
Foto delle impostazioni Squadd in una finestra sola, 4 schermate, test foto da 5,7 a 2,9 s in PR iOS
+ SquaddSettingsTests.swift: una UIWindow e un UIHostingController per tutte le foto, si cambia solo rootView; dati caricati prima dello scatto, readyPhoto si ferma prima
+ foto: tenute engines, keys, team-memory, connected-apps; tolte server-page, agents, agent-tools, memory-editor; le 4 restano identiche al pixel a quelle di dev
? f6-team-memory: la riga Kickoff alterna tra due versioni da un run all'altro (118 pixel), gia' prima di questo ramo
- PR iOS: il primo push non ha fatto partire il run per ~2 min e poi e' arrivato in ritardo cancellando quello del push dopo; si legge il run per head_sha
