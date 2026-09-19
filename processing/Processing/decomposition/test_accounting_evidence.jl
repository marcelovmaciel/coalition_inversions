using Test, CSV, DataFrames, Dates, Processing

const EVIDENCE_ROOT = normpath(joinpath(@__DIR__, "..", "..", "..", "build/results/accounting"))
evidence_csv(path) = CSV.read(joinpath(EVIDENCE_ROOT, path), DataFrame; stringtype=String,
    types=(i,n)->String(n) in ("period", "cabinet_period") ? String : nothing)
function exact_value(x)
    n,d=split(string(x),"//")
    parse(BigInt,n)//parse(BigInt,d)
end
near(a,b) = isapprox(Float64(a), Float64(b); atol=1e-10, rtol=0)

@testset "Independent exact panels and linked decomposition exports" begin
    cells=evidence_csv("raw/party_district_accounting_all_years.csv")
    parties=evidence_csv("raw/party_accounting_all_years.csv")
    districts=evidence_csv("raw/district_accounting_all_years.csv")
    @test allunique(select(cells, :election_year, :electoral_unit, :party))
    @test allunique(select(parties, :election_year, :party))
    @test allunique(select(districts, :election_year, :electoral_unit))
    totals=Dict(2014=>97355354, 2018=>98264190, 2022=>109413508)
    @test Set(parties.election_year)==Set(keys(totals))
    for row in eachrow(cells)
        within=BigInt(row.S_d)*row.v_id//row.V_d
        national=BigInt(row.S)*row.v_id//row.V
        expected=(within, national, row.s_id-within, within-national,
            BigInt(row.S)*(BigInt(row.S_d)//row.S-BigInt(row.V_d)//row.V)*(BigInt(row.v_id)//row.V_d), row.s_id-national)
        for (field,value) in zip((:within_district_quota,:national_quota_contribution,:a_id,:b_id,:b_id_factored,:d_id),expected)
            @test exact_value(row[Symbol(field,"_exact")])==value
            @test near(row[field],value)
        end
    end
    for (year,V) in totals
        ps=filter(r->r.election_year==year,parties); cs=filter(r->r.election_year==year,cells)
        ds=filter(r->r.election_year==year,districts)
        @test Set(zip(cs.electoral_unit,cs.party))==Set((d,p) for d in ds.electoral_unit for p in ps.party)
        @test nrow(ds)==27
        @test all(ps.V.==V) && all(ps.S.==513)
        @test sum(ps.v_i)==sum(ds.V_d)==V
        @test sum(ps.s_i)==sum(ds.S_d)==513
        @test sum(exact_value.(ps.q_i_exact))==513
        for component in (:A_i_exact,:B_i_exact,:d_i_exact)
            @test sum(exact_value.(ps[!,component]))==0
        end
    end
    for row in eachrow(parties)
        cs=filter(r->r.election_year==row.election_year && r.party==row.party,cells)
        q=BigInt(row.S)*row.v_i//row.V
        @test sum(cs.v_id)==row.v_i && sum(cs.s_id)==row.s_i
        @test exact_value(row.q_i_exact)==q
        @test exact_value(row.d_i_exact)==row.s_i-q
        @test near(row.R_i,row.s_i/q)
        for (field,cell) in ((:A_i,:a_id),(:B_i,:b_id),(:d_i,:d_id))
            value=sum(exact_value.(cs[!,Symbol(cell,"_exact")]))
            @test exact_value(row[Symbol(field,"_exact")])==value
            @test near(row[field],value)
        end
    end
    for row in eachrow(districts)
        cs=filter(r->r.election_year==row.election_year && r.electoral_unit==row.electoral_unit,cells)
        @test sum(cs.v_id)==row.V_d && sum(cs.s_id)==row.S_d
        @test sum(exact_value.(cs.a_id_exact))==0
        @test sum(exact_value.(cs.b_id_exact))==row.S_d-BigInt(row.S)*row.V_d//row.V
    end
    registry=evidence_csv("raw/inversion_case_registry.csv")
    cases=evidence_csv("raw/all_inversion_decomposition.csv")
    members=evidence_csv("raw/all_inversion_party_contributions.csv")
    states=evidence_csv("raw/all_inversion_district_contributions.csv")
    linked=evidence_csv("raw/all_inversion_party_district_contributions.csv")
    @test allunique(registry.case_id) && allunique(cases.case_id)
    @test Set(cases.case_id)==Set(registry.case_id)==Set(members.case_id)==Set(states.case_id)==Set(linked.case_id)
    @test allunique(select(members,:case_id,:party))
    @test allunique(select(states,:case_id,:electoral_unit))
    @test allunique(select(linked,:case_id,:party,:electoral_unit))
    source=Dict((r.election_year,r.party,r.electoral_unit)=>r for r in eachrow(cells))
    for row in eachrow(linked)
        original=source[(row.election_year,row.party,row.electoral_unit)]
        @test row.v_id==original.v_id && row.s_id==original.s_id
        for field in (:a_id,:b_id,:d_id)
            @test exact_value(row[Symbol(field,"_exact")])==exact_value(original[Symbol(field,"_exact")])
            @test near(row[field],original[field])
        end
    end
    for row in eachrow(cases)
        reg=only(eachrow(filter(r->r.case_id==row.case_id,registry)))
        mm=filter(r->r.case_id==row.case_id,members); dd=filter(r->r.case_id==row.case_id,states)
        cc=filter(r->r.case_id==row.case_id,linked)
        @test Set(mm.party)==Set(strip.(split(reg.coalition_parties,',')))
        @test Set(zip(cc.party,cc.electoral_unit))==Set((p,d) for p in mm.party for d in dd.electoral_unit)
        @test nrow(dd)==27
        @test sum(mm.v_i)==row.v_C && sum(mm.s_i)==row.s_C
        @test 2*row.v_C < row.V && row.s_C>=257
        q=BigInt(row.S)*row.v_C//row.V
        @test exact_value(row.q_C_exact)==q && exact_value(row.d_C_exact)==row.s_C-q
        @test exact_value(row.A_C_exact)+exact_value(row.B_C_exact)==exact_value(row.d_C_exact)
        for (total,party,state,cell) in ((:A_C,:A_i,:a_Cd,:a_id),(:B_C,:B_i,:b_Cd,:b_id),(:d_C,:d_i,:d_Cd,:d_id))
            value=exact_value(row[Symbol(total,"_exact")])
            @test sum(exact_value.(dd[!,Symbol(state,"_exact")]))==sum(exact_value.(cc[!,Symbol(cell,"_exact")]))==value
            @test near(sum(mm[!,party]),value) && near(row[total],value)
            for m in eachrow(mm)
                selected=filter(c->c.party==m.party,cc)
                @test near(sum(exact_value.(selected[!,Symbol(cell,"_exact")])),m[party])
            end
            for d in eachrow(dd)
                selected=filter(c->c.electoral_unit==d.electoral_unit,cc)
                @test sum(exact_value.(selected[!,Symbol(cell,"_exact")]))==exact_value(d[Symbol(state,"_exact")])
            end
        end
    end
    rankings=evidence_csv("raw/all_inversion_contribution_rankings.csv")
    expected=Dict{Tuple,Float64}()
    for (rows,level,fields) in ((members,"party",(:A_i,:B_i,:d_i)),(states,"district",(:a_Cd,:b_Cd,:d_Cd)),(linked,"party_district",(:a_id,:b_id,:d_id)))
        for row in eachrow(rows),field in fields
            expected[(row.case_id,level,string(field),level=="district" ? "" : row.party,level=="party" ? "" : row.electoral_unit)]=row[field]
        end
    end
    ranking_keys=[(r.case_id,r.aggregation_level,r.component,coalesce(r.party,""),coalesce(r.electoral_unit,"")) for r in eachrow(rankings)]
    @test allunique(ranking_keys) && Set(ranking_keys)==Set(Base.keys(expected))
    @test all(near(r.value,expected[k]) for (r,k) in zip(eachrow(rankings),ranking_keys))
    for group in groupby(rankings,[:case_id,:aggregation_level,:component])
        indices=collect(1:nrow(group))
        descending=sort(indices;by=i->(-group.value[i],group.unit_label[i]))
        ascending=sort(indices;by=i->(group.value[i],group.unit_label[i]))
        absolute=sort(indices;by=i->(-abs(group.value[i]),-group.value[i],group.unit_label[i]))
        for (order,field) in ((descending,:descending_rank),(ascending,:ascending_rank),(absolute,:absolute_rank))
            @test group[order,field]==indices
        end
        for (order,field,predicate) in ((descending,:positive_rank,>(0)),(ascending,:negative_rank,<(0)))
            selected=filter(i->predicate(group.value[i]),order)
            @test group[selected,field]==collect(1:length(selected))
            @test all(ismissing(group[i,field]) for i in indices if !predicate(group.value[i]))
        end
        @test all(r.value_sign==(r.value>0 ? "positive" : r.value<0 ? "negative" : "zero") for r in eachrow(group))
    end
end
