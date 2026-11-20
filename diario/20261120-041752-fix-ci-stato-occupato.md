## 2026-11-20 04:17 · MacBook-Pro-di-Roberto · e74fdc0d · squadd-multi-agents-ios · ramo: fix/ci-stato-occupato
CI iOS: anche build e annullamento a metà copia coperti (ci/pr_group.py), su richiesta del giudice della #74
+ ci/pr_group.py: build e test in un gruppo di processi registrato, con l'ora di avvio contro il riuso dei pid e la scrittura atomica; pr_state.py ferma i gruppi rimasti all'avvio del job dopo
- prova reale di annullamento: lo script che cercava xcodebuild orfani per nome di cartella ha preso il build del job successivo; serve l'ora d'avvio contro l'ora dell'annullamento per non confonderli
- git reset soft: fatto mentre lo script aveva già spinto un commit vuoto; riallineato con reset soft sul remoto, niente force push
? rami delle figlie senza la #74: usano il pr_state vecchio, e finché non uniscono dev un annullamento a metà copia li rompe ancora
