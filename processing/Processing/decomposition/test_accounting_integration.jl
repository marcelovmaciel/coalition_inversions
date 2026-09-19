using Test, DataFrames
include(joinpath(@__DIR__, "AccountingIntegration.jl"))
using .AccountingIntegration

@testset "Concentration, district weights and signed table quantities" begin
    gross=evidence_csv("raw/accounting_gross_component_concentration.csv")
    @test Set(gross.aggregation_level)==Set(["party","state"])
    @test Set(gross.component)==Set(["A","B","d"])
    for row in eachrow(gross)
        @test exact_value(row.gross_positive_exact)-exact_value(row.gross_negative_magnitude_exact)==exact_value(row.net_component_exact)
        @test 0<=row.cancellation_share<=1 && 0<=row.absolute_hhi<=1
    end
    anatomy=evidence_csv("figure_data/accounting_state_weighting_anatomy.csv")
    for row in eachrow(anatomy)
        @test exact_value(row.b_positive_eight_seat_exact)+exact_value(row.b_positive_other_exact)-exact_value(row.b_negative_sp_exact)-exact_value(row.b_negative_other_exact)==exact_value(row.B_C_exact)
        @test row.b_positive_eight_seat>=0 && row.b_negative_sp>=0
    end
    weights=evidence_csv("figure_data/accounting_district_electoral_weight.csv")
    @test allunique(select(weights,:election_year,:electoral_unit)) && nrow(weights)==81
    for row in eachrow(weights)
        expected=(BigInt(row.S_d)//row.V_d)/(BigInt(row.S)//row.V)
        @test exact_value(row.district_electoral_weight_exact)==expected
        @test near(row.district_electoral_weight,expected)
    end
    for g in groupby(weights,:election_year)
        @test g.electoral_unit[argmin(g.district_electoral_weight)]=="SP"
        @test g.electoral_unit[argmax(g.district_electoral_weight)]=="RR"
    end
    geography=evidence_csv("raw/accounting_selected_party_geography.csv")
    for row in eachrow(geography)
        @test exact_value(row.A_i_exact)+exact_value(row.B_i_exact)==exact_value(row.d_i_exact)
        @test exact_value(row.gross_positive_B_exact)-exact_value(row.gross_negative_B_magnitude_exact)==exact_value(row.B_i_exact)
    end
    contributions=evidence_csv("raw/coalition_party_contributions.csv")
    pp_pl=only(eachrow(evidence_csv("raw/coalition_party_contribution_named_aggregates.csv")))
    selected=filter(r->r.case_identifier=="ideological/2022/17-23" && r.party in ("PP","PL"),contributions)
    @test Set(selected.party)==Set(["PP","PL"])
    @test exact_value(pp_pl.combined_d_i_exact)==sum(exact_value.(selected.party_differential_d_i_exact))
    @test exact_value(pp_pl.share_of_d_C_exact)==exact_value(pp_pl.combined_d_i_exact)/exact_value(pp_pl.d_C_exact)
    @test round(pp_pl.share_of_d_C_pct;digits=2)==77.56
    for row in eachrow(evidence_csv("tables/table_coalition_party_contributions.csv"))
        d=AccountingIntegration.party_contribution_closure_preserving_display(row.d_C,row.gross_positive_party_contribution)
        milli(x)=parse(Int,replace(x,"."=>""))
        @test milli(d.gross_positive)-milli(d.gross_negative)==milli(d.d_C)
    end
    states=evidence_csv("raw/accounting_focal_state_contributions.csv")
    for row in eachrow(AccountingIntegration.cabinet_district_concentration(states))
        actual=filter(r->r.case_id==row.case_id,states)
        @test row.positive_count+row.negative_count<=27
        @test exact_value(row.positive_sum_exact)+exact_value(row.negative_sum_exact)==sum(exact_value.(actual.a_Cd_exact))
    end
end
