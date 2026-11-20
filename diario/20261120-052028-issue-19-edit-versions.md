## 2026-11-20 05:20 · claude-sandbox · 411cc745 · squadd-multi-agents-ios · ramo: issue/19-edit-versions
Unione di dev in #87 versioni e reazioni: conflitti con offline #91 e allegati #93 risolti, PR iOS verde 44679994899 su 3f2f291
+ SquaddChat.swift: SquaddMessage tiene parentId, reactions, reaction e attachments; chatMessage di dev con la guardia reaction == nil
+ SquaddChatTurnCoordinator.swift: olderMessages e shownRows restano, la cache di dev scrive le righe del ramo attivo; transcriptRows porta gli allegati
? giro dal vivo: non ripetuto dopo l'unione, vale 44679053538 su 2bd7546 perche' dopo e' entrato solo dev
- gh run watch: la guardia vuole --interval 30 o piu'
