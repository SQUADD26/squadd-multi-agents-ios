---
status: accepted
---

# La v1 parla solo con Squadd; Hermes e webui spenti da un flag, poi tolti

L'app nasce per Squadd Multi-Agents, non per chi ha un host Hermes. Tenere vivi i backend Hermes e webui vuol dire portarsi Kanban, Git, Workspace, MoveToHermes, Insights e il login OAuth di Hermes, che parlano solo con quei server. Toglierli subito alleggerisce il codice ma rende difficile ogni merge da Hermex upstream, da cui arrivano ancora correzioni utili alla chat e alla UI.

Decidiamo: nella v1 un flag di build spegne i tipi di server Hermes e webui. Con il flag spento l'app non offre di aggiungerli, non mostra le schermate che vivono solo lì (Kanban, Workspace, Git, MoveToHermes, import CLI, Thinking e Fast, rewind, checkpoint, subagenti, header personalizzati, widget dei limiti) e non manda dati a servizi di Hermex (hermex-stats, relay hermex-push). Il codice resta compilato e coperto dai suoi test finché serve a ricevere i merge; lo togliamo in un passo dopo la v1, quando i merge da upstream non valgono più il costo.

## Conseguenze

- Una schermata Hermes che si vede con il flag spento è un bug della v1.
- Il flag è uno solo e si legge in un posto solo: niente controlli sparsi sul nome del server.
- La rimozione del codice spento è un lavoro a sé, fuori dalla v1.
