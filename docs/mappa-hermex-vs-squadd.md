# Mappa: Hermex contro Squadd Multi-Agents

Serve a decidere come diventa l'app iPhone di Squadd Multi-Agents partendo da Hermex.
Codice letto il 2026-11-19: Hermex su `e306196` (questa repo), Squadd Multi-Agents su `SQUADD26/openmausbot` `origin/dev` `58a25af10`.
Ogni voce porta `file:riga` aperto nel codice. «non trovata» vuol dire cercata e non trovata nel codice.

## Le 5 decisioni da prendere

1. **Che cosa parla l'app?** Hermex parla due protocolli: quello di Hermes (REST e JSON-RPC su WebSocket) e quello di hermes-webui (REST e SSE). Il companion ne parla un terzo: `/api/bots/...` più lo stream SSE `/api/events` (`companion/src/routes.ts:82-258`). Proposta: aggiungere all'app un terzo backend, `Networking/Squadd/`, accanto ai due che ci sono, e tenere la UI. La strada opposta, far parlare Hermes al companion, costa di più e porta sul server concetti che Squadd non ha. Costo: circa 19 giorni per lista, chat, invio, stream, riconnessione, stop, coda, thread, approvazioni e domande (le prime righe della tabella).
2. **Teniamo Hermes e webui nell'app?** «Famola nostra» fa pensare a un'app solo Squadd. Togliere i due backend alleggerisce di molto il codice (Kanban, Git, Workspace, MoveToHermes e Insights parlano solo con Hermes o webui), ma ogni merge da Hermex diventa più difficile. Proposta: v1 solo Squadd, codice Hermes/webui spento dietro un flag, poi tolto.
3. **Come si collega il telefono alla v1?** Il pairing di Squadd passa da un QR `openmausbot://pair?...` (`packages/phone-protocol/src/pairing-link.ts:36-56`), un token bearer (`companion/src/proxy.ts:407`) e, fuori casa, un tunnel cifrato Noise NKpsk0 P-256 su yamux, diretto o via relay (`companion/src/e2e/noise.ts:7`, `companion/src/e2e/session.ts:1-2`). Hermex non ha uno scanner di QR (non trovato) né Noise o yamux. Proposta: v1 con QR, LAN, tailnet ed endpoint HTTPS ospitato (4-5 giorni); il tunnel E2E e il relay in un secondo passo (circa 10 giorni, rischio alto).
4. **Push e Live Activity su chi?** Hermex manda i token al relay hermex-push di Uzair (`HermesMobile/Push/PushRelayClient.swift:59`). Squadd ha già i suoi endpoint `/api/push/device` e `/api/push/activity` (`companion/src/routes.ts:221-226`) e un relay suo (`server/phone-push.ts:1-2`). Proposta: usare quelli di Squadd. Servono un bundle ID nostro, un team Apple e la chiave APNs sul relay di Squadd: è una decisione di account, non di codice.
5. **Android?** Un client Android di Hermex non esiste: il maintainer l'ha escluso (issue uzairansaruzi/hermex#1311). Ci sono port della community, ma parlano con Hermes, non con Squadd. Proposta: niente Android prima che la v1 iOS stia in piedi. Poi un'app Kotlin/Compose nativa con un core di protocollo Kotlin Multiplatform, sul modello di `unsupportedpastels/mercury`, costruita su `packages/phone-protocol`. Dettagli più sotto.

Somma della colonna Giorni: 142 giorni per tutte le 87 righe. La v1 proposta (decisioni 1-4, senza chiamata live, telefono come strumento, tunnel E2E, login cloud, app MCP, browser live, dati, computer use, inbox, team map, consumi, rigenera, condivisione con link e routine) vale 82,5 giorni; il resto, 59,5 giorni, viene dopo.

## Funzioni, una per riga

Colonne: **Chi** = solo Hermex (H), solo Squadd (S), entrambi (H+S). **Dove** = app iOS, companion (whitelist in `companion/src/routes.ts`), server Squadd. Giorni = lavoro di una persona, prova compresa. Rischio: B basso, M medio, A alto.

