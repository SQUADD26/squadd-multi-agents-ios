## 2026-11-20 01:45 · claude-sandbox · 71a4dc73 · squadd-multi-agents-ios · ramo: issue/18-cartelle-squadd
Cartelle Squadd sul telefono per #18: crea, sposta, riordina e cancella nell'ordine della sidebar del desktop, provate contro il companion isolato
+ ordine cartelle: folderRank di Sidebar.tsx (primo thread aperto) vince sull'ordine salvato; Move Up/Down su una cartella piena può non spostarla, come sul desktop
- merge di dev dopo lo squash di #17: il ramo di #18 portava i vecchi commit di #17 e andava in conflitto su 6 file; risolto riapplicando solo il diff di #18 (5848df8..fc392ce) su origin/dev
+ link ai thread di #70: SquaddThreadLink.row cerca anche nelle cartelle e negli archiviati, altrimenti un link valido diceva Thread Not Found
? registro build.sh: SquaddPairingInvite.swift usa AuthManager e va escluso dalla compilazione Linux, sennò resta il binario vecchio senza errore visibile
