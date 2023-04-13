module TestProjectFile

# Make sure we have a package dependency
using Example

export foo

foo() = Example.domath(1) + 1

end
