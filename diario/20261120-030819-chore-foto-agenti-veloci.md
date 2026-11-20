## 2026-11-20 03:08 · claude-sandbox · 96334640 · squadd-multi-agents-ios · ramo: chore/foto-agenti-veloci
Foto degli agenti di squadd-multi-agents-ios piu' veloci: SquaddAgentPhotoTests da 6,7 s a 2,1 s, foto identiche
+ misura: un tempi.txt scritto nella cartella delle foto (artefatto) dice costo per foto e fotogrammi; le PNG sono identiche byte per byte tra run, quindi md5 basta per provare "foto identiche"
+ readyPhoto: ogni foto costa almeno ~0,55 s (3 fotogrammi fermi a 0,1 s, render 3x ~55 ms); sotto i 3 s si sta solo con poche foto
- foto doppie: 0-home ripeteva a-agents di SquaddCompanionTests; picker e modello rifiutato restano provati dai test di modello, non a foto
? confronto a 1x in readyPhoto: lo porta la PR della CI; misurato qui 1,88 s contro 2,07 s
- pulizia: rimozione di worktree e ramo di confronto misura/foto-base-dev negata dai permessi, resta a sandbox-pulizia
