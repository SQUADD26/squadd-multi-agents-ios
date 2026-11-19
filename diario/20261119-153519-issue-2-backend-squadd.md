## 2026-11-19 15:35 · claude-sandbox · f5a6cbb9 · squadd-multi-agents-ios · ramo: issue/2-backend-squadd
Prove CI di #2 Squadd backend: foto delle schermate e righe rosse su runner macOS, merge di dev
+ HermesMobileTests/SquaddCompanionTests.swift: test foto ospitato (come ScreenPhotoTests di #6) con AuthManager vero e URLProtocol registrato che ripete le risposte del companion; niente target UI, niente App ID nuovo
+ ci/foto-2-backend/righe-rosse.sh: con -resultBundlePath e xcresulttool il log nomina l'asserzione che cade per ogni mutazione; il solo grep di xcodebuild non la mostrava
- foto d: AppLock appena creato mostra la copertina, non il lucchetto; serve sceneDidBecomeActive prima dello scatto
- limite API GitHub: gh run watch a intervallo corto con piu' figlie sullo stesso token lo ha esaurito; usare --interval 120
? HermexPushSettingsPage.swift riga 130: per un server Squadd le Notifiche offrono Connect Hermes, da chiudere con #30 o #3
