## 2026-11-20 01:57 · MacBook-Pro-di-Roberto · e74fdc0d · squadd-multi-agents-ios · ramo: claude/ci-sotto-minuto-c0ba9d
CI delle PR iOS sul Mac: coda di due push insieme misurata, #48 unita con il caso dei 115 s nel corpo
- coda: un solo runner, il secondo di due push contemporanei aspetta il primo, 59 s e 115 s (44641067361, 44641067833)
+ nice sui test: 36 s sul giro caldo, nessun costo misurabile
? secondo runner: due runner non possono condividere gli stati di build, DerivedData tiene percorsi assoluti; ognuno ha i suoi e i simulatori si dividono con un lucchetto