| Funzione | Chi | Hermex file:riga | Squadd file:riga | Cosa serve per averla su iPhone | Dove | Giorni | Rischio |
|---|---|---|---|---|---|---|---|
| Lista conversazioni | H+S | HermesMobile/Features/SessionList/HermesSessionListView.swift:35 | server/routes/tasks.ts:182; companion/src/routes.ts:124 | Lista di bot e thread da `GET /api/bots` e dalle task, nella vista sessioni che c'è già | app | 2 | B |
| Schermata chat e transcript | H+S | HermesMobile/Features/Chat/ChatView.swift:288 | server/routes/threads.ts:142; companion/src/routes.ts:177 | Adattare `ChatViewModel` ai messaggi di `/api/threads/:id/messages` | app | 3 | M |
| Invio messaggio | H+S | HermesMobile/Features/Chat/ChatViewModel.swift:3101 | server/routes/bot-messages.ts:193; companion/src/routes.ts:104 | `POST /api/bots/:id/messages` nel nuovo backend | app | 1 | B |
| Streaming della risposta | H+S | HermesMobile/Features/Chat/ChatStreamCoordinator.swift:148 | server/index.ts:14622; companion/src/routes.ts:85 | Decoder dei frame SSE di `/api/events` (`packages/phone-protocol/src/wire.ts:931-979`) al posto di quello webui | app | 4 | A |
| Riconnessione e reattach dello stream | H+S | HermesMobile/Features/Chat/ChatStreamCoordinator.swift:439 | server/index.ts:14622 (`Last-Event-ID`/`?since`) | Riusare backoff e reattach con `Last-Event-ID` | app | 2 | M |
| Stop del turno | H+S | HermesMobile/Features/Chat/ChatViewModel.swift:6767 | server/routes/bot-messages.ts:768; companion/src/routes.ts:108 | `POST /api/bots/:id/interrupt` | app | 0,5 | B |
| Steer di un messaggio in coda | H+S | HermesMobile/Features/Chat/ChatViewModel.swift:4270 | server/routes/bot-messages.ts:377; companion/src/routes.ts:107-109 | Coda di Squadd (steer, cancella) al posto di steer/btw di Hermes | app | 1,5 | M |
| Thread: crea, rinomina, cancella | H+S | HermesMobile/Features/SessionList/SessionListViewModel.swift:1256 | server/routes/tasks.ts:182; companion/src/routes.ts:124-127 | Collegare rinomina e cancella alle route delle task | app | 1 | B |
| Pin e archivio dei thread | H+S | HermesMobile/Features/SessionList/SessionListViewModel.swift:1169 | server/routes/tasks.ts:336, :341; companion/src/routes.ts:126 | `PATCH` della task con `pinned` e `archivedAt` | app | 0,5 | B |
| Cartelle / progetti | H+S | HermesMobile/Features/SessionList/SessionListViewModel.swift:1436 | server/routes/tasks.ts:121 (`projects/order`); companion/src/routes.ts:103 | Il companion apre solo `POST /api/sidebar-sections`: per creare e ordinare cartelle servono route in più | companion + app | 2 | M |
| Ricerca | H+S | HermesMobile/Features/SessionList/SessionListViewModel.swift:610 | server/routes/threads.ts:493; companion/src/routes.ts:189 | `GET /api/search` nel backend | app | 1 | B |
| Export della conversazione | H+S | HermesMobile/Features/SessionList/SessionListViewModel.swift:1361 | server/routes/threads.ts:544; companion/src/routes.ts:187 | `GET /api/threads/:id/export` | app | 0,5 | B |
| Modifica di un messaggio e versioni | H+S | HermesMobile/Features/Chat/ChatViewModel.swift:6273 | server/routes/bot-messages.ts:497, :549; companion/src/routes.ts:112, :119 | Edit più scelta del ramo attivo. Hermex non mostra versioni alternative (non trovata): serve un selettore di versione nuovo | app | 3 | M |
| Fork in un nuovo thread | H+S | HermesMobile/Features/Chat/ChatViewModel.swift:6071 | server/routes/tasks.ts:166; src/components/ForkPanel.tsx:10 | Il companion non apre `/tasks/:t/forks`: va aggiunto alla whitelist | companion + app | 1 | B |
| Undo dell'ultimo scambio | H+S | HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift:1061 | server/routes/undo.ts:13 | Il companion non apre `/api/threads/:id/undo`: va aggiunto | companion + app | 1 | B |
| Rigenera risposta | H | HermesMobile/Features/Chat/ChatViewModel.swift:6390 | non trovata | Esiste solo l'edit con nuovo ramo: si rigenera rimandando il messaggio come edit, oppure serve una route nuova | server + app | 2 | M |
| Rewind a un punto | H | HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift:1003 | non trovata | Senza equivalente: da nascondere nella v1 | app | 0 | B |
| Checkpoint dei file (rollback) | H | HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift:1093 | non trovata | Senza equivalente: da nascondere | app | 0 | B |
| Compattare il contesto | H+S | HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift:1127 | server/routes/bot-messages.ts:471; companion/src/routes.ts:120 | `POST /api/bots/:id/compact` | app | 0,5 | B |
| Stanze con più agenti | H+S | HermesMobile/Features/Bots/BotRoomView.swift:3 | server/routes/groups.ts:51; server/routes/channels.ts:353; companion/src/routes.ts:166-175 | Riusare `BotRoomView` sulle route `/api/groups`. Modifica e cancellazione della stanza non sono aperte dal companion | app (+ companion) | 4 | M |
| Lavoro delegato ai subagenti | H | HermesMobile/Features/Chat/HermesDelegatedWorkView.swift:119 | non trovata | Squadd non manda eventi di subagente sullo stream: da nascondere | app | 0 | B |
| Elenco degli agenti (bot) | H+S | HermesMobile/Features/Bots/BotsInboxView.swift:8 | server/routes/bots-create.ts:92; companion/src/routes.ts:94 | Inbox dei bot da `GET /api/bots` | app | 1,5 | B |
| Crea e modifica agente, avatar | H+S | HermesMobile/Features/Bots/BotCreateView.swift:7 | server/routes/bot-settings.ts:103; companion/src/routes.ts:95, :151, :154 | Riusare l'editor del profilo e la generazione dell'avatar | app | 2 | B |
| Menzioni @ di un agente | H+S | HermesMobile/Features/Bots/BotMentionAutocompleteView.swift:6 | server/routes/channels.ts:353 | Autocomplete sui membri della stanza | app | 1 | B |
| Approvazioni dei tool | H+S | HermesMobile/Features/Chat/ApprovalRequestInset.swift:37 | server/routes/bot-messages.ts:565; src/components/ApprovalCard.tsx:87; companion/src/routes.ts:106 | Card di approvazione sul frame dello stream, risposta con `POST /respond` | app | 2 | M |
| Sempre consentito | S | non trovata | server/routes/bot-settings.ts:207; companion/src/routes.ts:111 | Un bottone nella card di approvazione | app | 0,5 | B |
| Domande all'utente (opzioni) | H+S | HermesMobile/Features/Chat/ClarificationRequestCard.swift:202 | src/components/QuestionCard.tsx:44; server/routes/bot-messages.ts:641; companion/src/routes.ts:105, :188 | Adattare la card di clarify alle question card di Squadd | app | 2 | M |
| Card segreto, sign-in, connettore | H+S | HermesMobile/Features/Chat/HermesRequestCards.swift:14 | server/routes/secret-cards.ts:85; server/routes/sign-in-cards.ts:25; companion/src/routes.ts:115-118, :251-257 | Il segreto parte cifrato HPKE dal telefono (`packages/phone-protocol/src/phone-secret-envelope.ts:1-8`): HPKE in Swift con CryptoKit | app | 3 | M |
| Push ad app chiusa | H+S | HermesMobile/Push/PushRegistrar.swift:59 | server/routes/phone-push.ts:19; server/phone-push.ts:1; companion/src/routes.ts:221-223 | Registrare il token APNs su `/api/push/device` al posto del relay hermex-push; bundle ID e chiave APNs di Squadd | app + server | 3 | M |
| Estensione che decifra la notifica | H | HermesNotificationService/NotificationService.swift:7 | packages/phone-protocol/src/phone-push.ts:39 | Le push di Squadd non portano contenuto: l'estensione serve solo se si vuole il testo nella notifica | app | 1 | B |
| Tap sulla notifica che apre il thread | H+S | HermesMobile/Push/PushNotificationRouter.swift:7 | packages/phone-protocol/src/phone-push.ts:39 | Instradare i `kind` di Squadd (approval, question, sign-in, done) | app | 1 | B |
| Notifiche in-app | S | non trovata | server/routes/notifications.ts:52; packages/phone-protocol/src/wire.ts:945-946 | Elenco dai frame `notify`; `GET /api/notifications` non è aperto dal companion | companion + app | 2 | B |
| Inbox «Needs you» | S | non trovata | server/routes/inbox.ts:21; server/routes/today.ts:31 | Route da aprire nel companion e schermata nuova | companion + app | 3 | M |
| Live Activity e Dynamic Island | H+S | HermesMobile/LiveActivities/AgentLiveActivityManager.swift:182 | server/routes/phone-push.ts:49; companion/src/routes.ts:224-226 | Token della Live Activity su `/api/push/activity` | app | 2 | M |
| Widget (bot, limiti) | H | HermesLiveActivityWidget/BotWidget.swift:10 | non trovata | Il widget dei bot si riusa sui bot di Squadd; quello dei limiti dei provider va tolto | app | 1 | B |
| Allegati e foto | H+S | HermesMobile/Features/Chat/ChatAttachmentCoordinator.swift:28 | server/routes/threads.ts:345, :401; companion/src/routes.ts:193-200 | Upload su `/api/attachments` e `/api/files` | app | 1,5 | B |
| Fotocamera | H | HermesMobile/Features/Chat/CameraPickerView.swift:356 | companion/src/routes.ts:193 | Già pronta, usa lo stesso upload | app | 0 | B |
| Incolla immagini e testo lungo | H | HermesMobile/Features/Chat/ComposerChipTextView.swift:771 | companion/src/routes.ts:193 | Già pronto, usa lo stesso upload | app | 0 | B |
| Share extension | H | HermesShareExtension/ShareViewController.swift:4 | companion/src/routes.ts:193 | Cambiare app group e bundle ID; la consegna all'app (`HermesMobile/Features/Share/SharedDraftStore.swift:198`) resta | app | 1 | B |
| Condividere una conversazione con un link | S | non trovata | server/routes/conversation-share.ts:26 | Il companion non apre `/tasks/:t/share`: route più foglio di condivisione iOS | companion + app | 1,5 | B |
| Dettatura | H+S | HermesMobile/Features/Chat/ComposerVoiceInputController.swift:16 | src/components/Composer.tsx:195; server/routes/tts.ts:87 | Dettatura sul telefono con SFSpeech, già in Hermex. `/api/tts/transcribe` non è aperto dal companion | app | 1 | B |
| Nota vocale | H+S | HermesMobile/Features/Chat/ComposerVoiceNoteRecorder.swift:14 | src/components/VoiceNoteBubble.tsx:26; companion/src/routes.ts:195 | Upload mp3/wav più riproduzione con Range | app | 1 | B |
| Ascolta la risposta (TTS) | H+S | HermesMobile/Features/Chat/ChatViewModel.swift:6807 | server/routes/tts.ts:59; companion/src/routes.ts:203-205 | `/api/tts/prepare` e `/speak` al posto di `/api/tts` | app | 1 | B |
| Chiamata vocale live | S | non trovata | server/routes/live.ts:84; companion/src/routes.ts:209-212 | Nuovo: WebRTC sul telefono (framework WebRTC, dipendenza nuova). `/api/live/relay` (`server/routes/live.ts:111`) non è aperto e serve ai provider fish, gemini ed elevenlabs | app + companion | 10 | A |
| Slash command | H+S | HermesMobile/Features/Chat/SlashCommandAutocompleteView.swift:3 | src/components/SlashCommandMenu.tsx:9; shared/skill-command.ts:24 | Catalogo dei comandi di Squadd (`/goal`, `/learn`, `/setup` e le skill) nell'autocomplete | app | 1,5 | M |
| Scorciatoie da tastiera | H+S | HermesMobile/HermesMobileApp.swift:27 | src/components/KeyboardShortcutsModal.tsx:41 | Già pronte per iPad con tastiera | app | 0 | B |
| App Intents e Shortcuts | H | HermesMobile/AppIntents/HermexAppIntents.swift:59 | non trovata | Rinominare e puntare ai bot di Squadd | app | 1 | B |
| Deep link | H+S | HermesMobile/LiveActivities/HermesDeepLink.swift:3 | packages/phone-protocol/src/pairing-link.ts:1 | Schema `openmausbot://` per il pairing più uno per aprire i thread | app | 1 | B |
| Modello per agente | H+S | HermesMobile/Features/Shared/ModelPickerSheet.swift:10 | server/routes/bot-settings.ts:126; companion/src/routes.ts:153 | Picker sui modelli di `GET /api/instances` | app | 1,5 | B |
| Thinking e Fast | H | HermesMobile/Features/Chat/ThinkingControl.swift:90 | non trovata | Senza equivalente sul server: da nascondere | app | 0 | B |
| Provider ed engine | H+S | HermesMobile/Features/Settings/ProvidersView.swift:11 | server/routes/instances.ts:119; companion/src/routes.ts:86, :89 | Sola lettura più aggiornamento di Claude; account ed endpoint non aperti | app | 1,5 | B |
| Chiavi API | H+S | HermesMobile/Features/Settings/APIKeysView.swift:5 | server/routes/config.ts:129; companion/src/routes.ts:84 | Il companion apre solo la lettura dei «configurato sì/no» e nega la scrittura (`companion/src/routes.ts:278`): sul telefono solo lo stato | app | 0,5 | B |
| Connettori (app collegate) | H+S | HermesMobile/Features/Settings/ConnectedAppsView.swift:8 | server/index.ts:14887; companion/src/routes.ts:245-249 | Catalogo, collegati, authorize con `ASWebAuthenticationSession` | app | 2 | M |
| Server MCP | H+S | HermesMobile/Features/Settings/PluginsView.swift:7 | server/routes/mcp-servers.ts:81; companion/src/routes.ts:134 | Solo nomi e stato per agente; la gestione resta sul desktop | app | 1 | B |
| Skill | H+S | HermesMobile/Features/Skills/SkillsView.swift:4 | server/routes/bot-skills.ts:47; companion/src/routes.ts:137 | Sola lettura per agente | app | 1 | B |
| Memoria | H+S | HermesMobile/Features/Memory/MemoryView.swift:3 | server/routes/team-context.ts:20; companion/src/routes.ts:145-148 | Memoria del team (CRUD). Quella del singolo agente (`server/routes/bot-memory.ts:96`) non è aperta | app | 1,5 | B |
| Routine pianificate | H+S | HermesMobile/Features/Tasks/TasksView.swift:6 | server/index.ts:14510; companion/src/routes.ts:233-238 | Adattare la lista e l'editor dei cron alle routine di Squadd | app | 3 | M |
| Kanban | H | HermesMobile/Features/Kanban/KanbanLabView.swift:2486 | non trovata | Squadd non ha Kanban: da nascondere | app | 0 | B |
| Workspace e file | H | HermesMobile/Features/Workspace/FileBrowserView.swift:8 | server/routes/bot-config-files.ts:96 | Il companion non apre file né workspace: da nascondere nella v1 | app | 0 | B |
| Git (diff, commit) | H | HermesMobile/Features/Workspace/GitWorkspaceView.swift:6 | non trovata | Da nascondere | app | 0 | B |
| Insights e consumi | H+S | HermesMobile/Features/Insights/InsightsView.swift:7 | server/routes/usage.ts:88 | `/api/usage` non è aperto dal companion | companion + app | 2 | B |
| Dati (tabelle del bot) | S | non trovata | server/routes/table.ts; companion/src/routes.ts:140-142 | Vista tabelle nuova, sola lettura | app | 3 | M |
| App MCP dentro la chat | S | non trovata | server/routes/chat-apps.ts:40; companion/src/routes.ts:182-184 | WKWebView con il ponte `rpc` e `context`; Hermex ha già un WKWebView per i report HTML (`HermesMobile/Features/Chat/HTMLReportWebView.swift:7`) | app | 4 | A |
| Reazioni ai messaggi | S | non trovata | server/routes/reactions.ts:18; companion/src/routes.ts:186 | Voce nel menu del messaggio | app | 1 | B |
| Computer use: desktop cloud e VM | H+S | HermesMobile/Features/Screen/ScreenView.swift:7 | server/routes/computers.ts:248; companion/src/routes.ts:156-165; companion/src/viewer-relay.ts:27 | Hermex parla RFB su WebSocket (`HermesMobile/Networking/Screen/RFBClient.swift:30`); Squadd dà noVNC su `/vps-viewer/` WebSocket: va provato se `RFBClient` regge quel flusso | app | 3 | A |
| Browser live dell'agente | S | non trovata | server/routes/browser-viewers.ts:22; companion/src/routes.ts:160-161 | Vista nuova, con permesso per device | app | 3 | M |
| Telefono come strumento dell'agente | S | non trovata | server/routes/phones.ts:49; packages/phone-protocol/src/phone-apps.ts:5; companion/src/routes.ts:215-219 | Nuovo: job `device.job` per calendario, promemoria, contatti, posizione, casa e messaggi, con i permessi di iOS | app | 8 | A |
| Presenza attiva | S | non trovata | server/routes/presence.ts:27; companion/src/routes.ts:230 | Ping quando l'app è in primo piano | app | 0,5 | B |
| Team map e attività | S | non trovata | server/index.ts:14481, :14774; companion/src/routes.ts:90, :129-131 | Schermata panoramica nuova | app | 2 | B |
| Pairing con QR | S | non trovata | companion/src/control.ts:279; src/components/PhonePairingQr.tsx:12; packages/phone-protocol/src/pairing-link.ts:36-56 | Scanner con AVFoundation, lettura del link, `POST /api/pair` (`companion/src/proxy.ts:454`), token nel Keychain | app | 2 | M |
| Codice di pairing digitato | S | non trovata | packages/phone-protocol/src/pairing-code.ts:3-6 | Campo da 12 caratteri al posto del QR | app | 0,5 | B |
| Scelta della via (hosted, tailnet, LAN, Bonjour) | S | non trovata (Hermex usa un solo URL per server) | companion/src/endpoints.ts:63-72; companion/src/index.ts:75 | Provare gli endpoint in ordine; Bonjour `_openmausbot._tcp` con NWBrowser | app | 2 | M |
| Tunnel cifrato E2E e relay | S | non trovata | companion/src/e2e/noise.ts:7; companion/src/e2e/session.ts:1-2; relay/src/wire.ts:4 | Noise NKpsk0 P-256 AES-GCM in Swift con CryptoKit, più yamux e il relay `omb-relay.v1`; c'è un client di riferimento Node (`companion/src/e2e/phone.ts:1`) | app | 10 | A |
| Più computer collegati | H+S | HermesMobile/Auth/AuthManager.swift:293 | companion/src/devices.ts:343 | Ogni pairing diventa un server nel registro che c'è già | app | 1 | B |
| Login account e cloud Squadd | S | non trovata | electron/cloud-signin.mjs:14; server/routes/email-sign-in.ts:20 | Non serve per la v1 col companion; serve per i workspace ospitati, che rifiutano il pairing (`server/index.ts:12550`) | app + server | 5 | A |
| Piani a pagamento | S | non trovata | electron/cloud-buy.mjs:18; server/routes/usage-caps.ts:28 | Fuori dalla v1: un acquisto su iOS passa dalle regole dell'App Store | app | 0 | A |
| Blocco con Face ID | H | HermesMobile/Auth/AppLock.swift:47 | non trovata | Già pronto | app | 0 | B |
| Cache offline | H | HermesMobile/Persistence/CachedSession.swift:12 | src/components/HomeScreen.tsx:30 | Squadd mostra solo «computer offline». Riusare SwiftData per thread e messaggi di Squadd | app | 3 | M |
| Bozze non inviate | H | HermesMobile/Persistence/ChatDraftStore.swift:638 | non trovata | Già pronto | app | 0 | B |
| Rendering markdown, codice, diff | H+S | HermesMobile/Features/Chat/MarkdownRenderer.swift:8 | src/components/ChatMarkdown.tsx:3 | Già pronto in Hermex | app | 0 | B |
| Mermaid, matematica, HTML | H | HermesMobile/Features/Chat/HTMLReport.swift:86; HermesMobile/Features/Chat/DisplayMathView.swift:14 | non trovata | Già pronto | app | 0 | B |
| Onboarding | H+S | HermesMobile/Features/Onboarding/OnboardingView.swift:7 | src/components/PhoneSetupFlow.tsx:164 | Riscrivere i passi: installa Squadd sul computer, scansiona il QR | app | 2 | B |
| Header personalizzati | H | HermesMobile/Features/Shared/CustomHeadersEditor.swift:8 | non trovata | Inutile col bearer di Squadd: da nascondere | app | 0 | B |
| Aggiornamento del server dal telefono | H | HermesMobile/Features/Settings/HermesUpdateMachine.swift:17 | companion/src/routes.ts:89 | Solo l'aggiornamento di Claude è aperto | app | 0,5 | B |
| Usage report a hermex-stats | H | HermesMobile/Config/UsageReports.swift:285 | non trovata | Va spento o puntato a un collector nostro: oggi manda i dati a Uzair | app | 0,5 | M |
| MoveToHermes e import CLI | H | HermesMobile/Features/MoveToHermes/MoveToHermesView.swift:10; HermesMobile/Features/Settings/CliSessionsSyncModel.swift:19 | non trovata | Da togliere | app | 0 | B |
| Identità dell'app (nome, bundle ID, team, icona) | H | HermesMobile/Features/Settings/AppIconSettingsSection.swift:4 | non trovata | Cambiare i file `Config/*.xcconfig`, gli app group e gli ID di tutte le estensioni | app | 1 | M |

