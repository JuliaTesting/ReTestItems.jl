using Documenter, Example

makedocs(modules = [Example], sitename = "Example.jl")

deploydocs(repo = "github.com/quinnj/Example.jl.git", push_preview = true)
