## 2026-11-20 01:45 · MacBook-Pro-di-Roberto · e74fdc0d · squadd-multi-agents-ios · ramo: claude/ci-sotto-minuto-c0ba9d
CI delle PR iOS sul Mac: primi giri di un ramo nuovo da 79 s a 42-63 s, giri caldi 36-40 s
+ ci/pr_state.py: il costo pesava uguale file dell'app e di test, e un ramo partiva da uno stato con un file dell'app da ricompilare; ora un file dell'app vale 100, uno di test 1
+ ci/pr_state.py: clonefile(2) sull'intera cartella copia DerivedData in 0,1 s contro 1,9 s di cp -c, date dei file conservate
+ build dopo un clone: il sistema di build legge l'inode, la prima build a vuoto rifaceva asset e copie (7,9 s contro 1,8); il ramo nuovo prende i file originali e la base tiene il clone, ma la base ripaga ~5 s al ramo nuovo dopo
+ pr-ios.yml: ogni passo costa ~0,35 s di avvio e ~0,5 s di log a fine job; da 6 a 3 passi con gruppi nel log; cache dell'azione di upload nel .env del runner
- misure: ogni ramo di misura parte dalla #48 e porta le sue 4 classi foto (~15 s), che gonfiano tutti i primi giri; misurare dopo l'unione con PR vere
? build: emissione del modulo dell'app 17,5 s su un core per ogni cambio Swift, codice dell'app (macro @Observable, corpi SwiftUI): il pavimento resta lì
