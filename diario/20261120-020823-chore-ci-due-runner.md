## 2026-11-20 02:08 · MacBook-Pro-di-Roberto · e74fdc0d · squadd-multi-agents-ios · ramo: chore/ci-due-runner
Secondo runner della CI delle PR iOS sul Mac, con un terzo simulatore e uno condiviso
+ ci/pr_sims.py: il simulatore condiviso si presta solo se l'altro runner non ha un Runner.Worker, sotto lucchetto
- prima versione: il runner 2 prendeva un simulatore usato dai giri del vecchio workflow sul runner 1; ora ha il suo
- unione della #48: cinque figlie hanno unito dev insieme e il solo runner 1 le ha messe in fila fino a 224 s
+ memoria: due build in parallelo senza swap, libera minima 44%
