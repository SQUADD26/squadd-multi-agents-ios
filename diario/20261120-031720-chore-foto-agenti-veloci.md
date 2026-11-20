## 2026-11-20 03:17 · claude-sandbox · 96334640 · squadd-multi-agents-ios · ramo: chore/foto-agenti-veloci
Foto degli agenti di squadd-multi-agents-ios: tutte e 7 tenute, in tre classi sotto i 3 s ciascuna, foto identiche
+ giudice: togliere foto per stare sotto una soglia di tempo e' togliere a Roberto; si dividono in classi, che PR iOS manda sui due simulatori
- compilazione: un metodo async non privato con closure in una sottoclasse di XCTestCase finisce nel ponte ObjC ("escaping local function captures non-escaping value"); tre giri persi prima di farlo fileprivate
+ pr_tests: la classe base deve chiamarsi ...TestCase perche' il CLASS regex trovi le sottoclassi; ogni sottoclasse nomina FOTO_DIR e la vista nel commento per essere scelta quando cambia la schermata
