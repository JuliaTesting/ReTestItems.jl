using Documenter, ReTestItems

makedocs(modules = [ReTestItems], sitename = "ReTestItems.jl")

deploydocs(repo = "github.com/quinnj/ReTestItems.jl.git", push_preview = true)