## Protocollo: ogni chiamata di Hermex contro il companion

Per ogni chiamata di rete di `HermesMobile/Networking`, la route del companion che fa la stessa cosa, o «manca». `+X` sta per `HermesMobile/Networking/APIClient+X.swift`. Le route del companion sono in `companion/src/routes.ts` e si scrivono `routes.ts:N`.

### Server webui (REST e SSE)

| Chiamata di Hermex | Hermex file:riga | Companion | Companion file:riga |
|---|---|---|---|
| GET /health | HermesMobile/Networking/APIClient.swift:56 | GET /api/health | companion/src/proxy.ts:523 |
| GET /api/auth/status | HermesMobile/Networking/APIClient.swift:60 | manca: il pairing sostituisce il login | companion/src/proxy.ts:454 |
| POST /api/auth/login | HermesMobile/Networking/APIClient.swift:65 | POST /api/pair (token bearer) | companion/src/proxy.ts:454 |
| POST /api/auth/logout | HermesMobile/Networking/APIClient.swift:72 | manca: la revoca la fa il desktop | companion/src/control.ts:365 |
| GET /api/sessions | HermesMobile/Networking/APIClient+Sessions.swift:17 | GET /api/bots | routes.ts:94 |
| GET /api/sessions/search | HermesMobile/Networking/APIClient+Sessions.swift:24 | GET /api/search | routes.ts:189 |
| GET /api/session (messaggi) | HermesMobile/Networking/APIClient+Sessions.swift:37 | GET /api/threads/:id/messages | routes.ts:177 |
| GET /api/session/status | HermesMobile/Networking/APIClient+Sessions.swift:49 | GET /api/bots/:id/activity | routes.ts:131 |
| POST /api/session/import_cli | HermesMobile/Networking/APIClient+Sessions.swift:56 | manca | — |
| POST /api/session/new | HermesMobile/Networking/APIClient+Sessions.swift:72 | POST /api/bots/:id/tasks | routes.ts:124 |
| POST /api/session/rename | HermesMobile/Networking/APIClient+Sessions.swift:86 | PATCH /api/bots/:id/tasks/:t | routes.ts:126 |
| POST /api/session/delete | HermesMobile/Networking/APIClient+Sessions.swift:94 | DELETE /api/bots/:id/tasks/:t | routes.ts:127 |
| POST /api/session/pin | HermesMobile/Networking/APIClient+Sessions.swift:102 | PATCH task con `pinned` | routes.ts:126 |
| POST /api/session/archive | HermesMobile/Networking/APIClient+Sessions.swift:110 | PATCH task con `archivedAt` | routes.ts:126 |
| POST /api/session/branch | HermesMobile/Networking/APIClient+Sessions.swift:118 | manca (`/tasks/:t/forks` non è aperta) | — |
| POST /api/session/duplicate | HermesMobile/Networking/APIClient+Sessions.swift:129 | manca | — |
| POST /api/session/compress | HermesMobile/Networking/APIClient+Sessions.swift:137 | POST /api/bots/:id/compact | routes.ts:120 |
| POST /api/session/clear | HermesMobile/Networking/APIClient+Sessions.swift:148 | manca | — |
| POST /api/session/undo | HermesMobile/Networking/APIClient+Sessions.swift:156 | manca (`/api/threads/:id/undo` non è aperta) | — |
| POST /api/session/retry | HermesMobile/Networking/APIClient+Sessions.swift:164 | manca | — |
| POST /api/session/truncate | HermesMobile/Networking/APIClient+Sessions.swift:172 | POST /api/bots/:id/messages/:m/edit | routes.ts:112 |
| POST /api/session/update | HermesMobile/Networking/APIClient+Sessions.swift:185 | PATCH /api/bots/:id/model | routes.ts:153 |
| POST /api/session/move | HermesMobile/Networking/APIClient+Sessions.swift:198 | PATCH task con `projectId` | routes.ts:126 |
| GET e POST /api/session/yolo | HermesMobile/Networking/APIClient+Sessions.swift:205 | PATCH task con `approvalMode` | routes.ts:126; server/routes/tasks.ts:268 |
| GET /api/session/export | HermesMobile/Networking/APIClient+SessionExport.swift:39 | GET /api/threads/:id/export | routes.ts:187 |
| GET /api/projects | HermesMobile/Networking/APIClient+Projects.swift:5 | manca: le cartelle arrivano dentro `GET /api/bots` | — |
| POST /api/projects/create | HermesMobile/Networking/APIClient+Projects.swift:10 | POST /api/sidebar-sections | routes.ts:103 |
| POST /api/projects/rename | HermesMobile/Networking/APIClient+Projects.swift:18 | manca | — |
| POST /api/projects/delete | HermesMobile/Networking/APIClient+Projects.swift:26 | manca | — |
| POST /api/chat/start | HermesMobile/Networking/APIClient+Chat.swift:15 | POST /api/bots/:id/messages | routes.ts:104 |
| SSE /api/chat/stream | HermesMobile/Networking/APIClient+Chat.swift:31 | SSE GET /api/events | routes.ts:85 |
| GET /api/chat/cancel | HermesMobile/Networking/APIClient+Chat.swift:35 | POST /api/bots/:id/interrupt | routes.ts:108 |
| GET /api/chat/stream/status | HermesMobile/Networking/APIClient+Chat.swift:44 | GET /api/bots/:id/activity | routes.ts:131 |
| POST /api/chat/steer | HermesMobile/Networking/APIClient+Chat.swift:104 | POST /api/bots/:id/queue/:q/steer | routes.ts:109 |
| POST /api/goal | HermesMobile/Networking/APIClient+Chat.swift:135 | `/goal` come testo del messaggio | routes.ts:104 |
| GET /api/approval/pending | HermesMobile/Networking/APIClient+Chat.swift:51 | dentro `GET /api/threads/:id/messages` e i frame `message` | routes.ts:177 |
| SSE /api/approval/stream | HermesMobile/Networking/APIClient+Chat.swift:55 | SSE GET /api/events | routes.ts:85 |
| POST /api/approval/respond | HermesMobile/Networking/APIClient+Chat.swift:64 | POST /api/bots/:id/respond | routes.ts:106 |
| GET /api/clarify/pending | HermesMobile/Networking/APIClient+Chat.swift:75 | dentro i messaggi del thread | routes.ts:177 |
| SSE /api/clarify/stream | HermesMobile/Networking/APIClient+Chat.swift:79 | SSE GET /api/events | routes.ts:85 |
| POST /api/clarify/respond | HermesMobile/Networking/APIClient+Chat.swift:88 | POST /api/threads/:id/respond | routes.ts:188 |
| POST /api/btw | HermesMobile/Networking/APIClient+Chat.swift:150 | manca | — |
| POST /api/background | HermesMobile/Networking/APIClient+Chat.swift:158 | manca | — |
| GET /api/background/status | HermesMobile/Networking/APIClient+Chat.swift:165 | manca | — |
| GET /api/workspaces e /suggest | HermesMobile/Networking/APIClient+Workspace.swift:99, :103 | manca | — |
| POST /api/workspaces/add, /remove, /rename, /reorder | HermesMobile/Networking/APIClient+Workspace.swift:108 | manca | — |
| GET /api/list | HermesMobile/Networking/APIClient+Workspace.swift:140 | manca | — |
| GET /api/file | HermesMobile/Networking/APIClient+Workspace.swift:146 | manca | — |
| GET /api/file/raw | HermesMobile/Networking/APIClient+Workspace.swift:157 | GET file del messaggio (`MESSAGE_FILE_ROUTE`) | routes.ts:185 |
| GET /api/media | HermesMobile/Networking/APIClient+Workspace.swift:163 | GET /api/threads/:id/messages/:m/image, GET /api/attachments/... | routes.ts:178, :195 |
| GET /api/git-info, /git/status, /git/branches, /git/diff | HermesMobile/Networking/APIClient+Git.swift:214 | manca | — |
| POST /api/git/fetch, /pull, /push | HermesMobile/Networking/APIClient+Git.swift:233 | manca | — |
| POST /api/git/checkout, /stash-checkout | HermesMobile/Networking/APIClient+Git.swift:246 | manca | — |
| POST /api/git/stage, /unstage, /discard | HermesMobile/Networking/APIClient+Git.swift:263 | manca | — |
| POST /api/git/commit, /commit-selected | HermesMobile/Networking/APIClient+Git.swift:279 | manca | — |
| POST /api/git/commit-message, /commit-message-selected | HermesMobile/Networking/APIClient+Git.swift:294 | manca | — |
| GET /api/models, /api/models/live | HermesMobile/Networking/APIClient+ServerPanels.swift:5 | GET /api/instances | routes.ts:86 |
| GET /api/commands | HermesMobile/Networking/APIClient+ServerPanels.swift:16 | manca (gli slash sono nel client desktop, `src/components/SlashCommandMenu.tsx:9`) | — |
| POST /api/default-model | HermesMobile/Networking/APIClient+ServerPanels.swift:26 | PATCH /api/bots/:id/model | routes.ts:153 |
| GET e POST /api/reasoning | HermesMobile/Networking/APIClient+ServerPanels.swift:37 | manca | — |
| GET /api/personalities, POST /api/personality/set | HermesMobile/Networking/APIClient+ServerPanels.swift:60 | PATCH /api/bots/:id/profile | routes.ts:151 |
| GET /api/profiles | HermesMobile/Networking/APIClient+ServerPanels.swift:72 | GET /api/bots | routes.ts:94 |
| POST /api/profile/switch, /api/profile/create | HermesMobile/Networking/APIClient+ServerPanels.swift:77 | POST /api/bots | routes.ts:95 |
| GET /api/providers | HermesMobile/Networking/APIClient+ServerPanels.swift:110 | GET /api/instances | routes.ts:86 |
| GET /api/provider/quota | HermesMobile/Networking/APIClient+ProviderQuota.swift:200 | manca | — |
| GET e POST /api/settings | HermesMobile/Networking/APIClient+ServerPanels.swift:114 | solo GET /api/config | routes.ts:84 |
| GET e POST /api/updates/check, POST /api/updates/apply | HermesMobile/Networking/APIClient+ServerPanels.swift:143 | POST /api/instances/:id/claude-update | routes.ts:89 |
| GET /api/insights | HermesMobile/Networking/APIClient+ServerPanels.swift:171 | manca (`/api/usage` non è aperta) | — |
| GET /api/crons | HermesMobile/Networking/APIClient+Cron.swift:148 | GET /api/routines | routes.ts:233 |
| POST /api/crons/create | HermesMobile/Networking/APIClient+Cron.swift:163 | POST /api/routines | routes.ts:234 |
| POST /api/crons/update | HermesMobile/Networking/APIClient+Cron.swift:192 | PATCH /api/routines/:id | routes.ts:235 |
| POST /api/crons/delete | HermesMobile/Networking/APIClient+Cron.swift:221 | DELETE /api/routines/:id | routes.ts:236 |
| POST /api/crons/run | HermesMobile/Networking/APIClient+Cron.swift:229 | POST /api/routines/:id/run | routes.ts:237 |
| POST /api/crons/pause, /resume | HermesMobile/Networking/APIClient+Cron.swift:237 | PATCH /api/routines/:id | routes.ts:235 |
| GET /api/crons/run, /history, /status, /output | HermesMobile/Networking/APIClient+Cron.swift:252 | manca (solo cancel e seen di un run) | routes.ts:238 |
| GET /api/crons/delivery-options, /recent | HermesMobile/Networking/APIClient+Cron.swift:210 | manca | — |
| Kanban (config, boards, board, stats, assignees, events, tasks, log, comments, links, bulk, dispatch, block, unblock) | HermesMobile/Networking/APIClient+Kanban.swift:138 | manca | — |
| SSE /api/kanban/events/stream | HermesMobile/Networking/KanbanEventStreamClient.swift:111 | manca | — |
| GET /api/memory, POST /api/memory/write | HermesMobile/Networking/APIClient+Memory.swift:29 | GET, POST, PATCH, DELETE /api/team-memory | routes.ts:145-148 |
| GET /api/skills, /api/skills/content | HermesMobile/Networking/APIClient+Skills.swift:27 | GET /api/bots/:id/skills | routes.ts:137 |
| POST /api/skills/toggle | HermesMobile/Networking/APIClient+Skills.swift:36 | manca | — |
| POST /api/upload | HermesMobile/Networking/APIClient+Upload.swift:12 | POST /api/attachments, POST /api/files | routes.ts:193, :200 |
| POST /api/transcribe | HermesMobile/Networking/APIClient+Transcribe.swift:31 | manca (`/api/tts/transcribe` non è aperta) | — |
| POST /api/tts | HermesMobile/Networking/APIClient+TTS.swift:36 | POST /api/tts/prepare, /speak | routes.ts:204-205 |
| Eventi SSE token, reasoning, tool, done, approval, clarify… | HermesMobile/Networking/SSEClient.swift:238-305 | frame `message`, `message.patch`, `thread`, `notify`… | packages/phone-protocol/src/wire.ts:931-979 |

