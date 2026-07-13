# ZCKM3_ALV — Estratificação de custo do Material Ledger em ALV

Report ABAP que reproduz a visão de elementos de custo da transação **CKM3N**
em massa (multi-material / multi-lote), em ALV (`CL_SALV_TABLE`).

## Fonte de dados

| Origem | Uso |
|---|---|
| `CKMLHD` + `MARA` + `MAKT` | Materiais do centro com nº de cálculo (KALNR) |
| `MLCCS_READ_PR` | Split de preço do ML (resolve `CKMLKEPH`/`CKMLPRKEKO`) |
| `CKMLCR` | Unidade de preço (PEINH) por período/moeda |
| `TCKH1` | Textos dos elementos de custo do esquema (`ELEHK`) |

## Tela de seleção

- Centro (obrigatório), range de materiais e tipo de avaliação
- Período/ano (default = mês corrente)
- Tipo de moeda (`10` = moeda da empresa), tipo de preço (`V` periódico / `S` standard)
- Esquema de elementos (`P_ELEHK`, default `01` — confirmar na OKTZ)
- Checkbox para exibir elementos zerados

## Saída

Uma linha por Material × Elemento de custo com colunas **Total / Fixo / Variável**,
subtotal por material (fecha com o preço unitário, como a linha de total da CKM3N).
Valores por unidade de preço (PEINH), mesmo referencial da CKM3N.

## Pontos de atenção na instalação

- As tabelas do FM (`IT_INKEPH`/`OT_PRKEPH`) estão tipadas como
  `CKMLPRKEPH`/`CKMLPRKEKO`; se a release usar `MLINKEPH`/`MLPRKEPH`,
  basta trocar a tipagem — a lógica não muda.
- A moeda é derivada de `T001` (correto para CURTP 10); para 30/31/32
  ajustar a determinação.
- Textos de seleção (`TEXT-001`, `TEXT-002`) devem ser mantidos nos
  elementos de texto do programa (SE38 → Elementos de texto).
