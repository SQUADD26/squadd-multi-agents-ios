## 2026-11-19 23:51 · claude-sandbox · 1f6ef8e2 · squadd-multi-agents-ios · ramo: issue/28-impostazioni
Ticket 28, secondo giro dopo il NO del giudice: lettura diretta dal desktop, last4 trattenuto dal companion, editor dopo un conflitto
- prova 3: il registro del client sul telefono non basta, il giudice vuole una GET fatta al desktop senza il telefono; ora prova3.sh legge il desktop con curl prima e dopo, nei due versi
+ companion openmausbot: last4 aggiunto a WITHHELD_KEYS in wire.ts (PR openmausbot 112, unita), fixture settings-config.json registrata di nuovo senza last4
+ editor memoria: dopo un 409 i campi prendono la versione del computer, così il secondo Salva non sovrascrive alla cieca
