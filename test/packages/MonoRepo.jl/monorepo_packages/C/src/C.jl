module C

using D

greet() = (print("From C: "); D.greet())
test() = true

end # module
