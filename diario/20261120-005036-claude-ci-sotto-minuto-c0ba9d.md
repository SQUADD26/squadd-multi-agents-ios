## 2026-11-20 00:50 · MacBook-Pro-di-Roberto · e74fdc0d · squadd-multi-agents-ios · ramo: claude/ci-sotto-minuto-c0ba9d
CI delle PR iOS su runner del Mac di Roberto: giro caldo 36-40 s dal push al verde, primo giro di una PR nuova 70-80 s
+ ci/pr_state.py: copia di lavoro e DerivedData per PR, clone APFS per una PR nuova; senza, il cambio fra PR ricompilava tutto
+ pr-ios.yml: due simulatori sempre accesi, classi divise per i secondi dell'ultimo giro (ci/pr_split.py)
- emissione del modulo dell'app: 18-20 s su un core a ogni cambio Swift, tanta parte nelle macro @Observable; nessuna impostazione di Xcode la accorcia
- SWIFT_USE_INTEGRATED_DRIVER=NO con -no-emit-module-separately: build da 4 s ma modulo vecchio, un test rotto passava; scartato
? foto con attese fisse 1-2 s per scatto: tolte in una PR separata; lo scatto a fotogramma fermo deve usare Task.sleep, RunLoop blocca i caricamenti async