### Host Hermes (REST)

| Chiamata di Hermex | Hermex file:riga | Companion | Companion file:riga |
|---|---|---|---|
| GET api/status, api/health | HermesMobile/Networking/Hermes/HermesREST.swift:414, :416 | GET /api/health | companion/src/proxy.ts:523 |
| POST auth/password-login | HermesMobile/Networking/Hermes/HermesREST.swift:435 | POST /api/pair | companion/src/proxy.ts:454 |
| POST auth/native/refresh, /token; GET auth/native/authorize | HermesMobile/Networking/Hermes/HermesREST.swift:439, :443 | manca: il token del device non scade | companion/src/devices.ts:343 |
| GET api/auth/me, api/profiles/active | HermesMobile/Networking/Hermes/HermesREST.swift:446, :447 | manca | — |
| POST api/auth/ws-ticket, api/webapp/socket-ticket | HermesMobile/Networking/Hermes/HermesREST.swift:448, :450 | manca: lo stream usa lo stesso bearer | companion/src/proxy.ts:407 |
| GET api/gateway/migrate/plan, POST api/gateway/migrate | HermesMobile/Networking/Hermes/HermesREST.swift:417 | manca | — |
| api/hermes/update (check, update, status, receipt) | HermesMobile/Networking/Hermes/HermesREST.swift:420 | POST /api/instances/:id/claude-update | routes.ts:89 |
| DELETE api/profiles/{name} | HermesMobile/Networking/Hermes/HermesREST.swift:456 | DELETE /api/bots/:id | routes.ts:99 |
| POST api/chat/image-upload | HermesMobile/Networking/Hermes/HermesREST.swift:460 | POST /api/attachments | routes.ts:193 |
| POST api/audio/transcribe | HermesMobile/Networking/Hermes/HermesREST.swift:466 | manca | — |
| GET api/fs/download | HermesMobile/Networking/Hermes/HermesREST.swift:471 | GET file del messaggio | routes.ts:185 |
| GET, PUT, DELETE api/env | HermesMobile/Networking/Hermes/HermesREST.swift:481 | solo GET /api/config; la scrittura è negata | routes.ts:84, :278 |
| api/dashboard/agent-plugins (install, remove, toggle) | HermesMobile/Networking/Hermes/HermesREST.swift:491 | manca | — |
| api/plugins/hermex-screen (capabilities, status, observe, lease) | HermesMobile/Networking/Hermes/HermesREST.swift:496 | join e control del desktop, screenshot e join della VM | routes.ts:156-165 |
| POST api/gateway/restart | HermesMobile/Networking/Hermes/HermesREST.swift:509 | manca | — |
| GET api/messaging/platforms | HermesMobile/Networking/Hermes/HermesREST.swift:510 | GET /api/connectors | routes.ts:247 |
| GET api/memory | HermesMobile/Networking/Hermes/HermesREST.swift:511 | GET /api/team-memory | routes.ts:145 |
| GET api/dashboard/plugins/catalog, /hub | HermesMobile/Networking/Hermes/HermesREST.swift:512 | GET /api/connectors/catalog | routes.ts:245 |
| api/plugins/hermex-push (pairing, capabilities) | HermesMobile/Networking/Hermes/HermesREST.swift:513 | PUT, GET, DELETE /api/push/device | routes.ts:221-223 |
| GET api/plugins/hermex-push/provider-quota | HermesMobile/Networking/Hermes/HermesREST.swift:516 | manca | — |
| POST api/plugins/hermex-push/restart | HermesMobile/Networking/Hermes/HermesREST.swift:522 | manca | — |
| POST api/plugins/hermex-push/git (fetch, pull, branch) | HermesMobile/Networking/Hermes/HermesREST.swift:702 | manca | — |
| GET api/sessions/{key}/messages | HermesMobile/Networking/Hermes/HermesREST.swift:526 | GET /api/threads/:id/messages | routes.ts:177 |
| GET api/sessions | HermesMobile/Networking/Hermes/HermesREST.swift:543 | GET /api/bots | routes.ts:94 |
| PATCH api/sessions/{key} | HermesMobile/Networking/Hermes/HermesREST.swift:571 | PATCH /api/bots/:id/tasks/:t; POST /api/bots/:id/read | routes.ts:126, :110 |
| GET api/sessions/{key}/mutation-snapshot | HermesMobile/Networking/Hermes/HermesREST.swift:575 | manca | — |
| GET api/sessions/{key}/export | HermesMobile/Networking/Hermes/HermesREST.swift:578 | GET /api/threads/:id/export | routes.ts:187 |
| POST api/sessions/import | HermesMobile/Networking/Hermes/HermesREST.swift:584 | manca | — |
| GET api/sessions/search | HermesMobile/Networking/Hermes/HermesREST.swift:590 | GET /api/search | routes.ts:189 |
| GET e POST api/cron/jobs | HermesMobile/Networking/Hermes/HermesREST.swift:603 | GET e POST /api/routines | routes.ts:233-234 |
| PUT e DELETE api/cron/jobs/{id} | HermesMobile/Networking/Hermes/HermesREST.swift:607 | PATCH e DELETE /api/routines/:id | routes.ts:235-236 |
| POST api/cron/jobs/{id}/trigger, /pause, /resume | HermesMobile/Networking/Hermes/HermesREST.swift:609 | POST /api/routines/:id/run; PATCH | routes.ts:237, :235 |
| GET api/cron/jobs/{id}/runs, api/cron/delivery-targets | HermesMobile/Networking/Hermes/HermesREST.swift:616 | manca | — |
| GET api/skills, api/skills/content | HermesMobile/Networking/Hermes/HermesREST.swift:623 | GET /api/bots/:id/skills | routes.ts:137 |
| PUT api/skills/toggle | HermesMobile/Networking/Hermes/HermesREST.swift:627 | manca | — |
| GET api/fs/list, api/fs/read-text, api/fs/git-root | HermesMobile/Networking/Hermes/HermesREST.swift:635 | manca | — |
| api/git/... (status, review/list, diff, file-diff, stage, unstage, revert, commit, push, rev-parse, commit-context, ship-info, branches, branch/switch) | HermesMobile/Networking/Hermes/HermesREST.swift:653 | manca | — |
| GET api/files/read, POST api/files/upload | HermesMobile/Networking/Hermes/HermesREST.swift:712 | POST /api/files | routes.ts:200 |
| GET e PUT api/config | HermesMobile/Networking/Hermes/HermesREST.swift:720 | solo GET /api/config | routes.ts:84 |
| GET e PUT api/profiles/{name}/soul | HermesMobile/Networking/Hermes/HermesREST.swift:728 | PATCH /api/bots/:id/profile | routes.ts:151 |
| POST api/audio/speak | HermesMobile/Networking/Hermes/HermesREST.swift:734 | POST /api/tts/speak | routes.ts:205 |
| GET api/analytics/usage, /models | HermesMobile/Networking/Hermes/HermesREST.swift:735 | manca | — |
| api/plugins/kanban/... | HermesMobile/Networking/Hermes/HermesREST.swift:737 | manca | — |
| WebSocket api/ws (gateway JSON-RPC) | HermesMobile/Networking/Hermes/HermesREST.swift:829 | SSE GET /api/events più le POST REST | routes.ts:85 |
| WebSocket api/plugins/kanban/events | HermesMobile/Networking/Hermes/HermesREST.swift:846 | manca | — |
| WebSocket api/display/ws (RFB) | HermesMobile/Networking/Hermes/HermesREST.swift:864 | WebSocket /vps-viewer/... (noVNC) | companion/src/viewer-relay.ts:27 |

