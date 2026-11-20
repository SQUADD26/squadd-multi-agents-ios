## 2026-11-19 18:41 · claude-sandbox · 71a4dc73 · squadd-multi-agents-ios · ramo: issue/17-thread-squadd
Thread di Squadd sull'iPhone (#17): crea, rinomina, fissa, archivia, cancella, cerca ed esporta, nell'ordine del desktop, provati contro un companion isolato
+ ordine dei thread: il desktop usa orderedThreadList, fissati prima e poi lastThreadOrderAt o createdAt; il telefono lo copia in SquaddTask.desktopOrder
+ registro sul companion: swift 6.1.2 per Debian compila il client vero nella sandbox con sysroot dai .deb di libc6-dev, shim libncurses e -use-ld=lld
- pr-ci.yml: non parte più sulle PR (PR 46); build e test girano su un ramo foto con un workflow mio, come ha fatto la PR 38
? companion: i campi pinned, archivedAt e projectId spariscono quando sono vuoti, mai null; i modelli li leggono come opzionali
