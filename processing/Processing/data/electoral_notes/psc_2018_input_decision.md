This accepted frozen-input decision is preserved from the retired repair workflow. Historical generated audit filenames below are documentary; current electoral validation is test/test_inputs.jl.

# PSC 2018 federal-deputy seat audit

## Adjudication

The correct count for the paper's electoral object is **7 PSC seats**.

The external Câmara summary's **8** is a valid initial/provisional 2018 result snapshot. The current TSE candidate file is a later, retotalized result snapshot: Valdevan Noventa's PSC candidacy was invalidated for abuse of economic power, his votes were ordered null, and the Sergipe federal-deputy result was retotalized. The resulting seat is attributed to Márcio Macêdo (PT). This is not a party rename, post-election affiliation lookup, or missing winner-status variant.

For “seats won by election-year parties in the 2018 federal-deputy election,” the pipeline uses the authoritative final electoral result represented in its dated TSE source snapshot. A judicial retotalization changes the legally valid election result itself. It is therefore appropriate to count PSC 7 and PT 56, rather than freeze the election-night proclamation at PSC 8 and PT 55.

## Project derivation

Raw input:

- `data/raw/electionsBR/2018/candidate.csv`
- source generation timestamp in the file: `DT_GERACAO=13/11/2024`
- office: exact normalized `DEPUTADO FEDERAL`
- winner whitelist: exact normalized `ELEITO`, `ELEITO POR QP`, `ELEITO POR MEDIA`, or `ELEITO POR MÉDIA`

Distinct 2018 federal-deputy `DS_SIT_TOT_TURNO` values and row counts:

| Status | Rows | Counted by loader |
|---|---:|---|
| ELEITO POR QP | 387 | yes |
| ELEITO POR MÉDIA | 126 | yes |
| SUPLENTE | 4,586 | no |
| NÃO ELEITO | 2,984 | no |
| #NULO# | 524 | no |

The two present winner statuses are fully covered by the whitelist. There are exactly 513 counted candidate identifiers, all unique.

Aggregation checks:

| Aggregation | Total seats | PSC seats |
|---|---:|---:|
| raw `SG_PARTIDO` | 513 | 7 |
| canonical project party | 513 | 7 |

No 2018 canonicalization rule moves a winner into or out of PSC. `PSC` canonicalizes to `PSC`.

## Exact PSC winners in the retotalized snapshot

| Candidate ID | UF | Candidate | Ballot name | Raw status |
|---|---|---|---|---|
| 90000615998 | GO | GLAUSKSTON BATISTA RIOS | GLAUSTIN DA FOKUS | ELEITO POR QP |
| 130000611044 | MG | EUCLYDES MARCOS PETTERSEN NETO | EUCLYDES PETTERSEN | ELEITO POR QP |
| 170000616969 | PE | ANDRE FERREIRA RODRIGUES | ANDRE FERREIRA | ELEITO POR QP |
| 160000619724 | PR | PAULO EDUARDO LIMA MARTINS | PAULO MARTINS | ELEITO POR QP |
| 190000607836 | RJ | OTONI MOURA DE PAULO JUNIOR | OTONI DE PAULA | ELEITO POR QP |
| 250000615219 | SP | GILBERTO NASCIMENTO SILVA | GILBERTO NASCIMENTO | ELEITO POR MÉDIA |
| 270000610932 | TO | OSIRES RODRIGUES DAMASO | OSIRES DAMASO | ELEITO POR QP |

The complete 513-row audit is `psc_2018_elected_candidates.csv`. It includes candidate identifiers, names, UF, raw and canonical party, candidacy/result status fields, loader inclusion, and raw/canonical aggregate seat counts.

## Identity and chronology of the apparent eighth seat

The Câmara election summary and elected-deputy list identify the apparent eighth PSC deputy as **Valdevan Noventa (SE)**.

| Candidate ID | Candidate | Election-year party | Current raw candidacy status | Current raw result | Loader |
|---|---|---|---|---|---|
| 260000621977 | José Valdevan de Jesus Santos / Valdevan Noventa | PSC | INAPTO | NÃO ELEITO | excluded |
| 260000623622 | Márcio Costa Macêdo / Márcio Macêdo | PT | APTO | ELEITO POR MÉDIA | included |

Evidence chronology:

1. The [Câmara 2018 party summary](https://www.camara.leg.br/internet/agencia/infograficos-html5/TabelasEleicao/index.html) reports PSC 8; its [elected-deputy list](https://www.camara.leg.br/internet/agencia/infograficos-html5/DeputadosEleitos/index.html) includes Valdevan. These pages reflect the initial result snapshot.
2. On 26 September 2019, the [TSE confirmed a provisional decision allowing Valdevan to take office](https://www.tse.jus.br/comunicacao/noticias/2019/Setembro/confirmada-decisao-que-determinou-posse-de-deputado-federal-eleito-por-sergipe). The page explicitly describes him as elected in 2018 while the merits remained under judicial review.
3. On 17 March 2022, the [TSE confirmed cassation and ordered immediate retotalization](https://www.tse.jus.br/comunicacao/noticias/2022/Marco/tse-confirma-cassacao-e-inelegibilidade-do-deputado-federal-jose-valdevan), treating Valdevan's votes as null.
4. The [Câmara's 29 April 2022 notice](https://www.camara.leg.br/noticias/870163-mesa-diretora-declara-a-perda-do-mandato-de-deputado-de-sergipe/) records the loss of mandate and says the Sergipe vacancy was assigned to Márcio Macêdo (PT), who assumed on 27 April.
5. The project's TSE file was generated on 13 November 2024 and incorporates that retotalized outcome.

The corresponding one-seat difference is therefore **PSC −1 / PT +1** relative to the provisional Câmara table. Relative to the existing project pipeline, nothing changes: it already uses the retotalized PSC 7 / PT 56 allocation.

Valdevan's later Câmara label `PL-SE` is post-election affiliation and is irrelevant to his election-year party; the 2018 candidate record correctly identifies PSC. The discrepancy is resolved by result snapshot, not by substituting PL.

## Consequences and regression protection

Because the adjudicated count remains 7:

- no seat-loader or party-alias source code is changed;
- all 2018 party seat differentials and representation ratios remain unchanged;
- ideological interval results remain unchanged;
- only cabinet coalitions to which PSC is newly added change.

Regression coverage in `processing/Processing/test/test_inputs.jl` protects:

- exactly 513 unique counted 2018 candidate IDs;
- raw and canonical totals of 513;
- PSC seat count 7 under both aggregations;
- the exact seven PSC candidate IDs;
- Valdevan excluded and Márcio included with their exact status fields;
- the complete set of distinct status values found in the data.
