# District electoral-weight diagnostic

## Recommendation

**Appendix figure.** The plot is useful as a measurement diagnostic, but it is
not strong enough or sufficiently coalition-specific to justify a main-text
figure. It should replace the current categorical gross-state anatomy figure as
the visual evidence on district weighting, but it should be placed in the
accounting-diagnostics appendix beside the complete state-level contribution
outputs. The main text should retain only the compact sentence proposed below.

The diagnostic plot was not inserted into the manuscript.

## Construction and validation

The plotted quantity is computed for every state and election year as

\[
w_d=\frac{S_d/V_d}{513/V}
    =\frac{S_d/513}{V_d/V}.
\]

The Julia accounting layer derives each value in exact rational arithmetic and
verifies that the rate-ratio and share-ratio definitions agree. It uses the same
valid federal-deputy vote definition as the manuscript pipeline:

- 2014: nominal votes plus party-label votes;
- 2018 and 2022: valid nominal votes plus valid party-label votes.

The resulting national denominators are 97,355,354 (2014), 98,264,190 (2018),
and 109,413,508 (2022). District vote totals reproduce each national
denominator, district seats reproduce 513, and the seat totals are independently
checked against each election year's `seats.csv` input.

The seat allocation does **not** vary across the three elections in the
underlying data. In every year, the mean district magnitude is 19, the median is
10, eleven districts have 8 seats, and São Paulo is the unique maximum at 70
seats.

## What the plot shows

| Year | São Paulo \(w_d\) | 8-seat range | Pearson \(r\) | Spearman \(\rho\) |
|---:|---:|---:|---:|---:|
| 2014 | 0.625 | 0.915–6.376 | -0.319 | -0.475 |
| 2018 | 0.635 | 0.866–5.661 | -0.331 | -0.502 |
| 2022 | 0.640 | 0.863–5.849 | -0.319 | -0.447 |

The relationship is remarkably stable across years. It is best described as a
moderate inverse tendency with strong dispersion at low magnitude, not as a
tight magnitude–weight relationship. The logarithmic vertical scale is
appropriate because \(w_d\) is a ratio centered on 1.

### Answers to the requested questions

a. **Does it reveal a strong and interpretable pattern?** It reveals an
interpretable but only moderate inverse pattern. The rank correlation is about
-0.45 to -0.50, while the linear correlation is about -0.32. Most of the
dispersion is concentrated at the smallest magnitude.

b. **Is São Paulo clearly extreme?** Yes. It is the unique 70-seat district and
the lowest-weight district in every election, at 0.625–0.640. It is an endpoint
of the distribution, not a representative negative-weight comparison group.

c. **Do the eight-seat districts form a visible cluster?** They form a visible
vertical column at magnitude 8, but not a homogeneous weight cluster. Their
weights span 0.863–6.376 across the observed elections; two are below 1 in 2014
and 2018, and three are below 1 in 2022. Small magnitude is therefore not by
itself sufficient for above-average electoral weight.

d. **Does it justify a main-text figure?** No. The plot clarifies the structural
distribution of district weights, but it does not show coalition vote geography
or the coalition-specific \(b_{Cd}\) contributions that determine \(B_C\).

e. **Where should it go, and what should it replace?** Put it in the
accounting-diagnostics appendix, adjacent to the complete state contribution
outputs. It should replace the current main-text categorical state-anatomy
figure as the paper's visual diagnostic of district weighting; it should not be
added as an eighth main-text figure.

f. **Compact replacement prose:** “District electoral weight is only moderately
related to magnitude: São Paulo is the unique 70-seat, lowest-weight district in
all three elections, whereas the eleven eight-seat districts span values below
the national average to more than five times it.”

## Reproducible outputs

- Data generator: `processing/Processing/decomposition/AccountingIntegration.jl`
- Plot and summary generator: `writing/make_district_electoral_weight_diagnostic.py`
- Exact-audited figure data:
  `build/results/accounting/figure_data/accounting_district_electoral_weight.csv`
- Plot: `build/assets/district_electoral_weight_by_magnitude.pdf`
- Machine-readable summary:
  `build/results/accounting/diagnostics/district_electoral_weight_summary.csv`
- Focused tests:
  `processing/Processing/decomposition/test_accounting_integration.jl` and
  the frozen compact regressions in `processing/tests/test_empirical_results.py`