### Host Hermes (metodi JSON-RPC del gateway)

| Metodi di Hermex | Hermex file:riga | Companion | Companion file:riga |
|---|---|---|---|
| profiles.list, .describe, .get_asset, .set_asset, .configure, .create | HermesMobile/Networking/Hermes/HermesCall.swift:536-541 | GET, POST, PATCH /api/bots; profile; avatar | routes.ts:94-95, :151, :154 |
| plugins.manage | HermesMobile/Networking/Hermes/HermesCall.swift:542 | manca | — |
| connectors.catalog, .list, .connect, .accounts, .accounts.remove | HermesMobile/Networking/Hermes/HermesCall.swift:543-549 | /api/connectors (catalog, connected, authorize, accounts) | routes.ts:245-249 |
| connectors.operation.wake, connection.respond | HermesMobile/Networking/Hermes/HermesCall.swift:546, :547, :593 | connector-cards authorize, resume, dismiss | routes.ts:252 |
| session.list, .most_recent, .active_list | HermesMobile/Networking/Hermes/HermesCall.swift:550, :565, :567 | GET /api/bots | routes.ts:94 |
| session.create, .title, .close, .delete | HermesMobile/Networking/Hermes/HermesCall.swift:551-555 | /api/bots/:id/tasks (POST, PATCH, DELETE) | routes.ts:124-127 |
| session.branch | HermesMobile/Networking/Hermes/HermesCall.swift:556 | manca (fork non aperto) | — |
| session.workspace.move, .cwd.set | HermesMobile/Networking/Hermes/HermesCall.swift:557, :596 | manca | — |
| session.resume, .events.since, .detach | HermesMobile/Networking/Hermes/HermesCall.swift:562-564 | SSE /api/events con `Last-Event-ID` | routes.ts:85 |
| session.steer, .redirect | HermesMobile/Networking/Hermes/HermesCall.swift:575-576 | POST /api/bots/:id/queue/:q/steer | routes.ts:109 |
| session.interrupt | HermesMobile/Networking/Hermes/HermesCall.swift:577 | POST /api/bots/:id/interrupt | routes.ts:108 |
| session.mutate, .undo | HermesMobile/Networking/Hermes/HermesCall.swift:581-582 | edit e active-branch; undo manca | routes.ts:112, :119 |
| session.compress | HermesMobile/Networking/Hermes/HermesCall.swift:583 | POST /api/bots/:id/compact | routes.ts:120 |
| session.control.read, .control | HermesMobile/Networking/Hermes/HermesCall.swift:597-598 | manca | — |
| projects.tree, .create, .update, .delete | HermesMobile/Networking/Hermes/HermesCall.swift:558-561 | solo POST /api/sidebar-sections | routes.ts:103 |
| prompt.submit | HermesMobile/Networking/Hermes/HermesCall.swift:574 | POST /api/bots/:id/messages | routes.ts:104 |
| prompt.cancel, .resolve_unknown | HermesMobile/Networking/Hermes/HermesCall.swift:578-579 | POST /api/bots/:id/interrupt; DELETE queue | routes.ts:107-108 |
| prompt.btw, prompt.background | HermesMobile/Networking/Hermes/HermesCall.swift:588-589 | manca | — |
| approval.pending, approval.respond | HermesMobile/Networking/Hermes/HermesCall.swift:566, :590 | POST /api/bots/:id/respond | routes.ts:106 |
| clarify.respond, clarify.lock, request.answer | HermesMobile/Networking/Hermes/HermesCall.swift:580, :591, :592 | POST /api/threads/:id/respond; PATCH cards | routes.ts:188, :105 |
| rollback.list, .diff, .restore | HermesMobile/Networking/Hermes/HermesCall.swift:584-586 | manca | — |
| file.attach | HermesMobile/Networking/Hermes/HermesCall.swift:587 | POST /api/attachments | routes.ts:193 |
| model.options, config.set | HermesMobile/Networking/Hermes/HermesCall.swift:594-595 | GET /api/instances; PATCH /api/bots/:id/model | routes.ts:86, :153 |
| commands.catalog, command.dispatch, complete.slash, slash.exec | HermesMobile/Networking/Hermes/HermesCall.swift:599-603 | manca; lo slash va come testo | routes.ts:104 |
| complete.path | HermesMobile/Networking/Hermes/HermesCall.swift:601 | manca | — |
| insights.get | HermesMobile/Networking/Hermes/HermesCall.swift:604 | manca | — |
| llm.oneshot | HermesMobile/Networking/Hermes/HermesCall.swift:605 | manca | — |
| client.capabilities | HermesMobile/Networking/Hermes/HermesCall.swift:622 | frame `hello` dello stream | packages/phone-protocol/src/wire.ts:931 |
| display.status, .observe, .lease.acquire, .lease.release, .start, .stop | HermesMobile/Networking/Hermes/HermesCall.swift:568-573 | join e control del desktop, permesso per device | routes.ts:156-158; companion/src/proxy.ts:438 |
| subagent.list, .roster, .tail, .interrupt | HermesMobile/Networking/Hermes/HermesCall.swift:606-609 | manca | — |
| groups.capabilities, .list, .state, .log | HermesMobile/Networking/Hermes/HermesCall.swift:610-613 | frame `group` dello stream; GET messaggi del thread | packages/phone-protocol/src/wire.ts:931; routes.ts:177 |
| groups.send, .stop | HermesMobile/Networking/Hermes/HermesCall.swift:614-615 | POST /api/groups/:id/messages, /interrupt | routes.ts:167-168 |
| groups.create | HermesMobile/Networking/Hermes/HermesCall.swift:619 | POST /api/groups | routes.ts:166 |
| groups.approve, .retry, .discard | HermesMobile/Networking/Hermes/HermesCall.swift:616-618 | steer e DELETE della coda di gruppo | routes.ts:169-170 |
| groups.rename, .disband | HermesMobile/Networking/Hermes/HermesCall.swift:620-621 | manca | — |

