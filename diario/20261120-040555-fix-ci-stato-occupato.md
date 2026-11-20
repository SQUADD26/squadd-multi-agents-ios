## 2026-11-20 04:05 · MacBook-Pro-di-Roberto · e74fdc0d · squadd-multi-agents-ios · ramo: fix/ci-stato-occupato
CI iOS: stato di build occupato e test di un job annullato non rompono più i giri delle PR
- RUNNER_TRACKING_ID vuoto: un job annullato lascia vivi bash e xcodebuild del passo test, che riscrivono DerivedData dopo il parcheggio (Errno 66 su due runner); ora pr_sims.py li mette in un gruppo registrato e pr_state.py lo ferma al job dopo
+ pr_state.py: ogni destinazione già presente si sposta via e si cancella in background; uno stato senza src/.git non si riprende
- doppione: una figlia dell'altra madre ha aperto la #73 sullo stesso guasto mentre ci lavoravo; i suoi giri spostavano gli stati sotto di me, quindi riparazioni a mano solo dopo aver scelto una correzione
? build annullata: un xcodebuild di build orfano resta possibile (il passo build non è nel gruppo); non rompe più il giro ma può scrivere nella DerivedData del ramo dopo
