## 2026-11-20 00:11 · claude-sandbox · 71a4dc73 · squadd-multi-agents-ios · ramo: issue/17-thread-squadd
Thread Squadd sul telefono (#17), terzo giro: i quattro punti del giudice, merge della CI nuova di dev
+ ricerca: un errore non diventa più «No Results»; restano gli ultimi risultati e compare un toast, con test e riga rossa
+ foto: la home vera parte da un passo (SquaddHomeStart) e mostra ricerca, archiviati, conferma, rinomina ed export con i suoi handler
- foto export: il foglio di condivisione si disegna in un altro processo e nella foto non c'è; lo prova un'asserzione sul controller presentato
- SquaddCompanionClient: dev ha portato un call(_:_:body:) pubblico che rendeva ambiguo il mio privato; tenuto uno solo, con body [String: Any]
? sugarThread: le costanti stanno nella classe dei test del modello, non in quella delle foto; il primo giro di CI nuova è caduto lì