### Fuori dal server dell'utente

| Chiamata di Hermex | Hermex file:riga | Companion | Companion file:riga |
|---|---|---|---|
| POST e DELETE {relay}/installs/{key}/devices | HermesMobile/Push/PushRelayClient.swift:59, :73 | PUT e DELETE /api/push/device | routes.ts:221, :223 |
| PUT e DELETE …/activities | HermesMobile/Push/PushRelayClient.swift:79, :87 | PUT e DELETE /api/push/activity | routes.ts:224, :226 |
| POST …/notify (prova) | HermesMobile/Push/PushRelayClient.swift:101 | manca | — |
| POST hermex-stats /v1/report | HermesMobile/Config/UsageReports.swift:287 | manca (da spegnere) | — |

Conteggio: 170 righe di chiamate qui sopra; 103 hanno una route equivalente nel companion e 67 dicono «manca». Mancano soprattutto workspace, git, kanban, consumi, plugin e la dettatura sul server.

### Autenticazione, a confronto

| Cosa | Hermex file:riga | Squadd file:riga |
|---|---|---|
| Credenziale | cookie webui `HermesMobile/Networking/APIClient.swift:63`; bearer OAuth PKCE di Hermes `HermesMobile/Networking/Hermes/HermesConnection.swift:706` | token del device `omb_…` da `POST /api/pair`, `companion/src/devices.ts:343` |
| Stream | SSE con cookie `HermesMobile/Networking/SSEClient.swift:59`; WebSocket con ticket `HermesMobile/Networking/Hermes/HermesREST.swift:836` | SSE con bearer, `companion/src/proxy.ts:407`, `:569` |
| Fuori casa | tunnel dell'utente (Tailscale, Cloudflare), nessuna cifratura dell'app | endpoint HTTPS ospitato `companion/src/endpoints.ts:20` o Noise più relay `companion/src/e2e/noise.ts:7` |
| Browser rifiutati | — | header Origin → 403, `companion/src/proxy.ts:403` |

