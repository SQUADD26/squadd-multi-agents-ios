## 2026-11-20 01:02 · claude-sandbox · 1f6ef8e2 · squadd-multi-agents-ios · ramo: fix/squadd-photos-ready
Foto delle impostazioni Squadd: attesa fissa di un secondo sostituita da readyPhoto, foto uguali e test foto da 10,0 a 6,2 s
+ prova delle foto uguali: confronto pixel per pixel con le foto dello stesso runner prima della modifica; 7 su 8 identiche, f6 con 118 pixel diversi nella riga Kickoff, a occhio uguale
- confronto con le foto vecchie del ramo foto: tutte diverse perché quel workflow scattava in scuro e PR iOS in chiaro; si confronta solo con foto dello stesso runner
