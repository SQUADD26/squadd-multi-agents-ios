## 2026-11-19 11:59 · claude-sandbox · f5a6cbb9 · squadd-multi-agents-ios · ramo: issue/2-backend-squadd
Backend Squadd nell'app iPhone (#2): tipo di server squadd, client del companion, lista agenti e thread, rifai-pairing
+ HermesMobile/Networking/Squadd: client e modelli compilati su Linux con Swift 6.1.2 (toolchain in /tmp, header da deb Debian) e provati contro un companion vivo; il compilatore ha trovato un await mancante prima della CI
+ companion isolato: openmausbot origin/dev in un worktree a parte, porte 18799/18810/18811, motore finto; i task stanno in GET /api/bots, non c'è una GET dei task
- file lunghi: la guardia limite-righe blocca ogni Edit che allunga file sopra 300 righe; in AuthManager e ContentView solo modifiche a righe invariate, il resto in file nuovi (AuthManager+Squadd, SquaddRoute)
- file occupati: ServerAccount, AuthManager, ContentView, pbxproj erano toccati dalla PR #36; serve Condivisi dalla madre prima di cominciare, chiederlo subito
? SettingsView.swift riga 156: mostra «webui» per un server Squadd; il file è del ticket #4 (marchio), da sistemare lì