## Android

Domanda: esiste già qualcosa, e quanto si può condividere?

- **Hermex:** nessuna versione Android. Il maintainer l'ha esclusa nella issue uzairansaruzi/hermex#1311, chiusa come non pianificata, e nella #79 rimanda ai port della community.
- **Squadd:** nessun client telefono nel codice di openmausbot: niente `.swift` dell'app, niente `.kt`, niente `.xcodeproj`. Il contratto sta in `packages/phone-protocol` ed è TypeScript. Il push prevede già token FCM (`server/phone-push.ts:12-13`).

Repo controllati con `gh repo view` il 2026-11-19:

| Repo | Licenza | Ultimo push | Cos'è | Per noi |
|---|---|---|---|---|
| unsupportedpastels/mercury | MIT | 2026-11-14 | App Android e iOS per Hermes, UI nativa (Compose e SwiftUI) su un core Kotlin Multiplatform (`shared/mercury-core`), relay cifrato Noise XK | Il modello da seguire: dimostra un core KMP sotto due UI native |
| ComputerByte/hermex-android | MIT (file LICENSE; GitHub non rileva lo SPDX) | 2026-07-20 | Port nativo Kotlin/Compose di Hermex verso hermes-webui, con `API_CONTRACT.md` | Riferimento per le schermate Compose; parla webui |
| hermes-webui/hermes-android | MIT | 2026-11-15 | Guscio nativo attorno a un WebView della UI web di hermes-webui | Non adatto: Squadd non ha una UI web per il telefono |

