## 2026-11-20 06:49 · claude-sandbox · 96334640 · squadd-multi-agents-ios · ramo: issue/31-live-activity
Live Activity, Dynamic Island e widget dei bot di Squadd sull'iPhone (#31): attività per agente dallo stream, registrazione su /api/push/activity, widget limiti tolto
+ contratto: il tipo deve chiamarsi LiveActivityAttributes con content-state {name, props}, perché le push del companion lo indirizzano per nome
+ registrazione SSE: request.opened registrato da control-omb launch con FAKE_CLAUDE_MODE=hang e FAKE_CLAUDE_ELICIT; il server diretto con HOME finto usa il claude vero e non è loggato
- PUT /api/push/activity non registrabile: un companion lanciato da solo non ha il mutation token, quindi niente phoneKey (403); il test asserisce solo i campi della richiesta
- waitUntil: un double che non è @Observable non sveglia mai l'attesa; 5 s persi in CI
- push-tests: enable chiamava SquaddLiveActivities.shared, e il test dopo si appendeva fino al limite di 2 minuti; ora la sync è iniettata
? widget dei bot: nessuna foto, le viste del widget non stanno nel target dell'app; lo prova il test del publisher
