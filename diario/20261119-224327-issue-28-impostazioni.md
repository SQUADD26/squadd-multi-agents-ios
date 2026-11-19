## 2026-11-19 22:43 · claude-sandbox · 1f6ef8e2 · squadd-multi-agents-ios · ramo: issue/28-impostazioni
Impostazioni Squadd sul telefono, ticket 28: engine con aggiornamento di Claude, stato chiavi, MCP e skill per agente, memoria del team, provate contro un companion openmausbot isolato
+ prova dal vivo senza Mac: il client Swift di Networking/Squadd compila su Linux con swift 6.1 e gira contro il companion della sandbox; ha confermato in un minuto che il merge di dev non rompeva nulla
+ chiavi API: il companion rifiuta PUT /api/config con 403, quindi dal telefono solo lo stato sì/no; GET /api/config porta last4 e il modello lo scarta
- workflow di prova: Xcode 27 scrive «Test Case» con la C maiuscola e non stampa «Executed», il filtro delle righe rosse cadeva muto, e i cloni paralleli del simulatore andavano in timeout; ora -parallel-testing-enabled NO e grep su «Test Case .*failed|error:»
- pagina Chiavi: LabeledContent con un Label come valore dava righe altissime, visto solo in foto; corretto con SettingsStatusPill come le altre pagine
? runner condiviso: le corse «Foto simulatore» duplicate sui rami foto vanno annullate a mano, altrimenti occupano la coda