`Hungbocluaqua/hermex-android-port-hermes`, nonostante il nome, contiene `HermesMobile.xcodeproj` ed è codice Swift per iOS: non è Android. Tutti e tre i repo utili parlano Hermes o webui, non Squadd: si riusano idee e schermate, non il protocollo.

Le strade:

| Strada | Cosa si condivide con iOS | Pro | Contro |
|---|---|---|---|
| App Kotlin/Compose separata | il contratto `packages/phone-protocol` letto a mano | la più semplice da partire | il protocollo si scrive due volte (Swift e Kotlin) e due volte il Noise |
| Core KMP + UI native (Mercury) | rete, decodifica dei frame, Noise, yamux, pairing | Noise e yamux, la parte più rischiosa, si scrivono e si provano una volta | iOS ha già il suo strato di rete in Swift: o lo si rifà sopra KMP, o il core KMP serve solo ad Android |
| Skip (Swift → Kotlin/Compose, Apache-2.0) | quasi tutto il codice | un solo codice | non provato su un'app di queste dimensioni, con estensioni e Live Activity; rischio alto |
| React Native o PWA | — | — | si butta via il lavoro SwiftUI, e background e notifiche peggiorano |

**Raccomandazione:** prima la v1 iOS. Poi Android come app Kotlin/Compose nativa, con un core KMP solo per protocollo, Noise e yamux, sul modello di Mercury. Se il tunnel E2E si fa nella v1 iOS, conviene scriverlo subito in KMP e chiamarlo da Swift, così Android lo eredita. Stima Android dopo iOS: 25-35 giorni.

## Licenze

- Hermex è MIT (`LICENSE`, «Copyright (c) 2026 Uzair Ansar»). Il file resta e l'attribuzione va mantenuta anche nell'app (`HermesMobile/Resources/ThirdPartyNotices/`).
- Dipendenze con licenza diversa da MIT, nessuna incompatibile con un'app chiusa o aperta: LDSwiftEventSource (Apache-2.0, chiede di conservare la NOTICE), swift-cmark (BSD), font DM Sans e Lora (SIL OFL), Lucide (ISC). Highlightr include highlight.js (BSD-3): la sua licenza non è nelle notice, da aggiungere.
- Mercury, hermex-android e hermes-android sono MIT: si può copiare codice con attribuzione.

## CI

`pr-ci.yml` gira sulle PR verso `main` e `dev` e sui push su `main` e `dev`. Il runner resta `xcode-27`: è l'immagine ospitata da GitHub con Xcode 27.1 predefinito e il simulatore iPhone 17 su iOS 27.0 (`actions/runner-images`, `images/macos/xcode-27-arm64-Readme.md`), gratuita per una repo pubblica. Il minimo di Xcode non è cambiato. `release-candidate-testflight.yml` parte solo a mano e senza chiavi di App Store Connect non può caricare niente.
